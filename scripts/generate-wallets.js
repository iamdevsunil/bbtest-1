/* eslint-disable no-console */
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

async function main() {
  const ADMIN = ["PROTOCOL_FEE", "TREASURY", "COLD_TREASURY", "GUARDIAN_1", "GUARDIAN_2", "GUARDIAN_3"];
  const NODES = Array.from({ length: 20 }, (_, i) => `REWARD_NODE_${i + 1}`);
  const all = [...ADMIN, ...NODES];
  console.log(`\n🔐 Generating ${all.length} wallets...\n`);
  const wallets = all.map(n => { const w = ethers.Wallet.createRandom(); return { name: n, address: w.address, privateKey: w.privateKey }; });
  for (const w of wallets) console.log(`  ${w.name.padEnd(16)} → ${w.address}`);
  fs.writeFileSync(path.join(__dirname, "..", "configWallet.csv"),
    "name,address\n" + wallets.map(w => `${w.name},${w.address}`).join("\n") + "\n");
  fs.writeFileSync(path.join(__dirname, "..", "walletKeys-SECRET.csv"),
    "# ⚠️ PRIVATE KEYS — BACKUP OFFLINE, THEN DELETE FROM DISK\nname,address,privateKey\n" +
    wallets.map(w => `${w.name},${w.address},${w.privateKey}`).join("\n") + "\n");
  console.log("\n✅ configWallet.csv  (safe to share)");
  console.log("🔒 walletKeys-SECRET.csv  (BACKUP & DELETE)\n");
}
main().catch(e => { console.error(e); process.exit(1); });
