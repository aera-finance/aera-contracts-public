// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { TransientSlot } from "@oz/utils/TransientSlot.sol";

import { ADDRESS_SIZE_BITS, CALLBACK_DATA_OFFSET, NO_CALLBACK_DATA, SELECTOR_OFFSET } from "src/core/Constants.sol";
import { Approval } from "src/core/Types.sol";
import { ICallbackHandler } from "src/core/interfaces/ICallbackHandler.sol";

/// @title CallbackHandler
/// @notice Handles callback validation and execution for vault operations. This contract is designed to be
/// used as a mixin in BaseVault, providing the ability to register logic for safely handling callbacks during
/// guardian submissions. A common use case for handlers is receiving a flash loan. To receive a flashloan, the vault
/// has to cede control when requesting a flashloan and then atomically handle the callback to repay the flashloan
/// This requires two capabilities: the ability to register new handlers and the ability to initiate additional
/// operations in the handle while being restricted by the merkle tree constraints. The callback handler contract
/// achieves this by allowing guardians to "prepare" for a callback when they construct a given operation. If the
/// operation "has a callback" then the fallback function in this contract will handle it. It will use transient storage
/// to preserve information such as the expected callback caller, function selector of the callback and any
/// approvals that are created during the callback
/// @dev Uses transient storage to manage callback state and approvals

