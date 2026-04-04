#!/bin/bash
# ============================================================
# DEMO — Reverse Shield (EUR→USD protection)
# ============================================================
# Use case: US traveller going to Europe wants USD protection
# Subscriber pays EURC premium, Guardian deposits USDC collateral
#
# Roles:
#   Deployer       = oracle owner + validator
#   US_Traveller   = subscriber (wants USD if EUR weakens)
#   US_Company     = employer (funds EURC premium on behalf)
#   EU_Remote_Worker = guardian (deposits USDC collateral)
#
# Usage:
#   ./bulwarc/script/demo-reverse-shield.sh hit    → EUR weakens, exercise
#   ./bulwarc/script/demo-reverse-shield.sh miss   → EUR stable, expire
# ============================================================

set -e

MODE=${1:-hit}
if [ "$MODE" != "hit" ] && [ "$MODE" != "miss" ]; then
  echo "Usage: $0 [hit|miss]"
  exit 1
fi

source bulwarc/.env

BULWARC=$BULWARC_ADDRESS
ORACLE=$MOCK_ORACLE_ADDRESS
USDC="0x3600000000000000000000000000000000000000"
EURC="0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
RPC="$ARC_TESTNET_RPC_URL"

PK_DEPLOYER="$PRIVATE_KEY"
PK_SUBSCRIBER="$US_Traveller"
PK_EMPLOYER="$US_Company"
PK_GUARDIAN="$EU_Remote_Worker"

ADDR_DEPLOYER="0x8aeEe14Aa4f2eC295E4483bf8aAc6Ad80C63aF1E"
ADDR_SUBSCRIBER="0x446b6da199fdA020a0fAD6fffe2ECE9db693552d"
ADDR_EMPLOYER="0x24273C6eded4D04D34B047F988601D58EDf899bf"
ADDR_GUARDIAN="0xf9514b43972595a3329750A459165236e758af09"

# Shield params (REVERSE mode)
STRIKE=92000000           # 0.92 EUR/USD
NOTIONAL=1000000          # 1 USDC (guardian collateral)
PREMIUM=50000             # 0.05 EURC (subscriber premium)
FEE_BPS=100
SUB_FEE=$((PREMIUM * FEE_BPS / 10000))              # 500
GUARDIAN_AMOUNT=600000     # 0.6 USDC (60% fill)
GUARDIAN_FEE=$((GUARDIAN_AMOUNT * FEE_BPS / 10000))  # 6000
DELIVERY_RATE=50
EXPIRY=$(($(date +%s) + 90))

PASS=0
FAIL=0

# ============================================================
# Helpers
# ============================================================
parse() { echo "$1" | awk '{print $1}'; }
bal_usdc() { parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC")"; }
bal_eurc() { parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC")"; }

check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $label = $actual"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label = $actual (expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

GAS_TOLERANCE=100000
check_approx() {
  local label="$1" actual="$2" expected="$3"
  local diff=$((actual - expected))
  if [ $diff -lt 0 ]; then diff=$((-diff)); fi
  if [ $diff -le $GAS_TOLERANCE ]; then
    echo "  ✓ $label = $actual (~$expected, gas diff=$diff)"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label = $actual (expected ~$expected, diff=$diff > tolerance $GAS_TOLERANCE)"
    FAIL=$((FAIL + 1))
  fi
}

treasury_usdc() { parse "$(cast call "$BULWARC" "treasuryUSDC()(uint256)" --rpc-url "$RPC")"; }
treasury_eurc() { parse "$(cast call "$BULWARC" "treasuryEURC()(uint256)" --rpc-url "$RPC")"; }

echo "============================================================"
echo "  REVERSE SHIELD DEMO — MODE: $MODE"
echo "============================================================"
echo "  isReverse: true"
echo "  Subscriber: US Traveller (pays EURC premium)"
echo "  Employer:   US Company (funds EURC on behalf)"
echo "  Guardian:   EU Worker (deposits USDC collateral)"
echo ""
echo "  Strike:     0.92 EUR/USD"
echo "  Notional:   1 USDC"
echo "  Premium:    0.05 EURC"
echo "  Fill:       60% (0.6 USDC)"
echo "  Delivery:   50%"
echo "  Expiry:     $(date -r $EXPIRY '+%H:%M:%S')"
echo "============================================================"
echo ""

