// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';

import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {USDC_BASE_MAINNET, WETH_BASE_MAINNET} from '../constants/Addresses.sol';

/// @title Test Orders Script
/// @notice Tests Ghost Order flow on Anvil fork.
/// @dev Usage:
///   1. make demo-anvil
///   2. make demo-setup
///   3. forge script script/TestOrders.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract TestOrders is Script {
    address constant DEMO_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant DEMO_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant HOOK_ADDRESS = 0x3EB83B5592Fa61C8Db81945294A854D37badc0C0;

    uint256 constant ORDER_AMOUNT = 1000e6;
    uint256 constant MIN_DELAY = 60;

    function run() public {
        GhostVaultHookV2 hook = GhostVaultHookV2(HOOK_ADDRESS);

        uint256 nextOrderIdBefore = hook.nextOrderId();
        uint256 usdcBalance = IERC20(USDC_BASE_MAINNET).balanceOf(DEMO_ACCOUNT);

        console2.log('Test Ghost Order');
        console2.log('Hook:', HOOK_ADDRESS);
        console2.log('USDC balance:', usdcBalance / 1e6);
        console2.log('Next order ID:', nextOrderIdBefore);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH_BASE_MAINNET),
            currency1: Currency.wrap(USDC_BASE_MAINNET),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, DEMO_ACCOUNT));
        bytes32 intentHash = keccak256(abi.encode(uint256(0), false, salt));

        vm.startBroadcast(DEMO_PRIVATE_KEY);

        IERC20(USDC_BASE_MAINNET).approve(HOOK_ADDRESS, ORDER_AMOUNT);
        console2.log('Approved USDC');

        uint256 orderId = hook.commitOrder(
            USDC_BASE_MAINNET,
            ORDER_AMOUNT,
            intentHash,
            GhostVaultHookV2.OrderType.GHOST_ORDER,
            MIN_DELAY,
            0,
            poolKey
        );
        console2.log('Order created:', orderId);

        vm.stopBroadcast();

        console2.log('Next order ID:', hook.nextOrderId());
    }
}
