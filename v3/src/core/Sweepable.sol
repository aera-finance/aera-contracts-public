// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ISweepable } from "src/core/interfaces/ISweepable.sol";

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Auth2Step } from "src/core/Auth2Step.sol";

/// @title Sweepable
/// @notice This contract allows the owner of the contract to recover accidentally sent tokens
/// and the chain's native token
abstract contract Sweepable is ISweepable, Auth2Step {
    using SafeERC20 for IERC20;

    constructor(address initialOwner, Authority initialAuthority) Auth2Step(initialOwner, initialAuthority) { }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc ISweepable
    function sweep(address token, uint256 amount) external requiresAuth {
        if (token == address(0)) {
            // Interactions: send the native token to the owner
            (bool success,) = msg.sender.call{ value: amount }("");
            // Requirements: check that the execution was successful
            require(success, Aera__FailedToSendNativeToken());
        } else {
            // Interactions: transfer the token to the owner
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        // Log the sweep event
        emit Sweep(token, amount);
    }
}
