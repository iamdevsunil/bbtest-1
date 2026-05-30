/* eslint-disable no-console */
// scripts/deploy.js — Full deploy + verify pipeline (DEVELOPMENT variant)
//
// Run: npm run deploy:public
//      = npx hardhat run scripts/deploy.js --network bsc
//
// What this does:
//   1. Deploys tDT (test USDT, dev only)
//   2. Deploys 6 libraries
//   3. Deploys tBB token
//   4. Creates PancakeSwap pair (with retry on failure)
//   5. Deploys BigBullProtocol (library-linked)
//   6. Deploys VaultReader (RewardLib-linked)
//   7. Whitelists protocol + router + setStakingContract
//   8. Saves complete dump to deployments/bsc-<TIMESTAMP>/
//   9. Auto-verifies ALL contracts on BscScan
//
// Gas needed: ~0.15 BNB. Keep 0.5 BNB in deployer to be safe.

const hre = require("hardhat");
const { ethers, network, run } = hre;
const { saveDeployment } = require("./save-deployment");

const CFG = {
  ROUTER:  "0x10ED43C718714eb63d5aA57B78B54704E256024E",  // PancakeSwap V2 Router
  FACTORY: "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73",  // PancakeSwap V2 Factory

  TOKEN_NAME:    "Big Bull Test",
  TOKEN_SYMBOL:  "tBB",
  TOKEN_SUPPLY:  110000000n,
  TDT_INITIAL_SUPPLY: 10000000n,

  // ⚠️ UPDATE THESE — your wallets:
  GENESIS:       "0x6b5886292DD1B7E33C77eD635cC281EcCFD122eA",
  PROTOCOL_FEE:  "0x3732A7Ebe2cE8fcb87D0653A7368a328588da65B",
  TREASURY:      "0x560A9f5eaea1e86f2b491432a0A1BA8E005a688a",
  COLD_TREASURY: "0xcEc566B96B81dFD18BcDEeCa13910CC5EcAeb910",
  GUARDIANS: [
    "0x494172062cEd0039289a4e5b099062309fbcF2d0",
    "0xC74e2CFb60982E829b59D90F03052c5372Eb3018",
    "0x0d55866E62A90856B807D63c9B2B8488705d56CB",
  ],
};

// ─── Helper: retry tx with backoff ─────────────────────────────────────────
async function retry(fn, name, attempts = 3) {
  for (let i = 1; i <= attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      console.log(`  ⚠️ ${name} attempt ${i}/${attempts} failed:`, e.message?.slice(0, 80) || e);
      if (i === attempts) throw e;
      await new Promise(r => setTimeout(r, 5000 * i));
    }
  }
}

async function deployLib(name, libraries) {
  const f = await ethers.getContractFactory(name, libraries ? { libraries } : undefined);
  const c = await f.deploy();
  await c.waitForDeployment();
  const a = await c.getAddress();
  console.log(`  ${name.padEnd(18)} -> ${a}`);
  return a;
}

