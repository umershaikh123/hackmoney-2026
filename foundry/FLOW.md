# GhostVault — Technical Flow Reference

Quick reference for reviewing contract logic, data flow, and test coverage.

---

## What the Contract Does (One Paragraph)

GhostVaultHook accepts user deposits (USDC), immediately routes them into a MetaMorpho ERC-4626 vault to earn yield, stores an order with a commit-reveal intent hash, and waits. When conditions are met (price target via Chainlink, or time delay), any solver can call `executeOrder()` with the reveal data. The hook verifies the hash, redeems vault shares (principal + yield), deducts a 1% solver fee from yield, swaps the rest through the Uniswap v4 pool, and sends output tokens to the user. The user can cancel anytime and keep all principal + yield.

---

## Contract State

```
nextOrderId     : uint256                        — auto-incrementing counter
orders          : mapping(orderId => GhostOrder) — all order data
yieldRegistry   : mapping(token => YieldConfig)  — which vault to use per token
PRICE_FEED      : AggregatorV3Interface           — Chainlink ETH/USD (immutable)
OWNER           : address                         — deployer, can set yield config (immutable)
```

---

## Data Flow: commitOrder()

```
User                    GhostVaultHook              MetaMorpho Vault
  |                          |                           |
  |--- approve(hook, amt) -->|                           |
  |--- commitOrder() ------->|                           |
  |                          |-- transferFrom(user) ---->|
  |                          |     (pulls USDC)          |
  |                          |                           |
  |                          |-- approve(vault, amt) --->|
  |                          |-- vault.deposit(amt) ---->|
  |                          |<--- shares returned ------|
  |                          |                           |
  |                          | stores GhostOrder:        |
  |                          |   owner = msg.sender      |
  |                          |   status = ACTIVE         |
  |                          |   amountIn = amt          |
  |                          |   vaultShares = shares    |
  |                          |   intentHash = hash       |
  |                          |   minAmountOut = limit     |
  |                          |                           |
  |<-- orderId returned -----|                           |
  |                          |                           |
  |  emit OrderCommitted                                 |
```

**Key points:**
- `intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt))` — hides trade intent
- `minAmountOut` — user's slippage tolerance (0 = no limit)
- Shares are tracked per order, not per user — multiple orders are independent
- Token must be registered in `yieldRegistry` or reverts `TokenNotSupported`

---

## Data Flow: executeOrder()

```
Solver                  GhostVaultHook              MetaMorpho      PoolManager         Chainlink
  |                          |                         |                |                   |
  |-- executeOrder(id, rev)->|                         |                |                   |
  |                          |                         |                |                   |
  |                   1. VERIFY HASH                   |                |                   |
  |                   keccak256(reveal) == intentHash?  |                |                   |
  |                          |                         |                |                   |
  |                   2. CHECK CONDITIONS               |                |                   |
  |                   YieldOrder:                       |                |                   |
  |                          |------ latestRoundData() ------>----------|------------------>|
  |                          |<----- (price, updatedAt) ------|---------|---<----------------|
  |                          | if stale → revert OracleStale  |        |                   |
  |                          | if price wrong → revert        |        |                   |
  |                   GhostOrder:                       |                |                   |
  |                          | if too early → revert DelayNotElapsed    |                   |
  |                          |                         |                |                   |
  |                   3. CEI: status = EXECUTED         |                |                   |
  |                          |                         |                |                   |
  |                   4. REDEEM VAULT                   |                |                   |
  |                          |-- vault.redeem(shares)->|                |                   |
  |                          |<-- totalWithdrawn ------|                |                   |
  |                          |                         |                |                   |
  |                          | yield = total - principal                |                   |
  |                          | solverFee = yield * 1%                  |                   |
  |                          | amountToSwap = total - fee              |                   |
  |                          |                         |                |                   |
  |                   5. SWAP VIA POOL                  |                |                   |
  |                          |-- tstore(executing=1) --|                |                   |
  |                          |-- poolManager.unlock() ---------->----->|                   |
  |                          |                         |                |                   |
  |                          |   unlockCallback():     |                |                   |
  |                          |   poolManager.swap() ---|------->------->|                   |
  |                          |     (triggers beforeSwap on self)        |                   |
  |                          |     beforeSwap: check tload →            |                   |
  |                          |       oracle staleness check -->---------|------------------>|
  |                          |     swap executes                        |                   |
  |                          |     sync → transfer → settle (input)     |                   |
  |                          |     take → send to user (output)         |                   |
  |                          |<-- BalanceDelta ---------|---<-----------|                   |
  |                          |-- tstore(executing=0) --|                |                   |
  |                          |                         |                |                   |
  |                   6. SLIPPAGE CHECK                 |                |                   |
  |                          | if amountOut < minAmountOut → revert SlippageExceeded        |
  |                          |                         |                |                   |
  |                   7. PAY SOLVER FEE                 |                |                   |
  |                          |-- transfer fee to solver |               |                   |
  |<-- fee received ---------|                         |                |                   |
  |                          |                         |                |                   |
  |  emit OrderExecuted                                |                |                   |
```

