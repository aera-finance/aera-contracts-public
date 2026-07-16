// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { TransientSlot } from "@oz/utils/TransientSlot.sol";

import { BaseVaultDeployer } from "src/core/BaseVaultDeployer.sol";
import { FeeVaultParameters } from "src/core/Types.sol";
import { IFeeCalculator } from "src/core/interfaces/IFeeCalculator.sol";
import { IFeeVaultDeployer } from "src/core/interfaces/IFeeVaultDeployer.sol";

/// @title FeeVaultDeployer
/// @notice Helper contract for deploying fee-based vaults with single or multiple depositors
/// Does not deploy the fee vault itself or the FeeCalculator
/// @dev Stores and retrieves fee vault parameters using transient storage during deployment
abstract contract FeeVaultDeployer is IFeeVaultDeployer, BaseVaultDeployer {
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                       Constants                        //
    ////////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for storing fee vault parameters during deployment
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.factory.feeVaultParameters")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant FEE_VAULT_PARAMETERS_SLOT =
        0xe980a18a7f321cb444704cc245d4dfee0157b4ba12f1db4cab9c6992a98d2600;

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IFeeVaultDeployer
    function feeVaultParameters() external view returns (FeeVaultParameters memory params) {
        uint256 slot = uint256(FEE_VAULT_PARAMETERS_SLOT);

        unchecked {
            params.feeCalculator = IFeeCalculator(bytes32(slot).asAddress().tload());
            params.feeToken = IERC20(bytes32(++slot).asAddress().tload());
            params.feeRecipient = bytes32(++slot).asAddress().tload();
        }
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Stores fee vault parameters in transient storage
    /// @param params Struct with fee calculator, token, and recipient
    function _storeFeeVaultParameters(FeeVaultParameters calldata params) internal {
        uint256 slot = uint256(FEE_VAULT_PARAMETERS_SLOT);

        // Effects: store fee vault parameters in transient storage
        unchecked {
            bytes32(slot).asAddress().tstore(address(params.feeCalculator));
            bytes32(++slot).asAddress().tstore(address(params.feeToken));
            bytes32(++slot).asAddress().tstore(params.feeRecipient);
        }
    }
}
