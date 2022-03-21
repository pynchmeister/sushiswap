const { SUSHI_ADDRESS } = require("@sushiswap/core-sdk");

module.exports = async function ({ ethers, deployments, getNamedAccounts }) {
  const { deploy } = deployments;

  const { deployer, dev } = await getNamedAccounts();

  const chainId = await getChainId();

  let gzapAddress;

  if (chainId === "3") {
    sushiAddress = (await deployments.get("ZapDirector")).address;
  } else if (chainId in SUSHI_ADDRESS) {
    sushiAddress = SUSHI_ADDRESS[chainId];
  } else {
    throw Error("No GZAP!");
  }

  await deploy("MiniZapDirectorV2", {
    from: deployer,
    args: [sushiAddress],
    log: true,
    deterministicDeployment: false,
  });

  const miniZapDirectorV2 = await ethers.getContract("MiniZapDirectorV2");
  if ((await miniZapDirectorV2.owner()) !== dev) {
    console.log("Transfer ownership of MiniZapDirector to dev");
    await (await miniZapDirectorV2.transferOwnership(dev, true, false)).wait();
  }
};

module.exports.tags = ["MiniZapDirectorV2"];
module.exports.dependencies = ["UniswapV2Factory", "UniswapV2Router02"]
