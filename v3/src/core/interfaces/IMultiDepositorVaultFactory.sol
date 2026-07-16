// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { BaseVaultParameters, ERC20Parameters, FeeVaultParameters } from "src/core/Types.sol";
import { IBeforeTransferHook } from "src/core/interfaces/IBeforeTransferHook.sol";
import { IFeeVaultDeployer } from "src/core/interfaces/IFeeVaultDeployer.sol";

/// @title IMultiDepositorVaultFactory
/// @notice Interface for the multi depositor vault factory
interface IMultiDepositorVaultFactory is IFeeVaultDeployer {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when the vault is created
    /// @param vault Vault address
    /// @param owner Initial owner address
    /// @param hooks Vault hooks address
    /// @param erc20Params ERC20 parameters
    /// @param feeVaultParams Fee vault parameters
    /// @param beforeTransferHook Before transfer hooks
    /// @param description Vault description
    event VaultCreated(
        address indexed vault,
        address indexed owner,
        address hooks,
        ERC20Parameters erc20Params,
        FeeVaultParameters feeVaultParams,
        IBeforeTransferHook beforeTransferHook,
        string description
    );

    ////////////////////////////////////////////////////////////
    //                       Errors                           //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when deploy delegate is the zero address
    error Aera__ZeroAddressDeployDelegate();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Create multi depositor vault
    /// @param salt The salt used to generate the vault address
    /// @param description Vault description
    /// @param erc20Params ERC20 parameters for deployment
    /// @param baseVaultParams Base vault parameters for deployment
    /// @param feeVaultParams Fee vault parameters for deployment
    /// @param beforeTransferHook Before transfer hooks for deployment
    /// @param expectedVaultAddress Expected vault address to check against deployed vault address
    /// @return deployedVault Deployed vault address
    function create(
        bytes32 salt,
        string calldata description,
        ERC20Parameters calldata erc20Params,
        BaseVaultParameters calldata baseVaultParams,
        FeeVaultParameters calldata feeVaultParams,
        IBeforeTransferHook beforeTransferHook,
        address expectedVaultAddress
    ) external returns (address deployedVault);

    /// @notice Get the ERC20 name of vault units
    /// @return name The name of the vault ERC20 token
    function getERC20Name() external view returns (string memory name);

    /// @notice Get the ERC20 symbol of vault units
    /// @return symbol The symbol of the vault ERC20 token
    function getERC20Symbol() external view returns (string memory symbol);

    /// @notice Get the vault parameters
    /// @return beforeTransferHook The hooks called before vault unit transfers
    function multiDepositorVaultParameters() external view returns (IBeforeTransferHook beforeTransferHook);
}
