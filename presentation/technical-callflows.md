# BulwArc — Technical Call Flows

## Contract State Machine

```
                           ┌──────────┐
                           │ CREATED  │ No funds deposited
                           └────┬─────┘
                                │
                    fundShield() │ Premium token transferred
                   (by employer  │ (USDC or EURC depending on isReverse)
                    or subscriber)│
                                │
                           ┌────▼─────┐
                           │ PENDING  │ Premium locked, waiting for guardians
                           └────┬─────┘
                                │
                  matchShield()  │ Collateral deposited (partial or full)
                  (one or many   │ Premium distributed to guardian pro-rata
                   guardians)    │
                                │
                    ┌───────────┴───────────┐
                    │                       │
              filled < notional      filled == notional
                    │                       │
              stays PENDING          ┌──────▼──────┐
              (exercisable if        │   LOCKED    │
               fills > 0)           └──────┬──────┘
                    │                       │
                    └───────────┬───────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
              exercise()               expire()
              (before expiry)          (after expiry)
                    │                       │
           ┌───────▼────────┐      ┌───────▼────────┐
           │  EXERCISED     │      │   EXPIRED      │
           │                │      │                │
           │ Payoff →  sub  │      │ Collateral →   │
           │ Remaining →    │      │   guardians    │
           │   guardians    │      │ Fee refund →   │
           │ Fee refund →   │      │   subscriber   │
           │   subscriber   │      └────────────────┘
           └────────────────┘

         cancel() from CREATED or PENDING (no fills)
                    │
           ┌───────▼────────┐
           │   EXPIRED      │
           │ Premium + fee  │
           │  → subscriber  │
           └────────────────┘
```

---

## Call Flow 1: EU Worker Salary Protection (Normal Mode)

**Scenario**: Maria works remotely for a US startup. She's paid $1,000/month in USDC but lives in Lisbon and needs EUR.

```
Maria (subscriber)          US Startup (employer)         Pierre (guardian)           Oracle
       │                          │                            │                       │
       │ createShield(            │                            │                       │
       │   strike=0.92,           │                            │                       │
       │   notional=1000 EURC,    │                            │                       │
       │   premium=5 USDC,        │                            │                       │
       │   expiry=30d,            │                            │                       │
       │   validator=startup,     │                            │                       │
       │   isReverse=false)       │                            │                       │
       │──────────────────────────┤                            │                       │
       │ Shield #0 CREATED        │                            │                       │
       │                          │                            │                       │
       │                          │ USDC.approve(BulwArc, 5.05)│                       │
       │                          │ fundShield(0)              │                       │
       │                          │────────────────────────────┤                       │
       │                          │ 5 USDC premium locked      │                       │
       │                          │ 0.05 USDC fee → treasury   │                       │
       │                          │                            │                       │
       │ Shield #0 PENDING        │                            │                       │
       │                          │                            │                       │
       │                          │                            │ EURC.approve(BulwArc,  │
       │                          │                            │   1010 EURC)           │
       │                          │                            │ matchShield(0,         │
       │                          │                            │   pierre, 1000 EURC)   │
       │                          │                            │────────────────────────│
       │                          │                            │ 1000 EURC collateral   │
       │                          │                            │ 10 EURC fee → treasury │
       │                          │                            │ 5 USDC premium →       │
       │                          │                            │   pierre               │
       │                          │                            │                       │
       │ Shield #0 LOCKED         │                            │                       │
       │                          │                            │                       │
       │                          │ validateDelivery(0, 100)   │                       │
       │                          │────────────────────────────┤                       │
       │                          │ 100% work delivered        │                       │
       │                          │                            │                       │
       │                          │                            │                       │ EUR/USD
       │                          │                            │                       │ drops
       │                          │                            │                       │ to 0.88
       │                          │                            │                       │
       │ exercise(0)              │                            │                       │
       │──────────────────────────┤                            │                       │
       │                          │                            │                       │
       │ Oracle check: 0.88 < 0.92 ✓                          │                       │
       │ Delivery check: 100% ✓   │                            │                       │
       │                          │                            │                       │
       │ Payoff calculation:       │                            │                       │
       │ (0.92-0.88)/0.92 × 1000 × 100% = 43.47 EURC         │                       │
       │                          │                            │                       │
       │ ◄── 43.47 EURC payoff    │                            │                       │
       │                          │              956.53 EURC ──►│                       │
       │                          │              (remaining)    │                       │
       │                          │                            │                       │
       │ Shield #0 EXERCISED      │                            │                       │
```

