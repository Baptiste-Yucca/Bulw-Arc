#!/bin/bash
# ============================================================
# DEMO — Shield created, waiting for employer to fund
# ============================================================
# EU Remote Worker creates a shield but employer hasn't paid yet
# Status: CREATED (no funds, just declared)
# Expiry: 7 days
#
# Usage:
#   ./bulwarc/script/demo-waiting-employer.sh
# ============================================================

set -e

source bulwarc/.env

BULWARC=$BULWARC_ADDRESS
ORACLE=$MOCK_ORACLE_ADDRESS
RPC="$ARC_TESTNET_RPC_URL"

PK_WORKER="$EU_Remote_Worker"
ADDR_WORKER="0xf9514b43972595a3329750A459165236e758af09"
ADDR_EMPLOYER="0x24273C6eded4D04D34B047F988601D58EDf899bf"

parse() { echo "$1" | awk '{print $1}'; }

# Read oracle for dynamic strike
ORACLE_RATE=$(parse "$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC" | head -1)")
STRIKE=$((ORACLE_RATE * 95 / 100))
EXPIRY=$(($(date +%s) + 7 * 86400))

echo "============================================================"
echo "  DEMO — Shield waiting for employer"
echo "============================================================"
echo "  Worker:   $ADDR_WORKER"
echo "  Employer: $ADDR_EMPLOYER (hasn't paid yet)"
echo "  Oracle:   $ORACLE_RATE"
echo "  Strike:   $STRIKE (5% below)"
echo "  Notional: 2 EURC"
echo "  Premium:  0.1 USDC"
echo "  Expiry:   $(date -r $EXPIRY '+%Y-%m-%d %H:%M') (7 days)"
echo "============================================================"
echo ""

echo "=== Worker creates shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address,bool)" \
  "$STRIKE" 2000000 100000 "$EXPIRY" "0x0000000000000000000000000000000000000000" false \
  --rpc-url "$RPC" --private-key "$PK_WORKER" --json | jq -r '.transactionHash'

SHIELD_ID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID=$((SHIELD_ID - 1))

echo ""
echo "============================================================"
echo "  Shield #$SHIELD_ID — CREATED"
echo "  Status: Waiting for employer to call fundShield($SHIELD_ID)"
echo ""
echo "  Employer needs to:"
echo "    1. USDC.approve(BulwArc, 101000)   // 0.1 USDC + 1% fee"
echo "    2. BulwArc.fundShield($SHIELD_ID)"
echo ""
echo "  Then guardians can matchShield($SHIELD_ID, addr, amount)"
echo "============================================================"
