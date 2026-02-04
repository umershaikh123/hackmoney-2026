// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {HookMiner} from '@uniswap/v4-periphery/src/utils/HookMiner.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

import {GhostVaultHook} from '../src/GhostVaultHook.sol';
import {
    POOLMANAGER_BASE_MAINNET,
    ETH_USD_FEED_BASE_MAINNET,
    USDC_BASE_MAINNET,
    METAMORPHO_VAULT_BASE_MAINNET,
    POOLMANAGER_BASE_SEPOLIA,
    ETH_USD_FEED_BASE_SEPOLIA
} from '../constants/Addresses.sol';

/// @title GhostVault Hook Deployment Script
/// @author GhostVault Protocol
/// @notice Deploys GhostVaultHook to Base Sepolia or Base Mainnet using CREATE2 salt mining.
///
/// @dev Hook addresses must encode permission flags in their lowest address bits.
///      This script uses HookMiner to find a CREATE2 salt that produces an address
///      with the `BEFORE_SWAP_FLAG` bit set.
///
///      Usage:
///        Base Sepolia:
///          forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
///        Base Mainnet:
///          forge script script/Deploy.s.sol --rpc-url $BASE_MAINNET_RPC --broadcast --verify
///
///      Required environment variables (set in .env.local):
///        DEPLOYER_PRIVATE_KEY  - Private key of the deploying account
///        BASE_MAINNET_RPC      - Base mainnet RPC URL (optional, for mainnet deploy)
///        BASE_SEPOLIA_RPC      - Base Sepolia RPC URL (optional, for testnet deploy)
contract DeployGhostVault is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager constant POOL_MANAGER_MAINNET = IPoolManager(POOLMANAGER_BASE_MAINNET);
    AggregatorV3Interface constant PRICE_FEED_MAINNET = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET);

    IPoolManager constant POOL_MANAGER_SEPOLIA = IPoolManager(POOLMANAGER_BASE_SEPOLIA);
    AggregatorV3Interface constant PRICE_FEED_SEPOLIA = AggregatorV3Interface(ETH_USD_FEED_BASE_SEPOLIA);

    function run() public {
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');

        bool isSepolia = _isContract(address(POOL_MANAGER_SEPOLIA)) && !_isContract(address(POOL_MANAGER_MAINNET));

        IPoolManager poolManager = isSepolia ? POOL_MANAGER_SEPOLIA : POOL_MANAGER_MAINNET;
        AggregatorV3Interface priceFeed = isSepolia ? PRICE_FEED_SEPOLIA : PRICE_FEED_MAINNET;

        console2.log('');
        console2.log('========================================');
        console2.log('  GhostVault Hook Deployment');
        console2.log('========================================');
        console2.log('  Network:      ', isSepolia ? 'Base Sepolia' : 'Base Mainnet');
        console2.log('  PoolManager:  ', address(poolManager));
        console2.log('  Price Feed:   ', address(priceFeed));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), address(priceFeed));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GhostVaultHook).creationCode, constructorArgs);

        console2.log('  Mined address:', hookAddress);
        console2.log('');

        vm.startBroadcast(deployerKey);

        GhostVaultHook hook = new GhostVaultHook{salt: salt}(poolManager, priceFeed);
        require(address(hook) == hookAddress, 'Deploy: hook address mismatch');

        if (!isSepolia) {
            hook.setYieldConfig(USDC_BASE_MAINNET, METAMORPHO_VAULT_BASE_MAINNET);
            console2.log('  Yield Config: USDC -> MetaMorpho Gauntlet USDC Prime');
        }

        vm.stopBroadcast();

        console2.log('');
        console2.log('  Hook deployed at:', address(hook));
        console2.log('========================================');
        console2.log('');
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
