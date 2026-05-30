# BigBull V4 — Development Variant

Test deployment with **tDT** (test USDT) and **tBB** (test Big Bull) tokens on BSC mainnet.

## 🚀 Quick Deploy

```bash
# 1. Install
npm install

# 2. Setup .env
cp .env.example .env
# Edit .env and fill in:
#   PRIVATE_KEY=0xYOUR_DEPLOYER_KEY
#   ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY

# 3. Deploy + auto-verify (one command does everything)
npm run deploy:public
```

That's it. Script handles:
- ✅ tDT (10M supply)
- ✅ 6 libraries
- ✅ tBB token (110M supply)
- ✅ PancakeSwap V2 pair (with retry on gas spike)
- ✅ Protocol (library-linked)
- ✅ Reader
- ✅ Whitelist + setStakingContract
- ✅ Saves deployment dump
- ✅ Auto-verifies ALL 9 contracts on BscScan

## 📋 Pre-flight checklist

- [ ] Deployer wallet has ≥ **0.15 BNB**
- [ ] `.env` has valid `PRIVATE_KEY` (with `0x` prefix)
- [ ] `.env` has valid `ETHERSCAN_API_KEY` (get one at https://etherscan.io/myapikey)
- [ ] Wallets in `scripts/deploy.js CFG` are correct
- [ ] You're deploying to BSC mainnet (chainId 56)

## 🔧 What changed in this version

1. **EOA validation relaxed** — only `tx.origin == msg.sender` check.
   - Works with MetaMask Smart Account, Trust Wallet, Coinbase Wallet, Safe multi-sig, all AA wallets
   - Still blocks contract-to-contract calls (flash-loan bots)
2. **Genesis can be any wallet** — no longer required to be a "clean" EOA
3. **Reader has comprehensive views** with offset/limit pagination
4. **Single command deploy + verify**

## 📂 Deployment artifacts

After `npm run deploy:public`, find addresses in:
```
deployments/bsc-<timestamp>/addresses.json
```

## 🪜 Step 10 — Finalize the launch

After deploy, run these one-time setup commands in hardhat console:

```bash
npx hardhat console --network bsc
```

Then paste:

```javascript
const { ethers } = require("hardhat");
const addr = require("./deployments/bsc-LATEST/addresses.json");  // update timestamp

const [signer] = await ethers.getSigners();
const token = await ethers.getContractAt("BigBullToken", addr.Token, signer);
const protocol = await ethers.getContractAt("BigBullProtocol", addr.Protocol, signer);
const tdt = await ethers.getContractAt("BBP_TestUSDT", addr.TestUSDT, signer);

// 1) Transfer 40M tBB to Protocol (reward pool)
await (await token.transfer(addr.Protocol, ethers.parseEther("40000000"))).wait();
console.log("✅ 40M tBB transferred to Protocol");

// 2) Mint 50K tDT for deployer (LP + tests)
await (await tdt.mint(await signer.getAddress(), ethers.parseEther("50000"))).wait();
console.log("✅ 50K tDT minted");

// 3) Approve + add liquidity (100K tBB + 10K tDT = $0.10/tBB)
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
  "0x000000000000000000000000000000000000dEaD",  // LP → DEAD (lock forever)
  Math.floor(Date.now() / 1000) + 600
)).wait();
console.log("✅ 100K tBB + 10K tDT LP added, LP burned to DEAD");

// 4) Lock pair + whitelist + enable trading on Token
await (await token.setAndLockPair(addr.Pair)).wait();
await (await token.lockWhitelist()).wait();
await (await token.enableTrading()).wait();
console.log("✅ Pair locked, whitelist locked, trading enabled");

// 5) Enable claims on Protocol
try {
  await (await protocol.setClaimsEnabled(true)).wait();
  console.log("✅ Claims enabled");
} catch (e) {
  if (e.message.includes("0x5c427cd9")) console.log("✓ Claims already enabled");
  else throw e;
}

// 6) Final state verification
console.log("");
console.log("FINAL STATE:");
console.log("  officialPair      :", await token.officialPair());
console.log("  pairLocked        :", await token.pairLocked());
console.log("  whitelistLocked   :", await token.whitelistLocked());
console.log("  tradingEnabled    :", await token.tradingEnabled());
console.log("  claimsEnabled     :", await protocol.claimsEnabled());
```

## 🧪 Test airdrop + register flow

After Step 10:

```bash
# Setup test user wallets in MetaMask, send each:
#  - 0.005 BNB (for gas)
#  - 500 tDT (for staking after register)

# In their wallet:
# 1. Go to dApp, connect wallet
# 2. Register with ref = 0x6b5886292DD1B7E33C77eD635cC281EcCFD122eA (genesis)
# 3. Wait 30 sec, then stake $100 tDT
# 4. Wait grace period, then claim
```

## 🛠 Troubleshooting

### "Permission denied" errors after running with sudo
```bash
sudo chown -R $(whoami):staff .
```

### "Verification bytecode mismatch"
The auto-verify might fail occasionally due to BscScan indexing lag. Re-run:
```bash
npm run verify -- deployments/bsc-<timestamp>
```

### "createPair failed"
The script auto-retries 3 times with 5/10/15 sec backoff. If still failing, BSC gas may be spiking — wait 1 minute and retry.

### "InsufficientGas / NotEOA"
- Update gas price in `.env`: `BSC_GAS_PRICE_GWEI=5`
- Ensure deployer is a normal EOA (no Smart Account)

## 📚 Folder structure

```
bigbull-v4-Development/
├── contracts/              # Solidity sources
│   ├── access/             # ReentrancyGuard
│   ├── interfaces/         # IERC20
│   ├── libraries/          # All 12 libs
│   ├── mocks/              # Test mocks (Dev only)
│   ├── readers/            # VaultReader
│   ├── BBP_*.sol           # Core contracts
│   ├── BBP_TestUSDT.sol    # tDT (Dev only)
│   └── BigBullProtocol.sol # Main contract
├── scripts/
│   ├── deploy.js           # Main deploy + verify
│   ├── verify.js           # Standalone re-verify
│   ├── save-deployment.js  # Dump helper
│   └── generate-wallets.js # Random wallet generator
├── docs/
│   └── DEPLOYMENT_GUIDE.md # Detailed guide
├── hardhat.config.js
├── package.json
└── .env.example
```

## 🔗 Network

- **Chain**: BSC Mainnet (chainId 56)
- **Router**: PancakeSwap V2 (`0x10ED43C7...`)
- **Factory**: PancakeSwap V2 (`0xcA143Ce3...`)

## 💼 Wallet configuration

Pre-configured in `scripts/deploy.js`:

| Role          | Address |
|---------------|---------|
| GENESIS       | `0x6b5886292DD1B7E33C77eD635cC281EcCFD122eA` |
| PROTOCOL_FEE  | `0x3732A7Ebe2cE8fcb87D0653A7368a328588da65B` |
| TREASURY      | `0x560A9f5eaea1e86f2b491432a0A1BA8E005a688a` |
| COLD_TREASURY | `0xcEc566B96B81dFD18BcDEeCa13910CC5EcAeb910` |
| GUARDIAN_1    | `0x494172062cEd0039289a4e5b099062309fbcF2d0` |
| GUARDIAN_2    | `0xC74e2CFb60982E829b59D90F03052c5372Eb3018` |
| GUARDIAN_3    | `0x0d55866E62A90856B807D63c9B2B8488705d56CB` |

Edit `CFG` object in `scripts/deploy.js` to change.
# bbtest-1
