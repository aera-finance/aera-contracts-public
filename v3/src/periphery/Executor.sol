// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { OperationPayable } from "src/core/Types.sol";
import { IExecutor } from "src/periphery/interfaces/IExecutor.sol";

/// @title Executor
/// @notice Abstract contract for executing operations
/// @dev A similar version of this contract was previously audited
/// @dev See: https://github.com/aera-finance/aera-contracts-public/blob/main/v2/periphery/Executor.sol
abstract contract Executor is IExecutor, ReentrancyGuard {
    ////////////////////////////////////////////////////////////
    //                   External Functions                   //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IExecutor
    function execute(OperationPayable[] calldata operations) external nonReentrant {
        // Requirements: check operations to be executed
        _checkOperations(operations);

        uint256 numOperations = operations.length;

        // Requirements: check that the number of operations is not zero
        if (numOperations == 0) return;

        for (uint256 i = 0; i < numOperations; ++i) {
            // Effects: execute operation
            _executeOperation(operations[i]);
        }
    }

    ////////////////////////////////////////////////////////////
    //                   Internal Functions                   //
    ////////////////////////////////////////////////////////////

    /// @notice Execute a single operation
    /// @dev Executes the operation and reverts if it fails
    /// @param operation The operation to execute
    function _executeOperation(OperationPayable calldata operation) internal virtual {
        // Requirements: check the operation
        _checkOperation(operation);

        // Interactions: execute operation
        // slither-disable-next-line calls-loop,arbitrary-send-eth
        (bool success, bytes memory result) = operation.target.call{ value: operation.value }(operation.data);

        // Invariants: check that the operation was successful
        // Note: if operation.target is EOA, success will always be true
        // It is caller responsibility to check that the operation.target is a contract
        require(success, AeraPeriphery__ExecutionFailed(result));

        // Log that the operation was executed
        emit Executed(msg.sender, operation);
    }

    /// @notice Authorize the execution of operations
    /// @dev Intended to be marked by `onlyOwner` or similar access control modifier
    /// @param operations The operations to check
    function _checkOperations(OperationPayable[] calldata operations) internal view virtual;

    /// @notice Authorize the execution of a single operation
    /// @param operation The operation to check
    function _checkOperation(OperationPayable calldata operation) internal view virtual;
}
