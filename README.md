# GhostVault

A Uniswap v4 Hook that turns waiting capital into yield while hiding trade intent from MEV.

---

## The Problem

On-chain limit orders have two issues:

1. **Everyone sees your target price.** You place a limit order at $2,500. MEV bots see it, front-run when price approaches, and you get worse execution. MEV extraction costs Ethereum users ~$300K/day.

2. **Your capital sits idle.** Funds locked in orders earn nothing while waiting days or weeks for execution. Billions in DeFi capital sits dormant in pending orders.

---

## What We Built

GhostVault is a Uniswap v4 Hook with two order types:

**YieldOrder** — Price-triggered limit order
- Deposit USDC, set target price
- Funds route to MetaMorpho vault, earn ~4% APY
- When price hits target, agent executes swap
- You get WETH plus the yield you earned

**GhostOrder** — Time-delayed privacy swap
- Deposit USDC, set delay (1 hour, 1 day, etc.)
- Only a hash of your intent is stored on-chain
- After delay, agent reveals and executes
- MEV bots never knew what you were trading

---

## How Privacy Works

```
You                              Chain                           MEV Bot
 |                                 |                                 |
 |  commit(hash, amount)           |                                 |
 |-------------------------------->|                                 |
 |                                 |  "Someone deposited 10k USDC"   |
 |                                 |  "Intent: 0x7f3a...c91d"        |
 |                                 |  (hash reveals nothing)         |
 |                                 |                                 |
 |  [time passes, yield accrues]   |                                 |
 |                                 |                                 |
 |  reveal + execute               |                                 |
 |-------------------------------->|                                 |
 |                                 |  Swap happens                   |
 |                                 |-------------------------------->|
 |                                 |                                 |  "A swap happened"
 |                                 |                                 |  (too late to front-run)
```

The hash is `keccak256(targetPrice, direction, salt)`. You keep the plaintext. Agent gets it off-chain. MEV never sees it until execution.

---

## Why Not Just Use...

| Approach | What It Does | The Gap |
|----------|--------------|---------|
| **EulerSwap** | Yield for LPs via Euler vaults | Targets liquidity providers, not order makers |
| **CoW Protocol** | MEV protection via batch auctions | No yield on waiting capital |
| **Traditional limit orders** | Basic price triggers | Both: no yield, visible intent |

GhostVault is the first to combine yield generation with intent hiding for limit orders on Uniswap v4.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GhostVaultHookV2                        │
│                    (Uniswap v4 beforeSwap + afterSwap)          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   commitOrder()      ERC-4626 Vault        executeOrder()       │
│   ─────────────>     (MetaMorpho)      <─────────────           │
│   User deposits      Earns yield           Agent reveals        │
│   Hash stored        While waiting         Swaps on v4 pool     │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│   Chainlink Oracle        Batch Execution        Solver Agent   │
│   Price feeds             Aggregate orders       Monitors chain │
│   Staleness check         Hide individual sizes  Executes orders│
└─────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Hook | Solidity 0.8.26, Uniswap v4, OpenZeppelin |
| Yield | MetaMorpho ERC-4626 vault (Gauntlet USDC Prime) |
| Oracle | Chainlink ETH/USD price feed |
| Agent | TypeScript, viem, Node.js |
| Payments | x402 protocol (HTTP 402 agent marketplace) |
| Frontend | Next.js 16, wagmi v3, RainbowKit |
| Testing | Foundry, 35 tests (22 local + 13 fork) |

---

## Bounties

GhostVault implements intent-based trading: users express what they want (commit), agents compete to execute (solver model), and the chain only sees the final result.

### Agentic Finance ($5,000)

We built an autonomous solver agent that:
- Monitors on-chain orders via event subscription
- Checks execution conditions (price from Chainlink, time delays)
- Calculates profitability (solver fee vs gas cost)
- Executes orders when profitable
- Runs 24/7 without human intervention

The agent makes independent decisions using on-chain state. It interacts directly with Uniswap v4 pools for trade execution.

### Privacy DeFi ($5,000)

We implemented:
- **Commit-reveal pattern**: Trade intent hidden until execution
- **Temporal separation**: GhostOrders enforce unpredictable execution timing
- **Batch aggregation**: Multiple orders combined into single swap, hiding individual sizes
- **Off-chain reveal channel**: Plaintext never touches the chain

These mechanisms reduce information leakage and protect against MEV extraction.

---

## Quick Start

```bash
# Terminal 1: Start Anvil fork of Base mainnet
cd foundry && make demo-anvil

# Terminal 2: Deploy contracts
cd foundry && make demo-mock

# Terminal 3: Start frontend
cd frontend && npm run dev

# Open http://localhost:3000
# Import Anvil test account (first private key from Anvil output)
```

### Run Tests

```bash
cd foundry
make test-v2-mock    # 14 local tests
make test-v2-fork    # 7 fork tests (needs BASE_MAINNET_RPC)
```

### Start Agent

```bash
cd agent
cp .env.example .env  # Configure RPC and private key
npm install
npm start             # Daemon mode
npm run demo          # One-shot demo
```

---

## Project Structure

```
hackmoney-2026/
├── foundry/           # Smart contracts
│   ├── src/
│   │   ├── GhostVaultHookV2.sol    # Main hook contract
│   │   ├── SimpleYieldVault.sol    # Demo yield vault
│   │   └── MockChainlinkOracle.sol # Demo oracle
│   └── test/          # 35 tests
├── agent/             # Solver agent + x402 gateway
│   └── src/
│       ├── index.ts   # Daemon entry point
│       ├── checker.ts # Condition monitoring
│       ├── executor.ts # Order execution
│       └── gateway.ts # x402 HTTP server
├── frontend/          # Demo UI
│   └── src/
│       ├── components/
│       └── stores/    # Zustand for reveal data
└── README.md
```

---

## Trust Model

**Current (Hackathon MVP)**: Users share reveal data with a trusted solver agent. The agent is economically incentivized (earns fees) to execute honestly.

**Future (Roadmap)**: Agent registry with staking. Agents post collateral, get slashed for privacy violations or failed execution. See [FUTURE.md](FUTURE.md) for where we go from here.

---

## Links

- [Future Steps](FUTURE.md) — Where we go from here
- [Agent Documentation](agent/README.md) — How the solver works
- [Contract Documentation](foundry/README.md) — Technical details

---

## License

MIT