**Key points:**
- CEI pattern: `status = EXECUTED` set BEFORE external calls (line 342). If anything reverts after, the whole tx rolls back.
- Solver fee is 1% of YIELD only, not of principal. If no yield, fee = 0.
- The `beforeSwap` hook fires on itself during the swap. Transient storage (`tstore/tload`) tells it "this is my own swap, check oracle staleness."
- Slippage check after swap: if `minAmountOut > 0` and output is less, entire tx reverts.
- `amountSpecified = -int256(amountIn)` → exact-input swap (negative = exact-input in v4).

---

## Data Flow: cancelOrder()

```
User                    GhostVaultHook              MetaMorpho Vault
  |                          |                           |
  |--- cancelOrder(id) ----->|                           |
  |                          |                           |
  |                   verify: status == ACTIVE           |
  |                   verify: msg.sender == owner        |
  |                          |                           |
  |                          |-- vault.redeem(shares) -->|
  |                          |<-- totalWithdrawn --------|
  |                          |     (principal + yield)   |
  |                          |                           |
  |                          |-- transfer to user ------>| (directly to user, not hook)
  |                          |                           |
  |                   status = CANCELLED                 |
  |<-- all funds returned ---|                           |
  |                          |                           |
  |  emit OrderCancelled                                 |
```

**Key points:**
- No solver fee on cancel — user keeps ALL yield
- `vault.redeem(..., msg.sender, ...)` sends directly to user
- No Uniswap swap — user gets back the same token they deposited (e.g., USDC)

---

## beforeSwap Logic

```
PoolManager calls beforeSwap on every swap in pools using this hook.

Is this swap from our own executeOrder()?
  ├── YES (tload == 1): Check Chainlink staleness
  │     └── updatedAt too old? → revert OracleStale
  │     └── Fresh? → allow swap
  └── NO (tload == 0): External swap → pass through, do nothing
```

The hook only interferes with its OWN swaps. Normal pool users are unaffected.

---

## Security Layers

```
Layer 1: Commit-Reveal
  - Trade intent hidden until execution
  - keccak256(targetPrice, zeroForOne, salt) stored on commit
  - Must match exactly on execute or revert HashMismatch

Layer 2: Chainlink Oracle (YieldOrder)
  - Price condition verified against Chainlink, not pool price
  - Stale oracle (>1hr) blocks execution
  - Flash loan attacks can't bypass because Chainlink is off-chain

Layer 3: Time Delay (GhostOrder)
  - block.timestamp >= createdAt + minDelay
  - Funds invisible to AMM during delay (parked in Morpho)

Layer 4: Oracle Staleness in beforeSwap
  - Even if price condition passed 1 second ago, the swap itself
    checks oracle freshness again
  - Catches edge case: oracle goes stale between verify and swap

Layer 5: Slippage Protection
  - User sets minAmountOut at commit time
  - Checked AFTER swap — if pool gives bad output, revert

Layer 6: Access Control
  - setYieldConfig: onlyOwner (deployer)
  - Vault asset validation: vault.asset() must match token
  - cancelOrder: only order owner

Layer 7: CEI Pattern
  - status = EXECUTED before any external call
  - Prevents reentrancy via malicious vault or token
```

---

## How Yield Works (ERC-4626)

```
MetaMorpho vault is a standard ERC-4626 wrapper around Morpho Blue lending markets.

deposit(10000 USDC) → returns shares (e.g., 9595408787028282076283)
  - Shares represent proportional ownership of vault assets
  - As Morpho Blue earns interest, total assets grow
  - Same shares → more assets over time

After 30 days:
  convertToAssets(shares) = 10029 USDC  (was 10000)
  yield = 10029 - 10000 = $29 USDC

redeem(shares) → returns 10029 USDC
  - Vault burns shares, transfers underlying assets
```

**Why shares change in value:** Morpho Blue lends the USDC to borrowers. Interest accrues to the vault's total assets. Since total shares stay constant but total assets grow, each share is worth more over time.

---

## Test Architecture

### Mock Tests (test/GhostVaultHook.t.sol) — 8 tests

Use fake contracts (MockERC20, MockERC4626, MockAggregatorV3) so no RPC needed.

```
setUp():
  1. Deploy mock tokens (USDC, WETH)
  2. Deploy mock vault (MockERC4626 wrapping USDC)
  3. Deploy mock oracle (MockAggregatorV3)
  4. Deploy hook at address with beforeSwap bit set (deployCodeTo)
  5. Register USDC vault via setYieldConfig
  6. Initialize pool (USDC/WETH)
  7. Add liquidity to pool

Mock specifics:
  - MockERC4626.simulateYield(amount) — manually adds yield to vault
  - MockAggregatorV3.setPrice(price) — sets oracle price
  - MockAggregatorV3.setStale(true) — makes oracle return old timestamp
  - Token ordering: USDC < WETH (by mock address), so currency0 = USDC
  - Pool ratio: 1:1 (mock, not real prices)
```

