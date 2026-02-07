// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {LiquidityHelper} from '../test/helpers/LiquidityHelper.sol';
import {
    POOLMANAGER_BASE_MAINNET,
    USDC_BASE_MAINNET,
    WETH_BASE_MAINNET,
    METAMORPHO_VAULT_BASE_MAINNET,
    ETH_USD_FEED_BASE_MAINNET
} from '../constants/Addresses.sol';

/// @title GhostVault Demo Script
/// @notice Automated terminal demo showcasing YieldOrder, GhostOrder, and Cancel flows.
/// @dev Run with: HOOK_ADDRESS=0x... forge test --match-path script/DemoV2.t.sol --fork-url http://127.0.0.1:8545 -vvv
contract DemoV2 is Test {
    address constant DEMO_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant DEMO_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    IPoolManager constant POOL_MGR = IPoolManager(POOLMANAGER_BASE_MAINNET);
    uint160 constant INIT_SQRT_PRICE = uint160(4_339_505_179_874_779_508_375_552);

    GhostVaultHookV2 public hook;
    LiquidityHelper public liquidityHelper;
    PoolKey public poolKey;

    /// @dev Gauntlet USDC MetaMorpho vault APY on Base (~4%).
    ///      Used to simulate rebase yield that would accrue on mainnet.
    ///      On a fork, vm.warp advances time but no allocator calls reallocate(),
    ///      so we inject USDC into the vault to replicate the effect.
    uint256 constant VAULT_APY_BPS = 400; // 4.00%

    uint256 ordersCreated;
    uint256 ordersExecuted;
    uint256 ordersCancelled;

    function setUp() public {
        // Default address from `make demo-setup` deployment
        // If different, set HOOK_ADDRESS env var: HOOK_ADDRESS=0x... make demo
        address hookAddress = vm.envOr("HOOK_ADDRESS", address(0xE1b3087fDe44898dE9DA9a7158E7607B7d4f00C0));
        hook = GhostVaultHookV2(hookAddress);

        poolKey = PoolKey({
            currency0: Currency.wrap(WETH_BASE_MAINNET),
            currency1: Currency.wrap(USDC_BASE_MAINNET),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        // Initialize the pool with hook
        POOL_MGR.initialize(poolKey, INIT_SQRT_PRICE);

        // Add liquidity for swaps to work
        liquidityHelper = new LiquidityHelper(POOL_MGR);
        address lp = makeAddr('demoLP');
        deal(WETH_BASE_MAINNET, lp, 200e18);
        deal(USDC_BASE_MAINNET, lp, 600_000e6);

        vm.startPrank(lp);
        IERC20(WETH_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);
        IERC20(USDC_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);
        liquidityHelper.addLiquidity(poolKey, 5e15, -887_220, 887_220);
        vm.stopPrank();

        console2.log("");
        console2.log("========================================");
        console2.log("       GhostVault Protocol Demo");
        console2.log("========================================");
        console2.log("");
        console2.log("Hook:", hookAddress);
        console2.log("Demo account:", DEMO_ACCOUNT);
        console2.log("USDC balance:", IERC20(USDC_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) / 1e6, "USDC");
        console2.log("WETH balance:", IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) / 1e18, "WETH");
        console2.log("");
        console2.log("NOTE: Running on Anvil fork of Base mainnet.");
        console2.log("Vault yield is simulated via deal() rebase injection at 4%% APY");
        console2.log("(real Gauntlet USDC vault rate). On mainnet, MetaMorpho accrues");
        console2.log("yield natively via allocator rebalancing.");
        console2.log("");
    }

    function test_Demo() public {
        _demoYieldOrder();
        vm.clearMockedCalls(); // Clear stale mocks between demos
        _demoGhostOrder();
        vm.clearMockedCalls();
        _demoCancelWithYield();
        _printSummary();
    }

    function _demoYieldOrder() internal {
        console2.log("=== Demo 1: YieldOrder (Price-Triggered) ===");
        console2.log("");

        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();
        uint256 currentPrice = uint256(ethPrice);
        uint256 targetPrice = currentPrice + 100e8;

        console2.log("Current ETH price: $%s", currentPrice / 1e8);
        console2.log("Target price: $%s", targetPrice / 1e8);

        uint256 depositAmount = 5000e6;
        bool zeroForOne = false;
        bytes32 salt = keccak256(abi.encodePacked("yield-demo", block.timestamp));
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(DEMO_ACCOUNT);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET,
            depositAmount,
            intentHash,
            GhostVaultHookV2.OrderType.YIELD_ORDER,
            0,
            0,
            poolKey
        );
        vm.stopPrank();
        ordersCreated++;

        console2.log("Committed: orderId=%s, amount=%s USDC", orderId, depositAmount / 1e6);
        console2.log("Funds deposited to MetaMorpho vault (earning ~4%% APY)");

        // Read vault shares from the committed order
        (,,,,, uint256 vaultShares,,,) = hook.getOrder(orderId);

        // Advance 30 days and simulate vault rebase
        uint256 daysElapsed = 30;
        vm.warp(block.timestamp + daysElapsed * 1 days);
        _simulateVaultRebase(depositAmount, daysElapsed, vaultShares, address(hook));
        _mockChainlinkPrice(int256(currentPrice));
        _mockVaultMaxRedeem();

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);

        console2.log("");
        console2.log("After %s days:", daysElapsed);
        console2.log("  Vault value: %s USDC", valueAfter / 1e6);
        console2.log("  Yield accrued: %s USDC", yieldAccrued / 1e6);
        console2.log("  Yield (precise): %s units (6 decimals)", yieldAccrued);

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT);

        GhostVaultHookV2.RevealData memory reveal = GhostVaultHookV2.RevealData({
            targetPrice: targetPrice,
            zeroForOne: zeroForOne,
            salt: salt
        });

        address solver = makeAddr("solver");
        vm.prank(solver);
        hook.executeOrder(orderId, reveal);
        ordersExecuted++;

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) - userWethBefore;
        uint256 solverFee = IERC20(USDC_BASE_MAINNET).balanceOf(solver);

        console2.log("");
        console2.log("Executed:");
        console2.log("  WETH received: %s wei (%s.%s WETH)", wethReceived, wethReceived / 1e18, (wethReceived % 1e18) / 1e14);
        console2.log("  Solver fee paid: %s USDC", solverFee / 1e6);
        console2.log("  Solver fee (precise): %s units", solverFee);
        console2.log("");
    }

    function _demoGhostOrder() internal {
        console2.log("=== Demo 2: GhostOrder (Time-Delayed Privacy) ===");
        console2.log("");

        uint256 depositAmount = 1000e6;
        uint256 minDelay = 60;
        bool zeroForOne = false;
        bytes32 salt = keccak256(abi.encodePacked("ghost-demo", block.timestamp));
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(DEMO_ACCOUNT);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET,
            depositAmount,
            intentHash,
            GhostVaultHookV2.OrderType.GHOST_ORDER,
            minDelay,
            0,
            poolKey
        );
        vm.stopPrank();
        ordersCreated++;

        console2.log("Committed: orderId=%s, amount=%s USDC, delay=%ss", orderId, depositAmount / 1e6, minDelay);

        GhostVaultHookV2.RevealData memory reveal = GhostVaultHookV2.RevealData({
            targetPrice: targetPrice,
            zeroForOne: zeroForOne,
            salt: salt
        });

        address solver = makeAddr("solver2");
        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log("Early execution blocked (DelayNotElapsed)");

        vm.warp(block.timestamp + minDelay + 1);
        // GhostOrder delay is short (60s), yield is negligible but still accrues
        (,,,,, uint256 ghostShares,,,) = hook.getOrder(orderId);
        _simulateVaultRebase(depositAmount, 1, ghostShares, address(hook)); // 1 day minimum granularity
        _mockChainlinkFresh();
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT);

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);
        ordersExecuted++;

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) - userWethBefore;
        console2.log("Executed after delay:");
        console2.log("  WETH received: %s wei (%s.%s WETH)", wethReceived, wethReceived / 1e18, (wethReceived % 1e18) / 1e14);
        console2.log("");
    }

    function _demoCancelWithYield() internal {
        console2.log("=== Demo 3: Cancel Order (Returns Principal + Yield) ===");
        console2.log("");

        uint256 depositAmount = 2000e6;
        bytes32 salt = keccak256(abi.encodePacked("cancel-demo", block.timestamp));
        bytes32 intentHash = keccak256(abi.encode(uint256(5000e8), false, salt));

        vm.startPrank(DEMO_ACCOUNT);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET,
            depositAmount,
            intentHash,
            GhostVaultHookV2.OrderType.YIELD_ORDER,
            0,
            0,
            poolKey
        );
        vm.stopPrank();
        ordersCreated++;

        // Capture balance AFTER commit to avoid underflow from ERC-4626 rounding
        uint256 userBalanceAfterCommit = IERC20(USDC_BASE_MAINNET).balanceOf(DEMO_ACCOUNT);

        console2.log("Committed: orderId=%s, amount=%s USDC", orderId, depositAmount / 1e6);
        console2.log("Funds deposited to MetaMorpho vault");

        // Read vault shares from the committed order
        (,,,,, uint256 cancelShares,,,) = hook.getOrder(orderId);

        // Advance 7 days and simulate vault rebase
        uint256 daysElapsed = 7;
        vm.warp(block.timestamp + daysElapsed * 1 days);
        _simulateVaultRebase(depositAmount, daysElapsed, cancelShares, DEMO_ACCOUNT);

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);

        console2.log("");
        console2.log("After %s days:", daysElapsed);
        console2.log("  Vault value: %s USDC", valueAfter / 1e6);
        console2.log("  Yield accrued: %s USDC", yieldAccrued / 1e6);
        console2.log("  Yield (precise): %s units (6 decimals)", yieldAccrued);

        vm.prank(DEMO_ACCOUNT);
        hook.cancelOrder(orderId);
        ordersCancelled++;

        uint256 userBalanceAfter = IERC20(USDC_BASE_MAINNET).balanceOf(DEMO_ACCOUNT);
        uint256 totalReturned = userBalanceAfter - userBalanceAfterCommit;

        console2.log("");
        console2.log("Cancelled:");
        console2.log("  Returned: %s USDC (principal + yield)", totalReturned / 1e6);
        console2.log("  Returned (precise): %s units", totalReturned);
        console2.log("  Profit over principal: %s USDC", totalReturned > depositAmount ? (totalReturned - depositAmount) / 1e6 : 0);
        console2.log("  No solver fee on cancel (user keeps 100%% of yield)");
        console2.log("");
    }

    function _printSummary() internal view {
        console2.log("========================================");
        console2.log("            Demo Summary");
        console2.log("========================================");
        console2.log("");
        console2.log("Orders created: %s", ordersCreated);
        console2.log("Orders executed: %s", ordersExecuted);
        console2.log("Orders cancelled: %s", ordersCancelled);
        console2.log("");
        console2.log("Final balances:");
        console2.log("  USDC: %s", IERC20(USDC_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) / 1e6);
        console2.log("  WETH: %s", IERC20(WETH_BASE_MAINNET).balanceOf(DEMO_ACCOUNT) / 1e18);
        console2.log("");
        console2.log("----------------------------------------");
        console2.log("What we demonstrated:");
        console2.log("  1. YieldOrder: price-triggered execution, real yield + solver fee");
        console2.log("  2. GhostOrder: time-delayed swap with early-execution protection");
        console2.log("  3. Cancel: user reclaims principal + yield (no solver fee)");
        console2.log("");
        console2.log("Yield was simulated at 4%% APY (Gauntlet USDC vault rate).");
        console2.log("On mainnet, MetaMorpho accrues yield natively.");
        console2.log("See fork tests for real integration: make test-v2-fork -vvv");
        console2.log("");
        console2.log("Demo complete!");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────
    //  Rebase Simulation
    // ─────────────────────────────────────────────────────────────

    /// @dev Simulates MetaMorpho vault yield accrual on an Anvil fork.
    ///
    ///      Problem: MetaMorpho's totalAssets() iterates over Morpho Blue markets
    ///      via MORPHO.expectedSupplyAssets(). On a fork, vm.warp advances time but
    ///      Morpho Blue's interest accrual never runs, so convertToAssets stays flat.
    ///      deal()-ing USDC to the vault doesn't help because totalAssets() reads
    ///      from Morpho Blue state, not the vault's token balance.
    ///
    ///      Solution: We mock convertToAssets() for view calls and redeem() for
    ///      execution. Since mocked redeem() doesn't transfer tokens, we deal USDC
    ///      to the recipient that the hook expects to hold the funds after redemption.
    ///
    ///      Formula: yield = principal * (APY_BPS / 10000) * (days / 365)
    ///      Example: 5000 USDC * 4% * 30/365 = ~$16.44
    ///
    /// @param principal   The original deposit amount (USDC, 6 decimals)
    /// @param daysElapsed Days of simulated yield accrual
    /// @param shares      Vault shares held by the hook for this order
    /// @param recipient   Where to deal the simulated USDC (hook for execute, user for cancel)
    function _simulateVaultRebase(uint256 principal, uint256 daysElapsed, uint256 shares, address recipient) internal {
        uint256 yieldAmount = (principal * VAULT_APY_BPS * daysElapsed) / (365 * 10_000);
        uint256 totalWithYield = principal + yieldAmount;

        // Mock convertToAssets(shares) → getOrderValue() shows yield
        vm.mockCall(
            METAMORPHO_VAULT_BASE_MAINNET,
            abi.encodeWithSignature("convertToAssets(uint256)", shares),
            abi.encode(totalWithYield)
        );

        // Mock ALL redeem() calls → returns totalWithYield (no actual token transfer)
        vm.mockCall(
            METAMORPHO_VAULT_BASE_MAINNET,
            abi.encodeWithSelector(IERC4626.redeem.selector),
            abi.encode(totalWithYield)
        );

        // Deal USDC to the recipient since mocked redeem() doesn't transfer tokens.
        // - For executeOrder: recipient = hook (hook redeems to itself, then swaps)
        // - For cancelOrder:  recipient = user (hook redeems directly to user)
        deal(
            USDC_BASE_MAINNET,
            recipient,
            IERC20(USDC_BASE_MAINNET).balanceOf(recipient) + totalWithYield
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Mock Helpers
    // ─────────────────────────────────────────────────────────────

    function _mockChainlinkFresh() internal {
        (, int256 realPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();
        vm.mockCall(
            ETH_USD_FEED_BASE_MAINNET,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), realPrice, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _mockChainlinkPrice(int256 price) internal {
        vm.mockCall(
            ETH_USD_FEED_BASE_MAINNET,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _mockVaultMaxRedeem() internal {
        vm.mockCall(
            METAMORPHO_VAULT_BASE_MAINNET,
            abi.encodeWithSignature('maxRedeem(address)'),
            abi.encode(type(uint256).max)
        );
    }
}
