#!/bin/bash
# ============================================================
# DEMO NOMINAL — Happy path, full coverage, 100% delivery
# ============================================================
# EU worker, 1 USDC salary, fully covered, 100% delivery
# Short expiry for live demo
#
# Integrates with webapp API (optional):
#   - GET /currentRatio → enters test mode, gets live Binance rate
#   - POST /endTest → exits test mode after script
#   - If webapp is down, falls back to default oracle (0.92)
#
# Usage:
#   ./bulwarc/script/demo-nominal.sh hit    → USD weakens, exercise
#   ./bulwarc/script/demo-nominal.sh miss   → stable, expire
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

# Params — nominal case (strike/hit computed from oracle)
NOTIONAL=1000000          # 1 EURC
PREMIUM=50000             # 0.05 USDC
FEE_BPS=100
SUB_FEE=$((PREMIUM * FEE_BPS / 10000))              # 500
GUARDIAN_FEE=$((NOTIONAL * FEE_BPS / 10000))         # 10000
DELIVERY_RATE=100
EXPIRY=$(($(date +%s) + 60))

PASS=0
FAIL=0

parse() { echo "$1" | awk '{print $1}'; }
bal_usdc() { parse "$(cast call "$USDC" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC")"; }
bal_eurc() { parse "$(cast call "$EURC" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC")"; }
check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $label = $actual"; PASS=$((PASS + 1))
  else
    echo "  ✗ $label = $actual (expected $expected)"; FAIL=$((FAIL + 1))
  fi
}
GAS_TOLERANCE=100000
check_approx() {
  local label="$1" actual="$2" expected="$3"
  local diff=$((actual - expected))
  if [ $diff -lt 0 ]; then diff=$((-diff)); fi
  if [ $diff -le $GAS_TOLERANCE ]; then
    echo "  ✓ $label = $actual (~$expected, gas diff=$diff)"; PASS=$((PASS + 1))
  else
    echo "  ✗ $label = $actual (expected ~$expected, diff=$diff)"; FAIL=$((FAIL + 1))
  fi
}
treasury_usdc() { parse "$(cast call "$BULWARC" "treasuryUSDC()(uint256)" --rpc-url "$RPC")"; }
treasury_eurc() { parse "$(cast call "$BULWARC" "treasuryEURC()(uint256)" --rpc-url "$RPC")"; }

# ============================================================
# Read current oracle rate and compute strike/hit
# ============================================================
echo "=== Reading on-chain oracle ==="
ORACLE_RAW=$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC")
ORACLE_RATE=$(echo "$ORACLE_RAW" | head -1 | awk '{print $1}')
echo "  Oracle EUR/USD: $ORACLE_RATE (1e8)"

STRIKE=$((ORACLE_RATE * 95 / 100))   # 5% below current
HIT_SPOT=$((ORACLE_RATE * 92 / 100)) # 8% below current
echo "  Strike: $STRIKE (5% below)"
echo "  Hit spot: $HIT_SPOT (8% below)"
echo ""

echo "============================================================"
echo "  NOMINAL DEMO — MODE: $MODE"
echo "  Full coverage | 100% delivery | isReverse=false"
echo "============================================================"
echo "  Oracle:       $ORACLE_RATE (from on-chain)"
echo "  Strike:       $STRIKE (5% below oracle)"
echo "  Hit spot:     $HIT_SPOT (8% below oracle)"
echo "  Notional:     1 EURC (100% fill)"
echo "  Premium:      0.05 USDC"
echo "  Delivery:     100%"
echo "  Expiry:       $(date -r $EXPIRY '+%H:%M:%S') (60s)"
echo "============================================================"
echo ""

# [0] Initial balances
echo "=== [0] Initial balances ==="
W_USDC_0=$(bal_usdc "$ADDR_WORKER")
W_EURC_0=$(bal_eurc "$ADDR_WORKER")
E_USDC_0=$(bal_usdc "$ADDR_EMPLOYER")
G_USDC_0=$(bal_usdc "$ADDR_GUARDIAN")
G_EURC_0=$(bal_eurc "$ADDR_GUARDIAN")
T_USDC_0=$(treasury_usdc)
T_EURC_0=$(treasury_eurc)
echo "  Worker   USDC=$W_USDC_0  EURC=$W_EURC_0"
echo "  Employer USDC=$E_USDC_0"
echo "  Guardian USDC=$G_USDC_0  EURC=$G_EURC_0"
echo "  Treasury USDC=$T_USDC_0  EURC=$T_EURC_0"
echo ""

