// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/Ownable2Step.sol";
import "@openzeppelin/SafeERC20.sol";
import "./interfaces/ISweepable.sol";

/// @title Sweepable.
/// @notice Aera Sweepable contract.
/// @dev Allows owner of the contract to restore accidentally send tokens
//       and the chain's native token.
contract Sweepable is ISweepable, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @inheritdoc ISweepable
    function sweep(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            msg.sender.call{value: amount}("");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Sweep(token, amount);
    }
}
