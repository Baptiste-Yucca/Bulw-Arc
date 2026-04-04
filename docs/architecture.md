# BulwArc — Architecture & Call Flows

## Overview

BulwArc is a **bidirectional conditional escrow protocol** for FX salary protection, built on Arc Testnet using USDC and EURC natively. It solves a real problem: **remote workers paid in stablecoins need protection against currency fluctuations** — in both directions.

- A **European worker** paid in USDC wants to guarantee a minimum EUR income
- A **US traveller** going to Europe wants to lock in a USD/EUR rate before their trip

BulwArc lets both create a "shield" — a conditional escrow that automatically settles based on an oracle price feed, a validated delivery rate, and protocol fees.

## How It Maps to the Prize Criteria

### 1. Conditional Escrow with Onchain Dispute + Automatic Release

BulwArc is a **multi-party conditional escrow** where funds are locked and released based on three independent conditions:

- **FX Condition** (oracle): Has the EUR/USD rate crossed the strike price?
- **Delivery Condition** (validator): Has the worker delivered the agreed work?
- **Direction** (isReverse): Which side of the FX pair is being protected?

```
                    ┌─────────────────────┐
                    │     Collateral       │
                    │  (from Guardian)     │
                    │  EURC or USDC        │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │                     │
                    │   BulwArc Escrow    │
                    │                     │
                    │  Conditions:        │
                    │  ① FX oracle check  │
                    │  ② deliveryRate > 0 │
                    │  ③ before expiry    │
                    │                     │
                    └──────┬───────┬──────┘
                           │       │
              Exercise ◄───┘       └───► Expire
              (conditions met)        (after expiry)
                    │                      │
          ┌────────▼────────┐    ┌────────▼────────���
          │ Subscriber gets │    │ Guardian gets    │
          │ payoff (scaled  │    │ collateral back  │
          │ by deliveryRate)│    │ in full          │
          └─────────────────┘    └─────────────────┘
```

The **dispute mechanism** is the `deliveryRate`: a validator (employer, bot, or HR oracle) confirms what percentage of work was actually delivered. This directly scales the payoff:

- 100% delivered → full FX protection
- 50% delivered → 50% of the FX protection payoff
- 0% delivered → exercise blocked, guardian collateral is safe

This protects guardians from paying out on undelivered work while giving subscribers proportional coverage.

### 2. Programmable Payroll / Vesting in USDC and EURC

BulwArc implements **programmable payroll** with built-in FX hedging and separation of funding:

```
Employer                         Worker/Traveller                Guardian
     │                                │                            │
     │  1. Subscriber creates shield  │                            │
     │     (strike, notional, expiry, │                            │
     │      validator, isReverse)     │                            │
     │◄───────────────────────────────│                            │
     │                                │                            │
     │  2. Employer funds premium     │                            │
     │     on behalf (fundShield)     │                            │
     │───────────────────────────────►│                            │
     │                                │                            │
     │                                │  3. Guardian deposits      │
     │                                │     collateral             │
     │                                │     (receives premium)     │
     │                                │◄───────────────────────────│
     │                                │───────────��───────────────►│
     │                                │                            │
     │  4. Validator confirms         │                            │
     │     delivery (0-100%)          │                            │
     │───────────────────────────────►│                            │
     │                                │                            │
     │                    5. At expiry: oracle checks EUR/USD      │
     │                                │                            │
     │                    ┌───────────┴───────────┐                │
     │                    │                       │                │
     │            In the money            Out of the money         │
     │            (FX moved past          (FX stable or            │
     │             strike)                 favorable)              │
     │                    │                       │                │
     │           Subscriber gets          Guardian gets            │
     │           payoff (scaled           collateral back          │
     │           by deliveryRate)         Premium already earned   │
```

**Key payroll features:**
- **Separation of concerns**: The worker creates the shield, the employer funds it. The employer doesn't need to understand DeFi — they just approve and call `fundShield`.
- **On-behalf funding**: Any address can fund a shield for any subscriber.
- **Delivery validation**: A validator confirms work completion before settlement.
- **Proportional settlement**: Partial delivery = partial protection. Fair for everyone.

### 3. Multi-Step Settlement

The shield lifecycle is a **5-step state machine** with conditional transitions:

```
CREATED ──── fundShield() ────► PENDING ──── matchShield() ────► LOCKED
   │              │                │               │                │
   │         (employer or         │          (one or many          │
   │          subscriber          │           guardians,           │
   │          pays premium)       │           partial fill)        │
   │                              │                                │
   └── cancel() ──► EXPIRED       ├── exercise() ──► EXERCISED    │
                                  │   (if validated                │
                                  │    + FX condition met)         │
                                  │                                │
                                  └── expire() ──► EXPIRED         │
                                      (after expiry)               │
                                                                   │
                                               ├── exercise() ──► EXERCISED
                                               └── expire() ──► EXPIRED
```

## Bidirectional Design

The `isReverse` flag enables both directions of FX protection in a single contract:

### Normal Mode (`isReverse = false`)

**Use case**: EU remote worker paid in USDC wants EUR income protection.

| Step | Token | Flow |
|---|---|---|
| Premium | USDC | Subscriber/Employer → Escrow → Guardian |
| Collateral | EURC | Guardian → Escrow |
| Exercise condition | `spot < strike` | USD weakens vs EUR |
| Payoff | EURC | Escrow → Subscriber |
| Collateral return | EURC | Escrow → Guardian (remaining) |

