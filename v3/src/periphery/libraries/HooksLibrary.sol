// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { AFTER_HOOK_MASK, BEFORE_HOOK_MASK } from "src/core/BaseVault.sol";
import { HookCallType } from "src/core/Types.sol";
import { IBaseVault } from "src/core/interfaces/IBaseVault.sol";

/// @title HooksLibrary
/// @notice Library to be used when building custom operation hooks
library HooksLibrary {
    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error HookNotBefore();
    error HookNotAfter();
    error HookNotBeforeAndAfter();

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Check if the current hook call is a before hook call
    /// @return True if the current hook call is a before hook call, false otherwise
    function isCallBeforeHook() internal view returns (bool) {
        return IBaseVault(msg.sender).getCurrentHookCallType() == HookCallType.BEFORE;
    }

    /// @notice Check if the current hook call is an after hook call
    /// @return True if the current hook call is an after hook call, false otherwise
    function isCallAfterHook() internal view returns (bool) {
        return IBaseVault(msg.sender).getCurrentHookCallType() == HookCallType.AFTER;
    }

    /// @notice Check if the provided hook is a before hook
    /// @param hook The address of the hook to check
    /// @return True if the provided hook is a before hook, false otherwise
    function isBeforeHook(address hook) internal pure returns (bool) {
        return uint160(hook) & BEFORE_HOOK_MASK != 0;
    }

    /// @notice Check if the provided hook is an after hook
    /// @param hook The address of the hook to check
    /// @return True if the provided hook is an after hook, false otherwise
    function isAfterHook(address hook) internal pure returns (bool) {
        return uint160(hook) & AFTER_HOOK_MASK != 0;
    }

    /// @notice Check if the provided hook is a before and after hook
    /// @param hook The address of the hook to check
    /// @return True if the provided hook is a before and after hook, false otherwise
    function isBeforeAndAfterHook(address hook) internal pure returns (bool) {
        return isBeforeHook(hook) && isAfterHook(hook);
    }
}
