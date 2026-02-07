// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

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

        if (delta.amount0() > 0) {
            MANAGER.take(key.currency0, payer, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            MANAGER.take(key.currency1, payer, uint256(int256(delta.amount1())));
        }

        return '';
    }
}
