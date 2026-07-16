// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { BaseVaultParameters } from "src/core/Types.sol";

/// @title IBaseVaultDeployer
/// @notice Interface for vault deployer
interface IBaseVaultDeployer {
    ////////////////////////////////////////////////////////////
    //                       Errors                           //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when vault description is empty
    error Aera__DescriptionIsEmpty();

    /// @notice Thrown when deployed vault address doesn't match expected address
    /// @param deployed Address of the deployed vault
    /// @param expected Expected address of the vault
    error Aera__VaultAddressMismatch(address deployed, address expected);

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Vault parameters for vault deployment
    /// @return parameters Parameters used for vault deployment, including owner, submit hooks, and whitelist
    /// @dev Necessary to support deterministic vault deployments
    function baseVaultParameters() external view returns (BaseVaultParameters memory);
}
