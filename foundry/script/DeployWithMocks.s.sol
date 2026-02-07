// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {HookMiner} from '@uniswap/v4-periphery/src/utils/HookMiner.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {GhostVaultHookV2} from '../src/GhostVaultHookV2.sol';
import {MockChainlinkOracle} from '../src/MockChainlinkOracle.sol';
import {SimpleYieldVault} from '../src/SimpleYieldVault.sol';
import {POOLMANAGER_BASE_MAINNET, USDC_BASE_MAINNET} from '../constants/Addresses.sol';

/// @title GhostVault Demo Deployment with Mocks
/// @notice Deploys GhostVaultHookV2 with MockChainlinkOracle and SimpleYieldVault.
///         This allows full demo functionality on Anvil fork with time warping.
///
/// @dev    The mock oracle returns block.timestamp as updatedAt, so it's never stale.
///         The SimpleYieldVault provides 4% APY for demo purposes.
///
///         Usage: DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployWithMocks.s.sol --rpc-url $RPC --broadcast
contract DeployWithMocks is Script {
    // Default ETH price: $3000 (8 decimals)
    int256 constant DEFAULT_ETH_PRICE = 3000_00000000;

    // USDC address on Base mainnet
    address constant USDC = USDC_BASE_MAINNET;

    function run() public {
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
        address deployer = vm.addr(deployerKey);

        console2.log("Deploying GhostVault with mocks...");

        vm.startBroadcast(deployerKey);

        // 1. Deploy Mock Chainlink Oracle
        MockChainlinkOracle oracle = new MockChainlinkOracle(DEFAULT_ETH_PRICE);

        // 2. Deploy GhostVaultHookV2 with mock oracle
        IPoolManager poolManager = IPoolManager(POOLMANAGER_BASE_MAINNET);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(address(poolManager), address(oracle), deployer);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(GhostVaultHookV2).creationCode, constructorArgs);

        GhostVaultHookV2 hook = new GhostVaultHookV2{salt: salt}(
            poolManager,
            AggregatorV3Interface(address(oracle)),
            deployer
        );
        require(address(hook) == hookAddress, 'hook address mismatch');

        // 3. Deploy SimpleYieldVault (4% APY)
        SimpleYieldVault vault = new SimpleYieldVault(USDC, 6, "Demo USDC Vault", "dUSDC");

        // 4. Pre-fund vault with USDC for yield payouts
        uint256 yieldReserve = 10_000e6;
        IERC20(USDC).transfer(address(vault), yieldReserve);

        // 5. Register vault with hook
        hook.setYieldConfig(USDC, address(vault));

        vm.stopBroadcast();

        console2.log("Done!");
        console2.log("HOOK:", address(hook));
        console2.log("ORACLE:", address(oracle));
        console2.log("VAULT:", address(vault));
    }
}
