// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from '@uniswap/v4-periphery/src/utils/BaseHook.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

/// @title GhostVault Hook V2
/// @author GhostVault Protocol (ETH Global Hack Money 2026)
/// @notice A Uniswap v4 hook that routes idle order capital into an ERC-4626 yield vault
///         (MetaMorpho) until execution conditions are met.
///
/// @dev V2 improvements over V1:
///      - afterSwap hook: Observes all pool swaps, emitting PoolSwapObserved events for
///        real-time agent monitoring of price movements.
///      - Batch execution: executeBatch() aggregates multiple orders into a single swap,
///        hiding individual order sizes on-chain for stronger privacy.
///      - ReentrancyGuardTransient: Transient-storage reentrancy protection (Cancun EVM).
///      - tokenIn validation: commitOrder verifies tokenIn is one of the pool's currencies.
///
///      Two order types are supported:
///      - YieldOrder: A price-triggered limit order. Capital earns yield while waiting for a
///        Chainlink oracle-verified price target.
///      - GhostOrder: A time-delayed privacy swap. Commit-reveal hides trade intent; temporal
///        separation from the pool reduces MEV exposure.
///
///      Uses Cancun transient storage (tstore/tload) to distinguish hook-initiated swaps
///      from external swaps inside the beforeSwap and afterSwap callbacks.
contract GhostVaultHookV2 is BaseHook, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────

    enum OrderType {
        YIELD_ORDER,
        GHOST_ORDER
    }

    enum OrderStatus {
        ACTIVE,
        EXECUTED,
        CANCELLED
    }

    struct GhostOrder {
        address owner;
        OrderType orderType;
        OrderStatus status;
        Currency tokenIn;
        Currency tokenOut;
        uint256 amountIn;
        uint256 vaultShares;
        bytes32 intentHash;
        uint256 createdAt;
        uint256 minDelay;
        uint256 minAmountOut;
        PoolKey poolKey;
    }

    struct RevealData {
        uint256 targetPrice;
        bool zeroForOne;
        bytes32 salt;
    }

    struct YieldConfig {
        bool isSupported;
        IERC4626 vault;
    }

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    // ─────────────────────────────────────────────────────────────
    //  State Variables
    // ─────────────────────────────────────────────────────────────

    uint256 public nextOrderId;
    mapping(uint256 => GhostOrder) public orders;
    mapping(uint256 => IERC4626) public orderVaults;
    mapping(address => YieldConfig) public yieldRegistry;

    // solhint-disable-next-line var-name-mixedcase
    AggregatorV3Interface public immutable PRICE_FEED;
    // solhint-disable-next-line var-name-mixedcase
    address public immutable OWNER;

    uint256 public constant SOLVER_FEE_BPS = 100;
    uint256 public constant MAX_ORACLE_STALENESS = 3600;

    // ─────────────────────────────────────────────────────────────
    //  Transient Storage
    // ─────────────────────────────────────────────────────────────

    bytes32 private constant _EXECUTING_SWAP_SLOT = keccak256('GhostVault.executingSwap');

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event OrderCommitted(
        uint256 indexed orderId,
        address indexed owner,
        OrderType orderType,
        address tokenIn,
        uint256 amountIn,
        uint256 vaultShares,
        bytes32 intentHash
    );

    event OrderExecuted(
        uint256 indexed orderId,
        address indexed owner,
        address indexed solver,
        uint256 amountOut,
        uint256 yieldEarned,
        uint256 solverFee
    );

    event OrderCancelled(
        uint256 indexed orderId, address indexed owner, uint256 principalReturned, uint256 yieldEarned
    );

    event YieldConfigSet(address indexed token, address indexed vault);

    /// @notice Emitted by afterSwap when an external (non-hook-initiated) swap completes.
    /// @dev The solver agent subscribes to these events for real-time pool activity monitoring.
    event PoolSwapObserved(
        PoolId indexed poolId,
        bool zeroForOne,
        int128 amount0,
        int128 amount1
    );

    /// @notice Emitted when a batch of orders is executed in a single aggregated swap.
    event BatchExecuted(
        uint256[] orderIds,
        address indexed solver,
        uint256 totalAmountIn,
        uint256 totalAmountOut
    );

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    error TokenNotSupported();
    error OrderNotActive();
    error NotOrderOwner();
    error HashMismatch();
    error PriceConditionNotMet();
    error DelayNotElapsed();
    error OracleStale(uint256 updatedAt, uint256 currentTime);
    error OnlyPoolManager();
    error InsufficientVaultLiquidity();
    error NotOwner();
    error VaultAssetMismatch();
    error SlippageExceeded();
    error InvalidPool();
    error BatchEmpty();
    error BatchPoolMismatch();
    error BatchDirectionMismatch();

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(IPoolManager _manager, AggregatorV3Interface _priceFeed, address _owner) BaseHook(_manager) {
        PRICE_FEED = _priceFeed;
        OWNER = _owner;
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Permissions
    // ─────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (msg.sender != OWNER) revert NotOwner();
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────

    function setYieldConfig(address token, address vault) external onlyOwner {
        if (IERC4626(vault).asset() != token) revert VaultAssetMismatch();
        yieldRegistry[token] = YieldConfig({isSupported: true, vault: IERC4626(vault)});
        emit YieldConfigSet(token, vault);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Commit
    // ─────────────────────────────────────────────────────────────

    function commitOrder(
        address tokenIn,
        uint256 amountIn,
        bytes32 intentHash,
        OrderType orderType,
        uint256 minDelay,
        uint256 minAmountOut,
        PoolKey calldata key
    ) external nonReentrant returns (uint256 orderId) {
        YieldConfig memory config = yieldRegistry[tokenIn];
        if (!config.isSupported) revert TokenNotSupported();
        if (tokenIn != Currency.unwrap(key.currency0) && tokenIn != Currency.unwrap(key.currency1)) {
            revert InvalidPool();
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        IERC20(tokenIn).forceApprove(address(config.vault), amountIn);
        uint256 shares = config.vault.deposit(amountIn, address(this));

        orderId = nextOrderId++;
        orders[orderId] = GhostOrder({
            owner: msg.sender,
            orderType: orderType,
            status: OrderStatus.ACTIVE,
            tokenIn: Currency.wrap(tokenIn),
            tokenOut: Currency.wrap(tokenIn) == key.currency0 ? key.currency1 : key.currency0,
            amountIn: amountIn,
            vaultShares: shares,
            intentHash: intentHash,
            createdAt: block.timestamp,
            minDelay: minDelay,
            minAmountOut: minAmountOut,
            poolKey: key
        });
        orderVaults[orderId] = config.vault;

        emit OrderCommitted(orderId, msg.sender, orderType, tokenIn, amountIn, shares, intentHash);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Execute (Single)
    // ─────────────────────────────────────────────────────────────

    function executeOrder(uint256 orderId, RevealData calldata reveal) external nonReentrant {
        GhostOrder storage order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 computedHash = keccak256(abi.encode(reveal.targetPrice, reveal.zeroForOne, reveal.salt));
        if (computedHash != order.intentHash) revert HashMismatch();

        if (order.orderType == OrderType.YIELD_ORDER) {
            _verifyPriceCondition(reveal.targetPrice, reveal.zeroForOne);
        } else {
            if (block.timestamp < order.createdAt + order.minDelay) revert DelayNotElapsed();
        }

        order.status = OrderStatus.EXECUTED;

        (uint256 amountToSwap, uint256 solverFee, uint256 yieldEarned) = _redeemVaultPosition(orderId);

        _setExecutingSwap(true);

        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    key: order.poolKey,
                    zeroForOne: reveal.zeroForOne,
                    amountIn: amountToSwap,
                    recipient: order.owner
                })
            )
        );

        _setExecutingSwap(false);

        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 amountOut = uint256(int256(reveal.zeroForOne ? delta.amount1() : delta.amount0()));

        if (order.minAmountOut > 0 && amountOut < order.minAmountOut) revert SlippageExceeded();

        if (solverFee > 0) {
            IERC20(Currency.unwrap(order.tokenIn)).safeTransfer(msg.sender, solverFee);
        }

        emit OrderExecuted(orderId, order.owner, msg.sender, amountOut, yieldEarned, solverFee);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Execute (Batch — Privacy via Aggregation)
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute multiple orders in a single aggregated swap for privacy.
    /// @dev All orders must share the same pool and swap direction. Output tokens
    ///      are distributed proportionally to each order's input contribution.
    ///      On-chain observers see one large swap instead of N individual swaps,
    ///      hiding individual order amounts within the aggregate.
    /// @param orderIds Array of order IDs to execute as a batch.
    /// @param reveals Array of RevealData corresponding to each order.
    function executeBatch(uint256[] calldata orderIds, RevealData[] calldata reveals) external nonReentrant {
        uint256 len = orderIds.length;
        if (len == 0 || len != reveals.length) revert BatchEmpty();

        PoolKey memory batchPoolKey = orders[orderIds[0]].poolKey;
        bool batchZeroForOne = reveals[0].zeroForOne;

        uint256 totalAmountIn;
        uint256 totalSolverFee;
        uint256[] memory amountsIn = new uint256[](len);
        address[] memory recipients = new address[](len);

        // ── Phase 1: Validate + Redeem (scoped per-order) ──
        for (uint256 i = 0; i < len; i++) {
            {   // scope: order validation — order pointer freed at closing brace
                GhostOrder storage order = orders[orderIds[i]];
                if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();

                {   // scope: hash verification — computedHash freed
                    bytes32 computedHash = keccak256(abi.encode(reveals[i].targetPrice, reveals[i].zeroForOne, reveals[i].salt));
                    if (computedHash != order.intentHash) revert HashMismatch();
                }

                if (i > 0) {
                    if (keccak256(abi.encode(order.poolKey)) != keccak256(abi.encode(batchPoolKey))) {
                        revert BatchPoolMismatch();
                    }
                    if (reveals[i].zeroForOne != batchZeroForOne) revert BatchDirectionMismatch();
                }

                if (order.orderType == OrderType.YIELD_ORDER) {
                    _verifyPriceCondition(reveals[i].targetPrice, reveals[i].zeroForOne);
                } else {
                    if (block.timestamp < order.createdAt + order.minDelay) revert DelayNotElapsed();
                }

                order.status = OrderStatus.EXECUTED;
                recipients[i] = order.owner;
            }   // order pointer freed — stack has room for redeem results

            {   // scope: vault redemption — oid, amountToSwap, solverFee, yieldEarned freed
                uint256 oid = orderIds[i];
                (uint256 amountToSwap, uint256 solverFee, uint256 yieldEarned) = _redeemVaultPosition(oid);
                amountsIn[i] = amountToSwap;
                totalAmountIn += amountToSwap;
                totalSolverFee += solverFee;
                emit OrderExecuted(oid, recipients[i], msg.sender, 0, yieldEarned, solverFee);
            }
        }

        // ── Phase 2: Single aggregated swap ──
        uint256 totalAmountOut;
        {   // scope: swap + decode — result, delta freed
            _setExecutingSwap(true);
            bytes memory result = poolManager.unlock(
                abi.encode(SwapCallbackData({key: batchPoolKey, zeroForOne: batchZeroForOne, amountIn: totalAmountIn, recipient: address(this)}))
            );
            _setExecutingSwap(false);

            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            totalAmountOut = uint256(int256(batchZeroForOne ? delta.amount1() : delta.amount0()));
        }

        // ── Phase 3: Distribute output proportionally ──
        _distributeBatchOutput(
            orderIds, amountsIn, recipients, totalAmountIn, totalAmountOut,
            Currency.unwrap(batchZeroForOne ? batchPoolKey.currency1 : batchPoolKey.currency0)
        );

        // ── Phase 4: Pay solver + emit ──
        if (totalSolverFee > 0) {
            IERC20(Currency.unwrap(batchZeroForOne ? batchPoolKey.currency0 : batchPoolKey.currency1))
                .safeTransfer(msg.sender, totalSolverFee);
        }

        emit BatchExecuted(orderIds, msg.sender, totalAmountIn, totalAmountOut);
    }

    /// @dev Distributes swap output proportionally to batch participants.
    ///      Separate function because the outer executeBatch scope has 9+ live variables,
    ///      exceeding the legacy codegen's stack limit even with `{ }` scoping blocks.
    function _distributeBatchOutput(
        uint256[] calldata orderIds,
        uint256[] memory amountsIn,
        address[] memory recipients,
        uint256 totalAmountIn,
        uint256 totalAmountOut,
        address outputToken
    ) internal {
        uint256 len = orderIds.length;
        uint256 distributed;

        for (uint256 i = 0; i < len; i++) {
            uint256 share;
            if (i == len - 1) {
                share = totalAmountOut - distributed;
            } else {
                share = (totalAmountOut * amountsIn[i]) / totalAmountIn;
            }

            {   // scope: slippage check — minOut freed
                uint256 minOut = orders[orderIds[i]].minAmountOut;
                if (minOut > 0 && share < minOut) revert SlippageExceeded();
            }

            IERC20(outputToken).safeTransfer(recipients[i], share);
            distributed += share;
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Cancel
    // ─────────────────────────────────────────────────────────────

    function cancelOrder(uint256 orderId) external nonReentrant {
        GhostOrder storage order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();
        if (order.owner != msg.sender) revert NotOrderOwner();

        order.status = OrderStatus.CANCELLED;

        uint256 totalWithdrawn = orderVaults[orderId].redeem(order.vaultShares, msg.sender, address(this));
        uint256 yieldEarned = totalWithdrawn > order.amountIn ? totalWithdrawn - order.amountIn : 0;

        emit OrderCancelled(orderId, msg.sender, totalWithdrawn, yieldEarned);
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Callback: beforeSwap
    // ─────────────────────────────────────────────────────────────

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_isExecutingSwap()) {
            _verifyOracleDeviation();
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Callback: afterSwap (V2 — Pool Observation)
    // ─────────────────────────────────────────────────────────────

    /// @dev Called by the PoolManager after every swap on pools using this hook.
    ///      For external swaps: emits PoolSwapObserved so the solver agent can
    ///      monitor real-time price movements and trigger order execution.
    ///      For hook-initiated swaps: skips emission to avoid noise.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (!_isExecutingSwap()) {
            emit PoolSwapObserved(key.toId(), params.zeroForOne, delta.amount0(), delta.amount1());
        }

        return (IHooks.afterSwap.selector, int128(0));
    }

    // ─────────────────────────────────────────────────────────────
    //  Unlock Callback
    // ─────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        SwapCallbackData memory cbData = abi.decode(data, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(
            cbData.key,
            SwapParams({
                zeroForOne: cbData.zeroForOne,
                amountSpecified: -int256(cbData.amountIn),
                sqrtPriceLimitX96: cbData.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ''
        );

        Currency inputCurrency = cbData.zeroForOne ? cbData.key.currency0 : cbData.key.currency1;
        address inputToken = Currency.unwrap(inputCurrency);

        poolManager.sync(inputCurrency);
        IERC20(inputToken).safeTransfer(address(poolManager), cbData.amountIn);
        poolManager.settle();

        Currency outputCurrency = cbData.zeroForOne ? cbData.key.currency1 : cbData.key.currency0;
        int128 outputDelta = cbData.zeroForOne ? delta.amount1() : delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outputAmount = uint256(int256(outputDelta));
        poolManager.take(outputCurrency, cbData.recipient, outputAmount);

        return abi.encode(delta);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Vault Redemption
    // ─────────────────────────────────────────────────────────────

    function _redeemVaultPosition(uint256 orderId)
        internal
        returns (uint256 amountToSwap, uint256 solverFee, uint256 yieldEarned)
    {
        GhostOrder storage order = orders[orderId];
        IERC4626 vault = orderVaults[orderId];

        uint256 sharesToRedeem = order.vaultShares;
        if (sharesToRedeem > vault.maxRedeem(address(this))) revert InsufficientVaultLiquidity();

        uint256 totalWithdrawn = vault.redeem(sharesToRedeem, address(this), address(this));
        yieldEarned = totalWithdrawn > order.amountIn ? totalWithdrawn - order.amountIn : 0;

        solverFee = (yieldEarned * SOLVER_FEE_BPS) / 10_000;
        amountToSwap = totalWithdrawn - solverFee;
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Oracle Verification
    // ─────────────────────────────────────────────────────────────

    function _verifyPriceCondition(uint256 targetPrice, bool zeroForOne) internal view {
        (, int256 answer,, uint256 updatedAt,) = PRICE_FEED.latestRoundData();

        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
            revert OracleStale(updatedAt, block.timestamp);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currentPrice = uint256(answer);

        if (zeroForOne) {
            if (currentPrice < targetPrice) revert PriceConditionNotMet();
        } else {
            if (currentPrice > targetPrice) revert PriceConditionNotMet();
        }
    }

    function _verifyOracleDeviation() internal view {
        (,,, uint256 updatedAt,) = PRICE_FEED.latestRoundData();

        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
            revert OracleStale(updatedAt, block.timestamp);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Transient Storage
    // ─────────────────────────────────────────────────────────────

    function _setExecutingSwap(bool executing) internal {
        bytes32 slot = _EXECUTING_SWAP_SLOT;
        uint256 value = executing ? 1 : 0;
        assembly {
            tstore(slot, value)
        }
    }

    function _isExecutingSwap() internal view returns (bool) {
        bytes32 slot = _EXECUTING_SWAP_SLOT;
        uint256 value;
        assembly {
            value := tload(slot)
        }
        return value == 1;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    function getOrderValue(uint256 orderId) external view returns (uint256 currentValue, uint256 yieldAccrued) {
        GhostOrder memory order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) return (0, 0);

        currentValue = orderVaults[orderId].convertToAssets(order.vaultShares);
        yieldAccrued = currentValue > order.amountIn ? currentValue - order.amountIn : 0;
    }

    function getOrder(uint256 orderId)
        external
        view
        returns (
            address owner,
            OrderType orderType,
            OrderStatus status,
            address tokenIn,
            uint256 amountIn,
            uint256 vaultShares,
            bytes32 intentHash,
            uint256 createdAt,
            uint256 minDelay
        )
    {
        GhostOrder memory o = orders[orderId];
        return (
            o.owner,
            o.orderType,
            o.status,
            Currency.unwrap(o.tokenIn),
            o.amountIn,
            o.vaultShares,
            o.intentHash,
            o.createdAt,
            o.minDelay
        );
    }
}
