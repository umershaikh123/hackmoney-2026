# GhostVault Protocol — Project Context

## What We're Building

GhostVault is a **Uniswap v4 Hook** for the ETH Global Hack Money 2026 hackathon. It turns idle order capital (limit orders, time-delayed swaps) into yield-generating positions by routing funds to a MetaMorpho ERC-4626 vault until execution conditions are met.

**Two products, one hook contract:**
- **YieldOrder**: Price-triggered limit order. Funds earn yield in MetaMorpho while waiting. Chainlink oracle prevents flash-loan attacks.
- **GhostOrder**: Time-delayed privacy swap. Commit-reveal pattern hides trade intent. Temporal separation from pool reduces MEV exposure.

**Targeting both bounties:**
- Uniswap v4 Agentic Finance ($5,000)
- Uniswap v4 Privacy DeFi ($5,000)

See @hackmoney-2026\README.md for full architecture, user flows, and demo plan.
See @hackmoney-2026\hackathonProject.md for the original brainstorm (some details are outdated — README is the source of truth).

---

## Current Status

**Phases 1–5 + V2: COMPLETE** — Core hook V1 + V2, security-hardened, 22 mock tests + 13 fork tests passing, solver agent + x402 gateway built.

| Phase | Status | What |
|-------|--------|------|
| 1 | DONE | Core hook: commit/execute/cancel with ERC-4626 vault routing |
| 2 | DONE | MetaMorpho ERC-4626 integration + yield tracking + solver fees |
| 3 | DONE | Chainlink oracle + beforeSwap callback + transient storage + 14 tests passing |
| 3b | DONE | **V2 Hook**: afterSwap observation, batch execution, ReentrancyGuardTransient, tokenIn validation |
| 4 | DONE | TypeScript solver agent — condition monitoring + profitability + execution |
| 5 | DONE | x402 Gateway — HTTP 402 agent payment marketplace via @coinbase/x402 |
| 5b | DONE | Gateway hardening — idempotency, rate limiting, timeouts, ABI fix, x402-payments skill |
| 5c | IN PROGRESS | TypeScript type fixes — `AnyPublicClient` widening applied, need `npx tsc --noEmit` verification |
| 6 | TODO | Deploy Base Sepolia + demo video + polish |

---

## Project Structure

```
@hackmoney-2026\
├── src/
│   ├── GhostVaultHook.sol          # V1 hook (beforeSwap only — ~620 lines)
│   └── GhostVaultHookV2.sol        # V2 hook (beforeSwap + afterSwap + batch — ~680 lines)
├── constants/
│   └── Addresses.sol               # Single source of truth for all on-chain addresses
├── test/
│   ├── GhostVaultHook.t.sol        # V1 local unit tests (8/8 passing, no RPC needed)
│   ├── GhostVaultHookV2.t.sol      # V2 local unit tests (14/14 passing, no RPC needed)
│   ├── GhostVaultFork.t.sol        # V1 Base mainnet fork tests (6/6 passing)
│   ├── GhostVaultForkV2.t.sol      # V2 Base mainnet fork tests (7/7 passing)
│   ├── MorphoYield.t.sol           # Standalone Morpho yield tests (3 tests)
│   └── helpers/
│       ├── TestVault.sol           # Concrete solmate ERC4626 for local tests
│       ├── LiquidityHelper.sol     # Adds liquidity via unlock callback
│       └── SwapHelper.sol          # Executes swaps via unlock callback
├── agent/
│   ├── src/
│   │   ├── config.ts               # ABIs, addresses, chain config
│   │   ├── listener.ts             # Event subscription + order registry
│   │   ├── checker.ts              # Price/time conditions + profitability
│   │   ├── executor.ts             # Direct on-chain + x402 gateway execution
│   │   ├── logger.ts               # Structured JSON decision logging
│   │   ├── index.ts                # Long-running daemon
│   │   ├── demo.ts                 # One-shot demo script
│   │   └── gateway.ts              # x402 HTTP gateway server
│   ├── package.json                # @ghostvault/solver-agent
│   └── .env.example                # Required env vars
├── script/
│   ├── Deploy.s.sol                # V1 CREATE2 deployment with HookMiner
│   └── DeployV2.s.sol              # V2 CREATE2 deployment (BEFORE_SWAP + AFTER_SWAP flags)
├── lib/
│   ├── forge-std/                  # Foundry test framework
│   ├── v4-periphery/               # BaseHook, HookMiner, solmate (ERC4626, MockERC20)
│   ├── v4-core/                    # (also nested under v4-periphery)
│   ├── openzeppelin-contracts/     # IERC20, SafeERC20, IERC4626
│   ├── foundry-chainlink-toolkit/  # AggregatorV3Interface
│   ├── briefcase/
│   └── forge-chronicles/
├── Makefile                         # Build, test, and log commands
├── foundry.toml                     # Solidity 0.8.26, Cancun EVM, optimizer + via_ir
├── .env.example                     # Template for DEPLOYER_PRIVATE_KEY, RPC URLs
├── .env.local                       # Actual secrets (git-ignored)
├── README.md                        # Design doc, architecture, demo plan
└── CLAUDE.md                        # This file
```

