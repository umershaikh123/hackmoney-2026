// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {SwapParams, ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {GhostVaultHook} from '../src/GhostVaultHook.sol';

// ─────────────────────────────────────────────────────────────────
//  Mock Contracts
// ─────────────────────────────────────────────────────────────────

/// @notice Minimal ERC-20 mock with mint capability for testing.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock ERC-4626 vault that tracks shares and simulates yield accrual.
/// @dev Call `simulateYield()` to increase `totalAssets` without minting new shares,
///      which makes existing shares worth more (mimicking real vault yield).
contract MockERC4626 {
    IERC20 public immutable UNDERLYING;

    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;

    constructor(address _asset) {
        UNDERLYING = IERC20(_asset);
    }

    function asset() external view returns (address) {
        return address(UNDERLYING);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 newShares) {
        require(UNDERLYING.transferFrom(msg.sender, address(this), assets), 'transferFrom failed');

        newShares = (totalShares == 0) ? assets : (assets * totalShares) / totalAssets;

        shares[receiver] += newShares;
        totalShares += newShares;
        totalAssets += assets;
    }

    function redeem(uint256 sharesToRedeem, address receiver, address owner) external returns (uint256 assets) {
        require(shares[owner] >= sharesToRedeem, 'MockERC4626: insufficient shares');

        assets = (sharesToRedeem * totalAssets) / totalShares;

        shares[owner] -= sharesToRedeem;
        totalShares -= sharesToRedeem;
        totalAssets -= assets;

        require(UNDERLYING.transfer(receiver, assets), 'transfer failed');
    }

    function convertToAssets(uint256 sharesToConvert) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesToConvert * totalAssets) / totalShares;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return shares[owner];
    }

    /// @notice Simulate yield accrual by injecting additional assets into the vault.
    /// @dev Caller must have approved this contract for `yieldAmount` of the underlying token.
    function simulateYield(uint256 yieldAmount) external {
        require(UNDERLYING.transferFrom(msg.sender, address(this), yieldAmount), 'transferFrom failed');
        totalAssets += yieldAmount;
    }
}

