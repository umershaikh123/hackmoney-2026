// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';
import {MockERC20} from 'solmate/src/test/utils/mocks/MockERC20.sol';
import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {TestVault} from './helpers/TestVault.sol';
import {LiquidityHelper} from './helpers/LiquidityHelper.sol';
import {SwapHelper} from './helpers/SwapHelper.sol';

/// @title GhostVaultHookV2 Test Suite
/// @notice Tests for V2 features: afterSwap observation, batch execution, tokenIn validation,
///         plus all V1 lifecycle tests ported to the V2 contract.
contract GhostVaultHookV2Test is Test {
    using PoolIdLibrary for PoolKey;

    GhostVaultHookV2 public hook;
    PoolManager public poolManager;
    LiquidityHelper public liquidityHelper;
    SwapHelper public swapHelper;

    address constant ORACLE = address(0x0FACE);
    TestVault public vault;
    MockERC20 public usdc;
    MockERC20 public weth;

    PoolKey public poolKey;

    address public user = makeAddr('user');
    address public solver = makeAddr('solver');
    address public lp = makeAddr('liquidityProvider');

    uint256 constant INITIAL_USDC = 100_000e6;
    uint256 constant INITIAL_WETH = 50e18;

    function setUp() public {
        MockERC20 tokenA = new MockERC20('Token A', 'TKNA', 6);
        MockERC20 tokenB = new MockERC20('Token B', 'TKNB', 18);

        if (address(tokenA) < address(tokenB)) {
            usdc = tokenA;
            weth = tokenB;
        } else {
            usdc = tokenB;
            weth = tokenA;
        }

        poolManager = new PoolManager(address(0));

        _mockOraclePrice(2500e8);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddr = address(flags);

        deployCodeTo('GhostVaultHookV2.sol:GhostVaultHookV2', abi.encode(address(poolManager), ORACLE), hookAddr);
        hook = GhostVaultHookV2(hookAddr);

        vault = new TestVault(usdc);
        hook.setYieldConfig(address(usdc), address(vault));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc) < address(weth) ? address(usdc) : address(weth)),
            currency1: Currency.wrap(address(usdc) < address(weth) ? address(weth) : address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        uint160 initSqrtPrice = 79_228_162_514_264_337_593_543_950_336;
        poolManager.initialize(poolKey, initSqrtPrice);

        liquidityHelper = new LiquidityHelper(poolManager);
        swapHelper = new SwapHelper(poolManager);

        usdc.mint(lp, 10_000_000e6);
        weth.mint(lp, 10_000e18);

        vm.startPrank(lp);
        usdc.approve(address(liquidityHelper), type(uint256).max);
        weth.approve(address(liquidityHelper), type(uint256).max);
        liquidityHelper.addLiquidity(poolKey, 1_000_000e6, -887_220, 887_220);
        vm.stopPrank();

        usdc.mint(user, INITIAL_USDC);
        weth.mint(user, INITIAL_WETH);
    }

    // ─────────────────────────────────────────────────────────────
    //  V1 Tests (ported to V2)
    // ─────────────────────────────────────────────────────────────

    function test_YieldOrderExecution() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('mysecret');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        _mockOraclePrice(3000e8);
        usdc.mint(address(vault), 42_740_000);

        uint256 userWethBefore = weth.balanceOf(user);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 userWethAfter = weth.balanceOf(user);
        uint256 solverFee = usdc.balanceOf(solver);

        assertGt(userWethAfter, userWethBefore, 'User should have received WETH');
        assertGt(solverFee, 0, 'Solver should have received a fee');

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.EXECUTED));
    }

    function test_GhostOrderExecution() public {
        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800;
        bool zeroForOne = true;
        bytes32 salt = keccak256('ghostsecret');
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);

        vm.warp(block.timestamp + minDelay + 1);
        _mockOraclePrice(2500e8);
        usdc.mint(address(vault), 285_000);

        uint256 userWethBefore = weth.balanceOf(user);

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        assertGt(weth.balanceOf(user), userWethBefore, 'User should have received WETH');
    }

    function test_CancelOrderWithYield() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('cancel')));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.warp(block.timestamp + 14 days);
        usdc.mint(address(vault), 19_945_000);

        vm.prank(user);
        hook.cancelOrder(orderId);

        uint256 userBalanceAfter = usdc.balanceOf(user);
        assertGt(userBalanceAfter, userBalanceBefore + depositAmount, 'User should have earned yield');

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.CANCELLED));
    }

    function test_OracleRejectsStalePrice() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('oracle');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        hook.commitOrder(address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey);
        vm.stopPrank();

        vm.warp(10_000);
        _mockOracleStale(3000e8);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert();
        hook.executeOrder(0, reveal);
    }

    function test_CommitRevealRejectsWrongHash() public {
        uint256 depositAmount = 10_000e6;
        bytes32 realSalt = keccak256('real');
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, realSalt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        hook.commitOrder(address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey);
        vm.stopPrank();

        GhostVaultHookV2.RevealData memory fakeReveal =
            GhostVaultHookV2.RevealData({targetPrice: 3000e8, zeroForOne: true, salt: keccak256('fake')});

        _mockOraclePrice(3000e8);

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.HashMismatch.selector);
        hook.executeOrder(0, fakeReveal);
    }

    function test_OnlyOwnerCanCancel() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('safe')));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.NotOrderOwner.selector);
        hook.cancelOrder(orderId);
    }

    function test_PriceConditionNotMet() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('price');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        hook.commitOrder(address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, poolKey);
        vm.stopPrank();

        _mockOraclePrice(2500e8);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.PriceConditionNotMet.selector);
        hook.executeOrder(0, reveal);
    }

    function test_SlippageProtection() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('slippage');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));
        uint256 minAmountOut = 1_000e18;

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, minAmountOut, poolKey
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _mockOraclePrice(3000e8);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.SlippageExceeded.selector);
        hook.executeOrder(orderId, reveal);

        (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.ACTIVE));
    }

    // ─────────────────────────────────────────────────────────────
    //  V2 Test: tokenIn Validation
    // ─────────────────────────────────────────────────────────────

    function test_InvalidPoolReverts() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('invalid')));

        PoolKey memory fakeKey = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        vm.expectRevert(GhostVaultHookV2.InvalidPool.selector);
        hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.YIELD_ORDER, 0, 0, fakeKey
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    //  V2 Test: afterSwap Observation
    // ─────────────────────────────────────────────────────────────

    function test_AfterSwapEmitsEvent() public {
        address swapper = makeAddr('swapper');
        usdc.mint(swapper, 1_000e6);

        vm.startPrank(swapper);
        usdc.approve(address(swapHelper), type(uint256).max);

        vm.expectEmit(true, false, false, false, address(hook));
        emit GhostVaultHookV2.PoolSwapObserved(poolKey.toId(), true, 0, 0);

        swapHelper.swap(poolKey, true, -int256(100e6), swapper);
        vm.stopPrank();
    }

    function test_AfterSwapSilentOnExecution() public {
        uint256 depositAmount = 10_000e6;
        bool zeroForOne = true;
        bytes32 salt = keccak256('silenttest');
        bytes32 intentHash = keccak256(abi.encode(uint256(0), zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        _mockOraclePrice(2500e8);

        GhostVaultHookV2.RevealData memory reveal =
            GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: zeroForOne, salt: salt});

        vm.recordLogs();

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 observedTopic = keccak256('PoolSwapObserved(bytes32,bool,int128,int128)');
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != observedTopic, 'Should not emit PoolSwapObserved during execution');
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  V2 Test: Batch Execution
    // ─────────────────────────────────────────────────────────────

    function test_BatchExecution() public {
        uint256[] memory orderIds = new uint256[](3);
        uint256[3] memory amounts = [uint256(10_000e6), 20_000e6, 15_000e6];
        GhostVaultHookV2.RevealData[] memory reveals = new GhostVaultHookV2.RevealData[](3);

        for (uint256 i = 0; i < 3; i++) {
            bytes32 salt = keccak256(abi.encodePacked('batch', i));
            bytes32 intentHash = keccak256(abi.encode(uint256(0), true, salt));

            vm.startPrank(user);
            usdc.approve(address(hook), amounts[i]);
            orderIds[i] = hook.commitOrder(
                address(usdc), amounts[i], intentHash, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
            );
            vm.stopPrank();

            reveals[i] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: true, salt: salt});
        }

        vm.warp(block.timestamp + 2);
        _mockOraclePrice(2500e8);

        uint256 userWethBefore = weth.balanceOf(user);

        vm.prank(solver);
        hook.executeBatch(orderIds, reveals);

        uint256 userWethAfter = weth.balanceOf(user);
        assertGt(userWethAfter, userWethBefore, 'User should have received WETH from batch');

        for (uint256 i = 0; i < 3; i++) {
            (,, GhostVaultHookV2.OrderStatus status,,,,,,) = hook.getOrder(orderIds[i]);
            assertEq(uint8(status), uint8(GhostVaultHookV2.OrderStatus.EXECUTED));
        }
    }

    function test_BatchSlippageProtection() public {
        uint256[] memory orderIds = new uint256[](2);
        GhostVaultHookV2.RevealData[] memory reveals = new GhostVaultHookV2.RevealData[](2);

        bytes32 salt0 = keccak256('batchslip0');
        bytes32 hash0 = keccak256(abi.encode(uint256(0), true, salt0));
        vm.startPrank(user);
        usdc.approve(address(hook), 10_000e6);
        orderIds[0] = hook.commitOrder(
            address(usdc), 10_000e6, hash0, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
        );
        vm.stopPrank();
        reveals[0] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: true, salt: salt0});

        bytes32 salt1 = keccak256('batchslip1');
        bytes32 hash1 = keccak256(abi.encode(uint256(0), true, salt1));
        vm.startPrank(user);
        usdc.approve(address(hook), 10_000e6);
        orderIds[1] = hook.commitOrder(
            address(usdc), 10_000e6, hash1, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 1_000e18, poolKey
        );
        vm.stopPrank();
        reveals[1] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: true, salt: salt1});

        vm.warp(block.timestamp + 2);
        _mockOraclePrice(2500e8);

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.SlippageExceeded.selector);
        hook.executeBatch(orderIds, reveals);
    }

    function test_BatchPoolMismatch() public {
        bytes32 salt0 = keccak256('mismatch0');
        bytes32 hash0 = keccak256(abi.encode(uint256(0), true, salt0));

        vm.startPrank(user);
        usdc.approve(address(hook), 20_000e6);
        uint256 id0 = hook.commitOrder(
            address(usdc), 10_000e6, hash0, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, poolKey
        );

        PoolKey memory otherPoolKey = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(otherPoolKey, 79_228_162_514_264_337_593_543_950_336);

        bytes32 salt1 = keccak256('mismatch1');
        bytes32 hash1 = keccak256(abi.encode(uint256(0), true, salt1));
        uint256 id1 = hook.commitOrder(
            address(usdc), 10_000e6, hash1, GhostVaultHookV2.OrderType.GHOST_ORDER, 1, 0, otherPoolKey
        );
        vm.stopPrank();

        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = id0;
        orderIds[1] = id1;

        GhostVaultHookV2.RevealData[] memory reveals = new GhostVaultHookV2.RevealData[](2);
        reveals[0] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: true, salt: salt0});
        reveals[1] = GhostVaultHookV2.RevealData({targetPrice: 0, zeroForOne: true, salt: salt1});

        vm.warp(block.timestamp + 2);
        _mockOraclePrice(2500e8);

        vm.prank(solver);
        vm.expectRevert(GhostVaultHookV2.BatchPoolMismatch.selector);
        hook.executeBatch(orderIds, reveals);
    }

    // ─────────────────────────────────────────────────────────────
    //  Oracle Helpers
    // ─────────────────────────────────────────────────────────────

    function _mockOraclePrice(int256 price) internal {
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, uint256(0), block.timestamp, uint80(1))
        );
    }

    function _mockOracleStale(int256 price) internal {
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, uint256(0), block.timestamp - 7200, uint80(1))
        );
    }
}
