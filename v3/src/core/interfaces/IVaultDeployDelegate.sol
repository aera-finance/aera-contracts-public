// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IVaultDeployDelegate
/// @notice Interface for the VaultDeployDelegate
interface IVaultDeployDelegate {
    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Deploy a new vault
    /// @param salt The salt value to create vault
    /// @return deployed Deployed vault address
    function createVault(bytes32 salt) external returns (address);
}
