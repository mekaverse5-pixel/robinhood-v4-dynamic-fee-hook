// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal adapter interface for a pool's external reference price.
/// @dev `priceX18` is the human-readable amount of currency1 per one currency0,
///      normalized to 18 decimals. Adapters may expose the inverse price and let
///      the hook invert it through OracleConfig.
interface IReferencePriceOracle {
    function latestPriceX18() external view returns (uint256 priceX18, uint256 updatedAt, bool marketOpen);
}
