# GhostVault Protocol

Uniswap v4 Hook that earns yield on idle order capital via MetaMorpho.

## Quick Start

```bash
# 1. Install dependencies
forge install

# 2. Set RPC URL
cp .env.example .env.local
# Edit .env.local with your Base mainnet RPC (Alchemy, Infura, etc.)

# 3. Run tests
make test-mock      # Local tests (no RPC needed)
make test-fork      # Fork tests (requires RPC)
```

## Test Commands

| Command | Description |
|---------|-------------|
| `make test-mock` | V1 mock tests (8 tests, no RPC) |
| `make test-fork` | V1 fork tests (6 tests, Base mainnet) |
| `make test-v2-mock` | V2 mock tests (14 tests, no RPC) |
| `make test-v2-fork` | V2 fork tests (7 tests, Base mainnet) |
| `make test-morpho` | Morpho yield tests (3 tests) |
| `make test-all` | All tests |

## Demo Flow

### Option A: Frontend + Terminal (Recommended)

Use the frontend to generate cast commands and visualize on-chain state:

```bash
# Terminal 1: Start Anvil fork
make demo-anvil

# Terminal 2: Deploy hook + fund demo account
make demo-setup

# Terminal 3: Start frontend
cd ../frontend && npm run dev
```

**Demo workflow:**
1. Open http://localhost:3000 and connect wallet (MetaMask with Anvil account)
2. In "Cast Commands" section:
   - Select order type (Ghost or Yield)
   - Set amount (e.g., 1000 USDC)
   - Set delay for Ghost orders (e.g., 60 seconds)
3. Copy and run commands in Terminal 2:
   - Copy "Approve USDC" command → paste → execute
   - Copy "Commit Order" command → paste → execute
4. Watch the order appear in "Orders" section
5. Copy and run "Cancel Order" command to see status change

See `../frontend/DEMO_COMMANDS.md` for detailed command reference.

### Option B: Automated Demo

Single command showcases YieldOrder, GhostOrder, and Cancel with yield:

```bash
# Terminal 1: Start Anvil fork
make demo-anvil

# Terminal 2: Deploy + run demo
make demo-setup
make demo
```

The automated demo shows:
1. **YieldOrder** — Commit 5000 USDC, simulate 30 days, execute when price condition met
2. **GhostOrder** — Commit 1000 USDC with 60s delay, early execution blocked, execute after delay
3. **Cancel** — Commit 2000 USDC, simulate 7 days, cancel and receive principal + yield

### Option C: Fork Tests

Shows yield accrual, oracle protection, and batch execution:

```bash
make test-v2-fork -vvv
```

### Option D: Manual Cast Commands

For step-by-step exploration without frontend:

```bash
# Terminal 1: Start Anvil fork
make demo-anvil

# Terminal 2: Deploy hook + fund demo account
make demo-setup

# Terminal 2: Setup variables
HOOK=0x3EB83B5592Fa61C8Db81945294A854D37badc0C0
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC=http://127.0.0.1:8545

# Approve USDC
cast send $USDC "approve(address,uint256)" $HOOK 10000000000 --private-key $PK --rpc-url $RPC

# Commit Ghost Order (1000 USDC, 60s delay)
cast send $HOOK \
  "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 1000000000 \
  0x6c6d5e94bdb98da4daa5f6edbf0a880ccc2d1c8e3e8e5a9ee1c5c5b5a5a5a5a5 \
  1 60 0 \
  "($WETH,$USDC,3000,60,$HOOK)" \
  --private-key $PK --rpc-url $RPC

# Check order created
cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC

# Cancel order
cast send $HOOK "cancelOrder(uint256)" 0 --private-key $PK --rpc-url $RPC
```

## Project Structure

```
foundry/
├── src/
│   ├── GhostVaultHook.sol      # V1 hook (beforeSwap)
│   └── GhostVaultHookV2.sol    # V2 hook (beforeSwap + afterSwap + batch)
├── test/
│   ├── GhostVaultHook.t.sol    # V1 mock tests
│   ├── GhostVaultHookV2.t.sol  # V2 mock tests
│   ├── GhostVaultFork.t.sol    # V1 fork tests
│   └── GhostVaultForkV2.t.sol  # V2 fork tests
├── script/
│   ├── Deploy.s.sol            # V1 deployment
│   └── DeployV2.s.sol          # V2 deployment
└── constants/
    └── Addresses.sol           # All on-chain addresses
```

## Order Types

**YieldOrder** — Price-triggered limit order. Executes when Chainlink price meets target. Earns yield while waiting.

**GhostOrder** — Time-delayed swap with information exposure reduction. Commit-reveal pattern separates intent commitment from execution details. Temporal separation and batch aggregation provide MEV resistance by reducing observable trade information at execution time.

## Key Addresses (Base Mainnet)

| Contract | Address |
|----------|---------|
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| WETH | `0x4200000000000000000000000000000000000006` |
| MetaMorpho Vault | `0x050cE30b927Da55177A4914EC73480238BAD56f0` |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |

## Configuration

Create `.env.local` with:

```
BASE_MAINNET_RPC=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0x...  # For deployment only
```

## Demo Approach

### Cast Commands + Frontend Visualization

We split the demo into **input** (terminal) and **output** (frontend):

| Layer | Role | Component |
|-------|------|-----------|
| **Input** | Execute transactions | Terminal (`cast send`) or frontend command generator |
| **Output** | Visualize state | Frontend order list (read-only) |

**Why this approach:**
1. **Reliable transactions**: Cast commands work perfectly with Anvil fork
2. **Educational**: Shows raw contract calls — users learn the actual function signatures
3. **Real-time visualization**: Frontend reads on-chain state and displays orders with status, value, and yield
4. **Portable**: Commands can be used with any terminal, not locked to a specific wallet

**Frontend features:**
- Parameter inputs (order type, amount, delay) generate corresponding cast commands
- Copy-to-clipboard for each command (approve, commit, cancel)
- Order cards display vault value and yield accrued in real-time
- Dark theme with protocol branding

See `../frontend/DEMO_COMMANDS.md` for the complete command reference.

### Mocks Used in Demo

| Component | Mock | Reason |
|-----------|------|--------|
| Chainlink `updatedAt` | `vm.mockCall` | Fork-block timestamp freezes after vm.warp; we mock fresh timestamp while keeping real price |
| MetaMorpho `maxRedeem` | `vm.mockCall` | After vm.warp, liquidity state may desync; we bypass the limit |
| MetaMorpho yield | `_simulateVaultRebase()` | MetaMorpho's `totalAssets()` reads from Morpho Blue markets which don't accrue interest on fork. We mock `convertToAssets()` and `redeem()` to return principal + calculated yield at 4% APY, then `deal()` USDC to the recipient. |
| Time passage | `vm.warp` | Simulates 30 days for yield accrual demonstration |

All mocks are standard Foundry patterns used in production-grade test suites.

### What's Real (Not Mocked)

- MetaMorpho vault deposit/withdraw (ERC-4626 integration)
- Chainlink price values (real Base mainnet prices)
- Uniswap v4 PoolManager swap execution
- ERC-20 token transfers
- Hook contract logic (commit-reveal, yield tracking, solver fees)

## Help

```bash
make help
```
