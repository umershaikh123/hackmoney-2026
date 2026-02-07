// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SimpleYieldVault
/// @notice Minimal ERC-4626 vault that simulates yield accrual for GhostVault demos.
///         Deployed on testnets (Base Sepolia) where MetaMorpho doesn't exist.
///
/// @dev    How yield works:
///         - Tracks a weighted-average deposit time that shifts forward with each new deposit.
///         - Yield accrues from this weighted time, so new deposits don't get "free" past yield.
///         - The vault needs to be pre-funded with extra tokens to cover yield payouts.
///
///         This is NOT production code. It's a hackathon demo vault.
contract SimpleYieldVault is ERC20, IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 public immutable _asset;
    uint8 private immutable _assetDecimals;

    /// @notice Simulated APY in basis points (400 = 4.00%)
    uint256 public constant APY_BPS = 400;

    /// @notice Total assets deposited (principal only, before yield)
    uint256 public totalPrincipal;

    /// @notice Weighted-average deposit timestamp (shifts forward with new deposits)
    uint256 public weightedDepositTime;

    constructor(
        address asset_,
        uint8 assetDecimals_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        _asset = IERC20(asset_);
        _assetDecimals = assetDecimals_;
        weightedDepositTime = block.timestamp;
    }

    // ─── ERC-4626 View Functions ────────────────────────────────

    function asset() external view override returns (address) {
        return address(_asset);
    }

    function totalAssets() public view override returns (uint256) {
        if (totalPrincipal == 0) return 0;
        return totalPrincipal + _accruedYield();
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner_) external view override returns (uint256) {
        return convertToAssets(balanceOf(owner_));
    }

    function maxRedeem(address owner_) external view override returns (uint256) {
        return balanceOf(owner_);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets() + supply - 1) / supply; // round up
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply + totalAssets() - 1) / totalAssets(); // round up
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    // ─── ERC-4626 Mutative Functions ────────────────────────────

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = previewDeposit(assets);
        require(shares > 0, "zero shares");

        _asset.safeTransferFrom(msg.sender, address(this), assets);

        // Update weighted-average deposit time before adding new principal
        // newWeightedTime = (oldPrincipal * oldWeightedTime + newAssets * now) / (oldPrincipal + newAssets)
        if (totalPrincipal > 0) {
            weightedDepositTime = (totalPrincipal * weightedDepositTime + assets * block.timestamp)
                / (totalPrincipal + assets);
        } else {
            weightedDepositTime = block.timestamp;
        }

        totalPrincipal += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = previewMint(shares);

        _asset.safeTransferFrom(msg.sender, address(this), assets);

        // Update weighted-average deposit time
        if (totalPrincipal > 0) {
            weightedDepositTime = (totalPrincipal * weightedDepositTime + assets * block.timestamp)
                / (totalPrincipal + assets);
        } else {
            weightedDepositTime = block.timestamp;
        }

        totalPrincipal += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external override returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "insufficient allowance");
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        _burn(owner_, shares);
        _ensureBalance(assets);
        _asset.safeTransfer(receiver, assets);

        // Reduce principal proportionally
        uint256 principalPortion = (totalPrincipal * shares) / (totalSupply() + shares);
        totalPrincipal -= principalPortion > totalPrincipal ? totalPrincipal : principalPortion;

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external override returns (uint256 assets) {
        assets = previewRedeem(shares);

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "insufficient allowance");
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        _burn(owner_, shares);
        _ensureBalance(assets);
        _asset.safeTransfer(receiver, assets);

        // Reduce principal proportionally
        uint256 supply = totalSupply();
        uint256 principalPortion = supply > 0
            ? (totalPrincipal * shares) / (supply + shares)
            : totalPrincipal;
        totalPrincipal -= principalPortion > totalPrincipal ? totalPrincipal : principalPortion;

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ─── Internal ───────────────────────────────────────────────

    /// @dev Calculate accrued yield based on elapsed time from weighted deposit time
    function _accruedYield() internal view returns (uint256) {
        if (block.timestamp <= weightedDepositTime) return 0;
        uint256 elapsed = block.timestamp - weightedDepositTime;
        // yield = principal * APY_BPS / 10000 * elapsed / 365 days
        return (totalPrincipal * APY_BPS * elapsed) / (10_000 * 365 days);
    }

    /// @dev Ensure the vault has enough underlying tokens to pay out.
    ///      If the vault doesn't have enough (because yield is synthetic),
    ///      this is where a real vault would have earned interest.
    ///      On testnet with a mintable token, the deployer should pre-fund the vault.
    ///      We simply check and revert if underfunded.
    function _ensureBalance(uint256 needed) internal view {
        uint256 bal = _asset.balanceOf(address(this));
        require(bal >= needed, "vault underfunded: pre-fund with extra tokens to cover yield");
    }

    // ─── Admin ──────────────────────────────────────────────────

    /// @notice Pre-fund the vault with extra tokens to cover future yield payouts.
    ///         Call this after deployment: transfer tokens to the vault address.
    ///         No special function needed — just transfer tokens directly.

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _assetDecimals;
    }
}
