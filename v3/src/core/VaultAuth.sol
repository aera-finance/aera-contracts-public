// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Auth } from "@solmate/auth/Auth.sol";

/// @title VaultAuth
/// @notice Abstract contract that provides authorization check for vault operations
/// @dev Used by contracts that need to verify if a caller has permission to perform vault-specific actions. The
/// authorization can come from either being the vault owner or having explicit permission through the vault's authority
abstract contract VaultAuth {
    ////////////////////////////////////////////////////////////
    //                        Errors                          //
    ////////////////////////////////////////////////////////////

    error Aera__CallerIsNotAuthorized();

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    modifier requiresVaultAuth(address vault) {
        // Requirements: check that the caller is either the vault owner or has permission to call the function
        require(
            msg.sender == Auth(vault).owner() || Auth(vault).authority().canCall(msg.sender, address(this), msg.sig),
            Aera__CallerIsNotAuthorized()
        );
        _;
    }
}
