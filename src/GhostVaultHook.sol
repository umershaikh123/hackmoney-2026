// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from '@uniswap/v4-periphery/src/utils/BaseHook.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Minimal ERC-4626 interface for MetaMorpho vault integration.
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice Minimal Chainlink AggregatorV3 interface for price feeds.
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title GhostVault Hook
/// @author GhostVault Protocol (ETH Global Hack Money 2026)
/// @notice Uniswap v4 hook that routes idle order capital into an ERC-4626 yield vault
///         until execution conditions are met. Supports price-triggered (YieldOrder)
///         and time-delayed (GhostOrder) order types.
contract GhostVaultHook is BaseHook, IUnlockCallback {
    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────

    enum OrderType {
        YIELD_ORDER, // Price-triggered limit order with yield
        GHOST_ORDER  // Time-delayed privacy swap with yield
    }

    enum OrderStatus {
        ACTIVE,
        EXECUTED,
        CANCELLED
    }

    struct GhostOrder {
        address owner;           // Order creator
        OrderType orderType;
        OrderStatus status;
        Currency tokenIn;        // Deposited token (e.g. USDC)
        Currency tokenOut;       // Desired token (e.g. WETH)
        uint256 amountIn;        // Original deposit amount
        uint256 vaultShares;     // ERC-4626 shares from vault deposit
        bytes32 intentHash;      // keccak256(abi.encode(targetPrice, zeroForOne, salt))
        uint256 createdAt;
        uint256 minDelay;        // GhostOrder: minimum seconds before execution
        PoolKey poolKey;         // Uniswap v4 pool for swap execution
    }

    /// @notice Plaintext data revealed at execution to verify the commit-reveal scheme.
    struct RevealData {
        uint256 targetPrice;     // Target price in oracle decimals (8 for Chainlink)
        bool zeroForOne;         // Swap direction
        bytes32 salt;            // Random salt from commitment
    }

    /// @notice Maps a token to its ERC-4626 yield vault.
    struct YieldConfig {
        bool isSupported;
        IERC4626 vault;
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    uint256 public nextOrderId;
    mapping(uint256 => GhostOrder) public orders;
    mapping(address => YieldConfig) public yieldRegistry;
    IAggregatorV3 public immutable PRICE_FEED;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event OrderCommitted(uint256 indexed orderId, address indexed owner, OrderType orderType, address tokenIn, uint256 amountIn, uint256 vaultShares, bytes32 intentHash);
    event OrderExecuted(uint256 indexed orderId, address indexed owner, address indexed solver, uint256 amountOut, uint256 yieldEarned, uint256 solverFee);
    event OrderCancelled(uint256 indexed orderId, address indexed owner, uint256 principalReturned, uint256 yieldEarned);

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

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(IPoolManager _manager, IAggregatorV3 _priceFeed) BaseHook(_manager) {
        PRICE_FEED = _priceFeed;
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
            beforeSwap: true,           // Oracle price verification during execution swaps
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
    //  Core Functions (TODO)
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit funds and commit an order via commit-reveal scheme.
    /// @dev Pull tokens from user -> deposit into ERC-4626 vault -> store order metadata.
    ///      The intentHash hides target price and swap direction until execution.
    function commitOrder(
        address tokenIn,
        uint256 amountIn,
        bytes32 intentHash,
        OrderType orderType,
        uint256 minDelay,
        PoolKey calldata key
    ) external returns (uint256 orderId) {
        // TODO: Validate token is in yieldRegistry
        // TODO: safeTransferFrom tokens from user
        // TODO: Approve and deposit into ERC-4626 vault, track shares
        // TODO: Store GhostOrder struct
        // TODO: Emit OrderCommitted
    }

    /// @notice Execute an active order when conditions are met (called by solver/agent).
    /// @dev Verify commit-reveal hash -> check conditions -> redeem vault -> swap on pool -> pay solver.
    function executeOrder(uint256 orderId, RevealData calldata reveal) external {
        // TODO: Verify order is ACTIVE
        // TODO: Verify keccak256(reveal) == intentHash
        // TODO: If YIELD_ORDER: check Chainlink price condition
        // TODO: If GHOST_ORDER: check delay elapsed
        // TODO: Redeem vault shares (principal + yield)
        // TODO: Calculate solver fee from yield
        // TODO: Execute swap via poolManager.unlock() -> unlockCallback()
        // TODO: Send output tokens to owner, fee to solver
        // TODO: Emit OrderExecuted
    }

    /// @notice Cancel an active order and return principal + yield to owner.
    function cancelOrder(uint256 orderId) external {
        // TODO: Verify msg.sender == owner and order is ACTIVE
        // TODO: Redeem vault shares to owner
        // TODO: Mark CANCELLED
        // TODO: Emit OrderCancelled
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Callback (TODO)
    // ─────────────────────────────────────────────────────────────

    /// @dev Oracle sanity check during hook-initiated swaps.
    ///      Uses transient storage to distinguish execution swaps from external swaps.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // TODO: Check transient flag — is this a hook-initiated swap?
        // TODO: If yes: verify Chainlink oracle is not stale
        // TODO: If no: pass through (don't interfere with normal pool swaps)
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Called by PoolManager inside unlock() to execute the swap.
    /// @dev Settlement: sync -> transfer -> settle (input) + take (output).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // TODO: Verify msg.sender == poolManager
        // TODO: Decode SwapCallbackData
        // TODO: Execute swap (exact-input, no price limit)
        // TODO: Settle input token (sync -> transfer -> settle)
        // TODO: Take output token (send to order owner)
        return '';
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin (TODO)
    // ─────────────────────────────────────────────────────────────

    /// @notice Register a token for yield routing through an ERC-4626 vault.
    function setYieldConfig(address token, address vault) external {
        // TODO: Store vault in yieldRegistry
        // TODO: Emit YieldConfigSet
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions (TODO)
    // ─────────────────────────────────────────────────────────────

    /// @notice Get current vault value and accrued yield for an order.
    function getOrderValue(uint256 orderId) external view returns (uint256 currentValue, uint256 yieldAccrued) {
        // TODO: Query vault.convertToAssets(shares) and compute yield
    }

    /// @notice Get full order details.
    function getOrder(uint256 orderId) external view returns (
        address owner, OrderType orderType, OrderStatus status,
        address tokenIn, uint256 amountIn, uint256 vaultShares,
        bytes32 intentHash, uint256 createdAt, uint256 minDelay
    ) {
        // TODO: Return order fields
    }
}