**Result**: Maria got 43.47 EURC to compensate for the USD drop. Pierre kept his 5 USDC premium + got 956.53 EURC back.

---

## Call Flow 2: US Traveller EUR Protection (Reverse Mode)

**Scenario**: John is going to Paris next month. He wants to lock in EUR at today's rate.

```
John (subscriber)            His bank (employer)          Clara (guardian)             Oracle
       │                          │                            │                       │
       │ createShield(            │                            │                       │
       │   strike=0.92,           │                            │                       │
       │   notional=500 USDC,     │                            │                       │
       │   premium=3 EURC,        │                            │                       │
       │   expiry=30d,            │                            │                       │
       │   validator=0x0,         │   ← no validation          │                       │
       │   isReverse=true)        │   (personal, not payroll)  │                       │
       │──────────────────────────┤                            │                       │
       │                          │                            │                       │
       │ EURC.approve(3.03)       │                            │                       │
       │ fundShield(0)            │   ← John funds himself     │                       │
       │──────────────────────────┤                            │                       │
       │ 3 EURC premium locked    │                            │                       │
       │ 0.03 EURC fee → treasury │                            │                       │
       │                          │                            │                       │
       │                          │                            │ USDC.approve(BulwArc,  │
       │                          │                            │   505 USDC)            │
       │                          │                            │ matchShield(0,         │
       │                          │                            │   clara, 500 USDC)     │
       │                          │                            │────────────────────────│
       │                          │                            │ 500 USDC collateral    │
       │                          │                            │ 5 USDC fee → treasury  │
       │                          │                            │ 3 EURC premium → clara │
       │                          │                            │                       │
       │ Shield #0 LOCKED         │                            │                       │
       │                          │                            │                       │
       │                          │                            │                       │ EUR/USD
       │                          │                            │                       │ rises
       │                          │                            │                       │ to 0.96
       │                          │                            │                       │
       │ exercise(0)              │                            │                       │
       │──────────────────────────┤                            │                       │
       │                          │                            │                       │
       │ Oracle check: 0.96 > 0.92 ✓ (reverse condition)      │                       │
       │ No validator → 100% delivery                          │                       │
       │                          │                            │                       │
       │ Payoff:                   │                            │                       │
       │ (0.96-0.92)/0.92 × 500 × 100% = 21.73 USDC          │                       │
       │                          │                            │                       │
       │ ◄── 21.73 USDC payoff    │                            │                       │
       │                          │              478.27 USDC ──►│                       │
       │                          │                            │                       │
       │ Shield #0 EXERCISED      │                            │                       │
```

**Result**: John got 21.73 USDC to compensate for the EUR getting more expensive. Clara kept her 3 EURC premium + got 478.27 USDC back.

---

## Call Flow 3: Partial Fill + Partial Delivery

**Scenario**: Worker creates a 1000 EURC shield, only 600 gets filled, and delivery is 50%.

