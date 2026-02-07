// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {LiquidityHelper} from '../test/helpers/LiquidityHelper.sol';
import {
    POOLMANAGER_BASE_MAINNET,
    USDC_BASE_MAINNET,
    WETH_BASE_MAINNET
} from '../constants/Addresses.sol';

/// @title Initialize Pool Script
/// @notice Initializes the WETH/USDC pool with our hook and adds liquidity.
/// @dev Run after demo-setup and UseSimpleVault:
///      forge script script/InitPool.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract InitPool is Script {
    IPoolManager constant POOL_MGR = IPoolManager(POOLMANAGER_BASE_MAINNET);

    // sqrtPriceX96 for ~$2500 ETH price (WETH/USDC pool)
    // Formula: sqrt(2500 * 10^6 / 10^18) * 2^96 ≈ 4.339e21
    uint160 constant INIT_SQRT_PRICE = uint160(4_339_505_179_874_779_508_375_552);

    function run() external {
        address hookAddr = vm.envOr(
            'HOOK_ADDRESS',
            address(0x3EB83B5592Fa61C8Db81945294A854D37badc0C0)
        );

        console2.log('Initialize Pool');
        console2.log('Hook:', hookAddr);
        console2.log('PoolManager:', address(POOL_MGR));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH_BASE_MAINNET),
            currency1: Currency.wrap(USDC_BASE_MAINNET),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast();

        // 1. Initialize the pool (skip if already initialized)
        try POOL_MGR.initialize(poolKey, INIT_SQRT_PRICE) {
            console2.log('Pool initialized');
        } catch {
            console2.log('Pool already initialized, skipping');
        }

        // 2. Deploy LiquidityHelper
        LiquidityHelper liquidityHelper = new LiquidityHelper(POOL_MGR);
        console2.log('LiquidityHelper deployed:', address(liquidityHelper));

        // 3. Approve tokens for liquidity
        IERC20(WETH_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);
        IERC20(USDC_BASE_MAINNET).approve(address(liquidityHelper), type(uint256).max);

        // 4. Add liquidity (5e13 = smaller amount that fits demo account balance)
        liquidityHelper.addLiquidity(poolKey, 5e13, -887_220, 887_220);
        console2.log('Liquidity added');

        vm.stopBroadcast();

        console2.log('Pool ready for swaps!');
    }
}
