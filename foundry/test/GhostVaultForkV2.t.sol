// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {LiquidityHelper} from './helpers/LiquidityHelper.sol';

import {
    POOLMANAGER_BASE_MAINNET,
    USDC_BASE_MAINNET,
    WETH_BASE_MAINNET,
    METAMORPHO_VAULT_BASE_MAINNET,
    ETH_USD_FEED_BASE_MAINNET
} from '../constants/Addresses.sol';

/// @title GhostVault V2 Fork Tests
/// @notice Integration tests against real Base mainnet state (MetaMorpho, Chainlink, Uniswap v4).
///         Tests V2 features: afterSwap observation, batch execution, reentrancy guard, tokenIn validation.
/// @dev Run with: source .env.local && forge test --match-path test/GhostVaultForkV2.t.sol --fork-url $BASE_MAINNET_RPC -vvv
///
///      Token ordering on Base mainnet:
///        WETH (0x4200...) < USDC (0x8335...) -> currency0 = WETH, currency1 = USDC
///        This is the OPPOSITE of the mock tests where USDC < WETH.
///        For depositing USDC and wanting WETH: zeroForOne = false (sell currency1 for currency0).
contract GhostVaultForkV2Test is Test {
    IPoolManager constant POOL_MGR = IPoolManager(POOLMANAGER_BASE_MAINNET);

    GhostVaultHookV2 public hook;
    LiquidityHelper public liquidityHelper;

    PoolKey public poolKey;

    address public user = makeAddr('forkUser');
    address public solver = makeAddr('forkSolver');
    address public lp = makeAddr('forkLP');

    uint160 constant INIT_SQRT_PRICE = uint160(4_339_505_179_874_779_508_375_552);

    function setUp() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddr = address(flags);
        deployCodeTo(
            'GhostVaultHookV2.sol:GhostVaultHookV2', abi.encode(POOLMANAGER_BASE_MAINNET, ETH_USD_FEED_BASE_MAINNET), hookAddr
        );
        hook = GhostVaultHookV2(hookAddr);

        hook.setYieldConfig(USDC_BASE_MAINNET, METAMORPHO_VAULT_BASE_MAINNET);

        poolKey = PoolKey({
            currency0: Currency.wrap(WETH_BASE_MAINNET),
            currency1: Currency.wrap(USDC_BASE_MAINNET),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        POOL_MGR.initialize(poolKey, INIT_SQRT_PRICE);

        liquidityHelper = new LiquidityHelper(POOL_MGR);
        deal(WETH_BASE_MAINNET, lp, 200e18);
        deal(USDC_BASE_MAINNET, lp, 600_000e6);

        vm.startPrank(lp);
        IERC20(WETH_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);
        IERC20(USDC_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);
        liquidityHelper.addLiquidity(poolKey, 5e15, -887_220, 887_220);
        vm.stopPrank();

        deal(USDC_BASE_MAINNET, user, 100_000e6);
    }

    function _mockChainlinkFresh() internal {
        (, int256 realPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();
        vm.mockCall(
            ETH_USD_FEED_BASE_MAINNET,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), realPrice, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _mockVaultMaxRedeem() internal {
        vm.mockCall(
            METAMORPHO_VAULT_BASE_MAINNET,
            abi.encodeWithSignature('maxRedeem(address)'),
            abi.encode(type(uint256).max)
        );
    }

    function _mockChainlinkPrice(int256 price) internal {
        vm.mockCall(
            ETH_USD_FEED_BASE_MAINNET,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 1: Real MetaMorpho Deposit
    // ─────────────────────────────────────────────────────────────

    function test_RealMetaMorphoDeposit() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 1: Real MetaMorpho Deposit + Yield');
        console2.log('====================================================');

        IERC4626 vault = IERC4626(METAMORPHO_VAULT_BASE_MAINNET);
        uint256 depositAmount = 10_000e6;

        deal(USDC_BASE_MAINNET, address(this), depositAmount);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, depositAmount);
        uint256 shares = vault.deposit(depositAmount, address(this));

        console2.log('  Deposited:       %s USDC', depositAmount / 1e6);
        console2.log('  Shares received: %s', shares);
        assertGt(shares, 0, 'Should receive vault shares');

        uint256 valueBefore = vault.convertToAssets(shares);
        console2.log('  Value (t=0):     %s USDC', valueBefore / 1e6);

        vm.warp(block.timestamp + 7 days);

        uint256 valueAfter = vault.convertToAssets(shares);
        uint256 yieldEarned = valueAfter > depositAmount ? valueAfter - depositAmount : 0;

        console2.log('  Value (t=7d):    %s USDC', valueAfter / 1e6);
        console2.log('  Yield earned:    %s (raw)', yieldEarned);

        if (yieldEarned > 0) {
            uint256 apyBps = (yieldEarned * 365 * 10_000) / (depositAmount * 7);
            console2.log('  Implied APY:     %s.%s%%', apyBps / 100, apyBps % 100);
        }

        assertApproxEqAbs(valueAfter, depositAmount, 1, 'Value should not decrease (1 wei ERC-4626 rounding)');
        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: Real Chainlink Feed
    // ─────────────────────────────────────────────────────────────

    function test_RealChainlinkFeed() public view {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 2: Real Chainlink ETH/USD Feed');
        console2.log('====================================================');

        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET);
        (, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
        uint8 dec = feed.decimals();

        // forge-lint: disable-next-line(unsafe-typecast)
        console2.log('  ETH/USD Price: $%s', uint256(price) / (10 ** dec));
        console2.log('  Decimals:      %s', dec);
        console2.log('  Updated at:    %s', updatedAt);
        console2.log('  Block time:    %s', block.timestamp);

        assertEq(dec, 8, 'Chainlink ETH/USD should have 8 decimals');
        assertGt(price, 0, 'Price should be positive');
        // forge-lint: disable-next-line(unsafe-typecast)
        assertGt(uint256(price), 1000e8, 'ETH should be > $1,000');
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLt(uint256(price), 10_000e8, 'ETH should be < $10,000');
        assertGt(updatedAt, 0, 'Updated timestamp should be set');
        assertLe(updatedAt, block.timestamp, 'Updated should be <= block time');

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 3: Fork YieldOrder Lifecycle
    // ─────────────────────────────────────────────────────────────

    function test_ForkYieldOrderLifecycle() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 3: YieldOrder Full Lifecycle (Real Base)');
        console2.log('====================================================');

        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currentEthPrice = uint256(ethPrice);

        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = currentEthPrice + 100e8;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkYieldSecret');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:      %s USDC', depositAmount / 1e6);
        console2.log('  Real ETH price: $%s', currentEthPrice / 1e8);
        console2.log('  Target price:   $%s', targetPrice / 1e8);

        (uint256 valueBefore,) = hook.getOrderValue(orderId);
        console2.log('  Vault value:    %s USDC', valueBefore / 1e6);

        vm.warp(block.timestamp + 30 days);

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 30 days:');
        console2.log('  Vault value:    %s USDC', valueAfter / 1e6);
        console2.log('  Yield accrued:  %s (raw)', yieldAccrued);

        // forge-lint: disable-next-line(unsafe-typecast)
        _mockChainlinkPrice(int256(currentEthPrice));
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(user);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(user) - userWethBefore;
        uint256 solverFee = IERC20(USDC_BASE_MAINNET).balanceOf(solver);

        console2.log('');
        console2.log('  Execution Results:');
        console2.log('  WETH received:  %s (wei)', wethReceived);
        console2.log('  Solver fee:     %s USDC (raw)', solverFee);

        assertGt(wethReceived, 0, 'User should have received WETH');

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.EXECUTED));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 4: Fork GhostOrder Execution
    // ─────────────────────────────────────────────────────────────

    function test_ForkGhostOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 4: GhostOrder Time-Delayed (Real Base)');
        console2.log('====================================================');

        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkGhostSecret');
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHookV2.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:     %s USDC (hidden from pool)', depositAmount / 1e6);
        console2.log('  Min delay:     %s seconds', minDelay);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log('  Early execution blocked (DelayNotElapsed)');

        vm.warp(block.timestamp + minDelay + 1);
        _mockChainlinkFresh();
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(user);

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(user) - userWethBefore;

        console2.log('');
        console2.log('  After delay elapsed:');
        console2.log('  WETH received:  %s (wei)', wethReceived);
        console2.log('  MEV exposure:   NONE (funds were in Morpho)');

        assertGt(wethReceived, 0, 'User should have received WETH');

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 5: Fork Cancel with Real Yield
    // ─────────────────────────────────────────────────────────────

    function test_ForkCancelWithRealYield() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 5: Cancel with Real MetaMorpho Yield');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(5000e8), false, keccak256('forkCancel')));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        uint256 userBalanceBefore = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        console2.log('  Deposited:     %s USDC', depositAmount / 1e6);

        vm.warp(block.timestamp + 14 days);

        (uint256 currentValue, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 14 days:');
        console2.log('  Vault value:   %s USDC', currentValue / 1e6);
        console2.log('  Yield accrued: %s (raw)', yieldAccrued);

        vm.prank(user);
        hook.cancelOrder(orderId);

        uint256 userBalanceAfter = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        uint256 totalReturned = userBalanceAfter - userBalanceBefore;
        uint256 profit = totalReturned > depositAmount ? totalReturned - depositAmount : 0;

        console2.log('');
        console2.log('  Cancellation Results:');
        console2.log('  Total returned: %s USDC', totalReturned / 1e6);
        console2.log('  Yield kept:     %s (raw)', profit);

        assertApproxEqAbs(totalReturned, depositAmount, 1, 'Should return at least principal (1 wei ERC-4626 rounding)');

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.CANCELLED));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 6: Fork Oracle Protection
    // ─────────────────────────────────────────────────────────────

    function test_ForkOracleProtection() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 6: Oracle Protection (Real Chainlink)');
        console2.log('====================================================');

        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();

        uint256 depositAmount = 10_000e6;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 targetPrice = uint256(ethPrice) + 100e8;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkOracleTest');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Order committed: %s USDC', depositAmount / 1e6);
        // forge-lint: disable-next-line(unsafe-typecast)
        console2.log('  Real ETH price:  $%s', uint256(ethPrice) / 1e8);

        vm.warp(block.timestamp + 2 hours);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert();
        hook.executeOrder(orderId, reveal);

        console2.log('  After 2 hours without oracle update:');
        console2.log('  BLOCKED: Oracle is stale (>1 hour old)');
        console2.log('  User funds remain safe in MetaMorpho vault');

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.ACTIVE));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 7: Fork Batch Execution (V2 feature)
    // ─────────────────────────────────────────────────────────────

    function test_ForkBatchExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  V2 FORK TEST 7: Batch Execution (Real Base)');
        console2.log('====================================================');

        uint256 deposit0 = 10_000e6;
        uint256 deposit1 = 20_000e6;
        bool zeroForOne = false; // sell USDC (currency1) for WETH (currency0)

        // ── Order 0 ──
        bytes32 salt0 = keccak256('forkBatch0');
        bytes32 intentHash0 = keccak256(abi.encode(uint256(0), zeroForOne, salt0));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), deposit0 + deposit1);
        uint256 orderId0 = hook.commitOrder(
            USDC_BASE_MAINNET, deposit0, intentHash0, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
        );

        // ── Order 1 ──
        bytes32 salt1 = keccak256('forkBatch1');
        bytes32 intentHash1 = keccak256(abi.encode(uint256(0), zeroForOne, salt1));
        uint256 orderId1 = hook.commitOrder(
            USDC_BASE_MAINNET, deposit1, intentHash1, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Order 0: %s USDC committed', deposit0 / 1e6);
        console2.log('  Order 1: %s USDC committed', deposit1 / 1e6);

        vm.warp(block.timestamp + 2);
        _mockChainlinkFresh();
        _mockVaultMaxRedeem();

        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = orderId0;
        orderIds[1] = orderId1;

        GhostVaultHookV2.RevealData[] memory reveals = new GhostVaultHookV2.RevealData[](2);
        reveals[0] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: zeroForOne, salt: salt0});
        reveals[1] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: zeroForOne, salt: salt1});

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(user);

        vm.prank(solver);
        hook.executeBatch(orderIds, reveals);

        uint256 userWethAfter = IERC20(WETH_BASE_MAINNET).balanceOf(user);
        uint256 wethReceived = userWethAfter - userWethBefore;

        console2.log('');
        console2.log('  Batch Execution Results:');
        console2.log('  Total WETH received: %s (wei)', wethReceived);
        console2.log('  Orders in batch:     2');
        console2.log('  Privacy:             Individual sizes hidden in single swap');

        assertGt(wethReceived, 0, 'User should have received WETH from batch');

        // Verify both orders are EXECUTED
        for (uint256 i = 0; i < 2; i++) {
            (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderIds[i]);
            assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.EXECUTED));
        }

        uint256 solverFee = IERC20(USDC_BASE_MAINNET).balanceOf(solver);
        console2.log('  Solver fee:          %s USDC (raw)', solverFee);

        console2.log('====================================================');
        console2.log('');
    }
}
