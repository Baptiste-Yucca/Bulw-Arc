# Deploy to Arc Testnet

## Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
2. A wallet with testnet USDC (gas) — get some from the [Circle Faucet](https://faucet.circle.com)
3. Your private key ready

## 1. Setup Environment

```bash
cd bulwarc
cp .env.example .env
```

Edit `.env`:
```
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0xYOUR_PRIVATE_KEY_HERE"
```

Load it:
```bash
source .env
```

## 2. Deploy + Verify (one command)

```bash
./script/deploy-and-verify.sh
```

This will:
1. Deploy **MockOracle** + **BulwArc** to Arc Testnet
2. Extract deployed addresses from logs
3. Verify both contracts on the [Arc Testnet Explorer](https://testnet.arcscan.app) (Blockscout)
4. Print explorer links

### Manual deploy (without auto-verify)

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_TESTNET_RPC_URL --broadcast
```

### Manual verify (after deploy)

```bash
# Verify MockOracle
forge verify-contract <ORACLE_ADDR> src/mocks/MockOracle.sol:MockOracle \
  --constructor-args $(cast abi-encode "constructor(int256)" 92000000) \
  --verifier blockscout --verifier-url https://testnet.arcscan.app/api/ --chain-id 5042002

# Verify BulwArc
forge verify-contract <BULWARC_ADDR> src/BulwArc.sol:BulwArc \
  --constructor-args $(cast abi-encode "constructor(address,address)" 0x3600000000000000000000000000000000000000 <ORACLE_ADDR>) \
  --verifier blockscout --verifier-url https://testnet.arcscan.app/api/ --chain-id 5042002
```

## 4. Post-deploy Interactions

```bash
BULWARC=<deployed_address>
ORACLE=<deployed_address>
USDC=0x3600000000000000000000000000000000000000

# Check oracle price
cast call $ORACLE "getPrice()(int256,uint256)" --rpc-url $ARC_TESTNET_RPC_URL

# Update oracle price (only deployer)
cast send $ORACLE "setPrice(int256)" 92000000 \
  --rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY

# Approve BulwArc to spend your USDC
cast send $USDC "approve(address,uint256)" $BULWARC 5000000 \
  --rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY

# Create a shield: strike=0.92, notional=1000 USDC, premium=5 USDC, expiry=30 days
EXPIRY=$(($(date +%s) + 2592000))
cast send $BULWARC "createShield(uint256,uint256,uint256,uint256)" \
  92000000 1000000000 5000000 $EXPIRY \
  --rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY

# Read shield
cast call $BULWARC "getShield(uint256)" 0 --rpc-url $ARC_TESTNET_RPC_URL

# Get shield count
cast call $BULWARC "getShieldCount()(uint256)" --rpc-url $ARC_TESTNET_RPC_URL
```

## 5. Arc Testnet Network Info

| Field | Value |
|---|---|
| Network | Arc Testnet |
| RPC | `https://rpc.testnet.arc.network` |
| Chain ID | `5042002` |
| Gas token | USDC |
| Explorer | `https://testnet.arcscan.app` |
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |

## Troubleshooting

- **RPC errors**: Try alternative RPCs: `https://rpc.blockdaemon.testnet.arc.network` or `https://rpc.quicknode.testnet.arc.network`
- **Out of gas**: Get testnet USDC from [faucet.circle.com](https://faucet.circle.com)
- **Transaction stuck**: Check the explorer for tx status, increase gas if needed