---

## Foundry Configuration (Current)

### Compiler
- `solc = "0.8.26"`, `evm_version = "cancun"` (required for transient storage)
- Production: `via_ir = true`, `optimizer_runs = 999999`
- Tests: `via_ir = false`, `optimizer = false` (faster compilation)

### Remappings (in foundry.toml)
```toml
remappings = [
  "forge-std/=lib/forge-std/src/",
  "@uniswap/v4-core/=lib/v4-periphery/lib/v4-core/",
  "@uniswap/v4-periphery/=lib/v4-periphery/",
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
  "@chainlink/=lib/foundry-chainlink-toolkit/src/",
  "permit2/=lib/v4-periphery/lib/permit2/",
  "solmate/=lib/v4-periphery/lib/v4-core/lib/solmate/",
]
```

**Important**: v4-core is resolved through v4-periphery's nested copy (`lib/v4-periphery/lib/v4-core/`), NOT the top-level `lib/v4-core/`. This avoids version mismatches.

### Running Tests (via Makefile)
```bash
# V1 tests
make test-mock          # 8 V1 local unit tests (no RPC needed)
make test-fork          # 6 V1 fork tests (needs BASE_MAINNET_RPC in .env.local)
make test-morpho        # 3 standalone Morpho yield tests (needs RPC)

# V2 tests
make test-v2-mock       # 14 V2 local unit tests (no RPC needed)
make test-v2-fork       # 7 V2 fork tests (needs BASE_MAINNET_RPC)

# All tests
make test-all           # All V1 + V2 + Morpho tests
make logs               # Run all + save timestamped logs to test-logs/
```

---

## Contract Architecture (GhostVaultHook.sol)

### Inheritance
```
BaseHook (v4-periphery) + IUnlockCallback
```

### Hook Permissions
Only `beforeSwap: true` — used for oracle sanity check during execution swaps. All other hooks disabled.

### Key Data Structures
- `GhostOrder` — Full order state: owner, type, status, tokens, vault shares, intent hash, timing, minAmountOut
- `RevealData` — Commit-reveal plaintext: targetPrice, zeroForOne, salt
- `YieldConfig` — Maps token address → ERC-4626 vault
- `SwapCallbackData` — Passed through unlock() to unlockCallback()

### Core Functions
| Function | Purpose |
|----------|---------|
| `commitOrder()` | User deposits tokens → vault, stores order with intent hash |
| `executeOrder()` | Solver reveals intent, verifies conditions, redeems vault, swaps on pool |
| `cancelOrder()` | Owner withdraws full vault position (principal + yield), no solver fee |
| `_beforeSwap()` | Oracle staleness check on hook-initiated swaps only |
| `unlockCallback()` | Flash accounting: swap → sync/transfer/settle → take |

