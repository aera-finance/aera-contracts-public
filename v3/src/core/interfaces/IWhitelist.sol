// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IWhitelist
/// @notice Interface for managing address whitelisting
interface IWhitelist {
    ////////////////////////////////////////////////////////////
    //                        Events                          //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when an address whitelist status is updated
    /// @param addr The address whose whitelist status is updated
    /// @param isAddressWhitelisted Whether the address is whitelisted
    event WhitelistSet(address indexed addr, bool isAddressWhitelisted);

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Set the address whitelisted status
    /// @param addr The address to add/remove from the whitelist
    /// @param isAddressWhitelisted Whether address should be whitelisted going forward
    function setWhitelisted(address addr, bool isAddressWhitelisted) external;

    /// @notice Checks if the address is whitelisted
    /// @param addr The address to check
    /// @return True if the addr is whitelisted, false otherwise
    function isWhitelisted(address addr) external view returns (bool);

    /// @notice Get all whitelisted addresses
    /// @return An array of all whitelisted addresses
    function getAllWhitelisted() external view returns (address[] memory);
}
