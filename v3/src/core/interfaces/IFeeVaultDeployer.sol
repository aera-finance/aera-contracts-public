// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { FeeVaultParameters } from "src/core/Types.sol";
import { IBaseVaultDeployer } from "src/core/interfaces/IBaseVaultDeployer.sol";

/// @title IFeeVaultDeployer
/// @notice Interface for the fee vault deployer
interface IFeeVaultDeployer is IBaseVaultDeployer {
    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Get the deployment parameters for the fee vault
    /// @return params Deployment parameters for the fee vault
    function feeVaultParameters() external view returns (FeeVaultParameters memory params);
}
