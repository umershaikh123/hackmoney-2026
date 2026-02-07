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
# Note: Copy HOOK and ORACLE addresses for agent setup

# Terminal 3: Start frontend
cd frontend
npm run dev

# Terminal 4: (Optional) Start agent
# See "6. Agent Demo" section below for setup
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

### 3b. Batch Execution (Privacy Feature)

1. Click **Batch Execute** button to enter batch mode
2. Select 2+ active orders using checkboxes
3. Click **Execute N Orders** button
4. All selected orders execute in a single aggregated swap

**Privacy benefit:** On-chain observers see one large swap instead of individual orders, hiding individual order sizes.

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

## 6. Agent Demo (Automated Execution)

The solver agent monitors orders and executes them when conditions are met — no manual intervention required.

### Setup

**Terminal 4: Agent Daemon**

1. Create `agent/.env`:
   ```bash
   SOLVER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
   BASE_RPC_URL=http://127.0.0.1:8545
   HOOK_ADDRESS=<from make demo-mock output>
   ORACLE_ADDRESS=<from make demo-mock output>
   POLL_INTERVAL_MS=3000
   LOOKBACK_BLOCKS=100
   ```

2. Export reveal data from frontend:
   - In frontend, click **"Export Reveal Data"** (under Agent Export)
   - Copy the JSON
   - Save to `agent/reveal-data.json`

3. Start agent:
   ```bash
   cd agent
   npm start
   ```

### Agent Demo Flow

1. **Create order in frontend** (approve + commit)
2. **Export reveal data** to `agent/reveal-data.json`
3. Agent logs: `"Delay not elapsed"` or `"Price condition not met"`
4. **Warp time** (for Ghost Order) or **change price** (for Yield Order)
5. Agent detects condition met → **executes automatically**
6. Frontend shows order executed, WETH received

### Agent Logs

```
═══════════════════════════════════════════════════
  GhostVault Solver Agent — Daemon Mode
═══════════════════════════════════════════════════
Hook:     0x...
Chain:    Base (8453)
ETH/USD: $3000 (fresh: true)
──────────────────────────────────────────────────
[INFO] Order #0 - Delay not elapsed (30s / 60s)
[INFO] Order #0 - GhostOrder delay elapsed
[EXECUTE] Order #0 - Transaction submitted: 0x...
[EXECUTE] Order #0 - Order executed successfully
```

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
