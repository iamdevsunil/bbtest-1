/* eslint-disable no-console */
// Standalone verify — for when auto-verify in deploy.js failed.
// Usage: npm run verify -- <deployments/folder>
const fs = require("fs");
const path = require("path");
const { run } = require("hardhat");

async function main() {
  const dumpDir = process.argv[2];
  if (!dumpDir) { console.error("Usage: npm run verify -- deployments/<folder>"); process.exit(1); }
  const data = JSON.parse(fs.readFileSync(path.join(dumpDir, "addresses.json")));
  const libs = {
    RewardLib: data.RewardLib, RewardClaimLib: data.RewardClaimLib, DexLib: data.DexLib,
    DistributionLib: data.DistributionLib, TeamTierLib: data.TeamTierLib, AnomalyMonitor: data.AnomalyMonitor,
  };
  async function v(addr, name, args = [], libraries = undefined) {
    try {
      console.log(`Verifying ${name} @ ${addr}...`);
      await run("verify:verify", { address: addr, constructorArguments: args, libraries });
      console.log(`✅ ${name}`);
    } catch (e) {
      const msg = e.message?.toString() || '';
      if (msg.includes('Already Verified') || msg.includes('already verified')) console.log(`✓ ${name} already verified`);
      else console.log(`⚠️ ${name}:`, msg.split('\n')[0].slice(0, 100));
    }
  }
  await v(libs.RewardLib, "RewardLib");
  await v(libs.RewardClaimLib, "RewardClaimLib");
  await v(libs.DexLib, "DexLib");
  await v(libs.DistributionLib, "DistributionLib");
  await v(libs.TeamTierLib, "TeamTierLib", [], { DistributionLib: libs.DistributionLib });
  await v(libs.AnomalyMonitor, "AnomalyMonitor");
  if (data.TestUSDT) await v(data.TestUSDT, "BBP_TestUSDT", [10000000n]);
  await v(data.Token, "BigBullToken", [data._tokenName, data._tokenSymbol, BigInt(data._tokenSupply), data._usdt]);
  await v(data.Protocol, "BigBullProtocol", data._protocolConstructorArgs, libs);
  await v(data.Reader, "VaultReader", [data.Protocol], { RewardLib: libs.RewardLib });
}
main().catch(e => { console.error(e); process.exit(1); });
