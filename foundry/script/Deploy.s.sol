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

/// @title GhostVault Hook V1 Deployment
/// @notice Deploys GhostVaultHook (V1) via CREATE2 with HookMiner salt.
/// @dev Hook address encodes BEFORE_SWAP_FLAG (0x80).
///      Usage: DEPLOYER_PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
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

        console2.log('GhostVault V1 Deploy');
        console2.log('Network:', isSepolia ? 'Base Sepolia' : 'Base Mainnet');

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(address(poolManager), address(priceFeed));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GhostVaultHook).creationCode, constructorArgs);

        console2.log('Mined hook address:', hookAddress);

        vm.startBroadcast(deployerKey);

        GhostVaultHook hook = new GhostVaultHook{salt: salt}(poolManager, priceFeed);
        require(address(hook) == hookAddress, 'hook address mismatch');

        if (!isSepolia) {
            hook.setYieldConfig(USDC_BASE_MAINNET, METAMORPHO_VAULT_BASE_MAINNET);
            console2.log('Yield config: USDC -> MetaMorpho');
        }

        vm.stopBroadcast();

        console2.log('Hook deployed at:', address(hook));
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }
}
