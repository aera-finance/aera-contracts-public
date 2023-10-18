// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/Create2.sol";
import "./AeraVaultV2.sol";
import "./Sweepable.sol";
import "./interfaces/IAeraV2Factory.sol";
import "./interfaces/IAeraVaultAssetRegistryFactory.sol";
import "./interfaces/IAeraVaultHooksFactory.sol";
import {Parameters} from "./Types.sol";

/// @title AeraV2Factory
/// @notice Used to create new vaults and deploy modules.
/// @dev Only one instance of the factory will be required per chain.
contract AeraV2Factory is IAeraV2Factory, Sweepable {
    /// @notice The address of wrapped native token.
    address public immutable wrappedNativeToken;

    /// STORAGE ///

    /// @notice Vault parameters for vault deployment.
    Parameters public override parameters;

    /// EVENTS ///

    /// @notice Emitted when the vault is created.
    /// @param vault Vault address.
    /// @param assetRegistry Asset registry address.
    /// @param hooks Hooks address.
    /// @param owner Initial owner address.
    /// @param guardian Guardian address.
    /// @param feeRecipient Fee recipient address.
    /// @param fee Fees accrued per second, denoted in 18 decimal fixed point format.
    /// @param description Vault description.
    /// @param wrappedNativeToken The address of wrapped native token.
    event VaultCreated(
        address indexed vault,
        address assetRegistry,
        address hooks,
        address indexed owner,
        address indexed guardian,
        address feeRecipient,
        uint256 fee,
        string description,
        address wrappedNativeToken
    );

    /// ERRORS ///

    error Aera__DescriptionIsEmpty();
    error Aera__WrappedNativeTokenIsZeroAddress();
    error Aera__InvalidWrappedNativeToken();
    error Aera__VaultAddressMismatch(address deployed, address computed);
    error Aera__GuardianIsAssetRegistryOwner();
    error Aera__GuardianIsHooksOwner();

    /// FUNCTIONS ///

    /// @notice Initialize the factory contract.
    /// @param wrappedNativeToken_ The address of wrapped native token.
    constructor(address wrappedNativeToken_) Ownable() {
        if (wrappedNativeToken_ == address(0)) {
            revert Aera__WrappedNativeTokenIsZeroAddress();
        }
        if (wrappedNativeToken_.code.length == 0) {
            revert Aera__InvalidWrappedNativeToken();
        }
        try IERC20(wrappedNativeToken_).balanceOf(address(this)) returns (
            uint256
        ) {} catch {
            revert Aera__InvalidWrappedNativeToken();
        }

        wrappedNativeToken = wrappedNativeToken_;
    }

    /// @inheritdoc IAeraV2Factory
    function create(
        bytes32 saltInput,
        string calldata description,
        VaultParameters calldata vaultParameters,
        AssetRegistryParameters calldata assetRegistryParameters,
        HooksParameters calldata hooksParameters
    )
        external
        override
        onlyOwner
        returns (
            address deployedVault,
            address deployedAssetRegistry,
            address deployedHooks
        )
    {
        // Requirements: confirm that vault has a nonempty description.
        if (bytes(description).length == 0) {
            revert Aera__DescriptionIsEmpty();
        }

        // Requirements: check that guardian is disaffiliated from hooks/asset registry.
        if (vaultParameters.guardian == assetRegistryParameters.owner) {
            revert Aera__GuardianIsAssetRegistryOwner();
        }
        if (vaultParameters.guardian == hooksParameters.owner) {
            revert Aera__GuardianIsHooksOwner();
        }

        bytes32 salt = _calculateSalt(saltInput, vaultParameters, description);

        address computedVault = _computeVaultAddress(salt);

        // Effects: deploy asset registry.
        deployedAssetRegistry =
            _deployAssetRegistry(salt, computedVault, assetRegistryParameters);

        // Effects: deploy first instance of hooks.
        deployedHooks = _deployHooks(salt, computedVault, hooksParameters);

        // Effects: deploy the vault.
        deployedVault = _deployVault(
            salt,
            deployedAssetRegistry,
            deployedHooks,
            description,
            vaultParameters
        );

        // Invariants: check that deployed address matches computed address.
        if (deployedVault != computedVault) {
            revert Aera__VaultAddressMismatch(deployedVault, computedVault);
        }
    }

    /// @inheritdoc IAeraV2Factory
    function computeVaultAddress(
        bytes32 saltInput,
        string calldata description,
        VaultParameters calldata vaultParameters
    ) external view override returns (address) {
        return _computeVaultAddress(
            _calculateSalt(saltInput, vaultParameters, description)
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deploy asset registry.
    /// @param salt The salt value to deploy asset registry.
    /// @param vault Vault address.
    /// @param assetRegistryParameters Struct details for asset registry deployment.
    /// @return deployed The address of deployed asset registry.
    function _deployAssetRegistry(
        bytes32 salt,
        address vault,
        AssetRegistryParameters memory assetRegistryParameters
    ) internal returns (address deployed) {
        // Effects: deploy asset registry.
        deployed = IAeraVaultAssetRegistryFactory(
            assetRegistryParameters.factory
        ).deployAssetRegistry(
            salt,
            assetRegistryParameters.owner,
            vault,
            assetRegistryParameters.assets,
            assetRegistryParameters.numeraireToken,
            assetRegistryParameters.feeToken,
            assetRegistryParameters.sequencer
        );
    }

    /// @notice Deploy hooks.
    /// @param salt The salt value to deploy hooks.
    /// @param vault Vault address.
    /// @param hooksParameters Struct details for hooks deployment.
    /// @return deployed The address of deployed hooks.
    function _deployHooks(
        bytes32 salt,
        address vault,
        HooksParameters memory hooksParameters
    ) internal returns (address deployed) {
        // Effects: deploy hooks.
        deployed = IAeraVaultHooksFactory(hooksParameters.factory).deployHooks(
            salt,
            hooksParameters.owner,
            vault,
            hooksParameters.minDailyValue,
            hooksParameters.targetSighashAllowlist
        );
    }

    /// @notice Deploy V2 vault.
    /// @param salt The salt value to create vault.
    /// @param assetRegistry Asset registry address.
    /// @param hooks Hooks address.
    /// @param vaultParameters Struct details for vault deployment.
    /// @param description Vault description.
    /// @return deployed The address of deployed vault.
    function _deployVault(
        bytes32 salt,
        address assetRegistry,
        address hooks,
        string calldata description,
        VaultParameters memory vaultParameters
    ) internal returns (address deployed) {
        parameters = Parameters(
            vaultParameters.owner,
            assetRegistry,
            hooks,
            vaultParameters.guardian,
            vaultParameters.feeRecipient,
            vaultParameters.fee
        );

        // Requirements, Effects and Interactions: deploy vault with create2.
        deployed = address(new AeraVaultV2{salt: salt}());

        delete parameters;

        // Log vault creation.
        emit VaultCreated(
            deployed,
            assetRegistry,
            hooks,
            vaultParameters.owner,
            vaultParameters.guardian,
            vaultParameters.feeRecipient,
            vaultParameters.fee,
            description,
            wrappedNativeToken
        );
    }

    /// @notice Calculate deployment address of V2 vault.
    /// @param salt The salt value to create vault.
    /// @return Calculated deployment address.
    function _computeVaultAddress(bytes32 salt)
        internal
        view
        returns (address)
    {
        return Create2.computeAddress(
            salt, keccak256(type(AeraVaultV2).creationCode)
        );
    }

    /// @notice Calculate salt from vault parameters.
    /// @param saltInput The salt value to create vault.
    /// @param vaultParameters Struct details for vault deployment.
    /// @param description Vault description.
    function _calculateSalt(
        bytes32 saltInput,
        VaultParameters memory vaultParameters,
        string calldata description
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                saltInput,
                vaultParameters.owner,
                vaultParameters.guardian,
                vaultParameters.feeRecipient,
                vaultParameters.fee,
                description
            )
        );
    }
}
