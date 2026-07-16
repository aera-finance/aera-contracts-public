// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title ISolvingGate
/// @notice External gate queried by Provisioner to determine whether solving is allowed
/// @dev When the gate address is zero the Provisioner treats solving as always open
///      Implementations MUST return `true` when solving is paused and `false` otherwise
interface ISolvingGate {
    /// @notice Returns true if solving is currently paused for the given Provisioner and token
    /// @param provisioner The address of the Provisioner querying the gate
    /// @param token The token for which the solve is being attempted
    /// @return True if solving is currently paused, false otherwise
    function paused(address provisioner, IERC20 token) external view returns (bool);
}
