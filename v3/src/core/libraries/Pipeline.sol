// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    CALLDATA_OFFSET,
    COPY_WORD_OFFSET,
    MASK_16_BIT,
    MASK_8_BIT,
    RESULTS_INDEX_OFFSET,
    WORD_SIZE
} from "src/core/Constants.sol";
import { CalldataReader } from "src/core/libraries/CalldataReader.sol";

/// @title Pipeline
/// @notice Library for handling pipeline operations that copy and paste data between operations
/// @dev Uses bit manipulation and assembly for efficient data movement
library Pipeline {
    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when trying to copy from an invalid position in source data
    error Aera__CopyOffsetOutOfBounds();
    /// @notice Thrown when trying to paste to an invalid position in target data
    error Aera__PasteOffsetOutOfBounds();

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Process pipeline operations by copying data between operations
    /// @param data The calldata to modify
    /// @param reader Current position in the calldata
    /// @param results Array of previous operation results to copy from
    /// @return Updated CalldataReader position after processing pipeline operations
    function pipe(bytes memory data, CalldataReader reader, bytes[] memory results)
        internal
        pure
        returns (CalldataReader)
    {
        uint256 clipboardCount;
        (reader, clipboardCount) = reader.readU8();

        unchecked {
            for (; clipboardCount != 0; --clipboardCount) {
                uint256 clipboard;
                (reader, clipboard) = reader.readU32();

                uint256 resultIndex = clipboard >> RESULTS_INDEX_OFFSET;
                // Check that the result index is within the results bounds
                // will Panic(uint256) revert on out of bounds index
                bytes memory result = results[resultIndex];

                uint256 copyOffset = (clipboard >> COPY_WORD_OFFSET & MASK_8_BIT) * WORD_SIZE;
                // Check that the copy offset is within the result bounds
                require(copyOffset + WORD_SIZE <= result.length, Aera__CopyOffsetOutOfBounds());

                uint256 pasteOffset = clipboard & MASK_16_BIT;
                // Check that the paste offset is within the data bounds
                require(pasteOffset + WORD_SIZE <= data.length, Aera__PasteOffsetOutOfBounds());

                uint256 operationCalldataPointer;
                uint256 resultPointer;
                assembly ("memory-safe") {
                    // Since most operations don’t enter the loop, we avoid caching
                    // operationCalldataPointer upfront to save gas
                    operationCalldataPointer := data
                    resultPointer := result
                }

                uint256 pastePointer = operationCalldataPointer + pasteOffset + CALLDATA_OFFSET;
                uint256 copyPointer = resultPointer + WORD_SIZE + copyOffset;

                assembly ("memory-safe") {
                    mcopy(pastePointer, copyPointer, WORD_SIZE)
                }
            }
        }

        return reader;
    }
}
