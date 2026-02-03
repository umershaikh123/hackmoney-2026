// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from 'forge-std/Script.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {HookMiner} from '@uniswap/v4-periphery/src/utils/HookMiner.sol';
import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

import {GhostVaultHook} from '../src/GhostVaultHook.sol';

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
    /// @dev Standard CREATE2 deployer proxy address (same on all EVM chains).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ─────────────────────────────────────────────────────────────
    //  Base Mainnet Addresses
    // ─────────────────────────────────────────────────────────────

    IPoolManager constant POOL_MANAGER_MAINNET = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    AggregatorV3Interface constant ETH_USD_FEED_MAINNET =
        AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    address constant USDC_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant METAMORPHO_VAULT_MAINNET = 0x236919F11ff9eA9550A4287696C2FC9e18E6e890;

    // ─────────────────────────────────────────────────────────────
    //  Base Sepolia Addresses
    // ─────────────────────────────────────────────────────────────

    IPoolManager constant POOL_MANAGER_SEPOLIA = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    AggregatorV3Interface constant ETH_USD_FEED_SEPOLIA =
        AggregatorV3Interface(0x4Adc67d868eC7B3D15c20179412230BAB5325963);

    function run() public {
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');

        // Detect network by checking which PoolManager is deployed
        bool isSepolia = _isContract(address(POOL_MANAGER_SEPOLIA)) && !_isContract(address(POOL_MANAGER_MAINNET));

        IPoolManager poolManager = isSepolia ? POOL_MANAGER_SEPOLIA : POOL_MANAGER_MAINNET;
        AggregatorV3Interface priceFeed = isSepolia ? ETH_USD_FEED_SEPOLIA : ETH_USD_FEED_MAINNET;

        console2.log('');
        console2.log('========================================');
        console2.log('  GhostVault Hook Deployment');
        console2.log('========================================');
        console2.log('  Network:      ', isSepolia ? 'Base Sepolia' : 'Base Mainnet');
        console2.log('  PoolManager:  ', address(poolManager));
        console2.log('  Price Feed:   ', address(priceFeed));

        // The hook requires the BEFORE_SWAP_FLAG bit set in its address
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        // Mine a CREATE2 salt that produces an address with the correct flag bits
        bytes memory constructorArgs = abi.encode(address(poolManager), address(priceFeed));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GhostVaultHook).creationCode, constructorArgs);

        console2.log('  Mined address:', hookAddress);
        console2.log('');

        // Deploy
        vm.startBroadcast(deployerKey);

        GhostVaultHook hook = new GhostVaultHook{salt: salt}(poolManager, priceFeed);
        require(address(hook) == hookAddress, 'Deploy: hook address mismatch');

        // Register yield vault on mainnet (MetaMorpho Gauntlet USDC Frontier)
        if (!isSepolia) {
            hook.setYieldConfig(USDC_MAINNET, METAMORPHO_VAULT_MAINNET);
            console2.log('  Yield Config: USDC -> MetaMorpho Gauntlet USDC Frontier');
        }

        vm.stopBroadcast();

        console2.log('');
        console2.log('  Hook deployed at:', address(hook));
        console2.log('========================================');
        console2.log('');
    }

    /// @dev Check if an address has deployed code (used for network detection).
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