# [1] Worker creates shield
echo "=== [1] Worker creates shield ==="
cast send "$BULWARC" \
  "createShield(uint256,uint256,uint256,uint256,address,bool)" \
  "$STRIKE" "$NOTIONAL" "$PREMIUM" "$EXPIRY" "$ADDR_DEPLOYER" false \
  --rpc-url "$RPC" --private-key "$PK_WORKER" --json | jq -r '.transactionHash'

SHIELD_ID=$(parse "$(cast call "$BULWARC" "getShieldCount()(uint256)" --rpc-url "$RPC")")
SHIELD_ID=$((SHIELD_ID - 1))
echo "  Shield #$SHIELD_ID created"
echo ""

# [3] Employer funds premium
echo "=== [2] Employer funds premium ==="
APPROVE_AMT=$((PREMIUM + SUB_FEE))
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$APPROVE_AMT" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'

E_USDC_3=$(bal_usdc "$ADDR_EMPLOYER")
E_USDC_3_EXP=$((E_USDC_0 - PREMIUM - SUB_FEE))
check_approx "Employer USDC (paid premium+fee)" "$E_USDC_3" "$E_USDC_3_EXP"
echo ""

# [4] Guardian fills 100%
echo "=== [3] Guardian fills 100% ==="
GUARDIAN_TOTAL=$((NOTIONAL + GUARDIAN_FEE))
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$GUARDIAN_TOTAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_GUARDIAN" "$NOTIONAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'

G_EURC_4=$(bal_eurc "$ADDR_GUARDIAN")
G_EURC_4_EXP=$((G_EURC_0 - NOTIONAL - GUARDIAN_FEE))
check "Guardian EURC (collateral+fee)" "$G_EURC_4" "$G_EURC_4_EXP"

G_USDC_4=$(bal_usdc "$ADDR_GUARDIAN")
G_USDC_4_EXP=$((G_USDC_0 + PREMIUM))
check_approx "Guardian USDC (received premium)" "$G_USDC_4" "$G_USDC_4_EXP"
echo "  Shield #$SHIELD_ID → LOCKED"
echo ""

# [5] Validator confirms 100% delivery
echo "=== [4] Validator confirms 100% delivery ==="
cast send "$BULWARC" "validateDelivery(uint256,uint8)" "$SHIELD_ID" "$DELIVERY_RATE" \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
echo "  deliveryRate = 100%"
echo ""

