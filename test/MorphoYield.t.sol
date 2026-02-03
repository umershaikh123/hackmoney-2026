// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Minimal ERC-4626 interface for MetaMorpho.
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/// @title Standalone Morpho Yield Test
/// @notice Pure deposit/withdraw test against real MetaMorpho on Base mainnet fork.
///         No hooks, no Uniswap — just ERC-4626 vault interactions to verify real yield.
///
/// @dev Run with:
///   forge test --match-path test/MorphoYield.t.sol --fork-url $BASE_MAINNET_RPC -vvv
contract MorphoYieldTest is Test {
    // ── Real Base Mainnet Addresses ──
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant METAMORPHO = 0x236919F11ff9eA9550A4287696C2FC9e18E6e890; // Gauntlet USDC Frontier

    IERC4626 vault = IERC4626(METAMORPHO);
    address user = makeAddr('yieldUser');

    // ─────────────────────────────────────────────────────────────
    //  Test 1: Deposit and check yield at multiple time horizons
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit 10,000 USDC, warp through 7d/30d/90d/365d, check yield at each.
    ///         Uses convertToAssets (read-only) — no withdraw, just measuring growth.
    function test_YieldOverTime() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  Morpho Yield Over Time (10,000 USDC)');
        console2.log('====================================================');

        uint256 deposit = 10_000e6;


        deal(USDC, user, deposit);
        vm.startPrank(user);
        IERC20(USDC).approve(METAMORPHO, deposit);
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
    //  Test 2: Full deposit → warp → withdraw cycle
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit 50,000 USDC, warp 30 days, actually redeem shares, measure real return.
    function test_DepositWarpWithdraw() public {
        console2.log('');
        console2.log('====================================================');
        console2.log("Morpho deposit , 30 Days , Withdraw (50k USDC)");
        console2.log('====================================================');

        uint256 deposit = 50_000e6;


        deal(USDC, user, deposit);

        vm.startPrank(user);
        IERC20(USDC).approve(METAMORPHO, deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        uint256 userBalanceAfterDeposit = IERC20(USDC).balanceOf(user);
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

   
        uint256 redeemable = vault.maxRedeem(user);
        console2.log('');
        console2.log('  maxRedeem:         %s shares', redeemable);
        console2.log('  Our shares:        %s shares', shares);

    
        uint256 sharesToRedeem = shares < redeemable ? shares : redeemable;

        vm.prank(user);
        uint256 assetsReturned = vault.redeem(sharesToRedeem, user, user);

        uint256 finalBalance = IERC20(USDC).balanceOf(user);
        uint256 profit = assetsReturned > deposit ? assetsReturned - deposit : 0;

        console2.log('');
        console2.log('  Withdrawal Results:');
        console2.log('  Assets returned:   %s USDC (raw)', assetsReturned);
        console2.log('  Profit:            $%s.%s', profit / 1e6, (profit % 1e6) / 1e2);
        console2.log('  Final USDC bal:    %s USDC (raw)', finalBalance);

        assertGe(assetsReturned, deposit, 'Should return at least principal');
        console2.log('====================================================');
    }

    // ─────────────────────────────────────────────────────────────
    //  Test 3: Multiple deposits at different times
    // ─────────────────────────────────────────────────────────────

    /// @notice Simulate two users depositing at different times.
    ///         User A deposits 10k at t=0, User B deposits 10k at t=15d.
    ///         Both withdraw at t=30d. User A should have more yield.
    function test_StaggeredDeposits() public {
        console2.log('');
        console2.log('====================================================');
        console2.log('  Staggered Deposits: 2 Users, Different Timing');
        console2.log('====================================================');

        address userA = makeAddr('userA');
        address userB = makeAddr('userB');
        uint256 deposit = 10_000e6;

   
        deal(USDC, userA, deposit);
        vm.startPrank(userA);
        IERC20(USDC).approve(METAMORPHO, deposit);
        uint256 sharesA = vault.deposit(deposit, userA);
        vm.stopPrank();
        console2.log('  User A deposits $10,000 at t=0');

      
        vm.warp(block.timestamp + 15 days);

     
        deal(USDC, userB, deposit);
        vm.startPrank(userB);
        IERC20(USDC).approve(METAMORPHO, deposit);
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

        assertGt(yieldA, yieldB, 'User A should earn more yield (longer deposit)');
        console2.log('');
        console2.log('  User A earned more (30d vs 15d) as expected');
        console2.log('====================================================');
    }
}
