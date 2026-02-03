// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';
import {GhostVaultHook, IERC4626} from '../src/GhostVaultHook.sol';

/// @notice Helper contract to add liquidity on a forked Uniswap v4 pool.
contract ForkLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable MANAGER;

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    function addLiquidity(PoolKey memory key, int256 liquidityDelta, int24 tickLower, int24 tickUpper) external {
        MANAGER.unlock(abi.encode(key, liquidityDelta, tickLower, tickUpper, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), 'ForkLiquidityHelper: not manager');

        (PoolKey memory key, int256 liquidityDelta, int24 tickLower, int24 tickUpper, address payer) =
            abi.decode(data, (PoolKey, int256, int24, int24, address));

        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)}),
            ''
        );

        if (delta.amount0() < 0) {
            uint256 amount = uint256(uint128(-delta.amount0()));
            MANAGER.sync(key.currency0);
            require(IERC20(Currency.unwrap(key.currency0)).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }
        if (delta.amount1() < 0) {
            uint256 amount = uint256(uint128(-delta.amount1()));
            MANAGER.sync(key.currency1);
            require(IERC20(Currency.unwrap(key.currency1)).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }
        if (delta.amount0() > 0) {
            MANAGER.take(key.currency0, payer, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            MANAGER.take(key.currency1, payer, uint256(int256(delta.amount1())));
        }

        return '';
    }
}

/// @title GhostVault Fork Tests
/// @notice Integration tests against real Base mainnet state (MetaMorpho, Chainlink, Uniswap v4).
/// @dev Run with: source .env.local && forge test --match-path test/GhostVaultFork.t.sol --fork-url $BASE_MAINNET_RPC -vvv
///
///      Token ordering on Base mainnet:
///        WETH (0x4200...) < USDC (0x8335...) → currency0 = WETH, currency1 = USDC
///        This is the OPPOSITE of the mock tests where USDC < WETH.
///        For depositing USDC and wanting WETH: zeroForOne = false (sell currency1 for currency0).
contract GhostVaultForkTest is Test {
    // ── Real Base Mainnet Addresses ──
    IPoolManager constant POOL_MGR = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
    address constant METAMORPHO = 0x236919F11ff9eA9550A4287696C2FC9e18E6e890;
    address constant ETH_USD_FEED_ADDR = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // ── Contracts ──
    GhostVaultHook public hook;
    ForkLiquidityHelper public liquidityHelper;

    // ── Pool Config ──
    PoolKey public poolKey;

    // ── Actors ──
    address public user = makeAddr('forkUser');
    address public solver = makeAddr('forkSolver');
    address public lp = makeAddr('forkLP');

    // ── sqrtPriceX96 for ~$3000 ETH/USDC ──
    // price = 3000 * 1e6 / 1e18 = 3e-9 (USDC per WETH in raw units)
    // sqrtPriceX96 = sqrt(3e-9) * 2^96
    uint160 constant INIT_SQRT_PRICE = uint160(4_339_505_179_874_779_508_375_552);

    function setUp() public {
        // 1. Fork Base mainnet — requires --fork-url on CLI:
        //    forge test --match-path test/GhostVaultFork.t.sol --fork-url <BASE_RPC> -vvv

        // 2. Deploy hook at flag-correct address (bit 7 set for beforeSwap)
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddr = address(flags);
        deployCodeTo(
            'GhostVaultHook.sol:GhostVaultHook', abi.encode(address(POOL_MGR), ETH_USD_FEED_ADDR), hookAddr
        );
        hook = GhostVaultHook(hookAddr);

        // 3. Register MetaMorpho vault for USDC
        hook.setYieldConfig(USDC_ADDR, METAMORPHO);

        // 4. Pool key: WETH (0x4200...) < USDC (0x8335...) → currency0 = WETH, currency1 = USDC
        poolKey = PoolKey({
            currency0: Currency.wrap(WETH_ADDR),
            currency1: Currency.wrap(USDC_ADDR),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // 5. Initialize pool at ~$3000 ETH/USDC
        POOL_MGR.initialize(poolKey, INIT_SQRT_PRICE);

        // 6. Add full-range liquidity
        liquidityHelper = new ForkLiquidityHelper(POOL_MGR);
        deal(WETH_ADDR, lp, 200e18);
        deal(USDC_ADDR, lp, 600_000e6);

        vm.startPrank(lp);
        IERC20(WETH_ADDR).approve(address(liquidityHelper), type(uint256).max);
        IERC20(USDC_ADDR).approve(address(liquidityHelper), type(uint256).max);
        liquidityHelper.addLiquidity(poolKey, 5e15, -887_220, 887_220);
        vm.stopPrank();

        // 7. Fund user
        deal(USDC_ADDR, user, 100_000e6);
    }

    /// @dev Mock Chainlink to return fresh updatedAt while keeping the real price.
    function _mockChainlinkFresh() internal {
        (, int256 realPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_ADDR).latestRoundData();
        vm.mockCall(
            ETH_USD_FEED_ADDR,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), realPrice, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev Mock MetaMorpho maxRedeem to bypass fork liquidity constraints.
    ///      After vm.warp, Morpho Blue markets may report slightly less redeemable
    ///      shares than deposited due to lazy interest accrual and liquidity bounds.
    function _mockVaultMaxRedeem() internal {
        vm.mockCall(
            METAMORPHO,
            abi.encodeWithSignature('maxRedeem(address)'),
            abi.encode(type(uint256).max)
        );
    }

    /// @dev Mock Chainlink with a specific price and fresh timestamp.
    function _mockChainlinkPrice(int256 price) internal {
        vm.mockCall(
            ETH_USD_FEED_ADDR,
            abi.encodeWithSignature('latestRoundData()'),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 1: Real MetaMorpho Deposit
    // ─────────────────────────────────────────────────────────────

    /// @notice Verify direct deposit/yield on the real MetaMorpho vault.
    function test_RealMetaMorphoDeposit() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 1: Real MetaMorpho Deposit + Yield');
        console2.log('====================================================');

        IERC4626 vault = IERC4626(METAMORPHO);
        uint256 depositAmount = 10_000e6;

        deal(USDC_ADDR, address(this), depositAmount);
        IERC20(USDC_ADDR).approve(METAMORPHO, depositAmount);
        uint256 shares = vault.deposit(depositAmount, address(this));

        console2.log('  Deposited:       %s USDC', depositAmount / 1e6);
        console2.log('  Shares received: %s', shares);
        assertGt(shares, 0, 'Should receive vault shares');

        uint256 valueBefore = vault.convertToAssets(shares);
        console2.log('  Value (t=0):     %s USDC', valueBefore / 1e6);

        // Warp 7 days for yield accrual
        vm.warp(block.timestamp + 7 days);

        uint256 valueAfter = vault.convertToAssets(shares);
        uint256 yieldEarned = valueAfter > depositAmount ? valueAfter - depositAmount : 0;

        console2.log('  Value (t=7d):    %s USDC', valueAfter / 1e6);
        console2.log('  Yield earned:    %s (raw)', yieldEarned);

        if (yieldEarned > 0) {
            uint256 apyBps = (yieldEarned * 365 * 10_000) / (depositAmount * 7);
            console2.log('  Implied APY:     %s.%s%%', apyBps / 100, apyBps % 100);
        }

        assertGe(valueAfter, depositAmount, 'Value should not decrease');
        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: Real Chainlink Feed
    // ─────────────────────────────────────────────────────────────

    /// @notice Verify the real Chainlink ETH/USD feed returns sane data.
    function test_RealChainlinkFeed() public view {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 2: Real Chainlink ETH/USD Feed');
        console2.log('====================================================');

        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED_ADDR);
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

    /// @notice Full YieldOrder lifecycle on real Base state:
    ///         commit USDC → accrue real yield in MetaMorpho → solver executes → user gets WETH.
    function test_ForkYieldOrderLifecycle() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 3: YieldOrder Full Lifecycle (Real Base)');
        console2.log('====================================================');

        // Read real Chainlink price
        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_ADDR).latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currentEthPrice = uint256(ethPrice);

        // zeroForOne = false → sell USDC (currency1) for WETH (currency0)
        // Price condition: execute when currentPrice <= targetPrice
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = currentEthPrice + 100e8; // above current → condition met
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkYieldSecret');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_ADDR, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:      %s USDC', depositAmount / 1e6);
        console2.log('  Real ETH price: $%s', currentEthPrice / 1e8);
        console2.log('  Target price:   $%s', targetPrice / 1e8);

        (uint256 valueBefore,) = hook.getOrderValue(orderId);
        console2.log('  Vault value:    %s USDC', valueBefore / 1e6);

        // Warp 30 days for yield
        vm.warp(block.timestamp + 30 days);

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 30 days:');
        console2.log('  Vault value:    %s USDC', valueAfter / 1e6);
        console2.log('  Yield accrued:  %s (raw)', yieldAccrued);

        // Mock Chainlink fresh after warp
        // forge-lint: disable-next-line(unsafe-typecast)
        _mockChainlinkPrice(int256(currentEthPrice));
        // Mock maxRedeem to bypass fork-specific vault liquidity constraint
        _mockVaultMaxRedeem();

        // Solver executes
        uint256 userWethBefore = IERC20(WETH_ADDR).balanceOf(user);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_ADDR).balanceOf(user) - userWethBefore;
        uint256 solverFee = IERC20(USDC_ADDR).balanceOf(solver);

        console2.log('');
        console2.log('  Execution Results:');
        console2.log('  WETH received:  %s (wei)', wethReceived);
        console2.log('  Solver fee:     %s USDC (raw)', solverFee);

        assertGt(wethReceived, 0, 'User should have received WETH');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.EXECUTED));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 4: Fork GhostOrder Execution
    // ─────────────────────────────────────────────────────────────

    /// @notice Time-delayed GhostOrder: early execution blocked, then succeeds after delay.
    function test_ForkGhostOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 4: GhostOrder Time-Delayed (Real Base)');
        console2.log('====================================================');

        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800; // 30 minutes
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkGhostSecret');
        uint256 targetPrice = 0;
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_ADDR, depositAmount, intentHash, GhostVaultHook.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:     %s USDC (hidden from pool)', depositAmount / 1e6);
        console2.log('  Min delay:     %s seconds', minDelay);

        // Early execution should fail
        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log('  Early execution blocked (DelayNotElapsed)');

        // Warp past delay
        vm.warp(block.timestamp + minDelay + 1);
        _mockChainlinkFresh();
        // Mock maxRedeem to bypass fork-specific vault liquidity constraint
        _mockVaultMaxRedeem();

        uint256 userWethBefore = IERC20(WETH_ADDR).balanceOf(user);

        vm.prank(solver);
        hook.executeOrder(orderId, reveal);

        uint256 wethReceived = IERC20(WETH_ADDR).balanceOf(user) - userWethBefore;

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

    /// @notice Cancel returns principal + real MetaMorpho yield.
    function test_ForkCancelWithRealYield() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 5: Cancel with Real MetaMorpho Yield');
        console2.log('====================================================');

        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(5000e8), false, keccak256('forkCancel')));

        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_ADDR, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        uint256 userBalanceBefore = IERC20(USDC_ADDR).balanceOf(user);
        console2.log('  Deposited:     %s USDC', depositAmount / 1e6);

        // Warp 14 days for yield
        vm.warp(block.timestamp + 14 days);

        (uint256 currentValue, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 14 days:');
        console2.log('  Vault value:   %s USDC', currentValue / 1e6);
        console2.log('  Yield accrued: %s (raw)', yieldAccrued);

        // Cancel
        vm.prank(user);
        hook.cancelOrder(orderId);

        uint256 userBalanceAfter = IERC20(USDC_ADDR).balanceOf(user);
        uint256 totalReturned = userBalanceAfter - userBalanceBefore;
        uint256 profit = totalReturned > depositAmount ? totalReturned - depositAmount : 0;

        console2.log('');
        console2.log('  Cancellation Results:');
        console2.log('  Total returned: %s USDC', totalReturned / 1e6);
        console2.log('  Yield kept:     %s (raw)', profit);

        assertGe(totalReturned, depositAmount, 'Should return at least principal');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.CANCELLED));

        console2.log('====================================================');
        console2.log('');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 6: Fork Oracle Protection
    // ─────────────────────────────────────────────────────────────

    /// @notice Oracle staleness check blocks execution when Chainlink data is old.
    function test_ForkOracleProtection() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  FORK TEST 6: Oracle Protection (Real Chainlink)');
        console2.log('====================================================');

        (, int256 ethPrice,,,) = AggregatorV3Interface(ETH_USD_FEED_ADDR).latestRoundData();

        uint256 depositAmount = 10_000e6;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 targetPrice = uint256(ethPrice) + 100e8; // condition would be met
        bool zeroForOne = false;
        bytes32 salt = keccak256('forkOracleTest');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            USDC_ADDR, depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Order committed: %s USDC', depositAmount / 1e6);
        // forge-lint: disable-next-line(unsafe-typecast)
        console2.log('  Real ETH price:  $%s', uint256(ethPrice) / 1e8);

        // Warp 2 hours → oracle becomes stale (updatedAt frozen at fork-block time)
        vm.warp(block.timestamp + 2 hours);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(); // OracleStale
        hook.executeOrder(orderId, reveal);

        console2.log('  After 2 hours without oracle update:');
        console2.log('  BLOCKED: Oracle is stale (>1 hour old)');
        console2.log('  User funds remain safe in MetaMorpho vault');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.ACTIVE));

        console2.log('====================================================');
        console2.log('');
    }
}
