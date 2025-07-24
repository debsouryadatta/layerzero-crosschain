import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

// TODO declare your contract name here
const contractName = 'SimpleTokenCrossChainMint'

const deploy: DeployFunction = async (hre) => {
    // Simple token configuration
    const NAME = "CrossChain Token";
    const SYMBOL = "CCT";

    // Pool configuration (4 pools) - using string values
    const MINT_PRICES = [
        "1000000000000",    // Pool 1: 0,000001 ETH (or S token equivalent)
        "2000000000000",    // Pool 2: 0.000002 ETH  
        "3000000000000",    // Pool 3: 0.000003 ETH
        "4000000000000"     // Pool 4: 0.000004 ETH
    ];

    const MAX_SUPPLIES = [
        1000000,  // Pool 1: 1M tokens
        500000,   // Pool 2: 500K tokens
        300000,   // Pool 3: 300K tokens
        200000    // Pool 4: 200K tokens
    ];

    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // This is an external deployment pulled in from @layerzerolabs/lz-evm-sdk-v2
    //
    // @layerzerolabs/toolbox-hardhat takes care of plugging in the external deployments
    // from @layerzerolabs packages based on the configuration in your hardhat config
    //
    // For this to work correctly, your network config must define an eid property
    // set to `EndpointId` as defined in @layerzerolabs/lz-definitions
    //
    // For example:
    //
    // networks: {
    //   fuji: {
    //     ...
    //     eid: EndpointId.AVALANCHE_V2_TESTNET
    //   }
    // }
    const endpointV2Deployment = await hre.deployments.get('EndpointV2')

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            deployer, // owner
            NAME,
            SYMBOL,
            endpointV2Deployment.address, // LayerZero's EndpointV2 address
            MINT_PRICES,
            MAX_SUPPLIES,
        ],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]

export default deploy
