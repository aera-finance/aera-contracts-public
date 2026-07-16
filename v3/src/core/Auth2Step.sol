// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { IAuth2Step } from "src/core/interfaces/IAuth2Step.sol";

/// @title Auth2Step
/// @notice An extension of Auth.sol that supports two-step ownership transfer
contract Auth2Step is IAuth2Step, Auth {
    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the pending owner
    address public pendingOwner;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    modifier onlyOwner() {
        require(msg.sender == owner, Aera__Unauthorized());
        _;
    }

    constructor(address newOwner_, Authority authority_) Auth(newOwner_, authority_) { }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IAuth2Step
    function acceptOwnership() external virtual override {
        address pendingOwner_ = pendingOwner;

        // Requirements: the caller must be the pending owner
        require(msg.sender == pendingOwner_, Aera__Unauthorized());

        // Effects: set the owner to the pending owner and delete the pending owner
        owner = pendingOwner_;
        delete pendingOwner;

        // Log the ownership transfer
        emit OwnerUpdated(msg.sender, pendingOwner_);
    }

    /// @inheritdoc IAuth2Step
    function transferOwnership(address newOwner) public virtual onlyOwner {
        // Effects: set the pending owner and emit the event
        setOwner(newOwner);
    }

    /// @notice Start the ownership transfer of the contract to a new account
    /// @param newOwner Address to transfer ownership to
    /// @dev Replaces the pending transfer if there is one
    /// @dev Overrides the `Auth` contract's `transferOwnership` function
    /// @dev Zero check is not needed because pendingOwner can always be overwritten
    function setOwner(address newOwner) public virtual override onlyOwner {
        // Effects: set the pending owner
        //slither-disable-next-line missing-zero-check
        pendingOwner = newOwner;

        // Log the ownership transfer start
        emit OwnershipTransferStarted(owner, newOwner);
    }
}