### Internal Helpers
| Function | Purpose |
|----------|---------|
| `_checkOwner()` | Reverts with `NotOwner` if caller is not deployer (used by `onlyOwner` modifier) |
| `_redeemVaultPosition()` | Extracted for stack depth — redeems shares, calculates yield + solver fee |
| `_verifyPriceCondition()` | Chainlink price vs target + staleness check |
| `_verifyOracleDeviation()` | Staleness-only check in beforeSwap |
| `_setExecutingSwap()` / `_isExecutingSwap()` | Transient storage flag (tstore/tload) |

### Constants
```solidity
SOLVER_FEE_BPS          = 100;   // 1% of yield goes to solver
MAX_ORACLE_STALENESS    = 3600;  // 1 hour max oracle age
```

### Price Condition Logic
- `zeroForOne = true` (sell token0 for token1): execute when `currentPrice >= targetPrice`
- `zeroForOne = false` (sell token1 for token0): execute when `currentPrice <= targetPrice`

### Execution Flow (CEI Pattern)
```
executeOrder()
  → verify commit-reveal hash
  → check conditions (price or delay)
  → SET STATUS = EXECUTED  ← state update BEFORE external calls (CEI)
  → _redeemVaultPosition() — redeem shares, calc fees
  → _setExecutingSwap(true)
  → poolManager.unlock(SwapCallbackData)
    → unlockCallback()
      → poolManager.swap() → triggers _beforeSwap() → oracle check
      → sync/transfer/settle (input)
      → take (output → owner)
  → _setExecutingSwap(false)
  → slippage check: if amountOut < minAmountOut, revert SlippageExceeded
  → pay solver fee
```

---

## Contract Architecture (GhostVaultHookV2.sol)

V2 extends V1 with deeper v4 integration, stronger privacy, and security hardening. V1 files remain untouched.

### Inheritance
```
BaseHook (v4-periphery) + IUnlockCallback + ReentrancyGuardTransient (OpenZeppelin)
```

