# Test Scenarios Guide

## Prerequisites

1. Contracts deployed on Arc Testnet (see [deploy-arc-testnet.md](deploy-arc-testnet.md))
2. `.env` configured with all keys and addresses:
   ```
   PRIVATE_KEY=...          # Deployer (oracle + validator)
   EU_Remote_Worker=...     # Subscriber
   US_Company=...           # Employer (funder)
   US_Traveller=...         # Guardian
   BULWARC_ADDRESS=...
   MOCK_ORACLE_ADDRESS=...
   ```
3. All accounts funded:
   - Deployer: USDC (gas)
   - Worker: USDC (gas)
   - Employer: USDC (gas + premium)
   - Guardian: USDC (gas) + EURC (collateral)

## Unit Tests (local)

```bash
cd bulwarc
forge test -vvv
```

Runs all 22+ Foundry tests: create, fund, match, exercise, expire, cancel, fees, delivery validation, partial fills.

## On-chain Demo Scenarios

Two modes available:

### Strike reached (exercise)

```bash
./bulwarc/script/demo-scenario.sh hit
```

Flow:
1. Oracle set to 0.92 EUR/USD
2. Worker creates shield (strike 0.874 = 5% protection, validator = deployer)
3. Employer funds premium (0.05 USDC + 1% fee)
4. Guardian fills 60% (0.6 EURC + 1% fee)
5. Validator confirms 50% delivery
6. Oracle drops to 0.85 → **strike reached**
7. Worker exercises → receives EURC payoff (scaled by 60% fill × 50% delivery)
8. Guardian gets remaining EURC collateral back

Expected results:
- Worker receives EURC payoff (reduced by partial fill + partial delivery)
- Worker gets USDC fee refund (only 30% of fee used: 60% fill × 50% delivery)
- Guardian keeps USDC premium share + gets leftover EURC collateral
- Protocol treasury earns fees in both USDC and EURC

### Strike not reached (expire)

```bash
./bulwarc/script/demo-scenario.sh miss
```

Flow:
1. Steps 1-5 same as above
2. Oracle stays at 0.92 → **strike not reached**
3. Wait for expiry (~90 seconds)
4. Shield expired → guardian gets full EURC collateral back

Expected results:
- Worker receives no EURC payoff
- Worker gets USDC fee refund (40% unfilled portion)
- Guardian gets full EURC collateral back + keeps USDC premium
- Protocol treasury earns partial fees

## Verification

The script automatically checks balances before and after each step:
- EURC balances: exact match (not affected by gas)
- USDC balances: approximate match (tolerance for gas costs, USDC = gas token on Arc)

Each check shows ✓ (pass) or ✗ (fail) with a final summary.

## Set Oracle Rate

```bash
./bulwarc/script/set-rate.sh <EUR/USD rate>
```

Example:
```bash
./bulwarc/script/set-rate.sh 0.85    # simulate drop
./bulwarc/script/set-rate.sh 0.92    # reset to normal
```

## Roles Summary

| Key | Role | Pays | Receives |
|---|---|---|---|
| `PRIVATE_KEY` | Deployer/Validator | Gas | - |
| `EU_Remote_Worker` | Subscriber | Gas | EURC payoff + USDC fee refund |
| `US_Company` | Employer/Funder | USDC premium + fee + gas | - |
| `US_Traveller` | Guardian | EURC collateral + fee + gas | USDC premium share |

## Troubleshooting

- **"Not created"**: Contract not redeployed after code changes. Run `deploy-and-verify.sh`
- **"gas required exceeds allowance (0)"**: Account has 0 USDC = 0 gas. Fund via [faucet](https://faucet.circle.com)
- **USDC balance mismatch**: Expected — gas is paid in USDC on Arc. The script uses approximate checks
- **"Not pending"**: Shield was not funded before match. Check shield status with `cast call`
- **"Not validated"**: Validator hasn't called `validateDelivery()` yet
