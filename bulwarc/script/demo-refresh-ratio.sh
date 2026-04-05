#!/bin/bash
# ============================================================
# Fetch live EUR/USD from webapp and push to on-chain oracle
# ============================================================
# Usage:
#   ./bulwarc/script/demo-refresh-ratio.sh
#   ./bulwarc/script/demo-refresh-ratio.sh --no-test-mode  (skip webapp test mode)
# ============================================================

set -e

source bulwarc/.env

ORACLE=$MOCK_ORACLE_ADDRESS
RPC="$ARC_TESTNET_RPC_URL"
PK="$PRIVATE_KEY"
API="${WEBAPP_URL:-http://localhost:3001}"

echo "=== Current on-chain oracle ==="
CURRENT=$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC")
echo "  $CURRENT"
echo ""

echo "=== Fetching live rate from $API ==="
if [ "$1" = "--no-test-mode" ]; then
  RESPONSE=$(curl -s --connect-timeout 3 "$API/oracle" 2>/dev/null || echo "")
  if [ -n "$RESPONSE" ] && echo "$RESPONSE" | jq -e '.price' > /dev/null 2>&1; then
    echo "  (using /oracle endpoint, no test mode change)"
    RATIO=$(echo "$RESPONSE" | jq -r '.price')
    echo "  On-chain price: $RATIO"
    echo "  Already on-chain, nothing to push."
    exit 0
  fi
else
  RESPONSE=$(curl -s --connect-timeout 3 "$API/currentRatio" 2>/dev/null || echo "")
  if [ -n "$RESPONSE" ] && echo "$RESPONSE" | jq -e '.ratio' > /dev/null 2>&1; then
    RATIO=$(echo "$RESPONSE" | jq -r '.ratio')
    SOURCE=$(echo "$RESPONSE" | jq -r '.source')
    TEST_MODE=$(echo "$RESPONSE" | jq -r '.testMode')
    echo "  ✓ EUR/USD = $RATIO (source: $SOURCE)"
    echo "  ✓ Webapp test mode: $TEST_MODE"
  fi
fi

if [ -z "$RATIO" ] || [ "$RATIO" = "null" ]; then
  echo "  ✗ Webapp unreachable — cannot refresh"
  echo "  Try: cd backend && npm run dev"
  exit 1
fi

# Convert to 1e8 (e.g. 1.1517 → 115170000)
PRICE=$(echo "$RATIO * 100000000" | bc | cut -d. -f1)
echo ""
echo "=== Pushing EUR/USD = $RATIO (on-chain: $PRICE) ==="
cast send "$ORACLE" "setPrice(int256)" "$PRICE" \
  --rpc-url "$RPC" --private-key "$PK" --json | jq -r '.transactionHash'

echo ""
echo "=== New on-chain oracle ==="
cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC"
echo ""
echo "Done. Oracle synced with Binance rate."
