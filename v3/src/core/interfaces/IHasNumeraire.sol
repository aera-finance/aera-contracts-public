// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IHasNumeraire
/// @notice Interface for a contract with a numeraire token
interface IHasNumeraire {
    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__ZeroAddressNumeraire();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    // solhint-disable func-name-mixedcase
    /// @notice Get the vault's numeraire token
    /// @return The address of the numeraire token
    function NUMERAIRE() external view returns (address);
}
