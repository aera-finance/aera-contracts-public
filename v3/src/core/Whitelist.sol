// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EnumerableMap } from "@oz/utils/structs/EnumerableMap.sol";

import { Auth2Step, Authority } from "./Auth2Step.sol";

import { IS_WHITELISTED_FLAG } from "./Constants.sol";
import { IWhitelist } from "./interfaces/IWhitelist.sol";

/// @title Whitelist
/// @notice Contract for managing a whitelist of addresses
contract Whitelist is IWhitelist, Auth2Step {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Mapping of addresses to whether they are whitelisted
    EnumerableMap.AddressToUintMap internal whitelist;

    constructor(address initialOwner, Authority initialAuthority) Auth2Step(initialOwner, initialAuthority) { }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IWhitelist
    function setWhitelisted(address addr, bool isAddressWhitelisted) external requiresAuth {
        // Effects: set the address whitelisted status
        if (isAddressWhitelisted) {
            whitelist.set(addr, IS_WHITELISTED_FLAG);
        } else {
            whitelist.remove(addr);
        }

        // Log address whitelisted status
        emit WhitelistSet(addr, isAddressWhitelisted);
    }

    /// @inheritdoc IWhitelist
    function isWhitelisted(address addr) external view returns (bool) {
        (bool exists, uint256 value) = whitelist.tryGet(addr);
        return exists && value == IS_WHITELISTED_FLAG;
    }

    /// @inheritdoc IWhitelist
    function getAllWhitelisted() external view returns (address[] memory) {
        return whitelist.keys();
    }
}