async function verifyContract(addr, name, args = [], libraries = undefined) {
  try {
    console.log(`\n   Verifying ${name} @ ${addr} ...`);
    await run("verify:verify", {
      address: addr,
      constructorArguments: args,
      libraries,
    });
    console.log(`   ✅ ${name} verified`);
  } catch (e) {
    const msg = e.message?.toString() || '';
    if (msg.includes('Already Verified') || msg.includes('already verified')) {
      console.log(`   ✓ ${name} already verified`);
    } else {
      console.log(`   ⚠️ ${name} verification failed:`, msg.split('\n')[0]?.slice(0, 100));
      console.log(`     (Manual verify: npm run verify:single -- ${addr})`);
    }
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  console.log(`Network : ${network.name}`);
  console.log(`Deployer: ${deployerAddr}`);
  console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployerAddr))} BNB\n`);

  // 1) tDT
  console.log("1) BBP_TestUSDT (tDT):");
  const TUSDT = await ethers.getContractFactory("BBP_TestUSDT");
  const tdt = await TUSDT.deploy(CFG.TDT_INITIAL_SUPPLY);
  await tdt.waitForDeployment();
  const tdtAddr = await tdt.getAddress();
  console.log(`   tDT -> ${tdtAddr}`);

  // 2) Libraries
  console.log("\n2) Libraries:");
  const RewardLib       = await deployLib("RewardLib");
  const RewardClaimLib  = await deployLib("RewardClaimLib");
  const DexLib          = await deployLib("DexLib");
  const DistributionLib = await deployLib("DistributionLib");
  const TeamTierLib     = await deployLib("TeamTierLib", { DistributionLib });
  const AnomalyMonitor  = await deployLib("AnomalyMonitor");

  // 3) Token
  console.log("\n3) BigBullToken (tBB):");
  const Token = await ethers.getContractFactory("BigBullToken");
  const token = await Token.deploy(CFG.TOKEN_NAME, CFG.TOKEN_SYMBOL, CFG.TOKEN_SUPPLY, tdtAddr);
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();
  console.log(`   tBB -> ${tokenAddr}`);

  // 4) Pair — with retry on gas-spike failure
  console.log("\n4) Pair (tBB/tDT on PancakeSwap V2):");
  const factory = await ethers.getContractAt(
    ["function createPair(address,address) external returns (address)",
     "function getPair(address,address) external view returns (address)"],
    CFG.FACTORY
  );

  let pair = await factory.getPair(tokenAddr, tdtAddr);
  if (pair === ethers.ZeroAddress) {
    await retry(async () => {
      const tx = await factory.createPair(tokenAddr, tdtAddr, { gasLimit: 5_000_000n });
      console.log(`   createPair tx: ${tx.hash}`);
      await tx.wait();
    }, "createPair");

    // Re-fetch with delay
    await new Promise(r => setTimeout(r, 3000));
    pair = await factory.getPair(tokenAddr, tdtAddr);
  }

  if (pair === ethers.ZeroAddress) {
    throw new Error("❌ Pair still zero after createPair — check factory health");
  }
  console.log(`   Pair -> ${pair}`);

  // 5) Protocol
  console.log("\n5) BigBullProtocol:");
  const Protocol = await ethers.getContractFactory("BigBullProtocol", {
    libraries: { RewardLib, RewardClaimLib, DexLib, DistributionLib, TeamTierLib, AnomalyMonitor },
  });
  const walletsTuple = [pair, tokenAddr, tdtAddr, CFG.ROUTER, CFG.GENESIS, CFG.PROTOCOL_FEE, CFG.TREASURY, CFG.COLD_TREASURY];
  const protocol = await Protocol.deploy(walletsTuple, CFG.GUARDIANS);
  await protocol.waitForDeployment();
  const protocolAddr = await protocol.getAddress();
  console.log(`   Protocol -> ${protocolAddr}`);

  // 6) Reader
  console.log("\n6) VaultReader:");
  const Reader = await ethers.getContractFactory("VaultReader", { libraries: { RewardLib } });
  const reader = await Reader.deploy(protocolAddr);
  await reader.waitForDeployment();
  const readerAddr = await reader.getAddress();
  console.log(`   Reader -> ${readerAddr}`);

  // 7) Whitelist + staking
  console.log("\n7) Whitelist + setStakingContract:");
  await (await token.setWhitelistBatch([protocolAddr, CFG.ROUTER], true)).wait();
  await (await token.setStakingContract(protocolAddr)).wait();
  console.log("   ✅ Done");

  console.log("\n──────────────────────────────────────────────");
  console.log("✅ DEPLOYMENT COMPLETE");
  console.log("──────────────────────────────────────────────");
  console.log(`tDT      : ${tdtAddr}`);
  console.log(`tBB      : ${tokenAddr}`);
  console.log(`Pair     : ${pair}`);
  console.log(`Protocol : ${protocolAddr}`);
  console.log(`Reader   : ${readerAddr}`);
  console.log("──────────────────────────────────────────────\n");

  // 8) Save dump
  console.log("8) Saving deployment dump...");
  const addresses = {
    _network: network.name,
    _chainId: 56,
    _deployer: deployerAddr,
    _deployedAt: new Date().toISOString(),
    _tokenName: CFG.TOKEN_NAME,
    _tokenSymbol: CFG.TOKEN_SYMBOL,
    _tokenSupply: CFG.TOKEN_SUPPLY.toString(),
    _usdt: tdtAddr,
    _protocolConstructorArgs: [walletsTuple, CFG.GUARDIANS],
    RewardLib, RewardClaimLib, DexLib, DistributionLib, TeamTierLib, AnomalyMonitor,
    TestUSDT: tdtAddr, Token: tokenAddr, Pair: pair, Protocol: protocolAddr, Reader: readerAddr,
  };
  await saveDeployment(network.name, addresses);

  // 9) Auto-verify everything
  console.log("\n9) Auto-verifying contracts on BscScan...");
  console.log("   (Waiting 30s for BscScan to index...)");
  await new Promise(r => setTimeout(r, 30000));

  // Libraries (no constructor args)
  await verifyContract(RewardLib, "RewardLib");
  await verifyContract(RewardClaimLib, "RewardClaimLib");
  await verifyContract(DexLib, "DexLib");
  await verifyContract(DistributionLib, "DistributionLib");
  await verifyContract(TeamTierLib, "TeamTierLib", [], { DistributionLib });
  await verifyContract(AnomalyMonitor, "AnomalyMonitor");

  // tDT
  await verifyContract(tdtAddr, "BBP_TestUSDT", [CFG.TDT_INITIAL_SUPPLY]);

  // tBB
  await verifyContract(tokenAddr, "BigBullToken", [CFG.TOKEN_NAME, CFG.TOKEN_SYMBOL, CFG.TOKEN_SUPPLY, tdtAddr]);

  // Protocol (with libraries)
  await verifyContract(protocolAddr, "BigBullProtocol", [walletsTuple, CFG.GUARDIANS], {
    RewardLib, RewardClaimLib, DexLib, DistributionLib, TeamTierLib, AnomalyMonitor,
  });

  // Reader (only RewardLib)
  await verifyContract(readerAddr, "VaultReader", [protocolAddr], { RewardLib });

  console.log("\n──────────────────────────────────────────────");
  console.log("🎉 ALL DONE!");
  console.log("──────────────────────────────────────────────");
  console.log("BscScan links:");
  console.log(`  tDT      : https://bscscan.com/address/${tdtAddr}#code`);
  console.log(`  tBB      : https://bscscan.com/address/${tokenAddr}#code`);
  console.log(`  Pair     : https://bscscan.com/address/${pair}`);
  console.log(`  Protocol : https://bscscan.com/address/${protocolAddr}#code`);
  console.log(`  Reader   : https://bscscan.com/address/${readerAddr}#code`);
  console.log("──────────────────────────────────────────────\n");

  console.log("NEXT STEPS — Step 10 finalization (in hardhat console):");
  console.log(`  npx hardhat console --network bsc`);
  console.log(`  // see docs/DEPLOYMENT_GUIDE.md Step 10`);
}

main().catch((e) => { console.error(e); process.exit(1); });
