// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';
import {MockERC20} from 'solmate/src/test/utils/mocks/MockERC20.sol';
import {GhostVaultHook} from '../src/GhostVaultHook.sol';
import {TestVault} from './helpers/TestVault.sol';
import {LiquidityHelper} from './helpers/LiquidityHelper.sol';
import {SwapHelper} from './helpers/SwapHelper.sol';

/// @title GhostVaultHook Test Suite
/// @notice Integration tests covering the full order lifecycle, privacy features,
///         oracle safety, and access control for the GhostVault hook.
/// @dev Uses local mock contracts (no fork needed). Each test doubles as a demo scenario
///      with console2 output for the hackathon presentation.
///
///      Token ordering: USDC = currency0 (lower address), WETH = currency1 (higher address).
///      Therefore `zeroForOne = true` means selling USDC (currency0) for WETH (currency1).
///      The Chainlink oracle returns ETH/USD price; the price condition for zeroForOne = true
///      triggers when the current price >= target price.
contract GhostVaultHookTest is Test {
    GhostVaultHook public hook;
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

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddr = address(flags);

        deployCodeTo('GhostVaultHook.sol:GhostVaultHook', abi.encode(address(poolManager), ORACLE), hookAddr);
        hook = GhostVaultHook(hookAddr);

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
    //  Test 1: YieldOrder Full Lifecycle
    // ─────────────────────────────────────────────────────────────

    function test_YieldOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 1: YieldOrder Full Lifecycle');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('mysecret');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        (uint256 valueBefore,) = hook.getOrderValue(orderId);
        console2.log('  Committed:          %s USDC', depositAmount / 1e6);
        console2.log('  Vault shares value: %s USDC', valueBefore / 1e6);
        console2.log('  Target:             ETH >= $3,000');

        vm.warp(block.timestamp + 30 days);
        _mockOraclePrice(3000e8);

        uint256 simulatedYield = 42_740_000;
        usdc.mint(address(vault), simulatedYield);

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 30 days:');
        console2.log('  Vault shares value: %s USDC', valueAfter / 1e6);
        console2.log('  Yield accrued:      $%s.%s', yieldAccrued / 1e6, (yieldAccrued % 1e6) / 1e4);

        uint256 userWethBefore = weth.balanceOf(user);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 userWethAfter = weth.balanceOf(user);
        uint256 solverFee = usdc.balanceOf(solver);

        console2.log('');
        console2.log('  Execution Results:');
        console2.log('  WETH received by user: %s', userWethAfter - userWethBefore);
        console2.log('  Solver fee earned:     $%s.%s', solverFee / 1e6, (solverFee % 1e6) / 1e4);
        console2.log('  Standard limit order yield: $0.00');
        console2.log('====================================================');
        console2.log('');

        assertGt(userWethAfter, userWethBefore, 'User should have received WETH');
        assertGt(solverFee, 0, 'Solver should have received a fee');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.EXECUTED));
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: GhostOrder Privacy Execution
    // ─────────────────────────────────────────────────────────────

    function test_GhostOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 2: GhostOrder Privacy Execution');
        console2.log('====================================================');

        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800;
        bool zeroForOne = true;
        bytes32 salt = keccak256('ghostsecret');
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:     %s USDC (hidden from pool)', depositAmount / 1e6);
        console2.log('  Min delay:     %s seconds', minDelay);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log('  Early execution blocked (DelayNotElapsed)');

        vm.warp(block.timestamp + minDelay + 1);
        _mockOraclePrice(2500e8);
        usdc.mint(address(vault), 285_000);

        uint256 userWethBefore = weth.balanceOf(user);

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 userWethAfter = weth.balanceOf(user);

        console2.log('');
        console2.log('  Execution Results:');
        console2.log('  Delay elapsed:      31 min');
        console2.log('  WETH received:      %s', userWethAfter - userWethBefore);
        console2.log('  MEV exposure:       NONE (funds were in Morpho, not pool)');
        console2.log('====================================================');
        console2.log('');

        assertGt(userWethAfter, userWethBefore, 'User should have received WETH');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 3: Safe Cancellation with Yield
    // ─────────────────────────────────────────────────────────────

    function test_CancelOrderWithYield() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 3: Safe Cancellation (Principal + Yield)');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('cancel')));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        uint256 userBalanceBefore = usdc.balanceOf(user);
        console2.log('  Deposited:      %s USDC', depositAmount / 1e6);
        console2.log('  User USDC after deposit: %s', userBalanceBefore / 1e6);

        vm.warp(block.timestamp + 14 days);
        uint256 simulatedYield = 19_945_000;
        usdc.mint(address(vault), simulatedYield);

        (uint256 currentValue, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 14 days:');
        console2.log('  Current value:  $%s.%s', currentValue / 1e6, (currentValue % 1e6) / 1e4);
        console2.log('  Yield accrued:  $%s.%s', yieldAccrued / 1e6, (yieldAccrued % 1e6) / 1e4);

        vm.prank(user);
        hook.cancelOrder(orderId);

        uint256 userBalanceAfter = usdc.balanceOf(user);
        uint256 totalReturned = userBalanceAfter - userBalanceBefore;

        console2.log('');
        console2.log('  Cancellation Results:');
        console2.log('  Principal returned: $%s', depositAmount / 1e6);
        console2.log(
            '  Yield kept:         $%s.%s',
            (totalReturned - depositAmount) / 1e6,
            ((totalReturned - depositAmount) % 1e6) / 1e4
        );
        console2.log('  Total received:     $%s.%s', totalReturned / 1e6, (totalReturned % 1e6) / 1e4);
        console2.log('====================================================');
        console2.log('');

        assertGt(userBalanceAfter, userBalanceBefore + depositAmount, 'User should have earned yield');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.CANCELLED));
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 4: Oracle Rejects Stale Price
    // ─────────────────────────────────────────────────────────────

    function test_OracleRejectsStalePrice() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 4: Oracle Safety - Stale Price Rejection');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('oracle');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        vm.warp(10_000);
        _mockOracleStale(3000e8);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        console2.log('  Order committed: 10,000 USDC');
        console2.log('  Oracle price:    $3,000 (STALE - 2 hours old)');
        console2.log('  Attempting execution...');

        vm.prank(solver);
        vm.expectRevert();
        hook.executeOrder(orderId, reveal);

        console2.log('  BLOCKED: Oracle price is stale (>1 hour old)');
        console2.log('  User funds remain safe in vault');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.ACTIVE));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 5: Commit-Reveal Hash Verification
    // ─────────────────────────────────────────────────────────────

    function test_CommitRevealRejectsWrongHash() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 5: Commit-Reveal - Wrong Hash Rejected');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        bytes32 realSalt = keccak256('real');
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, realSalt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        GhostVaultHook.RevealData memory fakeReveal =
            GhostVaultHook.RevealData({targetPrice: 3000e8, zeroForOne: true, salt: keccak256('fake')});

        _mockOraclePrice(3000e8);

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.HashMismatch.selector);
        hook.executeOrder(orderId, fakeReveal);

        console2.log('  Order committed with hidden intent');
        console2.log('  Attacker tried to reveal with fake data');
        console2.log('  BLOCKED: HashMismatch - intent tampered');
        console2.log('  User funds remain safe in vault');
        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 6: Only Owner Can Cancel
    // ─────────────────────────────────────────────────────────────

    function test_OnlyOwnerCanCancel() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('safe')));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.NotOrderOwner.selector);
        hook.cancelOrder(orderId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 7: Price Condition Not Met
    // ─────────────────────────────────────────────────────────────

    function test_PriceConditionNotMet() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('price');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        hook.commitOrder(address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey);
        vm.stopPrank();

        _mockOraclePrice(2500e8);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.PriceConditionNotMet.selector);
        hook.executeOrder(0, reveal);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 8: Slippage Protection
    // ─────────────────────────────────────────────────────────────

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
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, minAmountOut, poolKey
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _mockOraclePrice(3000e8);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.SlippageExceeded.selector);
        hook.executeOrder(orderId, reveal);

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.ACTIVE));
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
