#!/bin/bash
# ============================================================
# Generate varied shields to populate the order book
# ============================================================
# Creates ~20 shields with different params, statuses, expiries
# Uses all wallets EXCEPT EU_Remote_Worker
# Idempotent: checks existing shield count, skips if already populated
#
# Usage:
#   ./bulwarc/script/generate-multiple-random-shield.sh
#   ./bulwarc/script/generate-multiple-random-shield.sh --force  (ignore existing shields)
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
TARGET=20

parse() { echo "$1" | awk '{print $1}'; }

# ============================================================
# Idempotency check
# ============================================================
CURRENT=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
echo "=== Current shield count: $CURRENT ==="

if [ "$CURRENT" -ge "$TARGET" ] && [ "$1" != "--force" ]; then
  echo "Already $CURRENT shields (target=$TARGET). Use --force to add more."
  exit 0
fi

echo "Creating shields to populate order book..."
echo ""

# ============================================================
# Helper: create + optionally fund + optionally match
# ============================================================
# Args: $1=PK_SUB $2=ADDR_SUB $3=strike $4=notional $5=premium $6=expiry $7=isReverse $8=status(C/P/L) $9=PK_GUARD $10=ADDR_GUARD
make_shield() {
  local PK_SUB="$1" ADDR_SUB="$2" STRIKE="$3" NOTIONAL="$4" PREMIUM="$5" EXPIRY="$6" REVERSE="$7" TARGET_STATUS="$8" PK_GUARD="$9" ADDR_GUARD="${10}"

  local SUB_FEE=$(((NOTIONAL + PREMIUM) * FEE_BPS / 10000))
  local GUARD_FEE=$((NOTIONAL * FEE_BPS / 10000))
  local LABEL="strike=$STRIKE not=$NOTIONAL rev=$REVERSE → $TARGET_STATUS"

  # Determine tokens
  if [ "$REVERSE" = "true" ]; then
    local SALARY_TOKEN="$EURC"
    local COLLATERAL_TOKEN="$USDC"
  else
    local SALARY_TOKEN="$USDC"
    local COLLATERAL_TOKEN="$EURC"
  fi

  if [ "$TARGET_STATUS" = "C" ]; then
    # CREATED only — no funds
    echo -n "  [$LABEL] createShield... "
    cast send "$BULWARC" \
      "createShield(uint256,uint256,uint256,uint256,address,bool)" \
      "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "0x0000000000000000000000000000000000000000" "$REVERSE" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json | jq -r '.transactionHash'

  elif [ "$TARGET_STATUS" = "P" ]; then
    # PENDING — create + fund (same wallet acts as sub + funder for demo)
    local FUND_TOTAL=$((NOTIONAL + PREMIUM + SUB_FEE))
    echo -n "  [$LABEL] create+fund... "
    cast send "$BULWARC" \
      "createShield(uint256,uint256,uint256,uint256,address,bool)" \
      "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "0x0000000000000000000000000000000000000000" "$REVERSE" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json > /dev/null

    local SID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
    SID=$((SID - 1))

    cast send "$SALARY_TOKEN" "approve(address,uint256)" "$BULWARC" "$FUND_TOTAL" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json > /dev/null
    cast send "$BULWARC" "fundShield(uint256)" "$SID" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json | jq -r '.transactionHash'

  elif [ "$TARGET_STATUS" = "L" ]; then
    # LOCKED — create + fund + match
    local FUND_TOTAL=$((NOTIONAL + PREMIUM + SUB_FEE))
    echo -n "  [$LABEL] create+fund+match... "
    cast send "$BULWARC" \
      "createShield(uint256,uint256,uint256,uint256,address,bool)" \
      "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "0x0000000000000000000000000000000000000000" "$REVERSE" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json > /dev/null

    local SID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
    SID=$((SID - 1))

    cast send "$SALARY_TOKEN" "approve(address,uint256)" "$BULWARC" "$FUND_TOTAL" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json > /dev/null
    cast send "$BULWARC" "fundShield(uint256)" "$SID" \
      --rpc-url "$RPC" --private-key "$PK_SUB" --json > /dev/null

    local GUARD_TOTAL=$((NOTIONAL + GUARD_FEE))
    cast send "$COLLATERAL_TOKEN" "approve(address,uint256)" "$BULWARC" "$GUARD_TOTAL" \
      --rpc-url "$RPC" --private-key "$PK_GUARD" --json > /dev/null
    cast send "$BULWARC" \
      "matchShield(uint256,address,uint256)" \
      "$SID" "$ADDR_GUARD" "$NOTIONAL" \
      --rpc-url "$RPC" --private-key "$PK_GUARD" --json | jq -r '.transactionHash'
  fi
}