### Hook Permissions
`beforeSwap: true` + `afterSwap: true`. Flag bits: `0xC0` (vs V1's `0x80`).

### V2 Additions over V1

| Feature | Purpose |
|---------|---------|
| `afterSwap` hook | Observes all pool swaps, emits `PoolSwapObserved` events for agent monitoring. Skips emission during hook's own swaps via transient storage flag. |
| `executeBatch()` | Aggregates N orders into a single swap. On-chain observers see one large swap instead of N individual ones — hides individual order sizes. |
| `ReentrancyGuardTransient` | Transient-storage reentrancy guard on `commitOrder`, `executeOrder`, `executeBatch`, `cancelOrder`. 100 gas vs 5000 for SSTORE-based. |
| `InvalidPool` validation | `commitOrder` verifies `tokenIn` is one of the pool's currencies. Prevents committing with mismatched poolKey. |

### Batch Execution Flow
```
executeBatch(orderIds[], reveals[])
  → validate all orders (hash, conditions, pool match, direction match)
  → mark all EXECUTED (CEI)
  → redeem all vault positions (tokens accumulate in hook)
  → single poolManager.unlock() with combined amountIn
  → distribute output proportionally: share = totalOut * orderAmountIn / totalAmountIn
  → last recipient gets remainder (rounding dust)
  → check each order's minAmountOut against its share
  → pay aggregated solver fee in one transfer
```

### Stack Depth Management
`executeBatch` uses `{ }` scoping blocks to free temporary variables (hash, order pointer, redeem results) in the validation loop. The distribution phase uses a separate `_distributeBatchOutput` helper because the outer scope has 9+ live variables, exceeding the legacy codegen's 16-slot stack limit even with scoping.

### New Events
- `PoolSwapObserved(PoolId indexed poolId, bool zeroForOne, int128 amount0, int128 amount1)` — emitted by afterSwap for external swaps
- `BatchExecuted(uint256[] orderIds, address indexed solver, uint256 totalAmountIn, uint256 totalAmountOut)` — emitted after batch completion

### New Errors
- `InvalidPool()` — tokenIn doesn't match pool currencies
- `BatchEmpty()` — empty or mismatched arrays
- `BatchPoolMismatch()` — orders target different pools
- `BatchDirectionMismatch()` — orders have different zeroForOne directions

---

## Test Suite

### V1 Tests (14/14 Passing)

#### Local Tests (GhostVaultHook.t.sol — 8/8)

**Test Infrastructure (no custom mocks — uses real implementations + Foundry cheat codes):**
- `MockERC20` — from `solmate/src/test/utils/mocks/MockERC20.sol` (lib)
- `TestVault` — concrete `solmate/ERC4626` subclass (`test/helpers/TestVault.sol`). Yield simulated via `usdc.mint(address(vault), amount)`.
- Chainlink oracle — `vm.mockCall` on a bare address. `_mockOraclePrice()` / `_mockOracleStale()` helpers in test contract.
- `LiquidityHelper` — Adds liquidity via unlock callback (`test/helpers/`)
- `SwapHelper` — Executes swaps via unlock callback (`test/helpers/`)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `test_YieldOrderExecution` | Full lifecycle: commit 10k USDC → 30d yield ($42.74) → solver executes → user gets WETH + solver gets fee |
| 2 | `test_GhostOrderExecution` | Time-delayed: commit 50k USDC → early blocked → delay passes → solver executes |
| 3 | `test_CancelOrderWithYield` | Cancel returns principal + yield, no solver fee |
| 4 | `test_OracleRejectsStalePrice` | Stale oracle (>1hr) blocks execution even if price condition met |
| 5 | `test_CommitRevealRejectsWrongHash` | Wrong reveal data → HashMismatch revert |
| 6 | `test_OnlyOwnerCanCancel` | Non-owner cancel → NotOrderOwner revert |
| 7 | `test_PriceConditionNotMet` | Oracle $2,500 < target $3,000 → PriceConditionNotMet revert |
| 8 | `test_SlippageProtection` | Unrealistic minAmountOut → SlippageExceeded revert, order stays ACTIVE |

**Mock Token Ordering:** USDC = currency0 (lower address), WETH = currency1 (higher address). Pool at 1:1 ratio.

#### Fork Tests (GhostVaultFork.t.sol — 6/6)

Run against **real Base mainnet** state: real MetaMorpho vault, real Chainlink feeds, real Uniswap v4 PoolManager.

| # | Test | What It Verifies | Key Results |
|---|------|-----------------|-------------|
| 1 | `test_RealMetaMorphoDeposit` | Direct deposit into real MetaMorpho vault, yield accrual after 7 days | 3.84% APY, $7.36 yield on 10k |
| 2 | `test_RealChainlinkFeed` | Real Chainlink ETH/USD returns sane data (8 decimals, fresh timestamp) | ETH at $2,119 |
| 3 | `test_ForkYieldOrderLifecycle` | Full lifecycle on real Base: commit → 30d yield → solver executes → WETH received | $29.11 yield, ~3.2 WETH out |
| 4 | `test_ForkGhostOrderExecution` | Time-delayed order: early blocked → delay passes → solver executes on real pool | ~14 WETH on 50k USDC |
| 5 | `test_ForkCancelWithRealYield` | Cancel returns principal + real MetaMorpho yield | $14.36 real yield on 10k/14d |
| 6 | `test_ForkOracleProtection` | Stale oracle (2hr warp) blocks execution on real Chainlink feed | Order stays ACTIVE |

**Fork Token Ordering (OPPOSITE of mocks):** On Base mainnet, WETH (`0x4200...`) < USDC (`0x8335...`) → currency0 = WETH, currency1 = USDC. `zeroForOne = false` to sell USDC for WETH.

**Fork-Specific Helpers:**
- `LiquidityHelper` — Shared helper (`test/helpers/`), adds liquidity on real PoolManager via unlock callback
- `_mockChainlinkFresh()` / `_mockChainlinkPrice()` — Override Chainlink `updatedAt` after `vm.warp`
- `_mockVaultMaxRedeem()` — Bypass MetaMorpho `maxRedeem` liquidity limit after time warp

### V2 Tests (21/21 Passing)

#### Local Tests (GhostVaultHookV2.t.sol — 14/14)

All 8 V1 tests ported to V2, plus 6 new V2-specific tests:

| # | Test | What It Verifies |
|---|------|-----------------|
| 9 | `test_InvalidPoolReverts` | Commit with mismatched poolKey → InvalidPool revert |
| 10 | `test_AfterSwapEmitsEvent` | External swap emits `PoolSwapObserved` event |
| 11 | `test_AfterSwapSilentOnExecution` | Hook's own execution swap does NOT emit PoolSwapObserved (via `vm.recordLogs`) |
| 12 | `test_BatchExecution` | 3 ghost orders batched → single swap → WETH distributed → all EXECUTED |
| 13 | `test_BatchSlippageProtection` | One order has unrealistic minAmountOut → SlippageExceeded revert for entire batch |
| 14 | `test_BatchPoolMismatch` | Orders from different pools → BatchPoolMismatch revert |

V2 hook flags: `Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG` (address bits `0xC0`).

#### Fork Tests (GhostVaultForkV2.t.sol — 7/7)

All 6 V1 fork tests ported to V2, plus 1 new batch fork test:

| # | Test | What It Verifies |
|---|------|-----------------|
| 7 | `test_ForkBatchExecution` | 2 ghost orders (10k + 20k USDC) batched against real Base mainnet pool |

---

## Deploy Scripts

### V1: Deploy.s.sol
- Uses `HookMiner.find()` to mine CREATE2 salt with `BEFORE_SWAP_FLAG` bit
- Auto-detects Base Sepolia vs Base Mainnet via `extcodesize` check
- Loads `DEPLOYER_PRIVATE_KEY` from environment
- Registers MetaMorpho vault on mainnet deployment
- CREATE2_DEPLOYER: `0x4e59b44847b379578588920cA78FbF26c0B4956C`

### V2: DeployV2.s.sol
- Same structure as V1 but mines for `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG` bits (`0xC0`)
- Deploys `GhostVaultHookV2` — different address than V1 due to different flag bits
- Both V1 and V2 hooks can coexist on the same chain

---

## On-Chain Addresses (constants/Addresses.sol — single source of truth)

```solidity
// ── Base Mainnet ──
address constant POOLMANAGER_BASE_MAINNET        = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
address constant ETH_USD_FEED_BASE_MAINNET       = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
address constant USDC_BASE_MAINNET               = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant WETH_BASE_MAINNET               = 0x4200000000000000000000000000000000000006;
address constant METAMORPHO_VAULT_BASE_MAINNET   = 0x050cE30b927Da55177A4914EC73480238BAD56f0; // Gauntlet USDC Prime

// ── Base Sepolia ──
address constant POOLMANAGER_BASE_SEPOLIA        = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
address constant ETH_USD_FEED_BASE_SEPOLIA       = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
```

All Solidity files import addresses from `constants/Addresses.sol`. No hardcoded addresses in contracts, tests, or scripts.

---

## Key Gotchas (Lessons Learned)

1. **v4-core version alignment**: Use v4-core nested under v4-periphery (`lib/v4-periphery/lib/v4-core/`). Installing a separate v4-core causes version conflicts.
2. **ModifyLiquidityParams**: In newer v4-core, `ModifyLiquidityParams` is a standalone struct in `PoolOperation.sol`, NOT on `IPoolManager`.
3. **Hook address bits**: The contract address must have bit 7 set for `beforeSwap`. Use `deployCodeTo()` in tests, HookMiner + CREATE2 for production.
4. **Re-entrancy in beforeSwap**: When hook calls `poolManager.swap()`, it triggers `beforeSwap` on itself. Transient storage (`tstore`/`tload`) distinguishes hook-initiated vs external swaps.
5. **Stack too deep**: Test compilation profile has `via_ir = false`. Keep functions shallow — extract helpers like `_redeemVaultPosition()` when needed.
6. **Token ordering**: Uniswap v4 requires `currency0 < currency1` by address. `zeroForOne = true` means selling currency0. Make sure the deposited token matches the swap input direction.
7. **ERC-4626 share rounding**: `deposit()` rounds shares down, `redeem()` rounds assets down. Always track exact shares received.
8. **Chainlink staleness**: Check `updatedAt` against `block.timestamp`. Reject stale prices (> 1 hour).
9. **USDC decimals**: 6 decimals, NOT 18. All math must account for this.
10. **Test timestamp**: Forge tests start at `block.timestamp = 1`. Use `vm.warp()` before any arithmetic that subtracts from `block.timestamp`.
11. **Checks-effects-interactions (CEI)**: `order.status = EXECUTED` must be set BEFORE external calls (`vault.redeem`, `poolManager.unlock`, `IERC20.safeTransfer`). A malicious vault could re-enter `executeOrder()` if status update comes after external calls.
12. **Fork token ordering is reversed**: On Base mainnet, WETH (`0x4200...`) < USDC (`0x8335...`), so currency0 = WETH. This is the OPPOSITE of mock tests where mock USDC < mock WETH by address.
13. **MetaMorpho `maxRedeem` after `vm.warp`**: After large time warps, `maxRedeem()` may return slightly fewer shares than deposited due to Morpho Blue market liquidity sync. Use `vm.mockCall` to bypass in fork tests.
14. **Chainlink staleness after `vm.warp`**: Real Chainlink `updatedAt` freezes at fork-block time. Use `vm.mockCall` to override `latestRoundData()` with fresh `updatedAt` while keeping the real price.
15. **Fork tests don't need `vm.createSelectFork`**: When `--fork-url` is passed on the CLI, Forge already forks. Adding `createSelectFork` in `setUp()` is redundant and requires an env var.
16. **`setYieldConfig` is onlyOwner**: The deployer (set via `OWNER = msg.sender` in constructor) is the only address that can register vaults. In tests, `deployCodeTo` runs the constructor from the test contract, so the test contract IS the owner.
17. **`commitOrder` has `minAmountOut` parameter**: Added between `minDelay` and `key`. Use `0` for no slippage limit. The check happens after the swap in `executeOrder()` — if it reverts, the entire tx rolls back including the CEI status change.
18. **Vault asset validation**: `setYieldConfig` checks `IERC4626(vault).asset() == token`. In local tests, `TestVault` (solmate ERC4626) returns the correct asset via its auto-generated `asset()` getter.
19. **ABI mismatch: `getOrder` vs `orders`**: The contract's `getOrder()` custom view returns 9 individual values (no tokenOut, no minAmountOut, no poolKey). The `orders(uint256)` auto-generated mapping getter returns 12 values (full struct including poolKey tuple). config.ts must have separate ABI entries for each. listener.ts uses `orders` (needs minAmountOut), gateway.ts uses `getOrder` (only needs status).
20. **viem Base chain type incompatibility**: `createPublicClient({ chain: base })` returns `PublicClient<HttpTransport, typeof base>` which includes OP Stack `deposit` transaction type. Functions accepting bare `PublicClient` won't accept it. Fix: use `type AnyPublicClient = PublicClient<Transport, Chain | undefined>` in all library function signatures.
21. **@x402/core `unpaidResponseBody`**: Must be a callback function `(ctx: HTTPRequestContext) => { contentType: string, body: unknown }`, NOT a plain object. The callback is invoked when a request lacks payment.
22. **@x402/core callback contexts**: `onAfterVerify` context has `ctx.requirements` (not `ctx.paymentRequirements`). `onAfterSettle` context has `ctx.result` (not `ctx.settleResult`). Both extend base contexts with `paymentPayload` and `requirements` properties.
23. **Currency type has no comparison operators**: `Currency` is a user-defined value type wrapping `address`. `Currency.wrap(tokenIn) != key.currency0` fails. Use `tokenIn != Currency.unwrap(key.currency0)` to compare with raw addresses.
24. **`{ }` scoping blocks for stack depth**: Variables declared inside `{ }` are freed from the EVM stack at the closing brace, letting the compiler reuse slots. Works well for moderate stack pressure (e.g., freeing a storage pointer before a function call). Does NOT help when 9+ outer variables exist — the legacy codegen's 16-slot DUP/SWAP limit is still exceeded. In those cases, extract a helper function.

---

## Reference Files (Uniswap v4)

**v4-periphery:**
- `lib/v4-periphery/src/utils/BaseHook.sol` — Abstract base. Override `getHookPermissions()` and `_beforeSwap()`.
- `lib/v4-periphery/src/libraries/HookMiner.sol` — CREATE2 salt mining for hook address flag bits.

**v4-core:**
- `lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol` — `swap()`, `unlock()`, `sync()`, `settle()`, `take()`.
- `lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol` — `SwapParams`, `ModifyLiquidityParams`.
- `lib/v4-periphery/lib/v4-core/src/types/Currency.sol` — Currency type (wraps address).
- `lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol` — Pool configuration struct.
- `lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol` — Return type for `beforeSwap`.
- `lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol` — `MIN_SQRT_PRICE`, `MAX_SQRT_PRICE`.

---

## Next Tasks

### Phase 4: TypeScript Solver Agent — DONE
- [x] Node.js + tsx project with viem
- [x] Chainlink price feed polling (ETH/USD via RPC)
- [x] Event listener: subscribe to OrderCommitted/Executed/Cancelled events
- [x] Order registry: track active orders + reveal data (off-chain JSON store)
- [x] Profitability calculator: solverFee (1% yield) vs gas cost (USDC-denominated)
- [x] Execute orders when conditions met (price for YieldOrder, time for GhostOrder)
- [x] Two modes: demo script (npm run demo) and daemon (npm run daemon)
- [x] Structured JSON decision logging

### Phase 5: x402 Gateway — DONE
- [x] Node.js HTTP server with @coinbase/x402 + @x402/core
- [x] 402 challenge-response flow (GET → 402 → POST with payment)
- [x] Gateway forwards execution to hook contract
- [x] Agent executor supports direct on-chain AND x402 gateway paths
- [x] Demo mode (no CDP credentials needed)

### Phase 5b: Gateway Hardening — DONE
Applied x402-payments skill validations and fixed ABI mismatch:
- [x] Idempotency: `executingOrders` Set prevents concurrent duplicates, `executedOrders` Map caches results (1hr TTL)
- [x] Rate limiting: per-IP token bucket (20 req/min window)
- [x] Execution timeout: `Promise.race` with 60s deadline
- [x] Input validation: revealData format checks before execution
- [x] On-chain order validation: reads `getOrder()` to verify ACTIVE status before paying gas
- [x] WWW-Authenticate headers on all 402 responses (x402 spec compliance)
- [x] ABI mismatch fix: split `getOrder` (9 outputs) vs `orders` (12 outputs) in config.ts
- [x] listener.ts updated to use `orders` getter with array destructuring
- [x] gateway.ts updated to use `getOrder` with `result[2]` for status

### Phase 5c: TypeScript Type Fixes — IN PROGRESS
Fixing 18 `npx tsc --noEmit` errors caused by viem chain-specific types and @x402/core API:
- [x] Added `AnyPublicClient = PublicClient<Transport, Chain | undefined>` type alias (Base OP Stack `deposit` tx type)
- [x] Applied `AnyPublicClient` to all function signatures in checker.ts, listener.ts, executor.ts
- [x] Fixed gateway.ts `unpaidResponseBody`: changed from plain object to callback `() => ({ contentType, body })`
- [x] Fixed gateway.ts `onAfterVerify`: `ctx.paymentRequirements` → `ctx.requirements`
- [x] Fixed gateway.ts `onAfterSettle`: `ctx.settleResult` → `ctx.result`
- [ ] **Run `npx tsc --noEmit` to verify all 18 errors resolved** ← RESUME HERE

### Phase 6: Deploy and Submit
- [ ] Deploy to Base Sepolia (use Deploy.s.sol)
- [ ] Record 3-minute demo video showing:
  1. YieldOrder lifecycle (commit → yield → execute)
  2. Cancel with yield
  3. Oracle attack prevention
  4. Agent decision logging
- [ ] Update README with deployed addresses + TxIDs
- [ ] GitHub repository finalized
- [ ] Submission checklist from README complete
