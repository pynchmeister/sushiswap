const { WETH_ADDRESS } = require("@sushiswap/core-sdk")

module.exports = async function ({ ethers: { getNamedSigner }, getNamedAccounts, deployments }) {
  const { deploy } = deployments

  const { deployer, dev } = await getNamedAccounts()

  const chainId = await getChainId()

  const factory = await ethers.getContract("UniswapV2Factory")
  const bar = await ethers.getContract("ZapStake")
  const gzap = await ethers.getContract("GZapToken")
  
  let wethAddress;
  
  if (chainId === '3') {
    wethAddress = (await deployments.get("WETH9Mock")).address
  } else if (chainId in WETH_ADDRESS) {
    wethAddress = WETH_ADDRESS[chainId]
  } else {
    throw Error("No WETH!")
  }

  await deploy("ZapWizard", {
    from: deployer,
    args: [factory.address, bar.address, gzap.address, wethAddress],
    log: true,
    deterministicDeployment: false
  })

  const maker = await ethers.getContract("ZapWizard")
  if (await maker.owner() !== dev) {
    console.log("Setting wizard owner")
    await (await maker.transferOwnership(dev, true, false)).wait()
  }
}

module.exports.tags = ["ZapWizard"]
module.exports.dependencies = ["UniswapV2Factory", "UniswapV2Router02", "ZapStake", "GZapToken"]