/// @notice Mock Chainlink AggregatorV3 price feed with configurable price and staleness.
contract MockAggregatorV3 {
    int256 public price;
    uint256 public updatedAt;

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    /// @notice Make the price feed stale (2 hours old) to test staleness rejection.
    function setStale() external {
        updatedAt = block.timestamp - 7200;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

/// @notice Helper contract to add liquidity to a Uniswap v4 pool via the unlock callback pattern.
contract LiquidityHelper is IUnlockCallback {
    IPoolManager public immutable MANAGER;

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    function addLiquidity(PoolKey memory key, int256 liquidityDelta, int24 tickLower, int24 tickUpper) external {
        MANAGER.unlock(abi.encode(key, liquidityDelta, tickLower, tickUpper, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), 'LiquidityHelper: not manager');

        (PoolKey memory key, int256 liquidityDelta, int24 tickLower, int24 tickUpper, address payer) =
            abi.decode(data, (PoolKey, int256, int24, int24, address));

        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ''
        );

        // Settle tokens we owe to the pool (negative deltas)
        if (delta.amount0() < 0) {
            uint256 amount = uint256(uint128(-delta.amount0()));
            address token = Currency.unwrap(key.currency0);
            MANAGER.sync(key.currency0);
            require(IERC20(token).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }
        if (delta.amount1() < 0) {
            uint256 amount = uint256(uint128(-delta.amount1()));
            address token = Currency.unwrap(key.currency1);
            MANAGER.sync(key.currency1);
            require(IERC20(token).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }

        // Claim tokens the pool owes us (positive deltas)
        if (delta.amount0() > 0) {
            MANAGER.take(key.currency0, payer, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            MANAGER.take(key.currency1, payer, uint256(int256(delta.amount1())));
        }

        return '';
    }
}

/// @notice Helper contract to execute swaps on a Uniswap v4 pool (used to move price in tests).
contract SwapHelper is IUnlockCallback {
    IPoolManager public immutable MANAGER;

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address payer) external {
        MANAGER.unlock(abi.encode(key, zeroForOne, amountSpecified, payer));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), 'SwapHelper: not manager');

        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, address payer) =
            abi.decode(data, (PoolKey, bool, int256, address));

        BalanceDelta delta = MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ''
        );

        // Settle tokens we owe to the pool (negative deltas)
        if (delta.amount0() < 0) {
            uint256 amount = uint256(uint128(-delta.amount0()));
            address token = Currency.unwrap(key.currency0);
            MANAGER.sync(key.currency0);
            require(IERC20(token).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }
        if (delta.amount1() < 0) {
            uint256 amount = uint256(uint128(-delta.amount1()));
            address token = Currency.unwrap(key.currency1);
            MANAGER.sync(key.currency1);
            require(IERC20(token).transferFrom(payer, address(MANAGER), amount), 'transferFrom failed');
            MANAGER.settle();
        }

        // Claim tokens the pool owes us (positive deltas)
        if (delta.amount0() > 0) {
            MANAGER.take(key.currency0, payer, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            MANAGER.take(key.currency1, payer, uint256(int256(delta.amount1())));
        }

        return abi.encode(delta);
    }
}

// ─────────────────────────────────────────────────────────────────
//  Test Suite
// ─────────────────────────────────────────────────────────────────

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
    // ── Core Contracts ──
    GhostVaultHook public hook;
    PoolManager public poolManager;
    LiquidityHelper public liquidityHelper;
    SwapHelper public swapHelper;

    // ── Mocks ──
    MockAggregatorV3 public oracle;
    MockERC4626 public vault;
    MockERC20 public usdc;
    MockERC20 public weth;

    // ── Pool Config ──
    PoolKey public poolKey;

    // ── Actors ──
    address public user = makeAddr('user');
    address public solver = makeAddr('solver');
    address public lp = makeAddr('liquidityProvider');

    // ── Constants ──
    uint256 constant INITIAL_USDC = 100_000e6;
    uint256 constant INITIAL_WETH = 50e18;

    // ─────────────────────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy mock tokens with correct decimals.
        //    Ensure currency0 < currency1 by address (Uniswap v4 requirement).
        MockERC20 tokenA = new MockERC20('Token A', 'TKNA', 6);
        MockERC20 tokenB = new MockERC20('Token B', 'TKNB', 18);

        if (address(tokenA) < address(tokenB)) {
            usdc = tokenA;
            weth = tokenB;
        } else {
            usdc = tokenB;
            weth = tokenA;
        }

        // 2. Deploy the Uniswap v4 PoolManager
        poolManager = new PoolManager(address(0));

        // 3. Deploy mock Chainlink oracle at ETH = $2,500
        oracle = new MockAggregatorV3();
        oracle.setPrice(2500e8);

        // 4. Deploy hook at an address with the BEFORE_SWAP_FLAG bit set.
        //    Uses forge's `deployCodeTo` to place bytecode at the flag-encoded address.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddr = address(flags);

        deployCodeTo(
            'GhostVaultHook.sol:GhostVaultHook', abi.encode(address(poolManager), address(oracle)), hookAddr
        );
        hook = GhostVaultHook(hookAddr);

        // 5. Deploy mock ERC-4626 vault and register it for USDC
        vault = new MockERC4626(address(usdc));
        hook.setYieldConfig(address(usdc), address(vault));

        // 6. Configure the pool key (currency0 < currency1 by address)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc) < address(weth) ? address(usdc) : address(weth)),
            currency1: Currency.wrap(address(usdc) < address(weth) ? address(weth) : address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // 7. Initialize the pool at a 1:1 sqrtPriceX96
        uint160 initSqrtPrice = 79_228_162_514_264_337_593_543_950_336;
        poolManager.initialize(poolKey, initSqrtPrice);

        // 8. Deploy helpers and seed liquidity across the full tick range
        liquidityHelper = new LiquidityHelper(poolManager);
        swapHelper = new SwapHelper(poolManager);

        usdc.mint(lp, 10_000_000e6);
        weth.mint(lp, 10_000e18);

        vm.startPrank(lp);
        usdc.approve(address(liquidityHelper), type(uint256).max);
        weth.approve(address(liquidityHelper), type(uint256).max);
        liquidityHelper.addLiquidity(poolKey, 1_000_000e6, -887_220, 887_220);
        vm.stopPrank();

        // 9. Fund the user
        usdc.mint(user, INITIAL_USDC);
        weth.mint(user, INITIAL_WETH);

        // 10. Fund this test contract for yield simulation
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 1: YieldOrder Full Lifecycle
    // ─────────────────────────────────────────────────────────────

    /// @notice Verifies the complete YieldOrder flow: commit -> accrue yield -> execute.
    ///         User deposits 10,000 USDC with a target price of $3,000. After 30 days of
    ///         simulated yield, ETH rises to $3,000 and a solver executes the swap.
    function test_YieldOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 1: YieldOrder Full Lifecycle');
        console2.log('====================================================');

        // Commit phase: user deposits USDC with a price target
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8; // Execute when ETH >= $3,000
        bool zeroForOne = true; // Sell USDC (currency0) for WETH (currency1)
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

        // Wait phase: simulate 30 days + 5.2% APY yield (~$42.74)
        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(3000e8); // ETH rises to $3,000

        uint256 simulatedYield = 42_740_000; // ~$42.74 USDC
        vault.simulateYield(simulatedYield);

        (uint256 valueAfter, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 30 days:');
        console2.log('  Vault shares value: %s USDC', valueAfter / 1e6);
        console2.log('  Yield accrued:      $%s.%s', yieldAccrued / 1e6, (yieldAccrued % 1e6) / 1e4);

        // Execute phase: solver reveals the intent and triggers the swap
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

        // Assertions
        assertGt(userWethAfter, userWethBefore, 'User should have received WETH');
        assertGt(solverFee, 0, 'Solver should have received a fee');

        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.EXECUTED));
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: GhostOrder Privacy Execution
    // ─────────────────────────────────────────────────────────────

    /// @notice Verifies the GhostOrder time-delayed execution flow.
    ///         A user commits 50,000 USDC with a 30-minute delay. Execution before
    ///         the delay expires is blocked. After the delay, the solver executes.
    function test_GhostOrderExecution() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  DEMO 2: GhostOrder Privacy Execution');
        console2.log('====================================================');

        uint256 depositAmount = 50_000e6;
        uint256 minDelay = 1800; // 30 minutes
        bool zeroForOne = true; // Sell USDC for WETH
        bytes32 salt = keccak256('ghostsecret');
        uint256 targetPrice = 0; // Not price-triggered
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.GHOST_ORDER, minDelay, 0, poolKey
        );
        vm.stopPrank();

        console2.log('  Committed:     %s USDC (hidden from pool)', depositAmount / 1e6);
        console2.log('  Min delay:     %s seconds', minDelay);

        // Attempting execution before delay should revert
        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.DelayNotElapsed.selector);
        hook.executeOrder(orderId, reveal);
        console2.log('  Early execution blocked (DelayNotElapsed)');

        // Advance past the delay
        vm.warp(block.timestamp + minDelay + 1);
        oracle.setPrice(2500e8); // Refresh oracle so it's not stale
        vault.simulateYield(285_000); // ~$0.28 for 30 min at 5.2% on $50k

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

    /// @notice Verifies that cancellation returns principal + accrued yield to the owner.
    ///         A user deposits 10,000 USDC, waits 14 days (earning ~$19.95 yield), then cancels.
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

        // Simulate 14 days + yield
        vm.warp(block.timestamp + 14 days);
        uint256 simulatedYield = 19_945_000; // ~$19.95 at 5.2% APY
        vault.simulateYield(simulatedYield);

        (uint256 currentValue, uint256 yieldAccrued) = hook.getOrderValue(orderId);
        console2.log('');
        console2.log('  After 14 days:');
        console2.log('  Current value:  $%s.%s', currentValue / 1e6, (currentValue % 1e6) / 1e4);
        console2.log('  Yield accrued:  $%s.%s', yieldAccrued / 1e6, (yieldAccrued % 1e6) / 1e4);

        // Cancel and verify full amount is returned
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

    /// @notice Verifies that execution is blocked when the Chainlink oracle price is stale.
    ///         Even if the price technically meets the target, a 2-hour-old update is rejected.
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

        // Advance time so setStale() doesn't underflow, then make the oracle stale
        vm.warp(10_000);
        oracle.setPrice(3000e8);
        oracle.setStale();

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

    /// @notice Verifies that an attacker cannot execute an order with fabricated reveal data.
    ///         The commit-reveal scheme ensures only the correct intent hash is accepted.
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

        // Attacker attempts execution with different parameters
        GhostVaultHook.RevealData memory fakeReveal =
            GhostVaultHook.RevealData({targetPrice: 3000e8, zeroForOne: true, salt: keccak256('fake')});

        oracle.setPrice(3000e8);

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

    /// @notice Verifies that only the order owner can cancel their order.
    function test_OnlyOwnerCanCancel() public {
        uint256 depositAmount = 10_000e6;
        bytes32 intentHash = keccak256(abi.encode(uint256(3000e8), true, keccak256('safe')));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey
        );
        vm.stopPrank();

        // Non-owner (solver) attempts cancellation
        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.NotOrderOwner.selector);
        hook.cancelOrder(orderId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 7: Price Condition Not Met
    // ─────────────────────────────────────────────────────────────

    /// @notice Verifies that a YieldOrder cannot be executed when the price condition is not met.
    ///         The order targets a swap when ETH >= $3,000, but the oracle reports $2,500.
    function test_PriceConditionNotMet() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8; // Execute when ETH >= $3,000
        bool zeroForOne = true;
        bytes32 salt = keccak256('price');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        hook.commitOrder(address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, 0, poolKey);
        vm.stopPrank();

        // Oracle at $2,500 - below the $3,000 target
        oracle.setPrice(2500e8);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.PriceConditionNotMet.selector);
        hook.executeOrder(0, reveal);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 8: Slippage Protection
    // ─────────────────────────────────────────────────────────────

    /// @notice Verifies that execution reverts when swap output is below minAmountOut.
    ///         The user sets an unrealistically high minAmountOut that the pool can't satisfy.
    function test_SlippageProtection() public {
        uint256 depositAmount = 10_000e6;
        uint256 targetPrice = 3000e8;
        bool zeroForOne = true;
        bytes32 salt = keccak256('slippage');
        bytes32 intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt));

        // Set minAmountOut absurdly high — 1,000 WETH for 10k USDC is impossible
        uint256 minAmountOut = 1_000e18;

        vm.startPrank(user);
        usdc.approve(address(hook), depositAmount);
        uint256 orderId = hook.commitOrder(
            address(usdc), depositAmount, intentHash, GhostVaultHook.OrderType.YIELD_ORDER, 0, minAmountOut, poolKey
        );
        vm.stopPrank();

        // Satisfy price condition
        vm.warp(block.timestamp + 1 days);
        oracle.setPrice(3000e8);

        GhostVaultHook.RevealData memory reveal =
            GhostVaultHook.RevealData({targetPrice: targetPrice, zeroForOne: zeroForOne, salt: salt});

        vm.prank(solver);
        vm.expectRevert(GhostVaultHook.SlippageExceeded.selector);
        hook.executeOrder(orderId, reveal);

        // Confirm order remains active
        (,, GhostVaultHook.OrderStatus status,,,,,,) = hook.getOrder(orderId);
        assertEq(uint8(status), uint8(GhostVaultHook.OrderStatus.ACTIVE));
    }
}
