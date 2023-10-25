// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "./IAssetRegistry.sol";
import "@chainlink/interfaces/AggregatorV2V3Interface.sol";

/// @title IAeraVaultAssetRegistryFactory
/// @notice Interface for the asset registry factory.
interface IAeraVaultAssetRegistryFactory {
    /// @notice Deploy asset registry.
    /// @param salt The salt value to deploy asset registry.
    /// @param owner Initial owner address.
    /// @param vault Vault address.
    /// @param assets Initial list of registered assets.
    /// @param numeraireToken Numeraire token address.
    /// @param feeToken Fee token address.
    /// @param sequencer Sequencer Uptime Feed address for L2.
    /// @return deployed The address of deployed asset registry.
    function deployAssetRegistry(
        bytes32 salt,
        address owner,
        address vault,
        IAssetRegistry.AssetInformation[] memory assets,
        IERC20 numeraireToken,
        IERC20 feeToken,
        AggregatorV2V3Interface sequencer
    ) external returns (address deployed);
}
