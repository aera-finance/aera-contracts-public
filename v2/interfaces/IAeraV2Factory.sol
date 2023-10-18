// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {
    AssetRegistryParameters,
    HooksParameters,
    VaultParameters
} from "../Types.sol";

/// @title IAeraV2Factory
/// @notice Interface for the V2 vault factory.
interface IAeraV2Factory {
    /// @notice Create V2 vault.
    /// @param saltInput The salt input value to generate salt.
    /// @param description Vault description.
    /// @param vaultParameters Struct details for vault deployment.
    /// @param assetRegistryParameters Struct details for asset registry deployment.
    /// @param hooksParameters Struct details for hooks deployment.
    /// @return deployedVault The address of deployed vault.
    /// @return deployedAssetRegistry The address of deployed asset registry.
    /// @return deployedHooks The address of deployed hooks.
    function create(
        bytes32 saltInput,
        string calldata description,
        VaultParameters calldata vaultParameters,
        AssetRegistryParameters memory assetRegistryParameters,
        HooksParameters memory hooksParameters
    )
        external
        returns (
            address deployedVault,
            address deployedAssetRegistry,
            address deployedHooks
        );

    /// @notice Calculate deployment address of V2 vault.
    /// @param saltInput The salt input value to generate salt.
    /// @param description Vault description.
    /// @param vaultParameters Struct details for vault deployment.
    function computeVaultAddress(
        bytes32 saltInput,
        string calldata description,
        VaultParameters calldata vaultParameters
    ) external view returns (address);

    /// @notice Returns the address of wrapped native token.
    function wrappedNativeToken() external view returns (address);

    /// @notice Returns vault parameters for vault deployment.
    /// @return owner Initial owner address.
    /// @return assetRegistry Asset registry address.
    /// @return hooks Hooks address.
    /// @return guardian Guardian address.
    /// @return feeRecipient Fee recipient address.
    /// @return fee Fees accrued per second, denoted in 18 decimal fixed point format.
    function parameters()
        external
        view
        returns (
            address owner,
            address assetRegistry,
            address hooks,
            address guardian,
            address feeRecipient,
            uint256 fee
        );
}
