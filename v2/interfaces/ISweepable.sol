// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

/// @title Interface for sweepable module.
interface ISweepable {
    /// @notice Emitted when sweep is called.
    /// @param token Token address or zero address if recovering the chain's native token.
    /// @param amount Withdrawn amount of token.
    event Sweep(address token, uint256 amount);

    /// @notice Withdraw any tokens accidentally sent to contract.
    /// @param token Token address to withdraw or zero address for the chain's native token.
    /// @param amount Amount to withdraw.
    function sweep(address token, uint256 amount) external;
}