```
Worker                    Employer                  Guardian A        Guardian B        Validator
  │                          │                          │                 │                │
  │ createShield(1000 EURC)  │                          │                 │                │
  │──────────────────────────│                          │                 │                │
  │                          │ fundShield()             │                 │                │
  │                          │──────────────────────────│                 │                │
  │                          │ 5 USDC + fee             │                 │                │
  │                          │                          │                 │                │
  │                          │                          │ matchShield(    │                │
  │                          │                          │  0, guardA,     │                │
  │                          │                          │  400 EURC)      │                │
  │                          │                          │─────────────────│                │
  │                          │                          │ → 2 USDC prem   │                │
  │                          │                          │                 │                │
  │                          │                          │                 │ matchShield(   │
  │                          │                          │                 │  0, guardB,    │
  │                          │                          │                 │  200 EURC)     │
  │                          │                          │                 │────────────────│
  │                          │                          │                 │ → 1 USDC prem  │
  │                          │                          │                 │                │
  │ Shield: 600/1000 filled (PENDING)                   │                 │                │
  │                          │                          │                 │                │
  │                          │                          │                 │                │
  │                          │                          │                 │  validateDel(  │
  │                          │                          │                 │   0, 50)       │
  │                          │                          │                 │────────────────│
  │                          │                          │                 │                │
  │ exercise(0)              │                          │                 │                │
  │──────────────────────────│                          │                 │                │
  │                          │                          │                 │                │
  │ Oracle: spot=0.88 < strike=0.92 ✓                   │                 │                │
  │ Delivery: 50% ✓          │                          │                 │                │
  │                          │                          │                 │                │
  │ Guardian A payoff: (0.92-0.88)/0.92 × 400 × 50% = 8.69 EURC         │                │
  │ Guardian B payoff: (0.92-0.88)/0.92 × 200 × 50% = 4.34 EURC         │                │
  │ Total payoff: 13.04 EURC │                          │                 │                │
  │                          │                          │                 │                │
  │ ◄── 13.04 EURC           │                          │                 │                │
  │                          │              391.31 EURC ─►                │                │
  │                          │                          │    195.65 EURC ─►                │
  │                          │                          │                 │                │
  │ Fee refund:              │                          │                 │                │
  │ usedFee = fee × 60% × 50% = 30% of fee             │                 │                │
  │ refund = 70% of fee → subscriber                    │                 │                │
  │ ◄── 0.70 × fee USDC     │                          │                 │                │
```

**Key insight**: The 400 EURC uncovered portion provides zero payoff. The subscriber only gets protection on what guardians actually covered, scaled by delivery rate. Fees follow the same double pro-rata logic.

---

## Call Flow 4: Cancel + Expire (No Exercise)

```
                    CANCEL (no fills)              EXPIRE (with fills)
                    ─────────────────              ──────────────────

                    Shield: PENDING                Shield: LOCKED
                    Filled: 0                      Filled: 1000 EURC
                    │                              │
                    │ cancel(0)                     │ block.timestamp > expiry
                    │                              │
                    │ → EXPIRED                     │ expire(0)
                    │                              │
                    │ Subscriber gets:             │ → EXPIRED
                    │   premium + full fee         │
                    │   (nothing was at risk)      │ Guardians get:
                    │                              │   full collateral back
                    │ Treasury: fee removed        │
                    │                              │ Subscriber gets:
                    │                              │   fee refund (if partial fill)
                    │                              │
                    │ Guardian: N/A                │ Premium: already distributed
                    │   (nobody matched)           │   at match time (kept by guardians)
```

---

## Token Flow Summary

### Normal Mode (`isReverse = false`)

```
USDC flow:
  Employer ──premium+fee──► BulwArc ──premium──► Guardian
                                    ──fee──► Treasury
                                    ──refund──► Subscriber (if partial)

EURC flow:
  Guardian ──collateral+fee──► BulwArc ──payoff──► Subscriber (exercise)
                                       ──remaining──► Guardian (exercise)
                                       ──full──► Guardian (expire)
                                       ──fee──► Treasury
```

### Reverse Mode (`isReverse = true`)

```
EURC flow:
  Employer ──premium+fee──► BulwArc ──premium──► Guardian
                                    ──fee──► Treasury
                                    ──refund──► Subscriber (if partial)

USDC flow:
  Guardian ──collateral+fee──► BulwArc ──payoff──► Subscriber (exercise)
                                       ──remaining──► Guardian (exercise)
                                       ──full──► Guardian (expire)
                                       ──fee──► Treasury
```

---

## Risk Balance

| Party | Risk | Protection | Reward |
|---|---|---|---|
| **Subscriber** | Premium lost if FX doesn't move | Payoff compensates FX loss | Guaranteed minimum income |
| **Guardian** | Collateral loss if FX moves against them | deliveryRate limits exposure | Premium income |
| **Employer** | Premium cost | Worker retention + compliance | Worker satisfaction |
| **Protocol** | Smart contract risk | Fees in both USDC + EURC | Growing treasury |

The `deliveryRate` ensures **guardians never lose more than they would without it**. Lower delivery = lower payoff = more collateral returned to guardian. It strictly protects guardians while giving subscribers proportional coverage.
