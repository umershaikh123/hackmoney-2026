# GhostVault Protocol — Makefile

#    make test-mock          Run 8 V1 mock tests (no RPC needed)
#    make test-fork          Run 6 V1 fork tests (Base mainnet)
#    make test-morpho        Run 3 standalone Morpho yield tests
#    make test-all           Run all tests
#    make test-v2-mock       Run 14 V2 mock tests (no RPC needed)
#    make test-v2-fork       Run 7 V2 fork tests (Base mainnet)
#    make build              Compile contracts
#    make logs               Run all tests and save logs to test-logs/
#    make clean-logs         Delete saved logs

# Load RPC URL from .env or .env.local
ifneq (,$(wildcard .env))
  include .env
  export
else ifneq (,$(wildcard .env.local))
  include .env.local
  export
endif

export PATH := $(HOME)/.foundry/bin:$(PATH)

LOG_DIR := test-logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)

$(LOG_DIR):
	mkdir -p $(LOG_DIR)

# ─────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────

.PHONY: build
build:
	forge build

# ─────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────

.PHONY: test-mock test-fork test-morpho test-v2-mock test-v2-fork test-all

test-mock:
	forge test --match-path test/GhostVaultHook.t.sol -vv

test-fork:
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

test-morpho:
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

test-v2-mock:
	forge test --match-path test/GhostVaultHookV2.t.sol -vv

test-v2-fork:
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --match-path test/GhostVaultForkV2.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

test-all:
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --fork-url $(BASE_MAINNET_RPC) -vv

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────

.PHONY: log-mock log-fork log-morpho logs

log-mock: $(LOG_DIR)
	forge test --match-path test/GhostVaultHook.t.sol -vvv 2>&1 | tee $(LOG_DIR)/mock_$(TIMESTAMP).log

log-fork: $(LOG_DIR)
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/fork_$(TIMESTAMP).log

log-morpho: $(LOG_DIR)
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/morpho_$(TIMESTAMP).log

logs: $(LOG_DIR)
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	@echo "Running all tests..."
	forge test --match-path test/GhostVaultHook.t.sol -vvv 2>&1 | tee $(LOG_DIR)/v1_mock_$(TIMESTAMP).log
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/v1_fork_$(TIMESTAMP).log
	forge test --match-path test/GhostVaultHookV2.t.sol -vvv 2>&1 | tee $(LOG_DIR)/v2_mock_$(TIMESTAMP).log
	forge test --match-path test/GhostVaultForkV2.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/v2_fork_$(TIMESTAMP).log
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/morpho_$(TIMESTAMP).log
	@echo "Logs saved to $(LOG_DIR)/"

# ─────────────────────────────────────────────────────────────
# Demo (Anvil Fork)
# ─────────────────────────────────────────────────────────────

DEMO_ACCOUNT := 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEMO_PK := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
USDC := 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH := 0x4200000000000000000000000000000000000006
ANVIL_RPC := http://127.0.0.1:8545

.PHONY: demo-anvil demo-setup demo

demo-anvil:
	@test -n "$(BASE_MAINNET_RPC)" || (echo "ERROR: BASE_MAINNET_RPC not set"; exit 1)
	@echo "Starting Anvil fork of Base mainnet (chain ID 31337)..."
	anvil --fork-url $(BASE_MAINNET_RPC) --chain-id 31337

demo-setup:
	@echo "GhostVault Demo Setup"
	@echo ""
	@echo "[1/3] Wrapping ETH to WETH..."
	@cast send $(WETH) "deposit()" --value 10ether --private-key $(DEMO_PK) --rpc-url $(ANVIL_RPC) > /dev/null
	@echo "[2/3] Setting USDC balance..."
	@cast rpc anvil_setStorageAt $(USDC) $$(cast index address $(DEMO_ACCOUNT) 9) 0x000000000000000000000000000000000000000000000000000000174876E800 --rpc-url $(ANVIL_RPC) > /dev/null
	@echo "[3/3] Deploying GhostVaultHookV2..."
	@source ~/.bashrc && DEPLOYER_PRIVATE_KEY=$(DEMO_PK) forge script script/DeployV2.s.sol --rpc-url $(ANVIL_RPC) --broadcast 2>&1 | tee /tmp/deploy_output.txt
	@grep -o "V2 Hook deployed at: 0x[a-fA-F0-9]*" /tmp/deploy_output.txt | sed 's/V2 Hook deployed at: //' > .hook_address
	@echo ""
	@echo "Deployed hook address saved to .hook_address"
	@cat .hook_address
	@echo ""
	@echo "Balances:"
	@echo "  USDC: $$(cast call $(USDC) 'balanceOf(address)(uint256)' $(DEMO_ACCOUNT) --rpc-url $(ANVIL_RPC))"
	@echo "  WETH: $$(cast call $(WETH) 'balanceOf(address)(uint256)' $(DEMO_ACCOUNT) --rpc-url $(ANVIL_RPC))"
	@echo ""
	@echo "Run 'make demo' to execute the automated demo"

demo:
	@echo ""
	@echo "Running GhostVault Automated Demo..."
	@test -f .hook_address && echo "Using hook: $$(cat .hook_address)" || echo "Warning: .hook_address not found, using default"
	@echo ""
	@HOOK_ADDRESS=$$(cat .hook_address 2>/dev/null || echo "") forge test --match-path script/DemoV2.t.sol --fork-url $(ANVIL_RPC) -vv

# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────

.PHONY: clean-logs
clean-logs:
	rm -rf $(LOG_DIR)

# ─────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "GhostVault Makefile"
	@echo ""
	@echo "Demo (Terminal 1: demo-anvil, Terminal 2: demo-setup + demo):"
	@echo "  make demo-anvil   Start Anvil fork"
	@echo "  make demo-setup   Deploy hook + fund account"
	@echo "  make demo         Run automated demo (YieldOrder, GhostOrder, Cancel)"
	@echo ""
	@echo "Build:"
	@echo "  make build        Compile contracts"
	@echo ""
	@echo "Tests:"
	@echo "  make test-mock    V1 mock tests (8)"
	@echo "  make test-fork    V1 fork tests (6)"
	@echo "  make test-v2-mock V2 mock tests (14)"
	@echo "  make test-v2-fork V2 fork tests (7)"
	@echo "  make test-morpho  Morpho yield tests (3)"
	@echo "  make test-all     All tests"
	@echo ""
	@echo "Logs:"
	@echo "  make logs         Run all + save logs"
	@echo "  make clean-logs   Delete logs"
