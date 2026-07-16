// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { SingleDepositorVault } from "src/core/SingleDepositorVault.sol";
import { IVaultDeployDelegate } from "src/core/interfaces/IVaultDeployDelegate.sol";

/// @title SingleDepositorVaultDeployDelegate
/// @notice Deploys a new SingleDepositorVault contract
/// @dev This contract is used to deploy a new SingleDepositorVault contract through a delegatecall
/// @dev It is separate from the SingleDepositorVaultFactory because of the 24kb contracts size limit
contract SingleDepositorVaultDeployDelegate is IVaultDeployDelegate {
    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IVaultDeployDelegate
    function createVault(bytes32 salt) external returns (address) {
        // Interactions: deploy the vault
        return address(new SingleDepositorVault{ salt: salt }());
    }
}
