// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from 'solmate/src/mixins/ERC4626.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @notice Minimal concrete ERC-4626 vault backed by solmate's real implementation.
/// @dev Uses `asset.balanceOf(address(this))` for `totalAssets()`, so yield
///      can be simulated by minting underlying tokens directly to this contract.
contract TestVault is ERC4626 {
    constructor(ERC20 _asset) ERC4626(_asset, 'Test Vault', 'tVAULT') {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
