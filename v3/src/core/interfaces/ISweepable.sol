// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ISweepable
/// @notice Interface for contracts that can recover tokens to a designated recipient
interface ISweepable {
    ////////////////////////////////////////////////////////////
    //                        Events                          //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when sweep is called
    /// @param token Token address or zero address if recovering the chain's native token
    /// @param amount Withdrawn amount of token
    event Sweep(address indexed token, uint256 amount);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when sweep of the native token has failed
    error Aera__FailedToSendNativeToken();

    ////////////////////////////////////////////////////////////
    //                        Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Withdraw any tokens accidentally sent to contract
    /// @param token Token address to withdraw or zero address for the chain's native token
    /// @param amount Amount to withdraw
    function sweep(address token, uint256 amount) external;
}
