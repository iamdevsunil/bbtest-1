const fs = require("fs");
const path = require("path");

async function saveDeployment(networkName, addresses) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dir = path.join(__dirname, "..", "deployments", `${networkName}-${timestamp}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "addresses.json"), JSON.stringify(addresses, null, 2));

  const artifactsDir = path.join(__dirname, "..", "artifacts", "contracts");
  const copy = (contractName, subPath) => {
    try {
      const src = path.join(artifactsDir, subPath, `${contractName}.json`);
      if (!fs.existsSync(src)) return;
      const artifact = JSON.parse(fs.readFileSync(src));
      fs.writeFileSync(
        path.join(dir, `${contractName}.json`),
        JSON.stringify({ abi: artifact.abi, bytecode: artifact.bytecode, deployedBytecode: artifact.deployedBytecode }, null, 2)
      );
    } catch (e) {}
  };

  copy("BigBullProtocol", "BigBullProtocol.sol");
  copy("BigBullToken", "BBP_Token.sol");
  copy("VaultReader", "readers/BBP_Reader.sol");
  copy("BBP_TestUSDT", "BBP_TestUSDT.sol");
  ["RewardLib","RewardClaimLib","DexLib","DistributionLib","TeamTierLib","AnomalyMonitor"].forEach(n => {
    copy(n, `libraries/BBP_${n === "AnomalyMonitor" ? "AnomalyMonitor" : n}.sol`);
  });

  console.log(`   Dumped to: ${dir}`);
}

module.exports = { saveDeployment };
