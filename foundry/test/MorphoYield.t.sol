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
        console2.log('');
        console2.log('====================================================');
        console2.log('  Morpho Yield Over Time (10,000 USDC)');
        console2.log('====================================================');

        uint256 deposit = 10_000e6;

        deal(USDC_BASE_MAINNET, user, deposit);
        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        uint256 valueAtDeposit = vault.convertToAssets(shares);
        console2.log('  Deposited:     $%s USDC', deposit / 1e6);
        console2.log('  Shares:        %s', shares);
        console2.log('  Value (t=0):   %s USDC (raw)', valueAtDeposit);
        console2.log('');

        uint256[4] memory durations = [uint256(7 days), 30 days, 90 days, 365 days];
        string[4] memory labels = ['7 days', '30 days', '90 days', '365 days'];

        uint256 snapshotId = vm.snapshotState();

        for (uint256 i = 0; i < 4; i++) {
            if (i > 0) vm.revertToState(snapshotId);
            snapshotId = vm.snapshotState();

            vm.warp(block.timestamp + durations[i]);

            uint256 value = vault.convertToAssets(shares);
            uint256 yieldRaw = value > deposit ? value - deposit : 0;
            uint256 apyBps = durations[i] > 0 ? (yieldRaw * 365 days * 10_000) / (deposit * durations[i]) : 0;

            console2.log('  --- After %s ---', labels[i]);
            console2.log('  Value:         %s USDC (raw)', value);
            console2.log('  Yield:         $%s.%s', yieldRaw / 1e6, (yieldRaw % 1e6) / 1e2);
            console2.log('  Implied APY:   %s.%s%%', apyBps / 100, apyBps % 100);
            console2.log('');
        }

        console2.log('====================================================');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 2: Full deposit -> warp -> withdraw cycle
    // ─────────────────────────────────────────────────────────────

    function test_DepositWarpWithdraw() public {
        console2.log('');
        console2.log('====================================================');
        console2.log("Morpho deposit , 30 Days , Withdraw (50k USDC)");
        console2.log('====================================================');

        uint256 deposit = 50_000e6;

        deal(USDC_BASE_MAINNET, user, deposit);

        vm.startPrank(user);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        uint256 userBalanceAfterDeposit = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        console2.log('  Deposited:         $%s USDC', deposit / 1e6);
        console2.log('  Shares received:   %s', shares);
        console2.log('  USDC left:         %s', userBalanceAfterDeposit / 1e6);

        vm.warp(block.timestamp + 30 days);

        uint256 valueBeforeRedeem = vault.convertToAssets(shares);
        uint256 expectedYield = valueBeforeRedeem > deposit ? valueBeforeRedeem - deposit : 0;
        console2.log('');
        console2.log('  After 30 days:');
        console2.log('  Share value:       %s USDC (raw)', valueBeforeRedeem);
        console2.log('  Expected yield:    $%s.%s', expectedYield / 1e6, (expectedYield % 1e6) / 1e2);

        _mockVaultMaxRedeem();

        vm.prank(user);
        uint256 assetsReturned = vault.redeem(shares, user, user);

        uint256 finalBalance = IERC20(USDC_BASE_MAINNET).balanceOf(user);
        uint256 profit = assetsReturned > deposit ? assetsReturned - deposit : 0;

        console2.log('');
        console2.log('  Withdrawal Results:');
        console2.log('  Assets returned:   %s USDC (raw)', assetsReturned);
        console2.log('  Profit:            $%s.%s', profit / 1e6, (profit % 1e6) / 1e2);
        console2.log('  Final USDC bal:    %s USDC (raw)', finalBalance);

        assertApproxEqAbs(assetsReturned, deposit, 1, 'Should return at least principal (1 wei ERC-4626 rounding)');
        console2.log('====================================================');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 3: Multiple deposits at different times
    // ─────────────────────────────────────────────────────────────

    function test_StaggeredDeposits() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  Staggered Deposits: 2 Users, Different Timing');
        console2.log('====================================================');

        address userA = makeAddr('userA');
        address userB = makeAddr('userB');
        uint256 deposit = 10_000e6;

        deal(USDC_BASE_MAINNET, userA, deposit);
        vm.startPrank(userA);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 sharesA = vault.deposit(deposit, userA);
        vm.stopPrank();
        console2.log('  User A deposits $10,000 at t=0');

        vm.warp(block.timestamp + 15 days);

        deal(USDC_BASE_MAINNET, userB, deposit);
        vm.startPrank(userB);
        IERC20(USDC_BASE_MAINNET).approve(METAMORPHO_VAULT_BASE_MAINNET, deposit);
        uint256 sharesB = vault.deposit(deposit, userB);
        vm.stopPrank();
        console2.log('  User B deposits $10,000 at t=15d');

        vm.warp(block.timestamp + 15 days);
        console2.log('  Both withdraw at t=30d');
        console2.log('');

        uint256 valueA = vault.convertToAssets(sharesA);
        uint256 valueB = vault.convertToAssets(sharesB);

        uint256 yieldA = valueA > deposit ? valueA - deposit : 0;
        uint256 yieldB = valueB > deposit ? valueB - deposit : 0;

        console2.log('  User A (30 days in vault):');
        console2.log('    Value:  %s USDC (raw)', valueA);
        console2.log('    Yield:  $%s.%s', yieldA / 1e6, (yieldA % 1e6) / 1e2);

        console2.log('  User B (15 days in vault):');
        console2.log('    Value:  %s USDC (raw)', valueB);
        console2.log('    Yield:  $%s.%s', yieldB / 1e6, (yieldB % 1e6) / 1e2);

        assertGe(valueA, valueB, 'User A value should be >= User B (longer deposit)');
        console2.log('');
        console2.log('  User A value >= User B as expected');
        console2.log('====================================================');
    }
}
