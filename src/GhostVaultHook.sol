// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from '@uniswap/v4-periphery/src/utils/BaseHook.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

/// @notice Minimal ERC-4626 tokenized vault interface used for MetaMorpho integration.
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function asset() external view returns (address);
}

/// @title GhostVault Hook
/// @author GhostVault Protocol (ETH Global Hack Money 2026)
/// @notice A Uniswap v4 hook that routes idle order capital into an ERC-4626 yield vault
///         (MetaMorpho) until execution conditions are met.
///
/// @dev Two order types are supported:
///      - YieldOrder: A price-triggered limit order. Capital earns yield while waiting for a
///        Chainlink oracle-verified price target.
///      - GhostOrder: A time-delayed privacy swap. Commit-reveal hides trade intent; temporal
///        separation from the pool reduces MEV exposure.
///
///      The hook implements `beforeSwap` solely for oracle sanity checks during its own
///      execution swaps. External swaps pass through unmodified.
///
///      Uses Cancun transient storage (tstore/tload) to distinguish hook-initiated swaps
///      from external swaps inside the `beforeSwap` callback.
contract GhostVaultHook is BaseHook, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────

    /// @notice Determines how order execution conditions are evaluated.
    enum OrderType {
        YIELD_ORDER, // Price-triggered (limit order with yield)
        GHOST_ORDER // Time-delayed (privacy swap with yield)
    }

    /// @notice Lifecycle status of an order.
    enum OrderStatus {
        ACTIVE,
        EXECUTED,
        CANCELLED
    }

    /// @notice Represents a user's committed order with vault position metadata.
    struct GhostOrder {
        address owner;
        OrderType orderType;
        OrderStatus status;
        Currency tokenIn;
        Currency tokenOut;
        uint256 amountIn;
        uint256 vaultShares; // ERC-4626 shares received on deposit
        bytes32 intentHash; // keccak256(abi.encode(targetPrice, zeroForOne, salt))
        uint256 createdAt;
        uint256 minDelay; // GhostOrder only: minimum seconds before execution
        PoolKey poolKey;
    }

    /// @notice Data revealed at execution time to verify the commit-reveal scheme.
    struct RevealData {
        uint256 targetPrice; // Target price in oracle decimals (8 for Chainlink)
        bool zeroForOne; // Swap direction: true = sell token0, false = sell token1
        bytes32 salt; // Random salt that was used in the commitment hash
    }

    /// @notice Configuration mapping a token to its ERC-4626 yield vault.
    struct YieldConfig {
        bool isSupported;
        IERC4626 vault;
    }

    /// @notice Packed context passed through `poolManager.unlock()` to `unlockCallback()`.
    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    // ─────────────────────────────────────────────────────────────
    //  State Variables
    // ─────────────────────────────────────────────────────────────

    /// @notice Auto-incrementing order identifier.
    uint256 public nextOrderId;

    /// @notice Order storage indexed by order ID.
    mapping(uint256 => GhostOrder) public orders;

    /// @notice Maps a token address to its ERC-4626 vault configuration.
    mapping(address => YieldConfig) public yieldRegistry;

    /// @notice Chainlink ETH/USD price feed (immutable, set at deployment).
    // solhint-disable-next-line var-name-mixedcase
    AggregatorV3Interface public immutable PRICE_FEED;

    /// @notice Maximum allowed deviation between pool and oracle prices (basis points).
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 200; // 2%

    /// @notice Percentage of accrued yield paid to the solver/agent (basis points).
    uint256 public constant SOLVER_FEE_BPS = 100; // 1%

    /// @notice Maximum acceptable age for a Chainlink price update (seconds).
    uint256 public constant MAX_ORACLE_STALENESS = 3600; // 1 hour

    // ─────────────────────────────────────────────────────────────
    //  Transient Storage
    // ─────────────────────────────────────────────────────────────

    /// @dev Slot used by tstore/tload to flag hook-initiated execution swaps.
    ///      When set to 1, `beforeSwap` applies the oracle staleness check.
    bytes32 private constant _EXECUTING_SWAP_SLOT = keccak256('GhostVault.executingSwap');

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted when a new order is committed and capital deposited into the vault.
    event OrderCommitted(
        uint256 indexed orderId,
        address indexed owner,
        OrderType orderType,
        address tokenIn,
        uint256 amountIn,
        uint256 vaultShares,
        bytes32 intentHash
    );

    /// @notice Emitted when an order is successfully executed via a solver/agent.
    event OrderExecuted(
        uint256 indexed orderId,
        address indexed owner,
        address indexed solver,
        uint256 amountOut,
        uint256 yieldEarned,
        uint256 solverFee
    );

    /// @notice Emitted when an order is cancelled by its owner.
    event OrderCancelled(
        uint256 indexed orderId, address indexed owner, uint256 principalReturned, uint256 yieldEarned
    );

    /// @notice Emitted when a token's yield vault configuration is updated.
    event YieldConfigSet(address indexed token, address indexed vault);

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    error TokenNotSupported();
    error OrderNotActive();
    error NotOrderOwner();
    error HashMismatch();
    error PriceConditionNotMet();
    error DelayNotElapsed();
    error OraclePriceDeviation(uint256 poolPrice, uint256 oraclePrice);
    error OracleStale(uint256 updatedAt, uint256 currentTime);
    error OnlyPoolManager();
    error InsufficientVaultLiquidity();

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _manager The Uniswap v4 PoolManager this hook is registered with.
    /// @param _priceFeed Chainlink AggregatorV3 price feed (e.g. ETH/USD on Base).
    constructor(IPoolManager _manager, AggregatorV3Interface _priceFeed) BaseHook(_manager) {
        PRICE_FEED = _priceFeed;
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Permissions
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────

    /// @notice Register a token for yield routing through an ERC-4626 vault.
    /// @dev In production this should be access-controlled. Open for hackathon demo.
    /// @param token The ERC-20 token address to register (e.g. USDC).
    /// @param vault The ERC-4626 vault address (e.g. MetaMorpho Gauntlet USDC Frontier).
    function setYieldConfig(address token, address vault) external {
        yieldRegistry[token] = YieldConfig({isSupported: true, vault: IERC4626(vault)});
        emit YieldConfigSet(token, vault);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Commit
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit funds and commit an order intent via the commit-reveal scheme.
    /// @dev Transfers `amountIn` from caller, deposits into the ERC-4626 vault, and stores
    ///      the order metadata. The `intentHash` hides the target price and swap direction
    ///      until execution (reveal phase).
    /// @param tokenIn The ERC-20 token to deposit.
    /// @param amountIn Amount of `tokenIn` to deposit.
    /// @param intentHash The commitment hash: `keccak256(abi.encode(targetPrice, zeroForOne, salt))`.
    /// @param orderType Whether this is a YIELD_ORDER (price-triggered) or GHOST_ORDER (time-delayed).
    /// @param minDelay Minimum delay in seconds before execution (only used for GHOST_ORDER).
    /// @param key The Uniswap v4 PoolKey for eventual swap execution.
    /// @return orderId The unique identifier assigned to this order.
    function commitOrder(
        address tokenIn,
        uint256 amountIn,
        bytes32 intentHash,
        OrderType orderType,
        uint256 minDelay,
        PoolKey calldata key
    ) external returns (uint256 orderId) {
        YieldConfig memory config = yieldRegistry[tokenIn];
        if (!config.isSupported) revert TokenNotSupported();

        // Pull tokens from the user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Deposit into the ERC-4626 vault and record the shares received
        IERC20(tokenIn).forceApprove(address(config.vault), amountIn);
        uint256 shares = config.vault.deposit(amountIn, address(this));

        // Persist order state
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
            poolKey: key
        });

        emit OrderCommitted(orderId, msg.sender, orderType, tokenIn, amountIn, shares, intentHash);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Execute
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute an active order when its conditions are met.
    /// @dev Called by a solver/agent. The reveal data is verified against the stored commitment
    ///      hash. For YieldOrders the Chainlink price must satisfy the target condition. For
    ///      GhostOrders the minimum delay must have elapsed.
    ///
    ///      Execution flow:
    ///      1. Verify commit-reveal hash
    ///      2. Check order-type conditions (price or delay)
    ///      3. Redeem vault shares (principal + yield)
    ///      4. Deduct solver fee from yield
    ///      5. Swap remaining amount through the pool
    ///      6. Send output tokens to the order owner
    ///
    /// @param orderId The order to execute.
    /// @param reveal The plaintext data corresponding to the commitment hash.
    function executeOrder(uint256 orderId, RevealData calldata reveal) external {
        GhostOrder storage order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();

        // Step 1: Verify commit-reveal integrity
        bytes32 computedHash = keccak256(abi.encode(reveal.targetPrice, reveal.zeroForOne, reveal.salt));
        if (computedHash != order.intentHash) revert HashMismatch();

        // Step 2: Validate order-type-specific conditions
        if (order.orderType == OrderType.YIELD_ORDER) {
            _verifyPriceCondition(reveal.targetPrice, reveal.zeroForOne);
        } else {
            if (block.timestamp < order.createdAt + order.minDelay) revert DelayNotElapsed();
        }

        // Steps 3-4: Withdraw from vault and calculate solver fee
        (uint256 amountToSwap, uint256 solverFee, uint256 yieldEarned) = _redeemVaultPosition(order);

        // Step 5: Execute swap via PoolManager.unlock() -> unlockCallback() -> swap()
        //         Set transient flag so beforeSwap knows this is a hook-initiated swap.
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

        // Decode swap result and pay solver fee
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 amountOut = uint256(int256(reveal.zeroForOne ? delta.amount1() : delta.amount0()));

        // Step 6: Pay solver fee from yield
        if (solverFee > 0) {
            IERC20(Currency.unwrap(order.tokenIn)).safeTransfer(msg.sender, solverFee);
        }

        order.status = OrderStatus.EXECUTED;

        emit OrderExecuted(orderId, order.owner, msg.sender, amountOut, yieldEarned, solverFee);
    }

    // ─────────────────────────────────────────────────────────────
    //  Core: Cancel
    // ─────────────────────────────────────────────────────────────

    /// @notice Cancel an active order and return the full vault position (principal + yield) to the owner.
    /// @dev Only the original order owner may cancel. No solver fee is deducted on cancellation.
    /// @param orderId The order to cancel.
    function cancelOrder(uint256 orderId) external {
        GhostOrder storage order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();
        if (order.owner != msg.sender) revert NotOrderOwner();

        address tokenInAddr = Currency.unwrap(order.tokenIn);
        IERC4626 vault = yieldRegistry[tokenInAddr].vault;
        uint256 totalWithdrawn = vault.redeem(order.vaultShares, msg.sender, address(this));

        uint256 yieldEarned = totalWithdrawn > order.amountIn ? totalWithdrawn - order.amountIn : 0;

        order.status = OrderStatus.CANCELLED;

        emit OrderCancelled(orderId, msg.sender, totalWithdrawn, yieldEarned);
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Callback: beforeSwap
    // ─────────────────────────────────────────────────────────────

    /// @dev Called by the PoolManager before every swap on pools using this hook.
    ///      Only applies the oracle staleness check when the transient flag indicates
    ///      this is a hook-initiated execution swap. External swaps pass through with
    ///      no interference to normal pool operation.
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
    //  Unlock Callback
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the PoolManager inside `unlock()` to execute the actual swap.
    /// @dev Settlement pattern: sync → transfer → settle for input; take for output.
    ///      The swap uses exact-input mode (negative `amountSpecified`) with no price limit.
    /// @param data ABI-encoded `SwapCallbackData` containing pool key, direction, amount, and recipient.
    /// @return ABI-encoded `BalanceDelta` from the swap.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        SwapCallbackData memory cbData = abi.decode(data, (SwapCallbackData));

        // Execute the swap as exact-input (negative amountSpecified)
        BalanceDelta delta = poolManager.swap(
            cbData.key,
            SwapParams({
                zeroForOne: cbData.zeroForOne,
                amountSpecified: -int256(cbData.amountIn),
                sqrtPriceLimitX96: cbData.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ''
        );

        // Settle input token: we owe the pool, so sync → transfer → settle
        Currency inputCurrency = cbData.zeroForOne ? cbData.key.currency0 : cbData.key.currency1;
        address inputToken = Currency.unwrap(inputCurrency);

        poolManager.sync(inputCurrency);
        IERC20(inputToken).safeTransfer(address(poolManager), cbData.amountIn);
        poolManager.settle();

        // Take output token: pool owes us, send directly to the order owner
        Currency outputCurrency = cbData.zeroForOne ? cbData.key.currency1 : cbData.key.currency0;
        int128 outputDelta = cbData.zeroForOne ? delta.amount1() : delta.amount0();
        // casting to uint256 is safe because outputDelta is positive (pool owes us tokens)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outputAmount = uint256(int256(outputDelta));
        poolManager.take(outputCurrency, cbData.recipient, outputAmount);

        return abi.encode(delta);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Vault Redemption
    // ─────────────────────────────────────────────────────────────

    /// @dev Redeem an order's vault shares and calculate the solver fee.
    ///      Extracted from `executeOrder` to reduce stack depth.
    /// @param order The order whose vault position should be redeemed.
    /// @return amountToSwap The amount available to swap after deducting the solver fee.
    /// @return solverFee The fee paid to the solver from accrued yield.
    /// @return yieldEarned The total yield earned above the original deposit.
    function _redeemVaultPosition(GhostOrder storage order)
        internal
        returns (uint256 amountToSwap, uint256 solverFee, uint256 yieldEarned)
    {
        address tokenInAddr = Currency.unwrap(order.tokenIn);
        IERC4626 vault = yieldRegistry[tokenInAddr].vault;

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

    /// @dev Verify the current Chainlink price satisfies the order's target condition.
    ///      For zeroForOne (selling token0 for token1, e.g. selling ETH for USDC):
    ///        execute when currentPrice >= targetPrice (sell high).
    ///      For !zeroForOne (buying token0 with token1, e.g. buying ETH with USDC):
    ///        execute when currentPrice <= targetPrice (buy low).
    /// @param targetPrice The user's target price in oracle decimals (8 decimals).
    /// @param zeroForOne The swap direction.
    function _verifyPriceCondition(uint256 targetPrice, bool zeroForOne) internal view {
        (, int256 answer,, uint256 updatedAt,) = PRICE_FEED.latestRoundData();

        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
            revert OracleStale(updatedAt, block.timestamp);
        }

        // casting to uint256 is safe because Chainlink price feeds return positive values
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currentPrice = uint256(answer);

        if (zeroForOne) {
            if (currentPrice < targetPrice) revert PriceConditionNotMet();
        } else {
            if (currentPrice > targetPrice) revert PriceConditionNotMet();
        }
    }

    /// @dev Verify the Chainlink oracle is not stale during a hook-initiated swap.
    ///      Acts as a flash-loan protection safety net: if the oracle feed is down or
    ///      stale, the swap is blocked even if the price condition was met moments ago.
    function _verifyOracleDeviation() internal view {
        (,,, uint256 updatedAt,) = PRICE_FEED.latestRoundData();

        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
            revert OracleStale(updatedAt, block.timestamp);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Transient Storage
    // ─────────────────────────────────────────────────────────────

    /// @dev Set or clear the transient flag that marks a hook-initiated swap.
    ///      Uses Cancun `tstore` — the value auto-clears at the end of the transaction.
    /// @param executing True to mark the start of an execution swap, false to clear.
    function _setExecutingSwap(bool executing) internal {
        bytes32 slot = _EXECUTING_SWAP_SLOT;
        uint256 value = executing ? 1 : 0;
        assembly {
            tstore(slot, value)
        }
    }

    /// @dev Check whether the current context is inside a hook-initiated swap.
    /// @return True if the transient flag is set.
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

    /// @notice Get the current vault value and accrued yield for an active order.
    /// @param orderId The order to query.
    /// @return currentValue The total value of the order's vault shares in the underlying token.
    /// @return yieldAccrued The yield earned above the original deposit amount.
    function getOrderValue(uint256 orderId) external view returns (uint256 currentValue, uint256 yieldAccrued) {
        GhostOrder memory order = orders[orderId];
        if (order.status != OrderStatus.ACTIVE) return (0, 0);

        address tokenInAddr = Currency.unwrap(order.tokenIn);
        IERC4626 vault = yieldRegistry[tokenInAddr].vault;
        currentValue = vault.convertToAssets(order.vaultShares);
        yieldAccrued = currentValue > order.amountIn ? currentValue - order.amountIn : 0;
    }

    /// @notice Get the full details of an order.
    /// @param orderId The order to query.
    /// @return owner The address that created the order.
    /// @return orderType YIELD_ORDER or GHOST_ORDER.
    /// @return status ACTIVE, EXECUTED, or CANCELLED.
    /// @return tokenIn The deposited token address.
    /// @return amountIn The original deposit amount.
    /// @return vaultShares The ERC-4626 shares held.
    /// @return intentHash The commitment hash.
    /// @return createdAt The block timestamp when the order was created.
    /// @return minDelay The minimum delay for GhostOrders (0 for YieldOrders).
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
