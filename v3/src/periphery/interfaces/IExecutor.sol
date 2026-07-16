// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OperationPayable } from "src/core/Types.sol";

/// @title IExecutor
/// @notice Interface for executing operations
/// @dev A similar version of this interface was previously audited
/// @dev See: https://github.com/aera-finance/aera-contracts-public/blob/main/v2/periphery/interfaces/IExecutor.sol
interface IExecutor {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when operations are executed
    /// @param caller The address that executed the operation
    /// @param operation The operation that was executed
    event Executed(address indexed caller, OperationPayable operation);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Error emitted when the execution of an operation fails
    /// @param result The error bytes returned from the failed operation
    error AeraPeriphery__ExecutionFailed(bytes result);

    ////////////////////////////////////////////////////////////
    //                   External Functions                   //
    ////////////////////////////////////////////////////////////

    /// @notice Execute arbitrary actions
    /// @param operations The operations to execute
    function execute(OperationPayable[] calldata operations) external;
}
