#!/bin/bash
set -e

# Load environment
source .env

echo "=== Deploying to Arc Testnet ==="
OUTPUT=$(forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_TESTNET_RPC_URL --broadcast 2>&1)
echo "$OUTPUT"

# Extract deployed addresses from logs
ORACLE_ADDR=$(echo "$OUTPUT" | grep "MockOracle deployed at:" | awk '{print $NF}')
BULWARC_ADDR=$(echo "$OUTPUT" | grep "BulwArc deployed at:" | awk '{print $NF}')

if [ -z "$BULWARC_ADDR" ] || [ -z "$ORACLE_ADDR" ]; then
  echo "ERROR: Could not extract deployed addresses from logs"
  exit 1
fi

echo ""
echo "=== Deployed ==="
echo "MockOracle: $ORACLE_ADDR"
echo "BulwArc:    $BULWARC_ADDR"
echo ""

echo "=== Verifying MockOracle ==="
forge verify-contract "$ORACLE_ADDR" \
  src/mocks/MockOracle.sol:MockOracle \
  --constructor-args $(cast abi-encode "constructor(int256)" 92000000) \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api/ \
  --chain-id 5042002

echo ""
echo "=== Verifying BulwArc ==="
forge verify-contract "$BULWARC_ADDR" \
  src/BulwArc.sol:BulwArc \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256)" 0x3600000000000000000000000000000000000000 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a "$ORACLE_ADDR" 100) \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api/ \
  --chain-id 5042002

echo ""
echo "=== Done ==="
echo "MockOracle: https://testnet.arcscan.app/address/$ORACLE_ADDR"
echo "BulwArc:    https://testnet.arcscan.app/address/$BULWARC_ADDR"
