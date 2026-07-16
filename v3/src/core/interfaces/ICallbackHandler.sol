// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICallbackHandler
/// @notice Errors used in the CallbackHandler mixin
interface ICallbackHandler {
    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when we receive a callback (or a regular call) that wasn't authorized
    error Aera__UnauthorizedCallback();
}
