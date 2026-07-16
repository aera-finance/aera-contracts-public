// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IHasNumeraire } from "src/core/interfaces/IHasNumeraire.sol";

/// @title HasNumeraire
/// @notice Abstract contract for contracts with an immutable numeraire token to be used for pricing
abstract contract HasNumeraire is IHasNumeraire {
    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the numeraire token
    address public immutable NUMERAIRE;

    ////////////////////////////////////////////////////////////
    //                      Constructor                       //
    ////////////////////////////////////////////////////////////

    constructor(address numeraire_) {
        // Requirements: check that the numeraire address is not zero
        require(numeraire_ != address(0), Aera__ZeroAddressNumeraire());

        // Effects: set the numeraire address
        NUMERAIRE = numeraire_;
    }

    ////////////////////////////////////////////////////////////
    //              Internal / Private Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Get the numeraire address
    /// @return The address of the numeraire token
    function _getNumeraire() internal view virtual returns (address) {
        return NUMERAIRE;
    }
}
