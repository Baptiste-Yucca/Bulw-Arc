# CLAUDE.md — BulwArc

## Contexte du projet

Projet hackathon Circle / Arc.
On construit un protocole de protection (shield) FX EUR/USD on-chain en P2P.
Terminologie : on ne parle jamais d'"option". On utilise "shield" / "protection" / "cover".

---

## Stack technique

| Composant | Choix |
|---|---|
| Blockchain | Arc Testnet |
| Smart contracts | Solidity + Foundry |
| Tokens | USDC (gas natif) + EURC |
| Frontend | React + ethers.js / wagmi |
| Wallet | MetaMask |

---

## Arc Testnet — Infos réseau

```
Network name : Arc Testnet
RPC URL      : https://rpc.testnet.arc.network
WebSocket    : wss://rpc.testnet.arc.network
Chain ID     : 5042002
Gas token    : USDC (18 décimales)
Explorer     : https://testnet.arcscan.app
Faucet       : https://faucet.circle.com
```

RPC alternatifs si le principal est instable :
- `https://rpc.blockdaemon.testnet.arc.network`
- `https://rpc.quicknode.testnet.arc.network`

---

## Adresses des contrats sur Arc Testnet

```
USDC : 0x3600000000000000000000000000000000000000
EURC : 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
```

Il n'y a pas d'oracle natif sur Arc. On utilise un MockOracle (owner-settable) alimenté par un bot off-chain.

---

## Setup Foundry

```bash
# Installation
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Init projet
cd bulwarc
```

### `.env` requis

```
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0x..."
BULWARC_ADDRESS=""              # rempli après deploy
MOCK_ORACLE_ADDRESS=""          # rempli après deploy
```

### Commandes clés

```bash
forge build                          # compilation
forge test                           # tests locaux
forge test -vvvv                     # tests verbose

# Deploy
forge create src/MySmartcontract.sol:MySmartcontract \
  --rpc-url $ARC_TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Interagir
cast call $BULWARC_ADDRESS "getShield(uint256)" 0 \
  --rpc-url $ARC_TESTNET_RPC_URL
```

---

## Architecture du smart contract

### Fichiers

```
bulwarc/
  src/
    BulwArc.sol             # contrat principal
    mocks/
      MockOracle.sol        # oracle EUR/USD settable par owner
  test/
    BulwArc.t.sol           # tests Foundry
  script/
    Deploy.s.sol            # script de déploiement
    deploy-and-verify.sh    # deploy + verify en une commande
```

### Structs core

```solidity
enum ShieldStatus { PENDING, MATCHED, EXERCISED, EXPIRED }

struct Shield {
    address subscriber;   // worker qui souscrit la protection
    uint256 strike;       // EUR/USD en 1e8 (ex: 92_000_000 = 0.92)
    uint256 notional;     // montant couvert en USDC (1e6)
    uint256 premium;      // prime en USDC (1e6)
    uint256 expiry;       // timestamp Unix
    ShieldStatus status;
    address guardian;     // celui qui prend le risque (0x0 si PENDING)
}
```

### Fonctions principales

```solidity
// Subscriber crée un shield
function createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external;
// Un tiers crée un shield pour un subscriber (employeur paie la prime)
function createShieldFor(address subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external;

// Guardian matche un shield
function matchShield(uint256 shieldId) external;
// Un tiers matche pour un guardian
function matchShieldFor(uint256 shieldId, address guardian) external;

// Subscriber exerce si EUR/USD spot < strike
function exercise(uint256 shieldId) external;

// Récupérer le collateral après expiry
function expire(uint256 shieldId) external;

// Annuler un shield non matché
function cancel(uint256 shieldId) external;
```

---

## Logique métier

### Maturités standardisées (MVP)

7 jours / 30 jours / 90 jours (tolérance ±1h).

### Condition d'exercice

```
oracle.getPrice() < strike  →  payoff = (strike - spot) × notional / 1e8
```

Fraîcheur oracle : `block.timestamp <= updatedAt + 5 minutes`.

### Flux de tokens

| Étape | Subscriber (worker) | Guardian |
|---|---|---|
| `createShield` | Dépose prime USDC | — |
| `matchShield` | — | Dépose collateral USDC, reçoit prime |
| `exercise` | Reçoit payoff USDC | Reçoit collateral restant |
| `expire` | — | Récupère collateral |

### OnBehalf

Un tiers (employeur, backer) peut payer via `createShieldFor` / `matchShieldFor`.
Les droits (exercise, cancel) restent au subscriber/guardian désigné.

---

## Ce que le jury attend (critères prize)

- [x] Conditional flows → exercice conditionnel via oracle
- [x] Onchain automation → settle via timestamp / oracle
- [x] Multi-step settlement → createShield → match → exercise → settle
- [x] USDC utilisé nativement
- [x] MVP fonctionnel + frontend + diagramme d'architecture

---

## Ce qu'on ne fait PAS (hors scope MVP)

- Crosschain (CCTP / Gateway) → v2
- AMM / price discovery → P2P suffit
- Partial fill → un shield = un subscriber + un guardian

---

## Conventions de code

- Solidity `^0.8.30` (compatible Arc)
- Tous les montants token en `1e6` (USDC/EURC sont 6 décimales)
- Events : `ShieldCreated`, `ShieldMatched`, `ShieldExercised`, `ShieldExpired`
- `require` avec messages explicites
- Pas d'upgradability pour le MVP
