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
import {GhostVaultHook} from '../src/GhostVaultHook.sol';
import {LiquidityHelper} from './helpers/LiquidityHelper.sol';

import {
    POOLMANAGER_BASE_MAINNET,
    USDC_BASE_MAINNET,
    WETH_BASE_MAINNET,
    METAMORPHO_VAULT_BASE_MAINNET,
    ETH_USD_FEED_BASE_MAINNET
} from '../constants/Addresses.sol';

/// @title GhostVault Fork Tests
/// @dev Run with: forge test --match-path test/GhostVaultFork.t.sol --fork-url $BASE_MAINNET_RPC -vvv
contract GhostVaultForkTest is Test {
    IPoolManager constant POOL_MGR = IPoolManager(POOLMANAGER_BASE_MAINNET);

    GhostVaultHook public hook;
    LiquidityHelper public liquidityHelper;
    PoolKey public poolKey;

    address public user = makeAddr('forkUser');
    address public solver = makeAddr('forkSolver');
    address public lp = makeAddr('forkLP');

    uint160 constant INIT_SQRT_PRICE = uint160(4_339_505_179_874_779_508_375_552);

    function setUp() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddr = address(flags);
        deployCodeTo(
            'GhostVaultHook.sol:GhostVaultHook', abi.encode(POOLMANAGER_BASE_MAINNET, ETH_USD_FEED_BASE_MAINNET), hookAddr
        );
        hook = GhostVaultHook(hookAddr);
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

    function test_RealMetaMorphoDeposit() public {
        IERC4626 vault = IERC4626(METAMORPHO_VAULT_BASE_MAINNET);
        uint256 depositAmount = 10_000e6;

        deal(USDC_BASE_MAINNET, address(this), depositAmount);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, depositAmount);
        uint256 shares = vault.deposit(depositAmount, address(this));

        console2.log("Deposited %s USDC, got %s shares", depositAmount / 1e6, shares);
        assertGt(shares, 0);

        uint256 valueBefore = vault.convertToAssets(shares);
        vm.warp(block.timestamp + 7 days);
        uint256 valueAfter = vault.convertToAssets(shares);
        uint256 yieldEarned = valueAfter > depositAmount ? valueAfter - depositAmount : 0;

        console2.log("After 7 days: value=%s, yield=%s", valueAfter / 1e6, yieldEarned);
        assertApproxEqAbs(valueAfter, depositAmount, 1);
    }

    function test_RealChainlinkFeed() public view {
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET);
        (, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
        uint8 dec = feed.decimals();

        console2.log("ETH/USD: $%s (decimals=%s)", uint256(price) / (10 ** dec), dec);
        assertEq(dec, 8);
        assertGt(price, 0);
        assertGt(uint256(price), 1000e8);
        assertLt(uint256(price), 10_000e8);
    }

    function test_ForkYieldOrderLifecycle() public {
        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();
        uint256 currentEthPrice = uint256(ethPrice);

        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = currentEthPrice + 100e8;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkYieldSecret');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log("Committed %s USDC, ETH=$%s, target=$%s", depositAmount / 1e6, currentEthPrice / 1e8, targetPrice / 1e8);

        vm.warp(block.timestamp + 30 days);
        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log("After 30 days: value=%s, yield=%s", valueAfter / 1e6, yieldAccrued);

        _mockChainlinkPrice(int256(currentEthPrice));
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(user);
        GhostVaultHook.RevealData memory reveal = GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(user) - userWethBefore;
        uint256 solverFee = IERC20(USDC_BASE_MAINNET).balanceOf(solver);
        console2.log("Executed: WETH=%s, solverFee=%s", wethReceived, solverFee);

        assertGt(wethReceived, 0);
        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.EXECUTED));
    }

    function test_ForkGhostOrderExecution() public {
        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkGhostSecret');
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHook.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        console2.log("Committed %s USDC with %ss delay", depositAmount / 1e6, minDelay);

        GhostVaultHook.RevealData memory reveal = GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log("Early execution blocked");

        vm.warp(block.timestamp + minDelay + 1);
        _mockChainlinkFresh();
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_BASE_MAINNET).balanceOf(user);
        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_BASE_MAINNET).balanceOf(user) - userWethBefore;
        console2.log("Executed after delay: WETH=%s", wethReceived);
        assertGt(wethReceived, 0);
    }

    function test_ForkCancelWithRealYield() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(5000e8), false, keccak256('forkCancel')));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        uint256 userBalanceBefore = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        console2.log("Deposited %s USDC", depositAmount / 1e6);

        vm.warp(block.timestamp + 14 days);
        (uint256 currentValue, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log("After 14 days: value=%s, yield=%s", currentValue / 1e6, yieldAccrued);

        vm.prank(user);
        hook.cancelOrder(orderId);

        uint256 userBalanceAfter = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        uint256 totalReturned = userBalanceAfter - userBalanceBefore;
        console2.log("Cancelled: returned=%s USDC", totalReturned / 1e6);

        assertApproxEqAbs(totalReturned, depositAmount, 1);
        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.CANCELLED));
    }

    function test_ForkOracleProtection() public {
        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET).latestRoundData();

        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = uint256(ethPrice) + 100e8;
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkOracleTest');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log("Committed %s USDC, ETH=$%s", depositAmount / 1e6, uint256(ethPrice) / 1e8);

        vm.warp(block.timestamp + 2 hours);

        GhostVaultHook.RevealData memory reveal = GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert();
        hook.executeOrder(orderId, reveal);

        console2.log("Blocked: oracle stale after 2 hours");
        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.ACTIVE));
    }
}
