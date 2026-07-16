// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { MultiDepositorVault } from "src/core/MultiDepositorVault.sol";
import { IVaultDeployDelegate } from "src/core/interfaces/IVaultDeployDelegate.sol";

/// @title MultiDepositorVaultDeployDelegate
/// @notice Deploys a new MultiDepositorVault contract
/// @dev This contract is used to deploy a new MultiDepositorVault contract through a delegatecall
/// @dev It is separate from the MultiDepositorVaultFactory because of the 24kb contracts size limit
contract MultiDepositorVaultDeployDelegate is IVaultDeployDelegate {
    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IVaultDeployDelegate
    function createVault(bytes32 salt) external returns (address) {
        // Interactions: deploy the vault
        return address(new MultiDepositorVault{ salt: salt }());
    }
}