# [6-7] Settlement
if [ "$MODE" = "hit" ]; then
  echo "=== [5] Oracle drops to $HIT_SPOT (STRIKE HIT) ==="
  cast send "$ORACLE" "setPrice(int256)" "$HIT_SPOT" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json | jq -r '.transactionHash'
  echo ""

  echo "=== [5b] Waiting for expiry... ==="
  REMAINING=$((EXPIRY - $(date +%s) + 2))
  if [ $REMAINING -gt 0 ]; then
    echo "  Sleeping $REMAINING seconds..."
    sleep $REMAINING
  fi
  echo ""

  echo "=== [6] Settle shield (in the money → swap) ==="
  TX=$(cast send "$BULWARC" "settle(uint256)" "$SHIELD_ID" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json)
  echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
  echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
  echo ""

  # Settle in the money = swap
  # collateralToWorker = NOTIONAL * DELIVERY_RATE / 100 = 1000000 (100%)
  COLLATERAL_TO_WORKER=$((NOTIONAL * DELIVERY_RATE / 100))
  COLLATERAL_BACK=$((NOTIONAL - COLLATERAL_TO_WORKER))
  # Guardian gets full USDC salary (notional * guardianAmount / filled = NOTIONAL)
  SALARY_TO_GUARDIAN=$NOTIONAL

  echo "=== [7] Verify balances ==="

  W_EURC_F=$(bal_eurc "$ADDR_WORKER")
  W_EURC_F_EXP=$((W_EURC_0 + COLLATERAL_TO_WORKER))
  check "Worker EURC (collateral=$COLLATERAL_TO_WORKER)" "$W_EURC_F" "$W_EURC_F_EXP"

  W_USDC_F=$(bal_usdc "$ADDR_WORKER")
  check_approx "Worker USDC (no refund, gas only)" "$W_USDC_F" "$W_USDC_0"

  G_EURC_F=$(bal_eurc "$ADDR_GUARDIAN")
  G_EURC_F_EXP=$((G_EURC_4 + COLLATERAL_BACK))
  check "Guardian EURC (back=$COLLATERAL_BACK)" "$G_EURC_F" "$G_EURC_F_EXP"

  G_USDC_F=$(bal_usdc "$ADDR_GUARDIAN")
  G_USDC_F_EXP=$((G_USDC_4 + SALARY_TO_GUARDIAN))
  check_approx "Guardian USDC (salary=$SALARY_TO_GUARDIAN)" "$G_USDC_F" "$G_USDC_F_EXP"

  T_USDC_F=$(treasury_usdc)
  T_USDC_F_EXP=$((T_USDC_0 + SUB_FEE))
  check "Treasury USDC (full fee)" "$T_USDC_F" "$T_USDC_F_EXP"

  T_EURC_F=$(treasury_eurc)
  T_EURC_F_EXP=$((T_EURC_0 + GUARDIAN_FEE))
  check "Treasury EURC (guardian fee)" "$T_EURC_F" "$T_EURC_F_EXP"

  echo ""
  echo "  Summary: Full coverage, 100% delivery, strike hit → swap"
  echo "  Worker: got $COLLATERAL_TO_WORKER EURC collateral"
  echo "  Guardian: got $SALARY_TO_GUARDIAN USDC salary + kept $PREMIUM USDC premium"
  echo "  Protocol fees: $SUB_FEE USDC + $GUARDIAN_FEE EURC"

else
  echo "=== [5] Waiting for expiry... ==="
  REMAINING=$((EXPIRY - $(date +%s) + 2))
  if [ $REMAINING -gt 0 ]; then
    echo "  Sleeping $REMAINING seconds..."
    sleep $REMAINING
  fi
  echo ""

  echo "=== [6] Settle shield (out of money → refund) ==="
  TX=$(cast send "$BULWARC" "settle(uint256)" "$SHIELD_ID" \
    --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json)
  echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
  echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
  echo ""

  echo "=== [7] Verify balances ==="

  W_EURC_F=$(bal_eurc "$ADDR_WORKER")
  check "Worker EURC unchanged" "$W_EURC_F" "$W_EURC_0"

  # Worker gets USDC salary back (refund)
  W_USDC_F=$(bal_usdc "$ADDR_WORKER")
  W_USDC_F_EXP=$((W_USDC_0 + NOTIONAL))
  check_approx "Worker USDC (salary back=$NOTIONAL)" "$W_USDC_F" "$W_USDC_F_EXP"

  G_EURC_F=$(bal_eurc "$ADDR_GUARDIAN")
  G_EURC_F_EXP=$((G_EURC_4 + NOTIONAL))
  check "Guardian EURC (full collateral back)" "$G_EURC_F" "$G_EURC_F_EXP"

  T_USDC_F=$(treasury_usdc)
  T_USDC_F_EXP=$((T_USDC_0 + SUB_FEE))
  check "Treasury USDC (full fee)" "$T_USDC_F" "$T_USDC_F_EXP"

  T_EURC_F=$(treasury_eurc)
  T_EURC_F_EXP=$((T_EURC_0 + GUARDIAN_FEE))
  check "Treasury EURC (guardian fee)" "$T_EURC_F" "$T_EURC_F_EXP"

  echo ""
  echo "  Summary: Full coverage, 100% delivery, strike not reached"
  echo "  Worker: no payoff (FX stable)"
  echo "  Guardian: full collateral back + kept $PREMIUM USDC premium"
  echo "  Protocol fees: $SUB_FEE USDC + $GUARDIAN_FEE EURC"
fi

echo ""
echo "=== Final Treasury ==="
echo "  USDC: $(treasury_usdc)"
echo "  EURC: $(treasury_eurc)"
echo ""
echo "============================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================================"
