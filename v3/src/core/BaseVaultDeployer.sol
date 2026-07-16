// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { TransientSlot } from "@oz/utils/TransientSlot.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { BaseVaultParameters } from "src/core/Types.sol";
import { IBaseVaultDeployer } from "src/core/interfaces/IBaseVaultDeployer.sol";
import { ISubmitHooks } from "src/core/interfaces/ISubmitHooks.sol";
import { IWhitelist } from "src/core/interfaces/IWhitelist.sol";

/// @title BaseVaultDeployer
/// @notice Base contract for deploying BaseVault and its variants
/// @dev Contains common deployment logic and parameter handling
abstract contract BaseVaultDeployer is IBaseVaultDeployer {
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                       Constants                        //
    ////////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for storing vault parameters during deployment
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.factory.baseVaultParameters")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant BASE_VAULT_PARAMETERS_SLOT =
        0xabbb07a7c84c47d0cde2038aa28d3c5b29638876472dc0cdc3a2448d1e4b7e00;

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IBaseVaultDeployer
    function baseVaultParameters() external view returns (BaseVaultParameters memory params) {
        uint256 slot = uint256(BASE_VAULT_PARAMETERS_SLOT);

        unchecked {
            params.owner = bytes32(slot).asAddress().tload();
            params.authority = Authority(bytes32(++slot).asAddress().tload());
            params.submitHooks = ISubmitHooks(bytes32(++slot).asAddress().tload());
            params.whitelist = IWhitelist(bytes32(++slot).asAddress().tload());
        }
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Store parameters in transient storage
    /// @param params The parameters to store
    function _storeBaseVaultParameters(BaseVaultParameters calldata params) internal {
        uint256 slot = uint256(BASE_VAULT_PARAMETERS_SLOT);

        unchecked {
            bytes32(slot).asAddress().tstore(params.owner);
            bytes32(++slot).asAddress().tstore(address(params.authority));
            bytes32(++slot).asAddress().tstore(address(params.submitHooks));
            bytes32(++slot).asAddress().tstore(address(params.whitelist));
        }
    }
}
