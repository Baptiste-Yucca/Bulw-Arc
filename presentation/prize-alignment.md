# BulwArc — Prize Alignment

## Prize: Best Smart Contracts on Arc with Advanced Stablecoin Logic ($3,000)

> Build and deploy smart contracts that demonstrate advanced programmable logic using USDC or EURC — such as conditional flows, onchain automation, or multi-step settlement mechanisms.

---

## Criteria Checklist

### ✅ Conditional Escrow with Onchain Dispute + Automatic Release

BulwArc is a **conditional escrow** where EURC or USDC collateral is locked and released based on **two independent onchain conditions**:

| Condition | Mechanism | Who Controls |
|---|---|---|
| **FX Price** | Oracle checks EUR/USD at exercise | Onchain oracle (MockOracle) |
| **Work Delivery** | `deliveryRate` (0-100%) scales payoff | Validator (employer / HR system) |

**Dispute resolution** is built into the contract:
- The `deliveryRate` acts as the dispute mechanism
- If the validator (employer) sets `deliveryRate = 50`, only 50% of the FX payoff is released to the subscriber
- The remaining 50% of collateral is returned to the guardian
- If `deliveryRate = 0`, exercise is blocked entirely — the guardian's collateral is fully protected
- This is **not trust-based**: the validator is chosen at shield creation, and `address(0)` disables validation entirely

**Automatic release** happens via:
- `exercise()`: triggered by subscriber when conditions are met (oracle + delivery)
- `expire()`: triggered by anyone after expiry — automatic collateral return
- Both functions are permissionless (anyone can call `expire`), enabling bot-driven settlement

**Code reference**: `exercise()` in BulwArc.sol lines 224-271

### ✅ Programmable Payroll / Vesting in USDC or EURC

BulwArc implements **programmable payroll** with FX protection as a native feature:

**The real-world scenario:**
1. A US company hires a remote worker in Portugal
2. The worker is paid $1,000/month in USDC
3. The worker needs EUR to pay rent — but the EUR/USD rate fluctuates
4. BulwArc lets the worker **lock in a minimum EUR income** via a shield

**How payroll works in the contract:**

```
Step 1: Worker creates shield
        createShield(strike=0.92, notional=1000, premium=5, expiry=30d, validator=employer)
        → No funds needed from worker

Step 2: Employer funds premium on behalf
        fundShield(shieldId)
        → Employer pays 5 USDC + fee — worker doesn't need USDC upfront

Step 3: Guardians provide EUR liquidity
        matchShield(shieldId, guardian, amount)
        → Guardians deposit EURC, receive USDC premium immediately

Step 4: Employer validates delivery
        validateDelivery(shieldId, 100)
        → Confirms worker delivered 100% of agreed work

Step 5: At expiry, if EUR/USD dropped:
        exercise(shieldId)
        → Worker receives EURC payoff, compensating for the FX loss
```

**Programmable features:**
- **On-behalf funding**: Employer pays, worker benefits (`fundShield`)
- **Delivery-gated release**: Work must be validated before exercise
- **Proportional vesting**: `deliveryRate` acts as vesting percentage — 75% delivered = 75% protection
- **Bidirectional**: `isReverse` flag enables both USD→EUR and EUR→USD protection in one contract
- **Partial fill**: Multiple guardians can provide fractional liquidity
- **Batch operations**: `createShieldBatch`, `fundShieldBatch`, `matchShieldBatch` for multi-employee payroll

**Code reference**: `fundShield()`, `validateDelivery()`, `_refundSubscriberFee()` in BulwArc.sol

### ��� Crosschain Conditional Transfer (Not Implemented — V2 Roadmap)

BulwArc currently operates on Arc Testnet only. A crosschain version using Circle Forwarder / CCTP is planned for V2:

- Employer on Ethereum mainnet deposits USDC into a forwarder
- Funds are bridged to Arc where the shield is created
- Settlement triggers a CCTP transfer back to the worker on their preferred chain

This is documented as a roadmap item, not implemented in the MVP.

---

## Advanced Stablecoin Logic Demonstrated

| Feature | USDC | EURC |
|---|---|---|
| Premium payment | ✅ (normal mode) | ✅ (reverse mode) |
| Collateral deposit | ✅ (reverse mode) | ✅ (normal mode) |
| Premium distribution to guardians | ✅ | ✅ |
| Payoff to subscriber | ✅ (reverse mode) | ✅ (normal mode) |
| Protocol fees | ✅ | ✅ |
| Treasury accumulation | ✅ | ✅ |
| Fee refund (pro-rata) | ✅ | ✅ |

**Both stablecoins are used natively** — not as wrapped tokens, not through a DEX. The contract holds, distributes, and refunds both USDC and EURC based on programmable conditions.

---

## What Makes BulwArc Advanced

| Aspect | Basic Escrow | BulwArc |
|---|---|---|
| Release condition | Single (time or approval) | Dual (oracle + delivery validation) |
| Tokens | One | Two (USDC + EURC) with direction flag |
| Parties | 2 (sender/receiver) | 3+ (subscriber, employer, guardian(s), validator) |
| Fill model | All-or-nothing | Partial fill with multiple guardians |
| Fee model | Fixed | Pro-rata refund based on fill × delivery |
| Settlement | Binary | Proportional payoff scaled by FX move + delivery |
| Direction | One-way | Bidirectional (`isReverse`) |

---

## Deployed & Verified on Arc Testnet

| Contract | Address | Verified |
|---|---|---|
| BulwArc | `0x4f1a6AcfCA1Fa10f92f1c9B06aAadc47F40894EB` | ✅ |
| MockOracle | `0x0Fa724eeb0B617a20c0A5F87D527e39D01210754` | ✅ |

- 27 unit tests passing (Foundry)
- On-chain demo scripts for both normal and reverse scenarios
- Frontend connected to live contract
