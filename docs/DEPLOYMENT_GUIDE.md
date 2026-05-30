# Deployment Guide — BigBull V4 Development

Complete step-by-step guide for testing on BSC mainnet with tDT/tBB.

## Step 1 — Setup environment

```bash
cd bigbull-v4-Development
npm install
cp .env.example .env
nano .env    # fill PRIVATE_KEY + ETHERSCAN_API_KEY
```

## Step 2 — Check deployer balance

```bash
node -e "
const { ethers } = require('ethers');
require('dotenv').config();
const p = new ethers.JsonRpcProvider('https://bsc-dataseed.binance.org');
const w = new ethers.Wallet(process.env.PRIVATE_KEY, p);
w.getAddress().then(a => p.getBalance(a).then(b => console.log(a, ':', ethers.formatEther(b), 'BNB')));
"
```

Need ≥ **0.15 BNB**. If short, top up before continuing.

## Step 3 — Compile (sanity check)

```bash
npm run compile
```

Should show:
```
Compiled 22 Solidity files successfully
```

## Step 4 — Deploy

```bash
npm run deploy:public
```

This takes ~5-8 minutes and deploys 9 contracts plus auto-verifies them all.

Expected output ends with:
```
🎉 ALL DONE!
BscScan links:
  tDT      : https://bscscan.com/address/0x...#code
  tBB      : https://bscscan.com/address/0x...#code
  Pair     : https://bscscan.com/address/0x...
  Protocol : https://bscscan.com/address/0x...#code
  Reader   : https://bscscan.com/address/0x...#code
```

## Step 5 — Note addresses

Find them in `deployments/bsc-<timestamp>/addresses.json`. Save these:
- tDT, tBB, Pair, Protocol, Reader

## Step 6-9 — Skipped (handled by deploy.js automatically)

These were old manual steps. Now auto-done:
- Library linking ✅
- Verification ✅
- Whitelist + setStakingContract ✅

## Step 10 — Finalize launch (run once)

```bash
npx hardhat console --network bsc
```

Then in console:

```javascript
// Load deployment
const fs = require("fs");
const path = require("path");
const dumps = fs.readdirSync("./deployments").filter(d => d.startsWith("bsc-")).sort();
const latest = dumps[dumps.length - 1];
const addr = require(`./deployments/${latest}/addresses.json`);
console.log("Using deployment:", latest);

const [signer] = await ethers.getSigners();
const me = await signer.getAddress();

const token = await ethers.getContractAt("BigBullToken", addr.Token, signer);
const protocol = await ethers.getContractAt("BigBullProtocol", addr.Protocol, signer);
const tdt = await ethers.getContractAt("BBP_TestUSDT", addr.TestUSDT, signer);

// === 1. Transfer 40M tBB to Protocol (reward pool) ===
console.log("Transferring 40M tBB to Protocol...");
await (await token.transfer(addr.Protocol, ethers.parseEther("40000000"))).wait();
console.log("  ✅ Done. Protocol balance:", ethers.formatEther(await token.balanceOf(addr.Protocol)));

// === 2. Mint 50K tDT for deployer (LP + tests) ===
console.log("Minting 50K tDT...");
await (await tdt.mint(me, ethers.parseEther("50000"))).wait();
console.log("  ✅ Done. Deployer tDT:", ethers.formatEther(await tdt.balanceOf(me)));

// === 3. Add LP (100K tBB + 10K tDT = $0.10/tBB) ===
console.log("Adding LP...");
const router = await ethers.getContractAt(
  ["function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns(uint256,uint256,uint256)"],
  "0x10ED43C718714eb63d5aA57B78B54704E256024E", signer
);
await (await token.approve(router.target, ethers.parseEther("100000"))).wait();
await (await tdt.approve(router.target, ethers.parseEther("10000"))).wait();
await (await router.addLiquidity(
  addr.Token, addr.TestUSDT,
  ethers.parseEther("100000"), ethers.parseEther("10000"),
  0, 0,
  "0x000000000000000000000000000000000000dEaD",
  Math.floor(Date.now() / 1000) + 600
)).wait();
console.log("  ✅ LP added, LP burned to DEAD");

// === 4. Lock pair + whitelist + enable trading ===
console.log("Locking token...");
await (await token.setAndLockPair(addr.Pair)).wait();
await (await token.lockWhitelist()).wait();
await (await token.enableTrading()).wait();
console.log("  ✅ Token configuration locked");

// === 5. Enable claims on Protocol ===
console.log("Enabling claims...");
try {
  await (await protocol.setClaimsEnabled(true)).wait();
  console.log("  ✅ Claims enabled");
} catch (e) {
  if (e.message.includes("0x5c427cd9")) console.log("  ✓ Claims already enabled");
  else throw e;
}

// === Verification ===
console.log("\n=== FINAL STATE ===");
console.log("officialPair      :", await token.officialPair());
console.log("pairLocked        :", await token.pairLocked());
console.log("whitelistLocked   :", await token.whitelistLocked());
console.log("tradingEnabled    :", await token.tradingEnabled());
console.log("claimsEnabled     :", await protocol.claimsEnabled());
console.log("\n🎉 LAUNCH FINALIZED");
```

## Step 11 — Update frontend

In your frontend repo:

```typescript
// src/config/env.ts
export const env = {
  contractAddress: "<your Protocol address>",
  readerAddress:   "<your Reader address>",
  tokenAddress:    "<your tDT address>",
  bibTokenAddress: "<your tBB address>",
  pairAddress:     "<your Pair address>",
  // ... rest
};
```

Replace `src/abi/contract.json` and `src/abi/reader.json` with new ABIs from:
```
deployments/bsc-<timestamp>/BigBullProtocol.json  → contract.json
deployments/bsc-<timestamp>/VaultReader.json      → reader.json
```

## Step 12 — Test flow

1. Create fresh MetaMask account
2. Send 0.005 BNB + 500 tDT to it (from deployer)
3. In dApp:
   - Connect with new wallet
   - Register with ref = `0x6b5886292DD1B7E33C77eD635cC281EcCFD122eA`
   - Wait 30 seconds (enroll-to-deposit grace)
   - Stake $100 tDT (you'll get tBB at locked price)
   - Wait 24h (first-claim lock) OR fast-forward in test
   - Claim — receives USD equivalent in tBB
   - Try to sell tBB on PancakeSwap — should work (after trading enabled)

## Troubleshooting

### `0xba092d16` = `NotEOA()`
Caller is a contract (or in test scripts, not a real signer). With relaxed checks, only blocks contract-to-contract calls. EOA-style wallets work fine.

### `0xc5d2460186...` = code hash mismatch
Old strict EOA check — should NOT happen anymore in this version. If you see it, you have stale contracts.

### `Verification bytecode mismatch`
Re-run: `npm run verify -- deployments/bsc-<timestamp>`

### `Failed to download solc`
Network issue. Try `npx hardhat compile --force` or use offline solc:
```bash
npm install -g solc@0.8.20
```
