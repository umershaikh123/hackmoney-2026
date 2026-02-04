# ─────────────────────────────────────────────────────────────
#  GhostVault Protocol — Makefile
# ─────────────────────────────────────────────────────────────
#
#  Usage:
#    make test-mock          Run 8 V1 mock tests (no RPC needed)
#    make test-fork          Run 6 V1 fork tests (Base mainnet)
#    make test-morpho        Run 3 standalone Morpho yield tests
#    make test-all           Run all tests
#    make test-v2-mock       Run 14 V2 mock tests (no RPC needed)
#    make test-v2-fork       Run 7 V2 fork tests (Base mainnet)
#    make build              Compile contracts
#    make logs               Run all tests and save logs to test-logs/
#    make clean-logs         Delete saved logs
#
# ─────────────────────────────────────────────────────────────

# Load RPC URL from .env / .env.local
ifneq (,$(wildcard .env))
  include .env
  export
else ifneq (,$(wildcard .env.local))
  include .env.local
  export
endif

# ── Foundry binary (add to PATH if not found) ──
export PATH := $(HOME)/.foundry/bin:$(PATH)

# ── Directories ──
LOG_DIR := test-logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)

# ── Ensure log directory exists ──
$(LOG_DIR):
	mkdir -p $(LOG_DIR)

# ─────────────────────────────────────────────────────────────
#  Build
# ─────────────────────────────────────────────────────────────

.PHONY: build
build:
	forge build

# ─────────────────────────────────────────────────────────────
#  Tests — Run in terminal
# ─────────────────────────────────────────────────────────────

.PHONY: test-mock test-fork test-morpho test-v2-mock test-v2-fork test-all

## Run 8 V1 mock unit tests (no RPC needed)
test-mock:
	forge test --match-path test/GhostVaultHook.t.sol -vv

## Run 6 V1 fork tests against real Base mainnet
test-fork:
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

## Run 3 standalone Morpho yield tests
test-morpho:
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

## Run 14 V2 mock unit tests (no RPC needed)
test-v2-mock:
	forge test --match-path test/GhostVaultHookV2.t.sol -vv

## Run 7 V2 fork tests against real Base mainnet
test-v2-fork:
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --match-path test/GhostVaultForkV2.t.sol --fork-url $(BASE_MAINNET_RPC) -vv

## Run all tests (v1 + v2 + morpho)
test-all:
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --fork-url $(BASE_MAINNET_RPC) -vv

# ─────────────────────────────────────────────────────────────
#  Tests — Run and save logs
# ─────────────────────────────────────────────────────────────

.PHONY: log-mock log-fork log-morpho logs

## Run mock tests and save log
log-mock: $(LOG_DIR)
	forge test --match-path test/GhostVaultHook.t.sol -vvv 2>&1 | tee $(LOG_DIR)/mock_$(TIMESTAMP).log
	@echo ""
	@echo "Log saved: $(LOG_DIR)/mock_$(TIMESTAMP).log"

## Run fork tests and save log
log-fork: $(LOG_DIR)
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/fork_$(TIMESTAMP).log
	@echo ""
	@echo "Log saved: $(LOG_DIR)/fork_$(TIMESTAMP).log"

## Run morpho tests and save log
log-morpho: $(LOG_DIR)
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/morpho_$(TIMESTAMP).log
	@echo ""
	@echo "Log saved: $(LOG_DIR)/morpho_$(TIMESTAMP).log"

## Run ALL tests and save each log + a combined summary
logs: $(LOG_DIR)
	@echo "═══════════════════════════════════════════════════"
	@echo "  Running all GhostVault tests — logging results"
	@echo "═══════════════════════════════════════════════════"
	@echo ""
	@if [ -z "$(BASE_MAINNET_RPC)" ]; then \
		echo "ERROR: BASE_MAINNET_RPC not set. Add it to .env.local or export it."; \
		exit 1; \
	fi
	@echo "── Mock Tests (8) ──────────────────────────────────"
	forge test --match-path test/GhostVaultHook.t.sol -vvv 2>&1 | tee $(LOG_DIR)/mock_$(TIMESTAMP).log
	@echo ""
	@echo "── Fork Tests (6) ──────────────────────────────────"
	forge test --match-path test/GhostVaultFork.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/fork_$(TIMESTAMP).log
	@echo ""
	@echo "── Morpho Tests (3) ────────────────────────────────"
	forge test --match-path test/MorphoYield.t.sol --fork-url $(BASE_MAINNET_RPC) -vvv 2>&1 | tee $(LOG_DIR)/morpho_$(TIMESTAMP).log
	@echo ""
	@echo "═══════════════════════════════════════════════════"
	@echo "  Logs saved to $(LOG_DIR)/"
	@echo "    mock_$(TIMESTAMP).log"
	@echo "    fork_$(TIMESTAMP).log"
	@echo "    morpho_$(TIMESTAMP).log"
	@echo "═══════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────
#  Cleanup
# ─────────────────────────────────────────────────────────────

.PHONY: clean-logs
clean-logs:
	rm -rf $(LOG_DIR)
	@echo "Cleared $(LOG_DIR)/"

# ─────────────────────────────────────────────────────────────
#  Help
# ─────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo ""
	@echo "GhostVault Protocol — Makefile Commands"
	@echo "──────────────────────────────────────────"
	@echo "  make build        Compile contracts"
	@echo ""
	@echo "  make test-mock    Run 8 V1 mock tests (no RPC)"
	@echo "  make test-fork    Run 6 V1 fork tests (needs RPC)"
	@echo "  make test-morpho  Run 3 Morpho yield tests (needs RPC)"
	@echo "  make test-v2-mock Run 14 V2 mock tests (no RPC)"
	@echo "  make test-v2-fork Run 7 V2 fork tests (needs RPC)"
	@echo "  make test-all     Run all tests"
	@echo ""
	@echo "  make log-mock     Run mock tests + save log"
	@echo "  make log-fork     Run fork tests + save log"
	@echo "  make log-morpho   Run morpho tests + save log"
	@echo "  make logs         Run ALL tests + save all logs"
	@echo ""
	@echo "  make clean-logs   Delete test-logs/ directory"
	@echo "  make help         Show this help"
	@echo ""
	@echo "RPC is loaded from .env.local automatically."
	@echo "Or: export BASE_MAINNET_RPC=https://..."
	@echo ""
