# GhostVault

Uniswap v4 Hook that earns yield on idle order capital.

When you place a limit order, your capital sits idle waiting for the price target. GhostVault routes that capital to an ERC-4626 vault (MetaMorpho) where it earns ~4% APY. When conditions are met, the order executes and you keep the yield.

## Features

- **Yield on idle capital** — Funds earn ~4% APY in MetaMorpho vault while waiting
- **Price-triggered orders** — YieldOrder executes when Chainlink price hits target
- **Time-delayed privacy** — GhostOrder uses commit-reveal pattern to hide intent
- **Batch execution** — Aggregate multiple orders into single swap for privacy
- **Solver incentives** — 1% of yield goes to solver who executes orders

## Order Types

**YieldOrder** — Price-triggered. Executes when Chainlink price hits target. Earns yield while waiting.

**GhostOrder** — Time-delayed. Executes after delay passes. Commit-reveal pattern hides intent for privacy.

## Quick Start

```bash
# Install
forge install

# Run tests
make test-v2-mock    # Local tests (no RPC)
make test-v2-fork    # Fork tests (requires BASE_MAINNET_RPC)
```

## Demo

See [../DEMO.md](../DEMO.md) for the full interactive demo guide.

```bash
# Terminal 1: Anvil fork
make demo-anvil

# Terminal 2: Deploy contracts
make demo-mock

# Terminal 3: Frontend
cd ../frontend && npm run dev
```

Open http://localhost:3000 — fully interactive with wagmi (no terminal commands needed).

## Frontend Features

- **Create Orders** — Approve + Commit via wallet
- **Manage Orders** — Cancel or Execute with one click
- **Batch Execute** — Select 2+ orders for privacy-preserving aggregated swap
- **Oracle Controls** — Set ETH/USD price with presets
- **Time Warp** — Advance block time to accrue yield

## Test Commands

| Command | Description |
|---------|-------------|
| `make test-v2-mock` | 14 local tests |
| `make test-v2-fork` | 7 fork tests (real Base mainnet) |
| `make test-all` | All tests |

## Project Structure

```
src/
├── GhostVaultHookV2.sol    # Main hook contract (V2 with batch + afterSwap)
├── SimpleYieldVault.sol    # Demo vault (4% APY)
└── MockChainlinkOracle.sol # Demo oracle (controllable price)

test/
├── GhostVaultHookV2.t.sol  # Local unit tests (14 tests)
└── GhostVaultForkV2.t.sol  # Fork tests (7 tests, real contracts)

script/
├── DeployWithMocks.s.sol   # Demo deployment
└── InitPool.s.sol          # Pool initialization
```

## Configuration

Create `.env.local`:

```
BASE_MAINNET_RPC=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
```

## Key Addresses (Base Mainnet)

| Contract | Address |
|----------|---------|
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| WETH | `0x4200000000000000000000000000000000000006` |
| MetaMorpho | `0x050cE30b927Da55177A4914EC73480238BAD56f0` |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
