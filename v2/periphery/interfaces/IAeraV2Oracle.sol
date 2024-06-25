// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/// @title IAeraV2Oracle
/// @notice Used to calculate price of ERC20 tokens using the same interface as Chainlink.
interface IAeraV2Oracle {
    /// @notice The decimals returned from the answer in latestRoundData.
    function decimals() external view returns (uint8);

    /// @notice Returns the latest price.
    /// @return roundId Optional, doesn't apply to non-Chainlink oracles.
    /// @return answer The price.
    /// @return startedAt Optional, doesn't apply to non-Chainlink oracles.
    /// @return updatedAt The most recent timestamp the price was updated
    /// @return answeredInRound Optional, doesn't apply to non-Chainlink oracles.
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}