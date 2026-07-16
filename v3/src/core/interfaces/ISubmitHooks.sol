// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ISubmitHooks
/// @notice Interface for hooks that execute before and after submit calls
interface ISubmitHooks {
    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Called before a submit
    /// @param data Encoded data of the submit
    /// @param guardian Address of the guardian that submitted
    function beforeSubmit(bytes memory data, address guardian) external;

    /// @notice Called after a submit
    /// @param data Encoded data of the submit
    /// @param guardian Address of the guardian that submitted
    function afterSubmit(bytes memory data, address guardian) external;
}
