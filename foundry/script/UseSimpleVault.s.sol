// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SimpleYieldVault} from "../src/SimpleYieldVault.sol";
import {GhostVaultHookV2} from "../src/GhostVaultHookV2.sol";

import {USDC_BASE_MAINNET} from "../constants/Addresses.sol";

/// @title  Switch hook to SimpleYieldVault on Anvil fork
/// @notice Deploys SimpleYieldVault, pre-funds it, and reconfigures the hook.
///         After this, commitOrder / executeOrder / cancelOrder all work
///         without MetaMorpho liquidity constraints.
///
/// @dev    Run (account #0 must be OWNER of the hook):
///         forge script script/UseSimpleVault.s.sol \
///           --rpc-url http://127.0.0.1:8545 --broadcast \
///           --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract UseSimpleVault is Script {
    function run() external {
        address hookAddr = vm.envOr(
            "HOOK_ADDRESS",
            address(0x3EB83B5592Fa61C8Db81945294A854D37badc0C0)
        );
        GhostVaultHookV2 hook = GhostVaultHookV2(hookAddr);

        console2.log('Deploy SimpleYieldVault on Anvil Fork');
        console2.log('Hook:', hookAddr);
        console2.log('Hook OWNER:', hook.OWNER());

        vm.startBroadcast();

        // 1. Deploy SimpleYieldVault
        SimpleYieldVault vault = new SimpleYieldVault(
            USDC_BASE_MAINNET,
            6,
            'GhostVault Yield Shares',
            'gvUSDC'
        );
        console2.log('SimpleYieldVault deployed:', address(vault));

        // 2. Pre-fund vault with USDC so it can pay out yield on redeem
        //    Transfer from the broadcaster (Anvil account #0 has 100k USDC from demo-setup)
        uint256 yieldReserve = 50_000e6;  
        IERC20(USDC_BASE_MAINNET).transfer(address(vault), yieldReserve);
        console2.log('Pre-funded vault:', yieldReserve / 1e6);

        // 3. Reconfigure hook to use SimpleYieldVault for USDC
        //    This calls setYieldConfig(token, vault) - requires msg.sender == OWNER
        hook.setYieldConfig(USDC_BASE_MAINNET, address(vault));
        console2.log('Hook reconfigured: USDC -> SimpleYieldVault');

        vm.stopBroadcast();

       
        console2.log('Vault asset:', vault.asset());
        console2.log('Vault balance:', IERC20(USDC_BASE_MAINNET).balanceOf(address(vault)) / 1e6);
        console2.log('Ready! Commit new orders - they will use SimpleYieldVault.');
    }
}