### Reverse Mode (`isReverse = true`)

**Use case**: US traveller wants to lock in a EUR rate before a trip.

| Step | Token | Flow |
|---|---|---|
| Premium | EURC | Subscriber/Employer → Escrow → Guardian |
| Collateral | USDC | Guardian → Escrow |
| Exercise condition | `spot > strike` | EUR weakens vs USD |
| Payoff | USDC | Escrow → Subscriber |
| Collateral return | USDC | Escrow → Guardian (remaining) |

### Side-by-side comparison

| | Normal | Reverse |
|---|---|---|
| Subscriber wants | EURC protection | USDC protection |
| Subscriber pays premium in | USDC | EURC |
| Guardian deposits collateral in | EURC | USDC |
| Exercise when | spot < strike | spot > strike |
| Subscriber receives | EURC payoff | USDC payoff |
| Guardian earns | USDC premium | EURC premium |

Both modes share the same fees, delivery validation, partial fill, and settlement logic.

## Protocol Fee Model

Fees are collected from **both sides** on every shield, in the token they deposit:

| Party | When | Fee basis | Token (normal) | Token (reverse) |
|---|---|---|---|---|
| Subscriber | `fundShield` | `premium × feeBps / 10000` | USDC | EURC |
| Guardian | `matchShield` | `collateral × feeBps / 10000` | EURC | USDC |

**Fee refund logic** ensures fairness across two dimensions:

```
usedFee = subscriberFee × (filled / notional) × (deliveryRate / 100)
refund  = subscriberFee - usedFee
```

- Shield **fully filled + 100% delivery** → full fee kept by protocol
- Shield **60% filled + 50% delivery** → only 30% of fee kept, 70% refunded
- Shield **cancelled** before any fill → full fee refunded
- Shield **expired** → fee prorated by fill ratio only (delivery irrelevant)

The treasury accumulates fees in **both USDC and EURC**, building reserves in both currencies regardless of shield direction.

## Partial Fill (Fractional Liquidity)

Shields support **multiple guardians** with any fill amount:

```
Shield: notional = 1000 (EURC or USDC depending on direction)

Guardian A: matchShield(0, addrA, 200)  → 20% premium share
Guardian B: matchShield(0, addrB, 500)  → 50% premium share
Guardian C: matchShield(0, addrC, 300)  → 30% premium share
                                         ─────────────────
                                         LOCKED (100% filled)
```

- Premium distributed **pro-rata** to each guardian at match time
- Exercise payoff distributed **pro-rata** from each guardian's collateral
- Subscribers can exercise **partially filled** shields — payoff covers only the filled portion
- Guardian fees collected individually on each fill

## Smart Contract Functions

### Write Functions

| Function | Caller | Description |
|---|---|---|
| `createShield(strike, notional, premium, expiry, validator, isReverse)` | Subscriber | Declare a new shield (no funds) |
| `createAndFundShield(...)` | Subscriber | Create + pay premium in one tx |
| `fundShield(shieldId)` | Anyone | Deposit premium for an existing shield |
| `matchShield(shieldId, guardian, amount)` | Anyone | Fill a shield with collateral (partial or full) |
| `validateDelivery(shieldId, rate)` | Validator | Confirm delivery percentage (0-100) |
| `exercise(shieldId)` | Subscriber | Claim payoff if FX condition met |
| `expire(shieldId)` | Anyone | Return collateral after expiry |
| `cancel(shieldId)` | Anyone | Cancel unfilled shield, refund premium + fee |

### Read Functions

| Function | Returns |
|---|---|
| `getShield(shieldId)` | Full shield data including isReverse |
| `getShieldCount()` | Total number of shields |
| `getFills(shieldId)` | All guardian fills for a shield |
| `getFillCount(shieldId)` | Number of fills |
| `treasuryUSDC()` / `treasuryEURC()` | Protocol fee balances |

### Batch Functions

| Function | Description |
|---|---|
| `createShieldBatch(CreateParams[])` | Create multiple shields in one tx |
| `fundShieldBatch(uint256[])` | Fund multiple shields in one tx |
| `matchShieldBatch(MatchParams[])` | Fill multiple shields in one tx |

### Admin Functions

| Function | Description |
|---|---|
| `setFeeBps(uint256)` | Update fee rate (max 10%) |
| `withdrawTreasury(address)` | Withdraw accumulated USDC + EURC fees |

## Events

| Event | When | Key Data |
|---|---|---|
| `ShieldCreated` | Shield declared | shieldId, subscriber, strike, notional, premium, expiry, isReverse |
| `ShieldFunded` | Premium deposited | shieldId, funder |
| `ShieldFilled` | Guardian fills | shieldId, guardian, amount |
| `ShieldLocked` | Fully filled | shieldId |
| `ShieldExercised` | Payoff distributed | shieldId, payoff |
| `ShieldExpired` | Collateral returned | shieldId |

## Deployed Contracts (Arc Testnet)

| Contract | Address |
|---|---|
| BulwArc | `0x4f1a6AcfCA1Fa10f92f1c9B06aAadc47F40894EB` |
| MockOracle | `0x0Fa724eeb0B617a20c0A5F87D527e39D01210754` |
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| Chain | Arc Testnet (ID: 5042002) |

> **Note**: Deployed contract may not reflect latest code with `isReverse`. Redeploy with `./bulwarc/script/deploy-and-verify.sh` to get the latest version.
