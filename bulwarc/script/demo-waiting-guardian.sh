#!/bin/bash
# ============================================================
# DEMO — Shield funded, 10% filled, waiting for more guardians
# ============================================================
# EU Remote Worker shield, employer funded, only 10% matched
# Status: PENDING (10% filled, 90% open)
# Expiry: 7 days
#
# Usage:
#   ./bulwarc/script/demo-waiting-guardian.sh
# ============================================================

set -e

source bulwarc/.env

BULWARC=$BULWARC_ADDRESS
ORACLE=$MOCK_ORACLE_ADDRESS
USDC="0x3600000000000000000000000000000000000000"
EURC="0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
RPC="$ARC_TESTNET_RPC_URL"

PK_WORKER="$EU_Remote_Worker"
PK_EMPLOYER="$US_Company"
PK_GUARDIAN="$US_Traveller"

ADDR_WORKER="0xf9514b43972595a3329750A459165236e758af09"
ADDR_EMPLOYER="0x24273C6eded4D04D34B047F988601D58EDf899bf"
ADDR_GUARDIAN="0x446b6da199fdA020a0fAD6fffe2ECE9db693552d"

FEE_BPS=100

parse() { echo "$1" | awk '{print $1}'; }

# Read oracle
ORACLE_RATE=$(parse "$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC" | head -1)")
STRIKE=$((ORACLE_RATE * 95 / 100))
EXPIRY=$(($(date +%s) + 7 * 86400))

NOTIONAL=2000000    # 2 EURC
PREMIUM=100000      # 0.1 USDC
SUB_FEE=$((PREMIUM * FEE_BPS / 10000))
FILL=200000         # 0.2 EURC (10%)
FILL_FEE=$((FILL * FEE_BPS / 10000))
REMAINING=$((NOTIONAL - FILL))

echo "============================================================"
echo "  DEMO — Shield waiting for guardians (10% filled)"
echo "============================================================"
echo "  Worker:   $ADDR_WORKER"
echo "  Oracle:   $ORACLE_RATE"
echo "  Strike:   $STRIKE (5% below)"
echo "  Notional: 2 EURC"
echo "  Premium:  0.1 USDC"
echo "  Filled:   0.2 EURC (10%)"
echo "  Open:     1.8 EURC (90%)"
echo "  Expiry:   $(date -r $EXPIRY '+%Y-%m-%d %H:%M') (7 days)"
echo "============================================================"
echo ""

# [1] Worker creates shield
echo "=== [1] Worker creates shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address,bool)" \
  "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "0x0000000000000000000000000000000000000000" false \
  --rpc-url "$RPC" --private-key "$PK_WORKER" --json | jq -r '.transactionHash'

SHIELD_ID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID=$((SHIELD_ID - 1))
echo "  Shield #$SHIELD_ID created"
echo ""

# [2] Employer funds
echo "=== [2] Employer funds premium ==="
APPROVE=$((PREMIUM + SUB_FEE))
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$APPROVE" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json > /dev/null
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'
echo "  Shield #$SHIELD_ID → PENDING"
echo ""

# [3] Guardian fills 10%
echo "=== [3] Guardian fills 10% (0.2 EURC) ==="
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$((FILL + FILL_FEE))" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json > /dev/null
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_GUARDIAN" "$FILL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'
echo ""

echo "============================================================"
echo "  Shield #$SHIELD_ID — PENDING (10% filled)"
echo ""
echo "  Filled:    0.2 / 2 EURC"
echo "  Open:      1.8 EURC for new guardians"
echo "  Expiry:    7 days"
echo ""
echo "  Any guardian can call:"
echo "    EURC.approve(BulwArc, amount + 1% fee)"
echo "    BulwArc.matchShield($SHIELD_ID, guardian_addr, amount)"
echo "============================================================"
