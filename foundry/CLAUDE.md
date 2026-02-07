# GhostVault — Developer Context

## What This Is

Uniswap v4 Hook for ETH Global Hack Money 2026. Turns idle order capital into yield via ERC-4626 vault while hiding trade intent with commit-reveal.

**Two order types:**
- YieldOrder — price-triggered, earns yield while waiting
- GhostOrder — time-delayed, commit-reveal for privacy

---

## Project Structure

```
hackmoney-2026/
├── foundry/                    # Contracts
│   ├── src/
│   │   ├── GhostVaultHookV2.sol     # Main hook (~680 lines)
│   │   ├── SimpleYieldVault.sol     # Demo vault (4% APY)
│   │   └── MockChainlinkOracle.sol  # Demo oracle
│   ├── test/
│   │   ├── GhostVaultHookV2.t.sol   # 14 local tests
│   │   └── GhostVaultForkV2.t.sol   # 7 fork tests
│   └── script/
│       ├── DeployV2.s.sol           # Production deploy
│       └── DeployWithMocks.s.sol    # Demo deploy
├── agent/                      # TypeScript solver
│   └── src/
│       ├── index.ts      # Daemon
│       ├── checker.ts    # Condition checks
│       ├── executor.ts   # Order execution
│       └── gateway.ts    # x402 HTTP server
└── frontend/                   # Next.js demo UI
    └── src/
        ├── components/   # Order cards, controls
        └── stores/       # Zustand reveal data
```

---

## Key Contracts

### GhostVaultHookV2.sol

```solidity
// Core functions
commitOrder(tokenIn, amount, intentHash, orderType, minDelay, minAmountOut, poolKey)
executeOrder(orderId, RevealData{targetPrice, zeroForOne, salt})
executeBatch(orderIds[], reveals[])
cancelOrder(orderId)

// Hook callbacks
beforeSwap() — oracle staleness check
afterSwap() — emits PoolSwapObserved for agent monitoring

// Constants
GAS_REIMBURSEMENT = 100_000           // 0.1 USDC
MIN_YIELD_FOR_REIMBURSEMENT = 100_000 // 0.1 USDC threshold
SOLVER_FEE_BPS = 100                  // 1% of yield
MAX_ORACLE_STALENESS = 3600           // 1 hour
```

### Solver Fee Model

```
if yield >= 0.1 USDC:
  solverFee = 0.1 USDC + (yield * 1%)
else:
  solverFee = yield * 1%

solverFee = min(solverFee, yield)  // capped at total yield
```

---

## Running Tests

```bash
cd foundry

# Local tests (no RPC needed)
make test-v2-mock      # 14 tests

# Fork tests (needs BASE_MAINNET_RPC in .env.local)
make test-v2-fork      # 7 tests

# All tests
make test-all
```

---

## Demo Setup

```bash
# Terminal 1: Anvil fork
make demo-anvil

# Terminal 2: Deploy with mocks
make demo-mock

# Terminal 3: Frontend
cd ../frontend && npm run dev
```

---

## On-Chain Addresses (Base Mainnet)

```solidity
POOLMANAGER    = 0x498581fF718922c3f8e6A244956aF099B2652b2b
ETH_USD_FEED   = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
USDC           = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH           = 0x4200000000000000000000000000000000000006
METAMORPHO     = 0x050cE30b927Da55177A4914EC73480238BAD56f0
```

---

## Critical Gotchas

1. **v4-core version**: Use `lib/v4-periphery/lib/v4-core/`, not top-level `lib/v4-core/`

2. **Hook address bits**: Contract address must have correct flag bits. Use HookMiner + CREATE2

3. **Token ordering**: Uniswap v4 requires `currency0 < currency1` by address. On Base mainnet, WETH < USDC

4. **Transient storage for re-entrancy**: When hook calls `poolManager.swap()`, it triggers `beforeSwap` on itself. Use `tstore`/`tload` to distinguish

5. **CEI pattern**: Set `order.status = EXECUTED` before external calls

6. **Chainlink staleness**: Check `updatedAt` against `block.timestamp`. Reject prices > 1 hour old

7. **USDC decimals**: 6 decimals, not 18

8. **CREATE2 via factory**: Pass `CREATE2_FACTORY` to HookMiner, not deployer EOA

9. **Demo needs mocks**: Real Chainlink freezes after `vm.warp`. Use MockChainlinkOracle for demos

10. **ABI mismatch**: `getOrder()` returns 9 values, `orders(uint256)` returns 12. Use correct one

---

## Agent Environment

```bash
# Required
SOLVER_PRIVATE_KEY=0x...
RPC_URL=https://...

# Optional
CHAIN_ID=8453              # 8453=Base, 31337=Anvil
GATEWAY_URL=http://...     # x402 gateway
GAS_PRICE_GWEI=0.001       # Override for L2
```

---

## Compiler Config

```toml
solc = "0.8.26"
evm_version = "cancun"     # Required for transient storage
via_ir = true              # Production
optimizer_runs = 999999
```
