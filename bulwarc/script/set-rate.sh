#!/bin/bash
# Usage: ./script/set-rate.sh <EUR/USD rate>
# Example: ./script/set-rate.sh 1.08   (1 EUR = 1.08 USD)
# Example: ./script/set-rate.sh 0.92   (1 EUR = 0.92 USD)

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <EUR/USD rate>"
  echo "Example: $0 1.08"
  exit 1
fi

source .env

if [ -z "$MOCK_ORACLE_ADDRESS" ]; then
  echo "ERROR: MOCK_ORACLE_ADDRESS not set in .env"
  exit 1
fi

RATE=$1
PRICE=$(echo "$RATE * 100000000" | bc | cut -d. -f1)

echo "=== Current oracle rate ==="
cast call "$MOCK_ORACLE_ADDRESS" "getPrice()(int256,uint256)" --rpc-url "$ARC_TESTNET_RPC_URL"

echo ""
echo "=== Pushing EUR/USD rate: $RATE (on-chain: $PRICE) ==="
cast send "$MOCK_ORACLE_ADDRESS" "setPrice(int256)" "$PRICE" \
  --rpc-url "$ARC_TESTNET_RPC_URL" --private-key "$PRIVATE_KEY"

echo ""
echo "=== New oracle rate ==="
cast call "$MOCK_ORACLE_ADDRESS" "getPrice()(int256,uint256)" --rpc-url "$ARC_TESTNET_RPC_URL"
