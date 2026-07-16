// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IVersioned
/// @notice Common interface for contracts versioning
interface IVersioned {
    /// @notice Returns the semantic version string for this contract surface
    /// @return The semantic version string
    function version() external pure returns (string memory);
}