# ============================================================
# [0] Initial balances
# ============================================================
echo "=== [0] Initial balances ==="
S_USDC_0=$(bal_usdc "$ADDR_SUBSCRIBER")
S_EURC_0=$(bal_eurc "$ADDR_SUBSCRIBER")
E_USDC_0=$(bal_usdc "$ADDR_EMPLOYER")
E_EURC_0=$(bal_eurc "$ADDR_EMPLOYER")
G_USDC_0=$(bal_usdc "$ADDR_GUARDIAN")
G_EURC_0=$(bal_eurc "$ADDR_GUARDIAN")
echo "  Subscriber  USDC=$S_USDC_0  EURC=$S_EURC_0"
echo "  Employer    USDC=$E_USDC_0  EURC=$E_EURC_0"
echo "  Guardian    USDC=$G_USDC_0  EURC=$G_EURC_0"
T_USDC_0=$(treasury_usdc)
T_EURC_0=$(treasury_eurc)
echo "  Treasury    USDC=$T_USDC_0  EURC=$T_EURC_0"
echo ""

# ============================================================
# [1] Set oracle to 0.92
# ============================================================
echo "=== [1] Set oracle to 0.92 EUR/USD ==="
cast send "$ORACLE" "setPrice(int256)" 92000000 \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
echo ""

# ============================================================
# [2] Subscriber creates REVERSE shield (validator=deployer)
# ============================================================
echo "=== [2] Subscriber creates reverse shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address,bool)" \
  "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "$ADDR_DEPLOYER" true \
  --rpc-url "$RPC" --private-key "$PK_SUBSCRIBER" --json | jq -r '.transactionHash'

SHIELD_ID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID=$((SHIELD_ID - 1))
echo "  Shield #$SHIELD_ID created (REVERSE, status: CREATED)"

# No funds moved (only gas)
S_EURC_2=$(bal_eurc "$ADDR_SUBSCRIBER")
check "Subscriber EURC unchanged" "$S_EURC_2" "$S_EURC_0"
echo ""

# ============================================================
# [3] Employer funds EURC premium on behalf
# ============================================================
echo "=== [3] Employer funds EURC premium (0.05 EURC + fee) ==="
APPROVE_AMT=$((PREMIUM + SUB_FEE))
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$APPROVE_AMT" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'

# Employer paid EURC premium + fee
E_EURC_3=$(bal_eurc "$ADDR_EMPLOYER")
E_EURC_3_EXP=$((E_EURC_0 - PREMIUM - SUB_FEE))
check "Employer EURC after fund" "$E_EURC_3" "$E_EURC_3_EXP"

# Treasury got EURC fee
T_EURC_3=$(treasury_eurc)
T_EURC_3_EXP=$((T_EURC_0 + SUB_FEE))
check "Treasury EURC (sub fee)" "$T_EURC_3" "$T_EURC_3_EXP"
echo ""

# ============================================================
# [4] Guardian fills 60% in USDC
# ============================================================
echo "=== [4] Guardian fills 60% (0.6 USDC + fee) ==="
GUARDIAN_TOTAL=$((GUARDIAN_AMOUNT + GUARDIAN_FEE))
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$GUARDIAN_TOTAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_GUARDIAN" "$GUARDIAN_AMOUNT" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'

# Guardian paid USDC collateral + fee
G_USDC_4=$(bal_usdc "$ADDR_GUARDIAN")
G_USDC_4_EXP=$((G_USDC_0 - GUARDIAN_AMOUNT - GUARDIAN_FEE))
check_approx "Guardian USDC after match" "$G_USDC_4" "$G_USDC_4_EXP"

# Guardian received EURC premium share (60% of 50000 = 30000)
PREMIUM_SHARE=$((PREMIUM * GUARDIAN_AMOUNT / NOTIONAL))
G_EURC_4=$(bal_eurc "$ADDR_GUARDIAN")
G_EURC_4_EXP=$((G_EURC_0 + PREMIUM_SHARE))
check "Guardian EURC after match (premium)" "$G_EURC_4" "$G_EURC_4_EXP"

# Treasury got USDC fee from guardian
T_USDC_4=$(treasury_usdc)
T_USDC_4_EXP=$((T_USDC_0 + GUARDIAN_FEE))
check_approx "Treasury USDC (guard fee)" "$T_USDC_4" "$T_USDC_4_EXP"
echo ""

# ============================================================
# [5] Validator confirms 50% delivery
# ============================================================
echo "=== [5] Validator confirms 50% delivery ==="
cast send "$BULWARC" "validateDelivery(uint256,uint8)" "$SHIELD_ID" "$DELIVERY_RATE" \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
echo "  deliveryRate = 50%"
echo ""

# ============================================================
# [6-7] Settlement
# ============================================================

