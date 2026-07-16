// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Authority } from "@solmate/auth/Auth.sol";
import { BaseVault } from "src/core/BaseVault.sol";
import { Sweepable } from "src/core/Sweepable.sol";
import { BaseVaultParameters } from "src/core/Types.sol";
import { IBaseVaultFactory } from "src/core/interfaces/IBaseVaultFactory.sol";

import { BaseVaultDeployer } from "src/core/BaseVaultDeployer.sol";

/// @title BaseVaultFactory
/// @notice Used to deploy new BaseVault instances
/// @dev Only one instance of the factory will be required per chain
contract BaseVaultFactory is IBaseVaultFactory, BaseVaultDeployer, Sweepable {
    constructor(address initialOwner, Authority initialAuthority) Sweepable(initialOwner, initialAuthority) { }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IBaseVaultFactory
    function create(
        bytes32 salt,
        string calldata description,
        BaseVaultParameters calldata baseVaultParams,
        address expectedVaultAddress
    ) external override requiresAuth returns (address deployedVault) {
        // Requirements: confirm that vault has a nonempty description
        require(bytes(description).length != 0, Aera__DescriptionIsEmpty());

        // Effects: deploy the vault
        deployedVault = _deployVault(salt, description, baseVaultParams);

        // Invariants: check that deployed address matches expected address
        require(deployedVault == expectedVaultAddress, Aera__VaultAddressMismatch(deployedVault, expectedVaultAddress));
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Deploy vault
    /// @param salt The salt value to create vault
    /// @param description Vault description
    /// @param baseVaultParams Parameters for vault deployment
    /// @return deployed The address of deployed vault
    function _deployVault(bytes32 salt, string calldata description, BaseVaultParameters calldata baseVaultParams)
        internal
        returns (address deployed)
    {
        // Effects: store parameters in transient storage
        _storeBaseVaultParameters(baseVaultParams);

        // Interactions: deploy vault with create2
        deployed = address(new BaseVault{ salt: salt }());

        // Log vault creation
        emit VaultCreated(deployed, baseVaultParams.owner, address(baseVaultParams.submitHooks), description);
    }
}