abstract contract CallbackHandler is ICallbackHandler {
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                       Constants                        //
    ////////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for storing the next authorized selector + caller
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.callbackHandler.call")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    /// @custom:security Critical for callback validation
    bytes32 internal constant CALLBACK_CALL_SLOT = 0xa48fd101fc9f41f09dc754b3b14722487070ffbd61259b49558564a3296a3f00;

    /// @notice ERC7201-compliant transient storage slot for storing the callback merkle root
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.callbackHandler.merkleRoot")) - 1) &
    ///      ~bytes32(uint256(0xff));
    /// @custom:security Critical for callback validation
    bytes32 internal constant CALLBACK_MERKLE_ROOT_SLOT =
        0x30fb041442610fd0a22e4654f60ea1c715088ef7320b5ec0c4e75cbdd99dbe00;

    /// @notice ERC7201-compliant transient storage slot for storing the approval tracking
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.callbackHandler.approvals")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    /// @custom:security Critical for tracking token approvals during callbacks
    bytes32 internal constant APPROVALS_SLOT = 0xba2cfcc1b17a97110b1fb218b61c42c0e510c6913e669a69d4ade619ace66c00;

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @notice Handle incoming callbacks and validates their authorization
    /// @dev Extracts callback data and forwards to _handleCallbackOperations if valid
    fallback(bytes calldata) external returns (bytes memory returnValue) {
        (address caller, bytes4 selector, uint16 userDataOffset) = _getAllowedCallback();
        // Requirements: check that the selector matches
        require(msg.sig == selector, Aera__UnauthorizedCallback());
        // Requirements: check that the caller matches
        require(msg.sender == caller, Aera__UnauthorizedCallback());

        bytes32 root = _getAllowedMerkleRoot();
        // Requirements: check that the merkle root is not zero
        require(root != bytes32(0), Aera__UnauthorizedCallback());

        // If NO_CALLBACK_DATA magic value is sent, we don't need to return anything
        if (userDataOffset == NO_CALLBACK_DATA) return bytes("");

        // Effects, Interactions: handle callback operations
        returnValue = _handleCallbackOperations(root, userDataOffset);
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Internal handler for validated callbacks
    /// @dev Callback operations are like regular operations, but with a return value, which are encoded after
    /// operations array
    /// ┌─────────────────────────────┬─────────────────────────┬───────────────────────────────────────────────┐
    /// │ FIELDS                      │ SIZE                    │ DESCRIPTION                                   │
    /// ├─────────────────────────────┴─────────────────────────┴───────────────────────────────────────────────┤
    /// │  returnTypeFlag              1 byte                     0 = no return, 1 = static, 2 = dynamic        │
    /// │  [if returnTypeFlag == 1]:                                                                            │
    /// │     returnDataLength         2 bytes                    Length of return data                         │
    /// │     returnData               <returnDataLength> bytes   Static return data                            │
    /// └───────────────────────────────────────────────────────────────────────────────────────────────────────┘
    /// @param root The merkle root of the callback
    /// @param cursor The cursor to the callback data
    /// @return returnValue The return value of the callback
    function _handleCallbackOperations(bytes32 root, uint256 cursor)
        internal
        virtual
        returns (bytes memory returnValue);

    /// @notice Whitelist a function selector and caller as a valid callback
    /// @dev Uses transient storage to store the callback data
    /// @param root The merkle root of the callback
    /// @param packedCallbackData Packed data containing caller, selector, and offsets
    function _allowCallback(bytes32 root, uint256 packedCallbackData) internal {
        // Effects: store the callback data
        CALLBACK_CALL_SLOT.asUint256().tstore(packedCallbackData);

        // Effects: store the merkle root
        CALLBACK_MERKLE_ROOT_SLOT.asBytes32().tstore(root);
    }

    /// @notice Store approvals for the current callback context
    /// @param approvals Array of token approvals to store
    /// @param length Length of the array
    /// @dev Uses transient storage to track approvals during callback execution
    /// @dev Length of the array, packed with the token address will be stored in the first slot
    /// @dev All other elements are laid out sequentially after the first slot, taking 2 slots per approval
    /// @dev If there are existing approvals, we will update length in the slot zero and append new approvals
    function _storeCallbackApprovals(Approval[] memory approvals, uint256 length) internal {
        if (length == 0) return;

        uint256 existingApproval = APPROVALS_SLOT.asUint256().tload();
        uint256 existingLength = existingApproval >> ADDRESS_SIZE_BITS;

        uint256 i;
        uint256 currentSlot = uint256(APPROVALS_SLOT);
        Approval memory approval;
        if (existingLength == 0) {
            approval = approvals[0];
            unchecked {
                // Effects: store the token and spender
                /// @dev Store packed token and length in the zero slot, and spender in the second
                bytes32(currentSlot).asUint256().tstore(_packLengthAndToken(length, approval.token));
                bytes32(++currentSlot).asAddress().tstore(approval.spender);
            }

            i = 1;
        } else {
            unchecked {
                uint256 newLength = existingLength + length;
                // Effects: store the token and spender
                /// @dev Update the length and preserve the token in the zero slot
                bytes32(currentSlot).asUint256().tstore(
                    _packLengthAndToken(newLength, address(uint160(existingApproval)))
                );
                /// Minus one to compensate for pre-increment in upcoming storage loop
                currentSlot += existingLength * 2 - 1;
            }
        }

        for (; i < length; ++i) {
            approval = approvals[i];
            unchecked {
                // Effects: store the token and spender
                bytes32(++currentSlot).asAddress().tstore(approval.token);
                bytes32(++currentSlot).asAddress().tstore(approval.spender);
            }
        }
    }

    /// @notice Retrieve the currently allowed callback data
    /// @dev Unpacks data from transient storage
    /// @return caller The authorized caller address
    /// @return selector The authorized function selector
    /// @return userDataOffset The offset in calldata where user data begins
    /// @custom:security Critical for callback validation
    function _getAllowedCallback() internal returns (address caller, bytes4 selector, uint16 userDataOffset) {
        (caller, selector, userDataOffset) = _unpackCallbackData(CALLBACK_CALL_SLOT.asUint256().tload());

        // Effects: clear the transient storage slot
        CALLBACK_CALL_SLOT.asUint256().tstore(0);
    }

    /// @notice Retrieves the currently allowed merkle root
    /// @dev Unpacks data from transient storage
    /// @return root The authorized merkle root
    /// @custom:security Critical for callback validation
    function _getAllowedMerkleRoot() internal returns (bytes32 root) {
        root = CALLBACK_MERKLE_ROOT_SLOT.asBytes32().tload();
        // Effects: clear the merkle root slot
        CALLBACK_MERKLE_ROOT_SLOT.asBytes32().tstore(bytes32(0));
    }

    /// @notice Retrieves the current callback approvals
    /// @dev Decodes approvals from transient storage
    /// @return approvals Array of current token approvals
    /// @dev The first slot contains the length of the array, packed with the token address
    /// @dev All other elements are laid out sequentially after the first slot, taking 2 slots per approval
    /// @dev Only length slot is cleared, the rest of the approvals are left in the transient storage
    /// @dev This is safe because even if new approvals are added, old ones will be overwritten for length slots
    function _getCallbackApprovals() internal returns (Approval[] memory approvals) {
        uint256 lengthWithToken = APPROVALS_SLOT.asUint256().tload();
        uint256 length = lengthWithToken >> ADDRESS_SIZE_BITS;
        if (length == 0) return approvals;

        // Effects: clear the approvals length slot
        APPROVALS_SLOT.asUint256().tstore(0);

        approvals = new Approval[](length);

        address token = address(uint160(lengthWithToken));

        uint256 slotUint256 = uint256(APPROVALS_SLOT);
        address spender;
        unchecked {
            spender = bytes32(++slotUint256).asAddress().tload();
        }

        approvals[0] = Approval({ token: token, spender: spender });

        for (uint256 i = 1; i < length; ++i) {
            unchecked {
                token = bytes32(++slotUint256).asAddress().tload();
                spender = bytes32(++slotUint256).asAddress().tload();
            }
            approvals[i] = Approval({ token: token, spender: spender });
        }
    }

    /// @notice Checks if an expected callback has been called
    /// @dev If callback was expected but not received, CALLBACK_CALL_SLOT will not be reset to 0
    /// @return True if an expected callback has been called, false otherwise
    function _hasCallbackBeenCalled() internal view returns (bool) {
        return CALLBACK_CALL_SLOT.asUint256().tload() == 0;
    }

    /// @notice Unpacks callback data from a packed uint256
    /// @param packed The packed uint256 containing callback data
    /// @return target The target address
    /// @return selector The function selector
    /// @return dataOffset The offset in calldata where user data begins
    function _unpackCallbackData(uint256 packed)
        private
        pure
        returns (address target, bytes4 selector, uint16 dataOffset)
    {
        target = address(uint160(packed));
        selector = bytes4(bytes32(packed << SELECTOR_OFFSET));
        dataOffset = uint16(packed >> CALLBACK_DATA_OFFSET);
    }

    /// @notice Packs a token address and length into a uint256
    /// @dev Used in transient storage slot zero
    /// @dev `length` is required to be less than `type(uint96).max + 1`
    /// @param length The length of the approvals array
    /// @param token The token address
    /// @return packed The packed uint256
    function _packLengthAndToken(uint256 length, address token) private pure returns (uint256) {
        return uint160(token) | (length << ADDRESS_SIZE_BITS);
    }
}