NOW=$(date +%s)
E_7D=$((NOW + 7 * 86400))
E_30D=$((NOW + 30 * 86400))
E_180D=$((NOW + 180 * 86400))

echo "=== Normal shields (isReverse=false) — sub=USDC, guard=EURC ==="
echo ""

# CREATED — various strikes and expiries (no funds needed)
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   90000000 500000  10000 "$E_7D"   false C
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 91000000 300000  8000  "$E_30D"  false C
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  93000000 200000  5000  "$E_180D" false C

# PENDING — funded, waiting for guardians
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   89000000 400000  12000 "$E_7D"   false P
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 92000000 600000  15000 "$E_30D"  false P
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  91500000 250000  7000  "$E_30D"  false P
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   90500000 350000  9000  "$E_180D" false P

# LOCKED — fully matched
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   92000000 200000  6000  "$E_30D"  false L "$PK_TRAVELLER" "$ADDR_TRAVELLER"
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  91000000 300000  8000  "$E_7D"   false L "$PK_TRAVELLER" "$ADDR_TRAVELLER"
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 90000000 150000  4000  "$E_180D" false L "$PK_COMPANY"   "$ADDR_COMPANY"

echo ""
echo "=== Reverse shields (isReverse=true) — sub=EURC, guard=USDC ==="
echo ""

# CREATED
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 93000000 400000  10000 "$E_7D"   true C
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   94000000 250000  6000  "$E_30D"  true C
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  92500000 300000  8000  "$E_180D" true C

# PENDING
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 93500000 350000  9000  "$E_30D"  true P
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   94500000 200000  5000  "$E_7D"   true P
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  92000000 450000  11000 "$E_180D" true P

# LOCKED
make_shield "$PK_TRAVELLER" "$ADDR_TRAVELLER" 93000000 200000  5000  "$E_30D"  true L "$PK_DEPLOYER"  "$ADDR_DEPLOYER"
make_shield "$PK_COMPANY"   "$ADDR_COMPANY"   94000000 150000  4000  "$E_7D"   true L "$PK_TRAVELLER" "$ADDR_TRAVELLER"
make_shield "$PK_DEPLOYER"  "$ADDR_DEPLOYER"  92500000 250000  7000  "$E_180D" true L "$PK_COMPANY"   "$ADDR_COMPANY"

echo ""
echo "============================================================"
FINAL=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
echo "  Shields before: $CURRENT"
echo "  Shields after:  $FINAL"
echo "  Created:        $((FINAL - CURRENT))"
echo ""

echo "=== Wallet balances ==="
echo "  Deployer  USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_DEPLOYER" --rpc-url "$RPC")")"
echo "  Company   USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_COMPANY" --rpc-url "$RPC")")"
echo "  Traveller USDC=$(parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$ADDR_TRAVELLER" --rpc-url "$RPC")")"
echo ""
echo "  Treasury  USDC=$(parse "$(cast call "$BULWARC" "treasuryUSDC()(uint256)" --rpc-url "$RPC")")  EURC=$(parse "$(cast call "$BULWARC" "treasuryEURC()(uint256)" --rpc-url "$RPC")")"
echo "============================================================"
