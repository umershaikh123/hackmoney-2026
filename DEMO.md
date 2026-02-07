# GhostVault Demo

## The Problem

Limit orders sit idle. You place a buy order at $2500 ETH, but the price is $3000. Your USDC does nothing while waiting.

GhostVault fixes this by routing order capital to ERC-4626 yield vaults. Your funds earn ~4% APY while waiting. When conditions are met, the order executes and you keep the yield.

---

## Quick Start

```bash
# Terminal 1: Start Anvil fork
cd foundry
make demo-anvil

# Terminal 2: Deploy contracts
cd foundry
make demo-mock

# Terminal 3: Start frontend
cd frontend
npm run dev
```

Open http://localhost:3000

---

## Frontend Demo (Fully Interactive)

The frontend is fully interactive with wagmi. No terminal commands needed for basic operations.

### 1. Connect Wallet

Import the Anvil test account into your wallet:
- Private Key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
- Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

Click "Connect Wallet" and select the imported account.

### 2. Create Orders

**Create Order Card:**
- Toggle between **Yield Order** (price-triggered) or **Ghost Order** (time-delayed)
- Enter amount in USDC
- For Yield Orders: set target price (e.g., $2500)
- For Ghost Orders: set minimum delay (e.g., 60 seconds)
- Click **Approve** → wait for confirmation
- Click **Commit** → order created and deposited to vault

### 3. Manage Orders

**Order Cards:**
- View order type, status, vault value, and yield accrued
- **Cancel** — Returns principal + yield (no swap)
- **Execute** — Triggers swap when conditions are met

### 4. Oracle Controls

**Set Oracle Price:**
- View current ETH/USD price
- Use preset buttons: $2,000 / $2,500 / $3,000 / $3,500
- Or enter custom price

This controls when Yield Orders can execute.

### 5. Time Warp

**Warp Block Time:**
- +1 Hour / +1 Day / +1 Week / +30 Days
- Advances Anvil's `block.timestamp`
- Yield accrues with time
- Order values auto-refresh after warp

---

## Order Types

### Ghost Order (Time-Delayed)

- Set a minimum delay (e.g., 60 seconds)
- Order can only execute after delay passes
- Privacy benefit: commit-reveal hides intent until execution

### Yield Order (Price-Triggered)

- Set a target price (e.g., $2500 for ETH)
- Order executes when oracle price meets condition
- `zeroForOne=false` (buy ETH): executes when price ≤ target
- `zeroForOne=true` (sell ETH): executes when price ≥ target

---

## Cheat Commands (Optional)

For advanced users who prefer terminal:

```bash
# Set environment
export HOOK=<hook_address_from_output>
export ORACLE=<oracle_address_from_output>
export RPC=http://127.0.0.1:8545
export PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Check order value
cast call $HOOK "getOrderValue(uint256)(uint256,uint256)" 0 --rpc-url $RPC

# Warp 1 week
cast rpc evm_increaseTime 604800 --rpc-url $RPC && cast rpc evm_mine --rpc-url $RPC

# Set oracle to $2500
cast send $ORACLE "setPrice(int256)" 250000000000 --private-key $PK --rpc-url $RPC
```

### Time Values Reference

| Duration | Seconds |
|----------|---------|
| 1 minute | 60 |
| 1 hour | 3600 |
| 1 day | 86400 |
| 1 week | 604800 |
| 30 days | 2592000 |

---

## What's Mocked

We use mocks for the demo because real Chainlink and MetaMorpho have limitations on Anvil fork:

| Component | Mock | Why |
|-----------|------|-----|
| Chainlink Oracle | `MockChainlinkOracle` | Real oracle `updatedAt` freezes after time warp |
| Yield Vault | `SimpleYieldVault` | Real MetaMorpho has liquidity limits after time warp |

The mocks behave identically to the real contracts for demo purposes:
- Oracle returns controllable price, always fresh
- Vault gives 4% APY, calculates yield per-deposit

## What's Real

- Uniswap v4 PoolManager (real Base mainnet contract)
- ERC-20 transfers (real USDC/WETH)
- Hook logic (commit-reveal, yield tracking, solver fees)
- Swap execution via unlock callback

---

## Fork Tests

To see the hook working with **real** Base mainnet contracts:

```bash
cd foundry
make test-v2-fork -vvv
```

These tests use:
- Real MetaMorpho vault (~4% APY)
- Real Chainlink ETH/USD feed
- Real Uniswap v4 PoolManager

Key tests:
- `test_ForkYieldOrderLifecycle` — 30 days yield, price-triggered execution
- `test_ForkCancelWithRealYield` — Cancel returns principal + real yield
- `test_ForkOracleProtection` — Stale oracle blocks execution
- `test_ForkBatchExecution` — Multiple orders aggregated for privacy

---

## Troubleshooting

**Wallet transactions stuck after Anvil restart?**
- Import a fresh Anvil account or clear pending transactions in wallet
- Wallets cache nonces from previous chain state

**Order not showing in frontend?**
- Refresh page or reconnect wallet
- Check console for errors

**Yield showing zero?**
- Use Time Warp buttons to advance time
- Order values auto-refresh after warp

**Execute button shows error?**
- For Yield Orders: check oracle price meets target condition
- For Ghost Orders: check if minimum delay has passed
- Use Time Warp or Oracle Controls to adjust conditions

**Anvil crashed?**
- Restart: `make demo-anvil` (Terminal 1)
- Redeploy: `make demo-mock` (Terminal 2)
- Reconnect wallet in frontend
