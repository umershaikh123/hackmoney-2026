// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {HookMiner} from '@uniswap/v4-periphery/src/utils/HookMiner.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {
    POOLMANAGER_BASE_MAINNET,
    ETH_USD_FEED_BASE_MAINNET,
    USDC_BASE_MAINNET,
    METAMORPHO_VAULT_BASE_MAINNET,
    POOLMANAGER_BASE_SEPOLIA,
    ETH_USD_FEED_BASE_SEPOLIA
} from '../constants/Addresses.sol';

/// @title GhostVault Hook V2 Deployment
/// @notice Deploys GhostVaultHookV2 via CREATE2 with HookMiner salt.
/// @dev Hook address encodes BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG (0xC0).
///      Usage: DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployV2.s.sol --rpc-url $RPC --broadcast
contract DeployGhostVaultV2 is Script {
    IPoolManager constant POOL_MANAGER_MAINNET = IPoolManager(POOLMANAGER_BASE_MAINNET);
    AggregatorV3Interface constant PRICE_FEED_MAINNET = AggregatorV3Interface(ETH_USD_FEED_BASE_MAINNET);
    IPoolManager constant POOL_MANAGER_SEPOLIA = IPoolManager(POOLMANAGER_BASE_SEPOLIA);
    AggregatorV3Interface constant PRICE_FEED_SEPOLIA = AggregatorV3Interface(ETH_USD_FEED_BASE_SEPOLIA);

    function run() public {
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
        address deployer = vm.addr(deployerKey);

        bool isSepolia = _isContract(address(POOL_MANAGER_SEPOLIA)) && !_isContract(address(POOL_MANAGER_MAINNET));
        IPoolManager poolManager = isSepolia ? POOL_MANAGER_SEPOLIA : POOL_MANAGER_MAINNET;
        AggregatorV3Interface priceFeed = isSepolia ? PRICE_FEED_SEPOLIA : PRICE_FEED_MAINNET;

        console2.log('GhostVault V2 Deploy');
        console2.log('Network:', isSepolia ? 'Base Sepolia' : 'Base Mainnet');
        console2.log('Deployer:', deployer);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(address(poolManager), address(priceFeed), deployer);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(GhostVaultHookV2).creationCode, constructorArgs);

        console2.log('Mined hook address:', hookAddress);

        vm.startBroadcast(deployerKey);

        GhostVaultHookV2 hook = new GhostVaultHookV2{salt: salt}(poolManager, priceFeed, deployer);
        require(address(hook) == hookAddress, 'hook address mismatch');

        if (!isSepolia) {
            hook.setYieldConfig(USDC_BASE_MAINNET, METAMORPHO_VAULT_BASE_MAINNET);
            console2.log('Yield config: USDC -> MetaMorpho');
        }

        vm.stopBroadcast();

        console2.log('V2 Hook deployed at:', address(hook));
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }
}
