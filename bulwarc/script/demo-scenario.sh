#!/bin/bash
# ============================================================
# DEMO SCENARIO — BulwArc on Arc Testnet
# ============================================================
# Usage:
#   ./tmp/demo-scenario.sh hit     → strike reached, exercise
#   ./tmp/demo-scenario.sh miss    → strike not reached, expire
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
PK_WORKER="$EU_Remote_Worker"
PK_EMPLOYER="$US_Company"
PK_GUARDIAN="$US_Traveller"

ADDR_DEPLOYER="0x8aeEe14Aa4f2eC295E4483bf8aAc6Ad80C63aF1E"
ADDR_WORKER="0xf9514b43972595a3329750A459165236e758af09"
ADDR_EMPLOYER="0x24273C6eded4D04D34B047F988601D58EDf899bf"
ADDR_GUARDIAN="0x446b6da199fdA020a0fAD6fffe2ECE9db693552d"

# Params
STRIKE=87400000           # 0.874 EUR/USD
NOTIONAL=1000000          # 1 EURC
PREMIUM=50000             # 0.05 USDC
FEE_BPS=100
SUB_FEE=$((PREMIUM * FEE_BPS / 10000))                # 500
GUARDIAN_AMOUNT=600000     # 0.6 EURC (60%)
GUARDIAN_FEE=$((GUARDIAN_AMOUNT * FEE_BPS / 10000))    # 6000
DELIVERY_RATE=50
EXPIRY=$(($(date +%s) + 90))

PASS=0
FAIL=0

# ============================================================
# Helpers
# ============================================================
# Parse cast output: "14989996 [1.498e7]" → "14989996"
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
# Approximate check with tolerance (for USDC balances affected by gas)
GAS_TOLERANCE=100000  # 0.1 USDC max gas tolerance
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
echo "  DEMO — MODE: $MODE"
echo "  Strike: 0.874 | Notional: 1 EURC | Premium: 0.05 USDC"
echo "  Guardian fill: 60% | Delivery: 50%"
echo "============================================================"
echo ""

# ============================================================
# [0] Initial balances
# ============================================================
echo "=== [0] Initial balances ==="
W_USDC_0=$(bal_usdc "$ADDR_WORKER")
W_EURC_0=$(bal_eurc "$ADDR_WORKER")
E_USDC_0=$(bal_usdc "$ADDR_EMPLOYER")
G_USDC_0=$(bal_usdc "$ADDR_GUARDIAN")
G_EURC_0=$(bal_eurc "$ADDR_GUARDIAN")
echo "  Worker   USDC=$W_USDC_0  EURC=$W_EURC_0"
echo "  Employer USDC=$E_USDC_0"
echo "  Guardian USDC=$G_USDC_0  EURC=$G_EURC_0"
echo ""

# ============================================================
# [1] Set oracle to 0.92
# ============================================================
echo "=== [1] Set oracle to 0.92 ==="
cast send "$ORACLE" "setPrice(int256)" 92000000 \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
echo ""

# ============================================================
# [2] Worker creates shield
# ============================================================
echo "=== [2] Worker creates shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address)" \
  "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "$ADDR_DEPLOYER" \
  --rpc-url "$RPC" --private-key "$PK_WORKER" --json | jq -r '.transactionHash'

SHIELD_ID=$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")
SHIELD_ID=$((SHIELD_ID - 1))
echo "  Shield #$SHIELD_ID created"

# Check: no funds moved (only gas spent)
W_USDC_2=$(bal_usdc "$ADDR_WORKER")
check_approx "Worker USDC after create (gas only)" "$W_USDC_2" "$W_USDC_0"
echo ""

# ============================================================
# [3] Employer funds premium
# ============================================================
echo "=== [3] Employer funds premium (0.05 USDC + 0.0005 fee) ==="
APPROVE_AMT=$((PREMIUM + SUB_FEE))
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$APPROVE_AMT" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'

# Check: employer paid premium + fee
E_USDC_3=$(bal_usdc "$ADDR_EMPLOYER")
E_USDC_3_EXP=$((E_USDC_0 - PREMIUM - SUB_FEE))
check_approx "Employer USDC after fund" "$E_USDC_3" "$E_USDC_3_EXP"

# Check: treasury got fee
T_USDC_3=$(treasury_usdc)
echo "  Treasury USDC: $T_USDC_3 (includes previous shields)"
echo ""

# ============================================================
# [4] Guardian fills 60% in EURC
# ============================================================
echo "=== [4] Guardian fills 60% (0.6 EURC + fee) ==="
GUARDIAN_TOTAL=$((GUARDIAN_AMOUNT + GUARDIAN_FEE))
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$GUARDIAN_TOTAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_GUARDIAN" "$GUARDIAN_AMOUNT" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'

# Check: guardian paid EURC collateral + fee
G_EURC_4=$(bal_eurc "$ADDR_GUARDIAN")
G_EURC_4_EXP=$((G_EURC_0 - GUARDIAN_AMOUNT - GUARDIAN_FEE))
check "Guardian EURC after match" "$G_EURC_4" "$G_EURC_4_EXP"

