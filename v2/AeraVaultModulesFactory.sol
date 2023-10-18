// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/IERC20.sol";
import "./AeraVaultAssetRegistry.sol";
import "./AeraVaultHooks.sol";
import "./Sweepable.sol";
import "./interfaces/IAeraV2Factory.sol";
import "./interfaces/IAeraVaultAssetRegistryFactory.sol";
import "./interfaces/IAeraVaultHooksFactory.sol";

/// @title AeraVaultModulesFactory
/// @notice Used to create new asset registry and hooks.
/// @dev Only one instance of the factory will be required per chain.
contract AeraVaultModulesFactory is
    IAeraVaultAssetRegistryFactory,
    IAeraVaultHooksFactory,
    Sweepable
{
    /// @notice The address of the v2 factory.
    address public immutable v2Factory;

    /// @notice Wrapped native token.
    IERC20 public immutable wrappedNativeToken;

    /// EVENTS ///

    /// @notice Emitted when the asset registry is created.
    /// @param assetRegistry Asset registry address.
    /// @param vault Vault address.
    /// @param owner Initial owner address.
    /// @param assets Initial list of registered assets.
    /// @param numeraireToken Numeraire token address.
    /// @param feeToken Fee token address.
    /// @param wrappedNativeToken Wrapped native token address.
    /// @param sequencer Sequencer Uptime Feed address for L2.
    event AssetRegistryCreated(
        address indexed assetRegistry,
        address indexed vault,
        address indexed owner,
        IAssetRegistry.AssetInformation[] assets,
        IERC20 numeraireToken,
        IERC20 feeToken,
        IERC20 wrappedNativeToken,
        AggregatorV2V3Interface sequencer
    );

    /// @notice Emitted when the hooks is created.
    /// @param hooks Hooks address.
    /// @param vault Vault address.
    /// @param owner Initial owner address.
    /// @param minDailyValue The minimum fraction of value that the vault has to retain
    ///                      during the day in the course of submissions.
    /// @param targetSighashAllowlist Array of target contract and sighash combinations to allow.
    event HooksCreated(
        address indexed hooks,
        address indexed vault,
        address indexed owner,
        uint256 minDailyValue,
        TargetSighashData[] targetSighashAllowlist
    );

    /// MODIFIERS ///

    error Aera_CallerIsNeitherOwnerOrV2Factory();
    error Aera__V2FactoryIsZeroAddress();

    /// MODIFIERS ///

    /// @dev Throws if called by any account other than the owner or v2 factory.
    modifier onlyOwnerOrV2Factory() {
        if (msg.sender != owner() && msg.sender != v2Factory) {
            revert Aera_CallerIsNeitherOwnerOrV2Factory();
        }
        _;
    }

    /// FUNCTIONS ///

    constructor(address v2Factory_) Ownable() {
        if (v2Factory_ == address(0)) {
            revert Aera__V2FactoryIsZeroAddress();
        }

        wrappedNativeToken =
            IERC20(IAeraV2Factory(v2Factory_).wrappedNativeToken());

        v2Factory = v2Factory_;
    }

    /// @inheritdoc IAeraVaultAssetRegistryFactory
    function deployAssetRegistry(
        bytes32 salt,
        address owner_,
        address vault,
        IAssetRegistry.AssetInformation[] memory assets,
        IERC20 numeraireToken,
        IERC20 feeToken,
        AggregatorV2V3Interface sequencer
    ) external override onlyOwnerOrV2Factory returns (address deployed) {
        // Effects: deploy asset registry.
        deployed = address(
            new AeraVaultAssetRegistry{salt: salt}(
                owner_,
                vault,
                assets,
                numeraireToken,
                feeToken,
                wrappedNativeToken,
                sequencer
            )
        );

        // Log asset registry creation.
        emit AssetRegistryCreated(
            deployed,
            vault,
            owner_,
            assets,
            numeraireToken,
            feeToken,
            wrappedNativeToken,
            sequencer
        );
    }

    /// @inheritdoc IAeraVaultHooksFactory
    function deployHooks(
        bytes32 salt,
        address owner_,
        address vault,
        uint256 minDailyValue,
        TargetSighashData[] memory targetSighashAllowlist
    ) external override onlyOwnerOrV2Factory returns (address deployed) {
        // Effects: deploy hooks.
        deployed = address(
            new AeraVaultHooks{salt:salt}(
                owner_,
                vault,
                minDailyValue,
                targetSighashAllowlist
            )
        );

        // Log hooks creation.
        emit HooksCreated(
            deployed, vault, owner_, minDailyValue, targetSighashAllowlist
        );
    }
}
