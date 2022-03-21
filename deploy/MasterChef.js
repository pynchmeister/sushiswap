module.exports = async function ({ ethers, deployments, getNamedAccounts }) {
  const { deploy } = deployments

  const { deployer, dev } = await getNamedAccounts()

  const gzap = await ethers.getContract("GZapToken")
  
  const { address } = await deploy("ZapDirector", {
    from: deployer,
    args: [gzap.address, dev, "1000000000000000000000", "0", "1000000000000000000000"],
    log: true,
    deterministicDeployment: false
  })

  if (await gzap.owner() !== address) {
    // Transfer GZap Ownership to Director
    console.log("Transfer GZap Ownership to Director")
    await (await gzap.transferOwnership(address)).wait()
  }

  const zapDirector = await ethers.getContract("ZapDirector")
  if (await zapDirector.owner() !== dev) {
    // Transfer ownership of ZapDirector to dev
    console.log("Transfer ownership of ZapDirector to dev")
    await (await zapDirector.transferOwnership(dev)).wait()
  }
}

module.exports.tags = ["ZapDirector"]
module.exports.dependencies = ["UniswapV2Factory", "UniswapV2Router02", "GZapToken"]