# Check: guardian received USDC premium share (60% of 50000 = 30000)
PREMIUM_SHARE=$((PREMIUM * GUARDIAN_AMOUNT / NOTIONAL))
G_USDC_4=$(bal_usdc "$ADDR_GUARDIAN")
G_USDC_4_EXP=$((G_USDC_0 + PREMIUM_SHARE))
check_approx "Guardian USDC after match (premium - gas)" "$G_USDC_4" "$G_USDC_4_EXP"
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
  SPOT=85000000  # 0.85

  echo "=== [6] Oracle drops to 0.85 (STRIKE HIT) ==="
  cast send "$ORACLE" "setPrice(int256)" "$SPOT" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
  echo ""

  echo "=== [7] Worker exercises ==="
  TX=$(cast send "$BULWARC" "exercise(uint256)" "$SHIELD_ID" \
    --rpc-url "$RPC" --private-key "$PK_WORKER" --json)
  echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
  echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
  echo ""

  # Expected payoff:
  # strikeDiff = 87400000 - 85000000 = 2400000
  # payoff = strikeDiff * GUARDIAN_AMOUNT * DELIVERY_RATE / (STRIKE * 100)
  # payoff = 2400000 * 600000 * 50 / (87400000 * 100) = 8237 (truncated)
  PAYOFF=$((2400000 * GUARDIAN_AMOUNT * DELIVERY_RATE / (STRIKE * 100)))
  GUARDIAN_RETURN=$((GUARDIAN_AMOUNT - PAYOFF))

  # Fee refund: usedFee = SUB_FEE * filled * rate / (notional * 100)
  # usedFee = 500 * 600000 * 50 / (1000000 * 100) = 150
  # refund = 500 - 150 = 350
  USED_FEE=$((SUB_FEE * GUARDIAN_AMOUNT * DELIVERY_RATE / (NOTIONAL * 100)))
  FEE_REFUND=$((SUB_FEE - USED_FEE))

  echo "=== [8] Verify balances ==="

  # Worker gets EURC payoff
  W_EURC_F=$(bal_eurc "$ADDR_WORKER")
  W_EURC_F_EXP=$((W_EURC_0 + PAYOFF))
  check "Worker EURC (payoff=$PAYOFF)" "$W_EURC_F" "$W_EURC_F_EXP"

  # Worker gets USDC fee refund (minus gas from create + exercise txs)
  W_USDC_F=$(bal_usdc "$ADDR_WORKER")
  W_USDC_F_EXP=$((W_USDC_0 + FEE_REFUND))
  check_approx "Worker USDC (fee refund=$FEE_REFUND - gas)" "$W_USDC_F" "$W_USDC_F_EXP"

  # Guardian gets EURC collateral back minus payoff
  G_EURC_F=$(bal_eurc "$ADDR_GUARDIAN")
  G_EURC_F_EXP=$((G_EURC_4 + GUARDIAN_RETURN))
  check "Guardian EURC (return=$GUARDIAN_RETURN)" "$G_EURC_F" "$G_EURC_F_EXP"

  echo ""
  echo "  Summary: Worker hedged for 60% of notional at 50% delivery"
  echo "  Payoff: $PAYOFF EURC (in 1e6)"
  echo "  Fee refund: $FEE_REFUND USDC (in 1e6)"

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

  # Fee refund on expire: usedFee = SUB_FEE * filled * 100 / (notional * 100) = SUB_FEE * 60%
  # usedFee = 500 * 600000 / 1000000 = 300
  # refund = 500 - 300 = 200
  USED_FEE=$((SUB_FEE * GUARDIAN_AMOUNT / NOTIONAL))
  FEE_REFUND=$((SUB_FEE - USED_FEE))

  echo "=== [8] Verify balances ==="

  # Worker: no EURC payoff
  W_EURC_F=$(bal_eurc "$ADDR_WORKER")
  check "Worker EURC unchanged" "$W_EURC_F" "$W_EURC_0"

  # Worker gets USDC fee refund (partial fill, minus gas)
  W_USDC_F=$(bal_usdc "$ADDR_WORKER")
  W_USDC_F_EXP=$((W_USDC_0 + FEE_REFUND))
  check_approx "Worker USDC (fee refund=$FEE_REFUND - gas)" "$W_USDC_F" "$W_USDC_F_EXP"

  # Guardian gets all EURC collateral back
  G_EURC_F=$(bal_eurc "$ADDR_GUARDIAN")
  G_EURC_F_EXP=$((G_EURC_4 + GUARDIAN_AMOUNT))
  check "Guardian EURC (full collateral back)" "$G_EURC_F" "$G_EURC_F_EXP"

  echo ""
  echo "  Summary: Strike not reached, shield expired"
  echo "  Guardian keeps premium ($PREMIUM_SHARE USDC) + gets collateral back"
  echo "  Fee refund: $FEE_REFUND USDC (40% unfilled)"
fi

echo ""
echo "=== Treasury ==="
echo "  USDC: $(treasury_usdc)"
echo "  EURC: $(treasury_eurc)"
echo ""
echo "============================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================================"
