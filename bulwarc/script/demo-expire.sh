#!/bin/bash
# ============================================================
# DEMO EXPIRE — Remote worker shield expires (not exercised)
# ============================================================
# Creates a shield for EU_Remote_Worker, funds it, matches it,
# validates delivery, waits for expiry, then expires.
# Guardian gets full collateral back.
#
# Usage:
#   ./bulwarc/script/demo-expire.sh
# ============================================================

set -e

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

FEE_BPS=100
NOTIONAL=1000000
PREMIUM=50000
SUB_FEE=$((PREMIUM * FEE_BPS / 10000))
GUARDIAN_FEE=$((NOTIONAL * FEE_BPS / 10000))
EXPIRY=$(($(date +%s) + 45))  # 45 sec — short for demo

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

# Read oracle
ORACLE_RATE=$(parse "$(cast call "$ORACLE" "getPrice()(int256,uint256)" --rpc-url "$RPC" | head -1)")
STRIKE=$((ORACLE_RATE * 95 / 100))

echo "============================================================"
echo "  EXPIRE DEMO — EU Remote Worker"
echo "============================================================"
echo "  Oracle:   $ORACLE_RATE"
echo "  Strike:   $STRIKE (5% below — won't be reached)"
echo "  Notional: 1 EURC"
echo "  Premium:  0.05 USDC"
echo "  Expiry:   $(date -r $EXPIRY '+%H:%M:%S') (45s)"
echo "============================================================"
echo ""

# [0] Balances before
echo "=== [0] Initial balances ==="
W_USDC_0=$(bal_usdc "$ADDR_WORKER")
W_EURC_0=$(bal_eurc "$ADDR_WORKER")
G_USDC_0=$(bal_usdc "$ADDR_GUARDIAN")
G_EURC_0=$(bal_eurc "$ADDR_GUARDIAN")
echo "  Worker   USDC=$W_USDC_0  EURC=$W_EURC_0"
echo "  Guardian USDC=$G_USDC_0  EURC=$G_EURC_0"
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

# [2] Employer funds
echo "=== [2] Employer funds premium ==="
APPROVE=$((PREMIUM + SUB_FEE))
cast send "$USDC" "approve(address,uint256)" "$BULWARC" "$APPROVE" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json > /dev/null
cast send "$BULWARC" "fundShield(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_EMPLOYER" --json | jq -r '.transactionHash'
echo ""

# [3] Guardian fills 100%
echo "=== [3] Guardian fills 100% ==="
GUARD_TOTAL=$((NOTIONAL + GUARDIAN_FEE))
cast send "$EURC" "approve(address,uint256)" "$BULWARC" "$GUARD_TOTAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json > /dev/null
cast send "$BULWARC" \
  "matchShield(uint256,address,uint256)" \
  "$SHIELD_ID" "$ADDR_GUARDIAN" "$NOTIONAL" \
  --rpc-url "$RPC" --private-key "$PK_GUARDIAN" --json | jq -r '.transactionHash'

G_EURC_3=$(bal_eurc "$ADDR_GUARDIAN")
G_EURC_3_EXP=$((G_EURC_0 - NOTIONAL - GUARDIAN_FEE))
check "Guardian EURC after match" "$G_EURC_3" "$G_EURC_3_EXP"
echo "  Shield #$SHIELD_ID → LOCKED"
echo ""

# [4] Wait for expiry
echo "=== [4] Waiting for expiry... ==="
REMAINING=$((EXPIRY - $(date +%s) + 2))
if [ $REMAINING -gt 0 ]; then
  echo "  Sleeping $REMAINING seconds..."
  sleep $REMAINING
fi
echo ""

# [5] Settle — anyone can call after expiry
echo "=== [5] Settle shield (out of money → refund) ==="
TX=$(cast send "$BULWARC" "settle(uint256)" "$SHIELD_ID" \
  --rpc-url "$RPC" --private-key "$PK_DEPLOYER" --json)
echo "  tx: $(echo "$TX" | jq -r '.transactionHash')"
echo "  https://testnet.arcscan.app/tx/$(echo "$TX" | jq -r '.transactionHash')"
echo ""

# [6] Verify
echo "=== [6] Verify balances ==="

# Worker: no EURC, gets USDC salary back
W_EURC_F=$(bal_eurc "$ADDR_WORKER")
check "Worker EURC unchanged" "$W_EURC_F" "$W_EURC_0"

W_USDC_F=$(bal_usdc "$ADDR_WORKER")
W_USDC_F_EXP=$((W_USDC_0 + NOTIONAL))
check_approx "Worker USDC (salary back=$NOTIONAL)" "$W_USDC_F" "$W_USDC_F_EXP"

# Guardian: full EURC collateral back
G_EURC_F=$(bal_eurc "$ADDR_GUARDIAN")
G_EURC_F_EXP=$((G_EURC_3 + NOTIONAL))
check "Guardian EURC (full collateral back)" "$G_EURC_F" "$G_EURC_F_EXP"

echo ""
echo "  Summary:"
echo "  Shield #$SHIELD_ID expired — strike not reached"
echo "  Worker: protected but didn't need it (FX was stable)"
echo "  Guardian: kept 0.05 USDC premium + got 1 EURC collateral back"
echo "  Employer: premium spent (cost of protection)"
echo ""
echo "============================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================================"
