// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {TargetSighash} from "../Types.sol";

/// @title Events emitted by AeraVaultHooks implementation.
interface IAeraVaultHooksEvents {
    /// @notice Emitted when targetSighash is added to allowlist.
    /// @param target Address of target.
    /// @param selector Selector of function.
    event TargetSighashAdded(address indexed target, bytes4 indexed selector);

    /// @notice Emitted when targetSighash is removed from allowlist.
    /// @param target Address of target.
    /// @param selector Selector of function.
    event TargetSighashRemoved(
        address indexed target, bytes4 indexed selector
    );

    /// @notice Emitted when hooks contract is decommissioned.
    event Decommissioned();
}