| # | Test | What It Proves |
|---|------|----------------|
| 1 | test_YieldOrderExecution | Full happy path: deposit → yield → execute → user gets WETH |
| 2 | test_GhostOrderExecution | Time delay enforced, then executes |
| 3 | test_CancelOrderWithYield | Cancel returns principal + yield, no fee |
| 4 | test_OracleRejectsStalePrice | Stale oracle blocks execution |
| 5 | test_CommitRevealRejectsWrongHash | Wrong salt/price → revert |
| 6 | test_OnlyOwnerCanCancel | Non-owner can't cancel |
| 7 | test_PriceConditionNotMet | Wrong price direction → revert |
| 8 | test_SlippageProtection | minAmountOut too high → revert |

### Fork Tests (test/GhostVaultFork.t.sol) — 6 tests

Run against **real Base mainnet** state. Real MetaMorpho, real Chainlink, real PoolManager.

```
setUp():
  1. Fork is created by --fork-url CLI flag (no vm.createSelectFork needed)
  2. Deploy hook at address with beforeSwap bit (deployCodeTo with real PoolManager)
  3. Register USDC → real MetaMorpho vault
  4. Initialize WETH/USDC pool on real PoolManager
  5. Add liquidity via ForkLiquidityHelper

Fork specifics:
  - Token ordering: WETH (0x4200...) < USDC (0x8335...) — OPPOSITE of mocks
  - Real MetaMorpho: deposit/redeem work, yield accrues after vm.warp
  - Real Chainlink: price is real ($2,119 ETH), but updatedAt freezes at fork-block
  - _mockChainlinkFresh(): overrides updatedAt to current block.timestamp
  - _mockVaultMaxRedeem(): overrides maxRedeem to bypass liquidity limits after warp
  - deal(USDC, user, amount): Foundry cheatcode to mint tokens
```

| # | Test | What It Proves |
|---|------|----------------|
| 1 | test_RealMetaMorphoDeposit | Real vault accepts deposit, yield accrues (3.84% APY) |
| 2 | test_RealChainlinkFeed | Real oracle returns sane price + decimals |
| 3 | test_ForkYieldOrderLifecycle | Full lifecycle on real protocols: $29 yield on 10k/30d |
| 4 | test_ForkGhostOrderExecution | Time delay works with real pool: ~14 WETH on 50k |
| 5 | test_ForkCancelWithRealYield | Cancel returns real yield: $14 on 10k/14d |
| 6 | test_ForkOracleProtection | Stale real Chainlink blocks execution |

### Morpho Yield Tests (test/MorphoYield.t.sol) — 3 tests

Standalone deposit/withdraw tests. No hooks, no swaps — just MetaMorpho.

| # | Test | What It Shows |
|---|------|---------------|
| 1 | test_YieldOverTime | Yield at 7d, 30d, 90d, 365d on 10k USDC |
| 2 | test_DepositWarpWithdraw | Full deposit → 30d → withdraw on 50k USDC |
| 3 | test_StaggeredDeposits | Two users, different timing, compare yields |

```bash
forge test --match-path test/MorphoYield.t.sol --fork-url $BASE_MAINNET_RPC -vvv
```

---

## Key Cheatcodes Used in Tests

| Cheatcode | What It Does | Where Used |
|-----------|-------------|------------|
| `deal(token, user, amount)` | Mints ERC-20 tokens to an address | All tests — fund users with USDC/WETH |
| `vm.prank(addr)` | Next call's msg.sender = addr | Execute as solver, cancel as user |
| `vm.startPrank(addr)` | All calls until stopPrank use addr | Multi-call sequences (approve + commit) |
| `vm.warp(timestamp)` | Set block.timestamp | Time warps for yield accrual / delay |
| `vm.expectRevert(selector)` | Next call must revert with this error | Negative tests (stale oracle, bad hash) |
| `vm.mockCall(target, data, ret)` | Override a contract's return value | Fresh Chainlink after warp, maxRedeem bypass |
| `vm.snapshotState()` | Save EVM state | Morpho test: check yield at multiple horizons |
| `vm.revertToState(id)` | Restore saved state | Morpho test: reset between measurements |
| `deployCodeTo(artifact, args, addr)` | Deploy bytecode at specific address | Hook needs specific address bits for beforeSwap |

---

## Uniswap v4 Flash Accounting (unlockCallback)

```
Normal ERC-20 swap: User sends tokenA, receives tokenB in same tx.
Uniswap v4 is different — it uses "flash accounting":

1. poolManager.unlock(data)
   → PoolManager calls our unlockCallback(data)

2. Inside unlockCallback:
   a. poolManager.swap(key, params, "")
      → Pool tracks: "hook owes me X tokenIn, I owe hook Y tokenOut"
      → No tokens move yet — just internal accounting

   b. Settle input (pay what we owe):
      poolManager.sync(inputCurrency)      — tell PM to check balance
      IERC20(input).transfer(poolManager)  — send tokens
      poolManager.settle()                 — PM confirms balance increased

   c. Take output (collect what pool owes us):
      poolManager.take(outputCurrency, recipient, amount)
      → PM sends output tokens directly to the order owner

3. unlock() returns — PM verifies all deltas are settled (net zero)
```

This is why the hook needs IUnlockCallback — it's the only way to interact with v4 pools.
