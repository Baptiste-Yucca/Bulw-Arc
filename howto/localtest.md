# Local Testing Guide

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`forge`, `cast`, `anvil`)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## 1. Run Unit Tests

```bash
cd bulwarc
forge test -vvv
```

All 9 tests should pass:
- `test_createShield` — worker creates a shield by paying a premium
- `test_matchShield` — counterparty deposits collateral and receives premium
- `test_exercise_inTheMoney` — worker exercises when EUR/USD drops below strike
- `test_expire_outOfMoney` — counterparty reclaims collateral after expiry
- `test_cancel_pending` — worker cancels an unmatched shield
- `test_revert_exercise_notMaker` — only the maker can exercise
- `test_revert_exercise_pastExpiry` — cannot exercise after expiry
- `test_revert_exercise_outOfMoney` — cannot exercise if spot >= strike
- `test_revert_doubleExercise` — cannot exercise twice

## 2. Run a Local Node (Anvil)

Start a local EVM node:

```bash
anvil
```

This gives you 10 funded accounts. Note the private keys printed in the terminal.

## 3. Deploy Locally

In a second terminal:

```bash
cd bulwarc

# Deploy MockOracle + BulwArc using Anvil's first account
forge create src/mocks/MockOracle.sol:MockOracle \
  --constructor-args 92000000 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Save the deployed address, then deploy BulwArc
# Replace <MOCK_ORACLE_ADDR> with the address from above
# Replace <MOCK_USDC_ADDR> with the MockUSDC address (see step 4)
```

## 4. Deploy a MockUSDC for Local Testing

Since Anvil doesn't have USDC, deploy the MockUSDC from the test file. Create a helper script:

```bash
# Deploy MockUSDC (copy from test contract or use a simple ERC20)
forge create test/BulwArc.t.sol:MockUSDC \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Then deploy BulwArc:

```bash
forge create src/BulwArc.sol:BulwArc \
  --constructor-args <MOCK_USDC_ADDR> <MOCK_ORACLE_ADDR> \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## 5. Interact with Cast

```bash
RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
WORKER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
BULWARC=<BULWARC_ADDR>
USDC=<MOCK_USDC_ADDR>
ORACLE=<MOCK_ORACLE_ADDR>

# Mint USDC to worker
cast send $USDC "mint(address,uint256)" $WORKER 1000000000 --rpc-url $RPC --private-key $PK

# Check balance
cast call $USDC "balanceOf(address)(uint256)" $WORKER --rpc-url $RPC

# Approve BulwArc to spend USDC
cast send $USDC "approve(address,uint256)" $BULWARC 5000000 --rpc-url $RPC --private-key $PK

# Create a shield: strike=0.92, notional=1000 USDC, premium=5 USDC, expiry=30 days
EXPIRY=$(($(date +%s) + 2592000))
cast send $BULWARC "createShield(uint256,uint256,uint256,uint256)" 92000000 1000000000 5000000 $EXPIRY --rpc-url $RPC --private-key $PK

# Read the shield
cast call $BULWARC "getShield(uint256)" 0 --rpc-url $RPC

# Update oracle price (simulate EUR/USD drop)
cast send $ORACLE "setPrice(int256)" 88000000 --rpc-url $RPC --private-key $PK
```

## 6. Full Local Scenario (end-to-end)

1. Deploy MockUSDC, MockOracle, BulwArc
2. Mint USDC to worker + counterparty accounts
3. Worker: `approve` + `createShield`
4. Counterparty: `approve` + `matchShield`
5. Set oracle price below strike
6. Worker: `exercise` — check balances changed correctly
