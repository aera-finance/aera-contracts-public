// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {TargetSighash} from "./Types.sol";

/// @title TargetSighashLib
/// @notice Conversion operations for the TargetSighash compound type.
library TargetSighashLib {
    /// @notice Get sighash from target and selector.
    /// @param target Target contract address.
    /// @param selector Function selector.
    /// @return targetSighash Packed value of target and selector.
    function toTargetSighash(
        address target,
        bytes4 selector
    ) internal pure returns (TargetSighash targetSighash) {
        targetSighash = TargetSighash.wrap(
            bytes20(target) | (bytes32(selector) >> (20 * 8))
        );
    }
}
