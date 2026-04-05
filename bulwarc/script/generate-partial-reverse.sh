#!/bin/bash
# ============================================================
# Generate a reverse shield (EUR→USD) partially filled at 80%
# by 2 different guardians, waiting for a 3rd to complete
# ============================================================
# For the jury demo: US-friendly, isReverse=true
# Subscriber pays EURC premium, guardians deposit USDC
#
# Usage:
#   ./bulwarc/script/generate-partial-reverse.sh
# ============================================================

set -e

source bulwarc/.env

BULWARC=$BULWARC_ADDRESS
ORACLE=$MOCK_ORACLE_ADDRESS
USDC="0x3600000000000000000000000000000000000000"
EURC="0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
RPC="$ARC_TESTNET_RPC_URL"

PK_DEPLOYER="$PRIVATE_KEY"
PK_COMPANY="$US_Company"
PK_TRAVELLER="$US_Traveller"

ADDR_DEPLOYER="0x8aeEe14Aa4f2eC295E4483bf8aAc6Ad80C63aF1E"
ADDR_COMPANY="0x24273C6eded4D04D34B047F988601D58EDf899bf"
ADDR_TRAVELLER="0x446b6da199fdA020a0fAD6fffe2ECE9db693552d"

FEE_BPS=100

parse() { echo "$1" | awk '{print $1}'; }

# ============================================================
# Read oracle for dynamic strike
# ============================================================
echo "=== Reading on-chain oracle ==="
ORACLE_RATE=$(parse "$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC" | head -1)")
STRIKE=$((ORACLE_RATE * 103 / 100))  # 3% above current (reverse: exercise if spot > strike)
echo "  Oracle: $ORACLE_RATE"
echo "  Strike: $STRIKE (3% above — triggers if EUR weakens)"
echo ""

# Shield params
NOTIONAL=5000000          # 5 USDC total collateral needed
PREMIUM=100000            # 0.1 EURC premium
SUB_FEE=$(((NOTIONAL + PREMIUM) * FEE_BPS / 10000))
EXPIRY=$(($(date +%s) + 30 * 86400))  # 30 days

# Guardian fills: 50% + 30% = 80%, leaving 20% open
FILL_A=2500000            # 2.5 USDC (50%) — Deployer
FILL_B=1500000            # 1.5 USDC (30%) — Company
REMAINING=1000000         # 1.0 USDC (20%) — waiting for jury/3rd guardian

FILL_A_FEE=$((FILL_A * FEE_BPS / 10000))
FILL_B_FEE=$((FILL_B * FEE_BPS / 10000))

echo "============================================================"
echo "  Reverse Shield — EUR→USD protection"
echo "============================================================"
echo "  Subscriber:   US Traveller (pays EURC premium)"
echo "  Guardian A:   Deployer     (fills 50% = 2.5 USDC)"
echo "  Guardian B:   US Company   (fills 30% = 1.5 USDC)"
echo "  Waiting for:  3rd guardian  (20% = 1.0 USDC)"
echo ""
echo "  Strike:       $STRIKE (3% above oracle)"
echo "  Notional:     5 USDC"
echo "  Premium:      0.1 EURC"
echo "  Expiry:       30 days"
echo "============================================================"
echo ""

# ============================================================
# [0] Balances before
# ============================================================
echo "=== [0] Balances before ==="
echo "  Traveller USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")"
echo "  Deployer  USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")"
echo "  Company   USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")"
echo ""

# ============================================================
# [1] Traveller creates + funds reverse shield (EURC premium)
# ============================================================
echo "=== [1] Traveller creates reverse shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address,bool)" \
  "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "0x0000000000000000000000000000000000000000" true \
  --rpc-url "$RPC" --private-key "$PK_TRAVELLER" --json | jq -r '.transactionHash'

SHIELD_ID_TMP=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID_TMP=$((SHIELD_ID_TMP - 1))

echo "=== [1b] Company funds reverse shield (EURC salary + premium + fee) ==="
FUND_TOTAL=$((NOTIONAL + PREMIUM + SUB_FEE))
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$FUND_TOTAL" \
  --rpc-url "$RPC" --private-key "$PK_COMPANY" --json > /dev/null
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID_TMP" \
  --rpc-url "$RPC" --private-key "$PK_COMPANY" --json | jq -r '.transactionHash'

SHIELD_ID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID=$((SHIELD_ID - 1))
echo "  Shield #$SHIELD_ID created (PENDING, reverse)"
echo ""

# ============================================================
# [2] Deployer fills 50% (2.5 USDC)
# ============================================================
echo "=== [2] Guardian A (Deployer) fills 50% = 2.5 USDC ==="
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$((FILL_A + FILL_A_FEE))" \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json > /dev/null
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_DEPLOYER" "$FILL_A" \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'

FILLED=$(parse "$(cast call "$BULWARC" "getShield(uint256)" "$SHIELD_ID" --rpc-url "$RPC" | sed -n '6p')")
echo "  Filled: $FILLED / $NOTIONAL"
echo ""

# ============================================================
# [3] Company fills 30% (1.5 USDC)
# ============================================================
echo "=== [3] Guardian B (Company) fills 30% = 1.5 USDC ==="
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$((FILL_B + FILL_B_FEE))" \
  --rpc-url "$RPC" --private-key "$PK_COMPANY" --json > /dev/null
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_COMPANY" "$FILL_B" \
  --rpc-url "$RPC" --private-key "$PK_COMPANY" --json | jq -r '.transactionHash'
echo ""

# ============================================================
# [4] Final state
# ============================================================
echo "=== [4] Shield #$SHIELD_ID state ==="
echo "  Shield:"
cast call "$BULWARC" "getShield(uint256)" "$SHIELD_ID" --rpc-url "$RPC"
echo ""
echo "  Fills ($(parse "$(cast call "$BULWARC" "getFillCount(uint256)(uint256)" "$SHIELD_ID" --rpc-url "$RPC")")):"
cast call "$BULWARC" "getFills(uint256)" "$SHIELD_ID" --rpc-url "$RPC"
echo ""

echo "=== Balances after ==="
echo "  Traveller USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")"
echo "  Deployer  USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")"
echo "  Company   USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")"
echo ""

echo "============================================================"
echo "  Shield #$SHIELD_ID — REVERSE (EUR→USD)"
echo "  Status: PENDING (80% filled, waiting for 20% = $REMAINING USDC)"
echo "  Fills:  Deployer=2.5 USDC (50%) + Company=1.5 USDC (30%)"
echo "  Open:   1.0 USDC for any guardian to complete"
echo ""
echo "  → Jury can connect wallet and matchShield($SHIELD_ID, their_addr, $REMAINING)"
echo "============================================================"
