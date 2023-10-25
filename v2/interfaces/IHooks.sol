// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {AssetValue, Operation} from "../Types.sol";

/// @title IHooks
/// @notice Interface for the hooks module.
interface IHooks {
    /// @notice Get address of vault.
    /// @return vault Vault address.
    function vault() external view returns (address vault);

    /// @notice Hook that runs before deposit.
    /// @param amounts Struct details for assets and amounts to deposit.
    /// @dev MUST revert if not called by vault.
    function beforeDeposit(AssetValue[] memory amounts) external;

    /// @notice Hook that runs after deposit.
    /// @param amounts Struct details for assets and amounts to deposit.
    /// @dev MUST revert if not called by vault.
    function afterDeposit(AssetValue[] memory amounts) external;

    /// @notice Hook that runs before withdraw.
    /// @param amounts Struct details for assets and amounts to withdraw.
    /// @dev MUST revert if not called by vault.
    function beforeWithdraw(AssetValue[] memory amounts) external;

    /// @notice Hook that runs after withdraw.
    /// @param amounts Struct details for assets and amounts to withdraw.
    /// @dev MUST revert if not called by vault.
    function afterWithdraw(AssetValue[] memory amounts) external;

    /// @notice Hook that runs before submit.
    /// @param operations Array of struct details for target and calldata to submit.
    /// @dev MUST revert if not called by vault.
    function beforeSubmit(Operation[] memory operations) external;

    /// @notice Hook that runs after submit.
    /// @param operations Array of struct details for target and calldata to submit.
    /// @dev MUST revert if not called by vault.
    function afterSubmit(Operation[] memory operations) external;

    /// @notice Hook that runs before finalize.
    /// @dev MUST revert if not called by vault.
    function beforeFinalize() external;

    /// @notice Hook that runs after finalize.
    /// @dev MUST revert if not called by vault.
    function afterFinalize() external;

    /// @notice Take hooks out of use.
    function decommission() external;
}
