import { task } from 'hardhat/config'

import { createGetHreByEid, createProviderFactory, getEidForNetworkName } from '@layerzerolabs/devtools-evm-hardhat'
import { Options } from '@layerzerolabs/lz-v2-utilities'

// send messages from a contract on one network to another
task('oapp:send', 'test send')
    // contract to send a message from
    .addParam('contractA', 'contract address on network A')
    // network that sender contract resides on
    .addParam('networkA', 'name of the network A')
    // network that receiver contract resides on
    .addParam('networkB', 'name of the network B')
    // message to send from network a to network b
    .addParam('message', 'message to send from network A to network B')
    .setAction(async (taskArgs, { ethers }) => {
        const eidA = getEidForNetworkName(taskArgs.networkA)
        const eidB = getEidForNetworkName(taskArgs.networkB)
        const contractA = taskArgs.contractA
        const environmentFactory = createGetHreByEid()
        const providerFactory = createProviderFactory(environmentFactory)
        const signer = (await providerFactory(eidA)).getSigner()

        const oappContractFactory = await ethers.getContractFactory('SimpleTokenCrossChainMint', signer)
        const oapp = oappContractFactory.attach(contractA)

        const options = Options.newOptions().addExecutorLzReceiveOption(200000, 0).toHex().toString()
        const [nativeFee] = await oapp.quoteSendString(eidB, taskArgs.message, options, false)
        console.log('native fee:', nativeFee)

        const r = await oapp.sendString(eidB, taskArgs.message, options, {
            value: nativeFee,
        })

        console.log(`Tx initiated. See: https://layerzeroscan.com/tx/${r.hash}`)
    })

// read message stored in SimpleTokenCrossChainMint
task('oapp:read', 'read message stored in SimpleTokenCrossChainMint')
    .addParam('contractA', 'contract address on network A')
    .addParam('contractB', 'contract address on network B')
    .addParam('networkA', 'name of the network A')
    .addParam('networkB', 'name of the network B')
    .setAction(async (taskArgs, { ethers }) => {
        const eidA = getEidForNetworkName(taskArgs.networkA)
        const eidB = getEidForNetworkName(taskArgs.networkB)
        const contractA = taskArgs.contractA
        const contractB = taskArgs.contractB
        const environmentFactory = createGetHreByEid()
        const providerFactory = createProviderFactory(environmentFactory)
        const signerA = (await providerFactory(eidA)).getSigner()
        const signerB = (await providerFactory(eidB)).getSigner()

        const oappContractAFactory = await ethers.getContractFactory('SimpleTokenCrossChainMint', signerA)
        const oappContractBFactory = await ethers.getContractFactory('SimpleTokenCrossChainMint', signerB)

        const oappA = oappContractAFactory.attach(contractA)
        const oappB = oappContractBFactory.attach(contractB)

        const dataOnOAppA = await oappA.lastMessage()
        const dataOnOAppB = await oappB.lastMessage()
        console.log({
            [taskArgs.networkA]: dataOnOAppA,
            [taskArgs.networkB]: dataOnOAppB,
        })
    })
