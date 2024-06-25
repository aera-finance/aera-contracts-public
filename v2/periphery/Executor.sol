// SPDX-License-Identifier: BUSL-1.1
// slither-disable-start unimplemented-functions
pragma solidity 0.8.21;

import "@openzeppelin/ReentrancyGuard.sol";
import "./interfaces/IExecutor.sol";
import "src/v2/Types.sol";

abstract contract Executor is IExecutor, ReentrancyGuard {
    /// FUNCTIONS ///

    /// @inheritdoc IExecutor
    function execute(Operation[] calldata operations) external nonReentrant {
        // Requirements: check operations to be executed.
        _checkOperations(operations);

        uint256 numOperations = operations.length;

        // Requirements: check that the number of operations is not zero.
        if (numOperations == 0) return;

        for (uint256 i = 0; i < numOperations;) {
            // Effects: execute operation.
            _executeOperation(operations[i]);
            unchecked {
                i++;
            } // gas savings
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Execute a single operation.
    function _executeOperation(Operation calldata operation)
        internal
        virtual
    {
        // Requirements: check the operation.
        _checkOperation(operation);

        // Interactions: execute operation.
        // slither-disable-next-line calls-loop,arbitrary-send-eth
        (bool success, bytes memory result) =
            operation.target.call{value: operation.value}(operation.data);

        // Invariants: check that the operation was successful.
        // Note: if operation.target is EOA, success will always be true.
        // It is caller responsibility to check that the operation.target is a contract.
        if (!success) {
            revert AeraPeriphery__ExecutionFailed(result);
        }

        // Log that the operation was executed.
        emit Executed(msg.sender, operation);
    }

    /// @dev Authorize the execution of operations. Intended to be marked by
    ///      `onlyOwner` or similar access control modifier.
    function _checkOperations(Operation[] calldata operations)
        internal
        view
        virtual;

    /// @dev Authorize the execution of a single operation.
    function _checkOperation(Operation calldata operation)
        internal
        view
        virtual;
}
// slither-disable-end unimplemented-functions