if [ "$MODE" = "hit" ]; then
  SPOT=96000000  # 0.96 — EUR weakens (spot > strike) → subscriber wins

  echo "=== [6] Oracle rises to 0.96 (EUR WEAKENS → STRIKE HIT) ==="
  cast send "$ORACLE" "setPrice(int256)" "$SPOT" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
  echo ""

  echo "=== [7] Subscriber exercises ==="
  TX=$(cast send "$BULWARC" "exercise(uint256)" "$SHIELD_ID" \
    --rpc-url "$RPC" --private-key "$PK_SUBSCRIBER" --json)
  echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
  echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
  echo ""

  # Expected:
  # strikeDiff = 96000000 - 92000000 = 4000000
  # payoff = 4000000 * 600000 * 50 / (92000000 * 100) = 13043
  PAYOFF=$((4000000 * GUARDIAN_AMOUNT * DELIVERY_RATE / (STRIKE * 100)))
  GUARDIAN_RETURN=$((GUARDIAN_AMOUNT - PAYOFF))

  # Fee refund: usedFee = 500 * 600000 * 50 / (1000000 * 100) = 150
  USED_FEE=$((SUB_FEE * GUARDIAN_AMOUNT * DELIVERY_RATE / (NOTIONAL * 100)))
  FEE_REFUND=$((SUB_FEE - USED_FEE))

  echo "=== [8] Verify balances ==="

  # Subscriber gets USDC payoff (collateral token in reverse = USDC)
  S_USDC_F=$(bal_usdc "$ADDR_SUBSCRIBER")
  S_USDC_F_EXP=$((S_USDC_0 + PAYOFF))
  check_approx "Subscriber USDC (payoff=$PAYOFF)" "$S_USDC_F" "$S_USDC_F_EXP"

  # Subscriber gets EURC fee refund (premium token in reverse = EURC)
  S_EURC_F=$(bal_eurc "$ADDR_SUBSCRIBER")
  S_EURC_F_EXP=$((S_EURC_0 + FEE_REFUND))
  check "Subscriber EURC (fee refund=$FEE_REFUND)" "$S_EURC_F" "$S_EURC_F_EXP"

  # Guardian gets remaining USDC collateral back
  G_USDC_F=$(bal_usdc "$ADDR_GUARDIAN")
  G_USDC_F_EXP=$((G_USDC_4 + GUARDIAN_RETURN))
  check_approx "Guardian USDC (return=$GUARDIAN_RETURN)" "$G_USDC_F" "$G_USDC_F_EXP"

  echo ""
  echo "  Summary (REVERSE — EUR weakened):"
  echo "  Subscriber (US traveller) gets $PAYOFF USDC payoff"
  echo "  Guardian (EU worker) keeps EURC premium + gets $GUARDIAN_RETURN USDC back"
  echo "  Fee refund: $FEE_REFUND EURC to subscriber"

else
  echo "=== [6] Waiting for expiry... ==="
  REMAINING=$((EXPIRY - $(date +%s) + 2))
  if [ $REMAINING -gt 0 ]; then
    echo "  Sleeping $REMAINING seconds..."
    sleep $REMAINING
  fi
  echo ""

  echo "=== [7] Expire shield ==="
  TX=$(cast send "$BULWARC" "expire(uint256)" "$SHIELD_ID" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json)
  echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
  echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
  echo ""

  # Fee refund on expire: rate=100, usedFee = 500 * 600000 * 100 / (1000000 * 100) = 300
  USED_FEE=$((SUB_FEE * GUARDIAN_AMOUNT / NOTIONAL))
  FEE_REFUND=$((SUB_FEE - USED_FEE))

  echo "=== [8] Verify balances ==="

  # Subscriber: no USDC payoff
  S_USDC_F=$(bal_usdc "$ADDR_SUBSCRIBER")
  check_approx "Subscriber USDC unchanged" "$S_USDC_F" "$S_USDC_0"

  # Subscriber gets EURC fee refund (partial fill)
  S_EURC_F=$(bal_eurc "$ADDR_SUBSCRIBER")
  S_EURC_F_EXP=$((S_EURC_0 + FEE_REFUND))
  check "Subscriber EURC (fee refund=$FEE_REFUND)" "$S_EURC_F" "$S_EURC_F_EXP"

  # Guardian gets full USDC collateral back
  G_USDC_F=$(bal_usdc "$ADDR_GUARDIAN")
  G_USDC_F_EXP=$((G_USDC_4 + GUARDIAN_AMOUNT))
  check_approx "Guardian USDC (full collateral back)" "$G_USDC_F" "$G_USDC_F_EXP"

  echo ""
  echo "  Summary (REVERSE — EUR stable):"
  echo "  Strike not reached → shield expired"
  echo "  Guardian keeps EURC premium ($PREMIUM_SHARE) + gets USDC collateral back"
  echo "  Fee refund: $FEE_REFUND EURC to subscriber (40% unfilled)"
fi

echo ""
echo "=== Treasury ==="
echo "  USDC: $(treasury_usdc)"
echo "  EURC: $(treasury_eurc)"
echo ""
echo "============================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================================"
