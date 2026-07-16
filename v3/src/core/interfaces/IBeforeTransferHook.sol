// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IBeforeTransferHook
/// @notice Interface for token transfer hooks used for vault units in multi-depositor vaults
interface IBeforeTransferHook {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when vault unit transferability is updated
    /// @param vault The vault address
    /// @param isTransferable Whether the vault units are transferable
    event VaultUnitTransferableSet(address indexed vault, bool isTransferable);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__NotVaultOwner();
    error Aera__VaultUnitsNotTransferable(address vault);

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Set whether vault units should be transferable
    /// @param vault The vault to update status for
    /// @param isTransferable Whether the vault units are transferable
    function setIsVaultUnitsTransferable(address vault, bool isTransferable) external;

    /// @notice Perform before transfer checks
    /// @param from Address that is sending the units
    /// @param to Address that is receiving the units
    /// @param transferAgent Address that is always allowed to transfer the units
    function beforeTransfer(address from, address to, address transferAgent) external view;
}
