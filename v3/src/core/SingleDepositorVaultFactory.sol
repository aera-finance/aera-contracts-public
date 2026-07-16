// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Address } from "@oz/utils/Address.sol";
import { TransientSlot } from "@oz/utils/TransientSlot.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { FeeVaultDeployer } from "src/core/FeeVaultDeployer.sol";
import { Sweepable } from "src/core/Sweepable.sol";
import { BaseVaultParameters, FeeVaultParameters } from "src/core/Types.sol";
import { ISingleDepositorVaultFactory } from "src/core/interfaces/ISingleDepositorVaultFactory.sol";
import { IVaultDeployDelegate } from "src/core/interfaces/IVaultDeployDelegate.sol";

/// @title SingleDepositorVaultFactory
/// @notice Used to create new vaults
/// @dev Only one instance of the factory will be required per chain
contract SingleDepositorVaultFactory is ISingleDepositorVaultFactory, FeeVaultDeployer, Sweepable {
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the deploy delegate
    address internal immutable _DEPLOY_DELEGATE;

    constructor(address initialOwner, Authority initialAuthority, address deployDelegate)
        Sweepable(initialOwner, initialAuthority)
    {
        // Requirements: check that deploy delegate is not the zero address
        require(deployDelegate != address(0), Aera__ZeroAddressDeployDelegate());

        // Effects: store deploy delegate
        _DEPLOY_DELEGATE = deployDelegate;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc ISingleDepositorVaultFactory
    function create(
        bytes32 salt,
        string calldata description,
        BaseVaultParameters calldata baseVaultParams,
        FeeVaultParameters calldata singleDepositorVaultParams,
        address expectedVaultAddress
    ) external override requiresAuth returns (address deployedVault) {
        // Requirements: confirm that vault has a nonempty description
        require(bytes(description).length != 0, Aera__DescriptionIsEmpty());

        // Effects: deploy the vault
        deployedVault = _deployVault(salt, description, baseVaultParams, singleDepositorVaultParams);

        // Invariants: check that deployed address matches expected address
        require(deployedVault == expectedVaultAddress, Aera__VaultAddressMismatch(deployedVault, expectedVaultAddress));
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Deploy vault
    /// @param salt The salt value to create vault
    /// @param description Vault description
    /// @param baseVaultParams Parameters for vault deployment used in BaseVault
    /// @param singleDepositorVaultParams Parameters for vault deployment specific to SingleDepositorVault
    /// @return deployed Deployed vault address
    function _deployVault(
        bytes32 salt,
        string calldata description,
        BaseVaultParameters calldata baseVaultParams,
        FeeVaultParameters calldata singleDepositorVaultParams
    ) internal returns (address deployed) {
        // Effects: store parameters in transient storage
        _storeBaseVaultParameters(baseVaultParams);
        _storeFeeVaultParameters(singleDepositorVaultParams);

        // Interactions: deploy vault with create2
        deployed = _createVault(salt);

        // Log vault creation
        emit VaultCreated(
            deployed,
            baseVaultParams.owner,
            address(baseVaultParams.submitHooks),
            singleDepositorVaultParams.feeToken,
            singleDepositorVaultParams.feeCalculator,
            singleDepositorVaultParams.feeRecipient,
            description
        );
    }

    /// @notice Create a new vault with delegate call
    /// @param salt The salt value to create vault
    /// @return deployed Deployed vault address
    function _createVault(bytes32 salt) internal returns (address deployed) {
        // Interactions: create vault with delegate call
        bytes memory data =
            Address.functionDelegateCall(_DEPLOY_DELEGATE, abi.encodeCall(IVaultDeployDelegate.createVault, (salt)));

        deployed = abi.decode(data, (address));
    }
}
