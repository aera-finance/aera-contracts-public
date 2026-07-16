// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    EXTRACTION_OFFSET_SHIFT_BITS,
    EXTRACT_OFFSET_SIZE_BITS,
    MAX_EXTRACT_OFFSETS_EXCLUSIVE,
    MINIMUM_CALLDATA_LENGTH,
    SELECTOR_SIZE,
    WORD_SIZE
} from "src/core/Constants.sol";

/// @title CalldataExtractor
/// @notice Library for extracting specific chunks of calldata based on configured offsets
/// used in configurable hooks to extract 32 byte chunks from calldata and check them against
/// expected values in the merkle tree
library CalldataExtractor {
    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__ExtractionNumberTooLarge();
    error Aera__CalldataTooShort();
    error Aera__OffsetOutOfBounds();

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Extract 32-byte chunks from calldata based on config offsets
    /// @param callData The calldata to extract from
    /// @param calldataOffsetsPacked Packed 16-bit extraction offsets
    /// @param calldataOffsetsCount Number of extractions to perform
    /// @return result Concatenated byte values at specific offsets
    /// @dev Number of provided offsets must be <= 16 because that's how many fit in uint256
    /// @dev Calldata must be at least 36 bytes long to be considered valid
    /// @dev All math is unchecked because we validate everything before doing any operations
    function extract(bytes memory callData, uint256 calldataOffsetsPacked, uint256 calldataOffsetsCount)
        internal
        pure
        returns (bytes memory)
    {
        unchecked {
            // Check that the number of extractions is less than the maximum allowed
            require(calldataOffsetsCount < MAX_EXTRACT_OFFSETS_EXCLUSIVE, Aera__ExtractionNumberTooLarge());
            // Initialize result bytes array with the length being number of extractions times 32 bytes
            bytes memory result = new bytes(calldataOffsetsCount * WORD_SIZE);

            uint256 resultPtr;
            assembly ("memory-safe") {
                resultPtr := result
            }
            // Skip the dynamic array length word
            resultPtr += WORD_SIZE;

            uint256 callDataLength = callData.length;
            // Requirements: check that the calldata is at least 36 bytes long (selector + one word)
            require(callDataLength >= MINIMUM_CALLDATA_LENGTH, Aera__CalldataTooShort());

            // Max valid offset is the length of callData minus 36 bytes(selector + one word)
            uint256 maxValidOffset = callDataLength - WORD_SIZE;

            uint256 calldataPointer;
            assembly ("memory-safe") {
                calldataPointer := callData
            }
            // Skip the dynamic array length word
            calldataPointer += WORD_SIZE;

            uint256 resultWriteOffset;
            for (uint256 i = 0; i < calldataOffsetsCount; ++i) {
                uint256 extractionOffset = (calldataOffsetsPacked >> EXTRACTION_OFFSET_SHIFT_BITS) + SELECTOR_SIZE;

                // Requirements: check that the offset is within the calldata bounds
                require(extractionOffset <= maxValidOffset, Aera__OffsetOutOfBounds());

                uint256 calldataOffsetPointer = calldataPointer + extractionOffset;

                // Extract 32 bytes from calldata at offset
                // mload from callData pointer + extraction offset
                bytes32 extracted;
                assembly ("memory-safe") {
                    extracted := mload(calldataOffsetPointer)
                }

                // Store extracted value in the result
                // mstore extracted word to result pointer + current result offset
                uint256 resultOffsetPointer = resultPtr + resultWriteOffset;
                assembly ("memory-safe") {
                    mstore(resultOffsetPointer, extracted)
                }

                resultWriteOffset += WORD_SIZE;
                calldataOffsetsPacked = calldataOffsetsPacked << EXTRACT_OFFSET_SIZE_BITS;
            }

            return result;
        }
    }
}
