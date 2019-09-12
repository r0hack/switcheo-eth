const { exchange, bn, decodeInput } = require('../../utils')
const { ETHER_ADDR } = require('../../constants')
const Web3 = require('web3')

const PrivateKeyProvider = require('truffle-privatekey-provider')
const provider = new PrivateKeyProvider(
    process.env.controlKey,
    'https://ropsten.infura.io/v3/' + process.env.infuraKey
)

const web3 = new Web3(provider)
const { utils } = web3

const KNC_ADDR = '0x4E470dc7321E84CA96FcAEDD0C8aBCebbAEB68C6'

const operator = '0x325085628e40801f5d2c249a2f91ea74bc8d73c3'

const privateKeys = {}
privateKeys[operator] = process.env.controlKey

function formatAmount(value, power) {
    return bn(value).mul(bn(10).pow(bn(power))).toString()
}

function getRandomNonce() {
    const min = 1
    const max = 1000 * 1000 * 1000
    return Math.floor(Math.random() * (max - min + 1)) + min
}

// async function uniswap_eth_to_tokens() {
//     const maker = operator

//     const offers = [{
//         maker,
//         offerAssetId: ETHER_ADDR,
//         offerAmount: formatAmount(1, 17), // 0.1 ETH
//         wantAssetId: DAI_ADDR,
//         wantAmount: formatAmount(10, 18), // 10 DAI
//         feeAssetId: DAI_ADDR,
//         feeAmount: formatAmount(1, 18), // 1 DAI
//         nonce: getRandomNonce()
//     }]
//     const matches = [{
//         offerIndex: 0,
//         surplusAssetId: DAI_ADDR,
//         data: 60, // max execution delay
//         tradeProvider: 1, // uniswap
//         takeAmount: formatAmount(1, 17) // take 0.1 ETH
//     }]

//     const result = await exchange.networkTrade({ offers, matches, operator }, { privateKeys })
//     console.log('result', result)
// }

// async function uniswap_tokens_to_eth() {
//     const maker = operator

//     const offers = [{
//         maker,
//         offerAssetId: DAI_ADDR,
//         offerAmount: formatAmount(10, 18), // 10 DAI
//         wantAssetId: ETHER_ADDR,
//         wantAmount: formatAmount(5, 16), // 0.05 ETH
//         feeAssetId: ETHER_ADDR,
//         feeAmount: formatAmount(1, 16), // 0.01 ETH
//         nonce: getRandomNonce()
//     }]
//     const matches = [{
//         offerIndex: 0,
//         surplusAssetId: ETHER_ADDR,
//         data: 60, // max execution delay
//         tradeProvider: 1, // uniswap
//         takeAmount: formatAmount(10, 18) // take 10 DAI
//     }]

//     const result = await exchange.networkTrade({ offers, matches, operator }, { privateKeys })
//     console.log('result', result)
// }

// async function uniswap_tokens_to_tokens() {
//     const maker = operator

//     const offers = [{
//         maker,
//         offerAssetId: DAI_ADDR,
//         offerAmount: formatAmount(10, 18), // 10 DAI
//         wantAssetId: MATIC_ADDR,
//         wantAmount: formatAmount(500, 18), // 500 MATIC
//         feeAssetId: MATIC_ADDR,
//         feeAmount: formatAmount(10, 18), // 10 MATIC
//         nonce: getRandomNonce()
//     }]
//     const matches = [{
//         offerIndex: 0,
//         surplusAssetId: MATIC_ADDR,
//         data: 60, // max execution delay
//         tradeProvider: 1, // uniswap
//         takeAmount: formatAmount(10, 18) // take 10 DAI
//     }]

//     const result = await exchange.networkTrade({ offers, matches, operator }, { privateKeys })
//     console.log('result', result)
// }

async function kyberswap_tokens_to_eth() {
    const maker = operator

    const offers = [{
        maker,
        offerAssetId: DAI_ADDR,
        offerAmount: formatAmount(10, 18), // 10 DAI
        wantAssetId: ETHER_ADDR,
        wantAmount: formatAmount(5, 16), // 0.05 ETH
        feeAssetId: ETHER_ADDR,
        feeAmount: formatAmount(1, 16), // 0.01 ETH
        nonce: getRandomNonce()
    }]
    const matches = [{
        offerIndex: 0,
        surplusAssetId: ETHER_ADDR,
        data: 0, // index of fee-sharing wallet address in addresses
        tradeProvider: 0, // kyberswap
        takeAmount: formatAmount(10, 18) // take 10 DAI
    }]

    const result = await exchange.networkTrade({ offers, matches, operator, gas: '1000000' }, { privateKeys })
    console.log('result', result)
}

async function kyberswap_tokens_to_tokens() {
    const maker = operator

    const offers = [{
        maker,
        offerAssetId: DAI_ADDR,
        offerAmount: formatAmount(3, 18), // 3 DAI
        wantAssetId: KNC_ADDR,
        wantAmount: formatAmount(12, 18), // 12 KNC
        feeAssetId: KNC_ADDR,
        feeAmount: formatAmount(1, 18), // 1 KNC
        nonce: getRandomNonce()
    }]
    const matches = [{
        offerIndex: 0,
        surplusAssetId: KNC_ADDR,
        data: 0, // index of fee-sharing wallet address in addresses
        tradeProvider: 0, // kyberswap
        takeAmount: formatAmount(3, 18) // take 3 DAI
    }]

    const result = await exchange.networkTrade({ offers, matches, operator, gas: '1000000' }, { privateKeys })
    console.log('result', result)
}

async function kyberswap_eth_to_tokens() {
    const maker = operator

    const offers = [{
        maker,
        offerAssetId: ETHER_ADDR,
        offerAmount: formatAmount(1, 17), // 0.1 ETH
        wantAssetId: KNC_ADDR,
        wantAmount: formatAmount(30, 18), // 30 KNC
        feeAssetId: KNC_ADDR,
        feeAmount: formatAmount(1, 18), // 1 KNC
        nonce: getRandomNonce()
    }]
    const matches = [{
        offerIndex: 0,
        surplusAssetId: KNC_ADDR,
        data: 0, // index of fee-sharing wallet address in addresses
        tradeProvider: 0, // kyberswap
        takeAmount: formatAmount(1, 17) // take 0.1 ETH
    }]

    const result = await exchange.networkTrade({ offers, matches, operator, gas: '1000000' }, { privateKeys })
    console.log('result', result)
}

// async function kyberswap_eth_to_tokens() {
//     const maker = operator
//
//     const offers = [{
//         maker,
//         offerAssetId: ETHER_ADDR,
//         offerAmount: formatAmount(5, 16), // 0.05 ETH
//         wantAssetId: KNC_ADDR,
//         wantAmount: formatAmount(40, 18), // 40 KNC
//         feeAssetId: KNC_ADDR,
//         feeAmount: formatAmount(1, 18), // 1 KNC
//         nonce: getRandomNonce()
//     }]
//     const matches = [{
//         offerIndex: 0,
//         surplusAssetId: KNC_ADDR,
//         data: 0, // index of fee-sharing wallet address in addresses
//         tradeProvider: 0, // kyberswap
//         takeAmount: formatAmount(5, 16) // take 0.05 ETH
//     }]
//
//     const result = await exchange.networkTrade({ offers, matches, operator, gas: '1000000' }, { privateKeys })
//     console.log('result', result)
// }

kyberswap_eth_to_tokens()
