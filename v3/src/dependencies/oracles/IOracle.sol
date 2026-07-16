// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Implements the spec at https://eips.ethereum.org/EIPS/eip-7726
interface IOracle {
    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Returns the value of `baseAmount` of `base` in `quote` terms
    /// @dev MUST round down towards 0
    /// MUST revert with `OracleUnsupportedPair` if not capable to provide data for the specified `base`
    /// and `quote` pair
    /// MUST revert with `OracleUntrustedData` if not capable to provide data within a degree of
    /// confidence publicly specified
    /// @param baseAmount The amount of `base` to convert
    /// @param base The asset that the user needs to know the value for
    /// @param quote The asset in which the user needs to value the base
    /// @return quoteAmount The value of `baseAmount` of `base` in `quote` terms
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}
