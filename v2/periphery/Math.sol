// SPDX-License-Identifier: MIT
// slither-disable-start dead-code
pragma solidity 0.8.21;

library Math {
    /// @dev Multiply two quantities, then divide by a third.
    ///      Copied from solmate FixedPointMathLib.
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        // slither-disable-next-line assembly
        assembly {
            // Store x * y in z for now.
            z := mul(x, y)

            // Equivalent to require(denominator != 0 && (x == 0 || (x * y) / x == y))
            if iszero(
                and(
                    iszero(iszero(denominator)),
                    or(iszero(x), eq(div(z, x), y))
                )
            ) { revert(0, 0) }

            // Divide z by the denominator.
            z := div(z, denominator)
        }
    }
}
// slither-disable-end dead-code