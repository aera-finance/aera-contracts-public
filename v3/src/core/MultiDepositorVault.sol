// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { ERC20 } from "@oz/token/ERC20/ERC20.sol";

import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { FeeVault } from "src/core/FeeVault.sol";

import { IBeforeTransferHook } from "src/core/interfaces/IBeforeTransferHook.sol";
import { IMultiDepositorVault } from "src/core/interfaces/IMultiDepositorVault.sol";
import { IMultiDepositorVaultFactory } from "src/core/interfaces/IMultiDepositorVaultFactory.sol";
import { IProvisionerV2 } from "src/core/interfaces/IProvisionerV2.sol";

/// @title MultiDepositorVault
/// @notice A vault that allows users to deposit and withdraw multiple tokens. This contract just mints and burns unit
/// tokens and all logic and validation is handled by the provisioner
contract MultiDepositorVault is IMultiDepositorVault, ERC20, FeeVault {
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Hooks contract called before unit transfers/mints/burns
    IBeforeTransferHook public beforeTransferHook;

    /// @notice Role that can mint/burn vault units
    address public provisioner;

    /// @notice Ensures caller is the provisioner
    modifier onlyProvisioner() {
        // Requirements: check that the caller is the provisioner
        require(msg.sender == provisioner, Aera__CallerIsNotProvisioner());
        _;
    }

    ////////////////////////////////////////////////////////////
    //                      Constructor                       //
    ////////////////////////////////////////////////////////////

    constructor()
        ERC20(
            IMultiDepositorVaultFactory(msg.sender).getERC20Name(),
            IMultiDepositorVaultFactory(msg.sender).getERC20Symbol()
        )
    {
        // Interactions: get the before transfer hook contract
        IBeforeTransferHook beforeTransferHook_ =
            IMultiDepositorVaultFactory(msg.sender).multiDepositorVaultParameters();

        // Effects: set the before transfer hook contract
        _setBeforeTransferHook(beforeTransferHook_);
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IMultiDepositorVault
    function enter(address sender, IERC20 token, uint256 tokenAmount, uint256 unitsAmount, address recipient)
        external
        whenNotPaused
        onlyProvisioner
    {
        // Interactions: pull tokens from the sender
        if (tokenAmount > 0) token.safeTransferFrom(sender, address(this), tokenAmount);

        // Effects: mint units to the recipient
        _mint(recipient, unitsAmount);

        // Log the enter event
        emit Enter(sender, recipient, token, tokenAmount, unitsAmount);
    }

    /// @inheritdoc IMultiDepositorVault
    function exit(address sender, IERC20 token, uint256 tokenAmount, uint256 unitsAmount, address recipient)
        external
        whenNotPaused
        onlyProvisioner
    {
        // Effects: burn units from the sender
        _burn(sender, unitsAmount);

        // Interactions: transfer tokens to the recipient
        if (tokenAmount > 0) token.safeTransfer(recipient, tokenAmount);

        // Log the exit event
        emit Exit(sender, recipient, token, tokenAmount, unitsAmount);
    }

    /// @notice Sets the provisioner address
    /// @param provisioner_ The new provisioner address
    function setProvisioner(address provisioner_) external requiresAuth {
        // Effects: set the provisioner
        _setProvisioner(provisioner_);
    }

    /// @inheritdoc IMultiDepositorVault
    function setBeforeTransferHook(IBeforeTransferHook hook) external requiresAuth {
        // Effects: set the transfer hook
        _setBeforeTransferHook(hook);
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Internal function to update token balances with transfer hook checks
    /// @param from The address tokens are transferred from
    /// @param to The address tokens are transferred to
    /// @param amount The amount of tokens to transfer
    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 amount) internal override {
        IBeforeTransferHook hook = beforeTransferHook;
        if (address(hook) != address(0)) {
            // Requirements: perform before transfer checks
            hook.beforeTransfer(from, to, provisioner);
        }

        // Requirements: check that the from address does not have its units locked
        // from == address(0) is to allow minting further units for user with locked units
        // to == address(0) is to allow burning units in refundDeposit
        require(
            from == address(0) || to == address(0) || !IProvisionerV2(provisioner).areUserUnitsLocked(from),
            Aera__UnitsLocked()
        );

        // Effects: transfer the tokens
        return super._update(from, to, amount);
    }

    /// @notice Set the transfer hook
    /// @param hook_ The transfer hook address
    function _setBeforeTransferHook(IBeforeTransferHook hook_) internal {
        // Effects: set the transfer hook contract
        beforeTransferHook = hook_;

        // Log that the transfer hook contract has been set
        emit BeforeTransferHookSet(address(hook_));
    }

    /// @notice Set the provisioner
    /// @param provisioner_ The provisioner address
    function _setProvisioner(address provisioner_) internal {
        // Requirements: check that the provisioner is not zero
        require(provisioner_ != address(0), Aera__ZeroAddressProvisioner());

        // Effects: set the provisioner
        provisioner = provisioner_;

        // Log that provisioner was set
        emit ProvisionerSet(provisioner_);
    }
}
