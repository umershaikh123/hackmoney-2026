# GhostVault Protocol

**The Yield-Bearing Execution Layer for Uniswap v4**

> Your capital works while your orders wait.

---

## Problem

Conditional orders (limit orders, time-delayed swaps) lock user funds in dormant contracts earning **0% yield**. A $10,000 limit order waiting 30 days could earn ~$42 in a lending protocol — but earns nothing in every existing order system.

## Solution

GhostVault is a **Uniswap v4 Hook** that routes idle order capital into a **MetaMorpho ERC-4626 vault** until execution conditions are met. Users get their swap output **plus** accrued yield.

### Two Order Types

| Order Type | Trigger | Privacy | Yield |
|-----------|---------|---------|-------|
| **YieldOrder** | Chainlink price target | Commit-reveal hides intent | Earned while waiting |
| **GhostOrder** | Time delay (e.g. 30 min) | Temporal separation from pool | Earned during delay |

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Smart Contracts | Solidity 0.8.26 / Foundry |
| DEX | Uniswap v4 (PoolManager + Hooks) |
| Yield Source | MetaMorpho ERC-4626 Vault (Base) |
| Oracle | Chainlink Price Feeds (Base) |
| Network | Base (L2) |

## Getting Started

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test -vvv
```

## License

MIT
