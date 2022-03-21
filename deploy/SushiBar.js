module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments

  const { deployer } = await getNamedAccounts()

  const sushi = await deployments.get("GZapToken")

  await deploy("ZapStake", {
    from: deployer,
    args: [sushi.address],
    log: true,
    deterministicDeployment: false
  })
}

module.exports.tags = ["ZapStake"]
module.exports.dependencies = ["UniswapV2Factory", "UniswapV2Router02", "GZapToken"]
