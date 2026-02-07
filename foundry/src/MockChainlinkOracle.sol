// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from '@chainlink/interfaces/feeds/AggregatorV3Interface.sol';

/// @title MockChainlinkOracle
/// @notice Mock Chainlink price feed for GhostVault demos.
///         Allows setting price via cast commands. Always returns fresh `updatedAt`.
///
/// @dev    Usage with cast:
///         # Set price to $2500 (8 decimals)
///         cast send $ORACLE "setPrice(int256)" 250000000000 --private-key $PK --rpc-url $RPC
///
///         # Read current price
///         cast call $ORACLE "latestRoundData()" --rpc-url $RPC
contract MockChainlinkOracle is AggregatorV3Interface {
    int256 public price;
    uint8 public constant DECIMALS = 8;
    string public constant DESCRIPTION = "Mock ETH/USD";
    uint256 public constant VERSION = 1;

    /// @notice Initialize with a default price ($3000 with 8 decimals)
    constructor(int256 _initialPrice) {
        price = _initialPrice;
    }

    /// @notice Set the price (anyone can call - this is a demo mock)
    /// @param _price New price in 8 decimal format (e.g., 3000_00000000 for $3000)
    function setPrice(int256 _price) external {
        price = _price;
    }

    /// @notice Returns the current price data
    /// @dev `updatedAt` is always `block.timestamp` so the oracle is never stale
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (
            1,                      // roundId
            price,                  // answer (the price)
            block.timestamp,        // startedAt
            block.timestamp,        // updatedAt - ALWAYS FRESH
            1                       // answeredInRound
        );
    }

    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    function description() external pure override returns (string memory) {
        return DESCRIPTION;
    }

    function version() external pure override returns (uint256) {
        return VERSION;
    }

    // Legacy function for older interfaces
    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
