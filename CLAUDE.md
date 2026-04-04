# CLAUDE.md — FXOptionVault

## Contexte du projet

Projet hackathon Circle / Arc.
On construit un marché d'options FX EUR/USD on-chain où le smart contract joue le rôle de la banque (market maker).

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

L'oracle EUR/USD est natif Arc — ne pas utiliser Chainlink.

---

## Setup Foundry

```bash
# Installation
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Init projet
forge init fx-option-vault && cd fx-option-vault
```

### `.env` requis

```
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0x..."
FXOPTIONVAULT_ADDRESS="0x..."   # rempli après deploy
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
cast call $FXOPTIONVAULT_ADDRESS "getOrder(uint256)(tuple)" 0 \
  --rpc-url $ARC_TESTNET_RPC_URL
```

---

## Architecture du smart contract

### Fichiers

```
src/
  MySmartcontract.sol     # contrat principal
  interfaces/
    IOracle.sol         # interface oracle EUR/USD Arc natif
test/
  Mytest.t.sol   # tests Foundry
script/
  Deploy.s.sol          # script de déploiement
```

### Structs core

``` Pseudo code
enum OptionType { PUT, CALL }
enum OrderStatus { PENDING, MATCHED, EXERCISED, EXPIRED }

struct OptionOrder {
    address maker;
    OptionType optionType;
    uint256 strike;         // prix en 1e8 (ex: 0.45 USD/EUR = 45_000_000)
    uint256 notional;       // en USDC, 1e6
    uint256 amountFilled;   // partial fill : montant déjà matché
    uint256 premium;        // prime en USDC, 1e6
    uint256 expiry;         // timestamp Unix
    OrderStatus status;
    address counterparty;   // adresse du matcher (0x0 si PENDING)
}
```

### Fonctions principales


// Matcher un ordre existant (partial fill supporté)
function matchOrder(uint256 orderId, uint256 amount) external;

// Exercer une option américaine (à tout moment avant expiry)
function exercise(uint256 orderId) external;

// Récupérer le collateral si option non exercée après expiry
function expire(uint256 orderId) external;
```

---

## Logique métier (DRAFT)

### Maturités standardisées (MVP)

Pour simplifier le matching : 7 jours / 30 jours / 90 jours uniquement.
Validation : `require(expiry == block.timestamp + 7 days || ...)`.

### Matching (Queue FIFO + partial fill)

- Deux queues séparées : `putQueue` et `callQueue`
- Match si : même strike ET même expiry ET `amountFilled < notional`
- Partial fill : le maker garde son ordre en PENDING avec `amountFilled` mis à jour
- Le notionnel restant = `notional - amountFilled`

### Condition d'exercice

```
PUT  : oracle.getPrice() < strike  →  payoff = (strike - spot) × amount / 1e8
CALL : oracle.getPrice() > strike  →  payoff = (spot - strike) × amount / 1e8
```

Vérifier la fraîcheur du prix oracle : `require(oracle.updatedAt() > block.timestamp - 5 minutes)`.

### Flux de tokens

| Étape | PUT maker (américain) | CALL maker (européen) |
|---|---|---|
| `openPosition` | Dépose prime en USDC | Dépose prime en EURC |
| `matchOrder` | Counterparty dépose collateral USDC | Counterparty dépose collateral EURC |
| `exercise` | Reçoit payoff USDC | Reçoit payoff EURC |
| `expire` | Récupère collateral | Récupère collateral |

---

## Ce que le jury attend (critères prize)

- [x] Conditional flows → logique d'exercice conditionnelle via oracle
- [x] Onchain automation → trigger automatique settle via timestamp / oracle
- [x] Multi-step settlement → openPosition → match → exercise → settle
- [x] USDC + EURC utilisés nativement
- [x] MVP fonctionnel + frontend + diagramme d'architecture

---

## Ce qu'on ne fait PAS (hors scope MVP)

- Crosschain (CCTP / Gateway) → v2
- AMM / price discovery → queue FIFO suffit
- Partial fill sur les dates → dates standardisées
- Agrégation multi-ordres → un match = deux contreparties

---

## Conventions de code

- Solidity `^0.8.30` (compatible Arc)
- Tous les montants token en `1e6` (USDC/EURC sont 6 décimales)
- Events sur chaque action : `OrderOpened`, `OrderMatched`, `OptionExercised`, `OptionExpired`
- `require` avec messages explicites
- Pas d'upgradability pour le MVP
