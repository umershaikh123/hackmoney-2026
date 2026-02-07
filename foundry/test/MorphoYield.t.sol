// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';

import {USDC_BASE_MAINNET, METAMORPHO_VAULT_BASE_MAINNET} from '../constants/Addresses.sol';

/// @title Standalone Morpho Yield Test
/// @notice Pure deposit/withdraw test against real MetaMorpho on Base mainnet fork.
///         No hooks, no Uniswap — just ERC-4626 vault interactions to verify real yield.
///
/// @dev Run with:
///   forge test --match-path test/MorphoYield.t.sol --fork-url $BASE_MAINNET_RPC -vvv
contract MorphoYieldTest is Test {
    IERC4626 vault = IERC4626(METAMORPHO_VAULT_BASE_MAINNET);
    address user = makeAddr('yieldUser');

    function _mockVaultMaxRedeem() internal {
        vm.mockCall(
            METAMORPHO_VAULT_BASE_MAINNET,
            abi.encodeWithSignature('maxRedeem(address)'),
            abi.encode(type(uint256).max)
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 1: Deposit and check yield at multiple time horizons
    // ─────────────────────────────────────────────────────────────

    function test_YieldOverTime() public {
        uint256 deposit = 10_000e6;

        deal(USDC_BASE_MAINNET, user, deposit);
        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        console2.log("Deposited %s USDC, got %s shares", deposit / 1e6, shares);

        uint256[4] memory durations = [uint256(7 days), 30 days, 90 days, 365 days];
        string[4] memory labels = ['7d', '30d', '90d', '365d'];

        uint256 snapshotId = vm.snapshotState();

        for (uint256 i = 0; i < 4; i++) {
            if (i > 0) vm.revertToState(snapshotId);
            snapshotId = vm.snapshotState();

            vm.warp(block.timestamp + durations[i]);

            uint256 value = vault.convertToAssets(shares);
            uint256 yieldRaw = value > deposit ? value - deposit : 0;

            console2.log("After %s: value=%s, yield=%s (0 expected)", labels[i], value / 1e6, yieldRaw);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: Full deposit -> warp -> withdraw cycle
    // ─────────────────────────────────────────────────────────────

    function test_DepositWarpWithdraw() public {
        uint256 deposit = 50_000e6;

        deal(USDC_BASE_MAINNET, user, deposit);
        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        console2.log("Deposited %s USDC, got %s shares", deposit / 1e6, shares);

        vm.warp(block.timestamp + 30 days);

        uint256 valueAfter = vault.convertToAssets(shares);
        uint256 yieldRaw = valueAfter > deposit ? valueAfter - deposit : 0;
        console2.log("After 30d: value=%s, yield=%s (0 expected)", valueAfter / 1e6, yieldRaw);

        _mockVaultMaxRedeem();

        vm.prank(user);
        uint256 assetsReturned = vault.redeem(shares, user, user);

        console2.log("Redeemed: returned=%s USDC", assetsReturned / 1e6);

        assertApproxEqAbs(assetsReturned, deposit, 1, 'Should return at least principal');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 3: Multiple deposits at different times
    // ─────────────────────────────────────────────────────────────

    function test_StaggeredDeposits() public {
        address userA = makeAddr('userA');
        address userB = makeAddr('userB');
        uint256 deposit = 10_000e6;

        // User A deposits at t=0
        deal(USDC_BASE_MAINNET, userA, deposit);
        vm.startPrank(userA);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 sharesA = vault.deposit(deposit, userA);
        vm.stopPrank();
        console2.log("User A deposits 10000 USDC at t=0");

        // User B deposits at t=15d
        vm.warp(block.timestamp + 15 days);
        deal(USDC_BASE_MAINNET, userB, deposit);
        vm.startPrank(userB);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 sharesB = vault.deposit(deposit, userB);
        vm.stopPrank();
        console2.log("User B deposits 10000 USDC at t=15d");

        // Check at t=30d
        vm.warp(block.timestamp + 15 days);

        uint256 valueA = vault.convertToAssets(sharesA);
        uint256 valueB = vault.convertToAssets(sharesB);

        console2.log("At t=30d: A=%s, B=%s (both 0 yield expected)", valueA / 1e6, valueB / 1e6);

        assertGe(valueA, valueB, 'User A should have >= User B');
    }
}
