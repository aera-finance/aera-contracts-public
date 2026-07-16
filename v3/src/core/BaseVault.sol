// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { CallbackHandler } from "src/core/CallbackHandler.sol";

// solhint-disable no-unused-import

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { IERC721Receiver } from "@oz/interfaces/IERC721Receiver.sol";
import { Pausable } from "@oz/utils/Pausable.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { TransientSlot } from "@oz/utils/TransientSlot.sol";
import { MerkleProof } from "@oz/utils/cryptography/MerkleProof.sol";
import { EnumerableMap } from "@oz/utils/structs/EnumerableMap.sol";
import { Authority } from "@solmate/auth/Auth.sol";

import { Auth2Step } from "src/core/Auth2Step.sol";
import {
    AFTER_HOOK_MASK,
    BEFORE_HOOK_MASK,
    CONFIGURABLE_HOOKS_LENGTH_MASK,
    ERC20_SPENDER_OFFSET,
    HOOKS_FLAG_MASK,
    WORD_SIZE
} from "src/core/Constants.sol";
import { Approval, BaseVaultParameters, HookCallType, OperationContext, ReturnValueType } from "src/core/Types.sol";
import { IBaseVault } from "src/core/interfaces/IBaseVault.sol";
import { IBaseVaultFactory } from "src/core/interfaces/IBaseVaultFactory.sol";
import { ISubmitHooks } from "src/core/interfaces/ISubmitHooks.sol";
import { IWhitelist } from "src/core/interfaces/IWhitelist.sol";
import { CalldataExtractor } from "src/core/libraries/CalldataExtractor.sol";
import { CalldataReader, CalldataReaderLib } from "src/core/libraries/CalldataReader.sol";
import { Pipeline } from "src/core/libraries/Pipeline.sol";
import { IERC20WithAllowance } from "src/dependencies/openzeppelin/token/ERC20/IERC20WithAllowance.sol";

/// @title BaseVault
/// @notice This contract embeds core Aera platform functionality: the ability to enlist off-chain guardians to take
/// guarded actions on a vault. It is meant to either be extended with deposit/withdraw capabilities for users or used
/// directly. When used directly, a depositor can simply transfer assets to the vault and a guardian can transfer them
/// out when needed
///
/// Registered guardians call the submit function and trigger vault operations. The vault may run before and after
/// submit
/// hooks and revert if a guardian is using an unauthorized operation. Authorized operations are configured in an
/// off-chain merkle tree and guardians need to provide a merkle proof for each operation. In addition to validating
/// operation targets (the contract and function being called), the merkle tree can maintain custom per-operation hooks
/// that extract specific parts of the calldata for validation or even perform (possibly stateful) validation during
/// the submit call
contract BaseVault is IBaseVault, Pausable, CallbackHandler, ReentrancyGuardTransient, Auth2Step, IERC721Receiver {
    using Pipeline for bytes;
    using CalldataExtractor for bytes;
    using EnumerableMap for EnumerableMap.AddressToBytes32Map;
    using TransientSlot for *;

    ///////////////////////////////////////////////////////////
    //                       Constants                       //
    ///////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for the current hook call type flag
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.basevault.hookCallType")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant HOOK_CALL_TYPE_SLOT = 0xb8706f504833578f7e830b12e31c3cfba31669a85b02596177f00c6a7faf6e00;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice The whitelist contract that controls vault permissions
    IWhitelist public immutable WHITELIST;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the submit hooks contract for vault-level operations
    ISubmitHooks public submitHooks;

    /// @notice Enumerable map of each guardian address to their merkle root
    EnumerableMap.AddressToBytes32Map internal guardianRoots;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    /// @notice Ensures caller either has auth authorization requiresAuth (owner or authorized role) or is a guardian
    modifier onlyAuthOrGuardian() {
        require(
            isAuthorized(msg.sender, msg.sig) || guardianRoots.contains(msg.sender), Aera__CallerIsNotAuthOrGuardian()
        );
        _;
    }

    constructor() Auth2Step(msg.sender, Authority(address(0))) {
        // Interactions: get initialization parameters from the factory
        BaseVaultParameters memory params = IBaseVaultFactory(msg.sender).baseVaultParameters();

        address initialOwner = params.owner;
        // Requirements: check that the owner address is not zero
        require(initialOwner != address(0), Aera__ZeroAddressOwner());
        // Effects: sets the pending owner via Auth2Step two-step process
        transferOwnership(initialOwner);

        if (params.authority != Authority(address(0))) {
            // Effects: set the authority
            setAuthority(params.authority);
        }

        // Effects: set the whitelist
        WHITELIST = params.whitelist;

        // Effects: set vault-level submit hooks
        ISubmitHooks submitHooks_ = params.submitHooks;
        if (address(submitHooks_) != address(0)) {
            _setSubmitHooks(submitHooks_);
        }
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @notice Receive function to allow the vault to receive native tokens
    receive() external payable { }

    /// @inheritdoc IBaseVault
    function submit(bytes calldata data) external whenNotPaused nonReentrant {
        (bool success, bytes32 root) = guardianRoots.tryGet(msg.sender);
        // Requirements: check that the caller is a guardian
        require(success, Aera__CallerIsNotGuardian());

        address submitHooks_ = address(submitHooks);
        // Requirements + Interactions: call the before submit hooks if defined
        _beforeSubmitHooks(submitHooks_, data);

        CalldataReader reader = CalldataReaderLib.from(data);
        CalldataReader end = reader.readBytesEnd(data);

        Approval[] memory approvals;
        uint256 approvalsLength;
        // Requirements + Interactions: execute operations
        (approvals, approvalsLength,, reader) = _executeSubmit(root, reader, false);

        // Requirements + Interactions: call the after submit hooks if defined
        _afterSubmitHooks(submitHooks_, data);

        // Invariants: verify no outgoing approvals are left
        _noPendingApprovalsInvariant(approvals, approvalsLength);

        // Invariants: check that the reader is at the end of the calldata
        reader.requireAtEndOf(end);
    }

    /// @inheritdoc IBaseVault
    function setGuardianRoot(address guardian, bytes32 root) external virtual requiresAuth {
        // Requirements + Effects: set the guardian root
        _setGuardianRoot(guardian, root);
    }

    /// @inheritdoc IBaseVault
    function removeGuardian(address guardian) external virtual requiresAuth {
        // Effects: set the guardian root to zero
        guardianRoots.remove(guardian);

        // Log emit guardian root set event
        emit GuardianRootSet(guardian, bytes32(0));
    }

    /// @inheritdoc IBaseVault
    function checkGuardianWhitelist(address guardian) external returns (bool isRemoved) {
        // Requirements: check that the guardian is not in the whitelist
        if (!WHITELIST.isWhitelisted(guardian)) {
            // Effects: set the guardian root to zero
            guardianRoots.remove(guardian);

            isRemoved = true;

            // Log guardian root set
            emit GuardianRootSet(guardian, bytes32(0));
        }
    }

    /// @inheritdoc IBaseVault
    function setSubmitHooks(ISubmitHooks newSubmitHooks) external virtual requiresAuth {
        // Requirements + Effects: set the submit hooks address
        _setSubmitHooks(newSubmitHooks);
    }

    /// @inheritdoc IBaseVault
    function pause() external onlyAuthOrGuardian {
        // Effects: pause the vault
        _pause();
    }

    /// @inheritdoc IBaseVault
    function unpause() external requiresAuth {
        // Effects: unpause the vault
        _unpause();
    }

    /// @inheritdoc IBaseVault
    function getActiveGuardians() external view returns (address[] memory) {
        return guardianRoots.keys();
    }

    /// @inheritdoc IBaseVault
    function getGuardianRoot(address guardian) external view returns (bytes32) {
        (bool success, bytes32 root) = guardianRoots.tryGet(guardian);
        return success ? root : bytes32(0);
    }

    /// @inheritdoc IBaseVault
    function getCurrentHookCallType() external view returns (HookCallType) {
        return HookCallType(HOOK_CALL_TYPE_SLOT.asUint256().tload());
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc CallbackHandler
    function _handleCallbackOperations(bytes32 root, uint256 cursor)
        internal
        virtual
        override
        returns (bytes memory returnValue)
    {
        CalldataReader reader = CalldataReader.wrap(cursor);
        CalldataReader end = reader.readBytesEnd();

        Approval[] memory approvals;
        uint256 approvalsLength;
        bytes[] memory results;
        // Requirements + Interactions: execute vault operations received from the callback
        (approvals, approvalsLength, results, reader) = _executeSubmit(root, reader, true);

        // Effects: store the history of outgoing token approvals for later verification in submit
        _storeCallbackApprovals(approvals, approvalsLength);

        (reader, returnValue) = _getReturnValue(reader, results);

        // Invariants: check that the reader is at the end of the calldata
        reader.requireAtEndOf(end);

        return returnValue;
    }

    /// @notice Prepare for a callback if the guardian expects one
    /// @dev Writes to transient storage to encode callback expectations
    /// @param reader Current position in the calldata
    /// @param root The merkle root of the active guardian that triggered the callback
    /// @return Updated cursor position
    /// @return Packed callback data
    function _processExpectedCallback(CalldataReader reader, bytes32 root) internal returns (CalldataReader, uint208) {
        bool hasCallback;
        (reader, hasCallback) = reader.readBool();

        if (!hasCallback) {
            return (reader, 0);
        }

        uint208 packedCallbackData;
        (reader, packedCallbackData) = reader.readU208();

        // Requirements + Effects: allow the callback
        _allowCallback(root, packedCallbackData);

        return (reader, packedCallbackData);
    }

    /// @notice Call the before submit hooks if defined
    /// @param hooks Address of the submit hooks contract
    /// @param data Calldata to pass to the before submit hooks
    /// @dev Submit hooks passed as an argument to reduce storage loading
    function _beforeSubmitHooks(address hooks, bytes calldata data) internal {
        if (_hasBeforeHooks(hooks)) {
            // Interactions: call the before submit hooks
            (bool success, bytes memory result) =
                hooks.call(abi.encodeWithSelector(ISubmitHooks.beforeSubmit.selector, data, msg.sender));
            // Requirements: check that the hooks call succeeded
            require(success, Aera__BeforeSubmitHooksFailed(result));
        }
    }

    /// @notice Call the after submit hooks if defined
    /// @param hooks Address of the submit hooks contract
    /// @param data Calldata to pass to the after submit hooks
    /// @dev Submit hooks passed as an argument to reduce storage loading
    function _afterSubmitHooks(address hooks, bytes calldata data) internal {
        if (_hasAfterHooks(hooks)) {
            // Interactions: call the after submit hooks
            (bool success, bytes memory result) =
                hooks.call(abi.encodeWithSelector(ISubmitHooks.afterSubmit.selector, data, msg.sender));
            // Invariants: check that the hooks call succeeded
            require(success, Aera__AfterSubmitHooksFailed(result));
        }
    }

    /// @notice Call the before operation hooks if defined
    /// @param operationHooks Address of the operation-specific hooks
    /// @param data Operation calldata
    /// @param i Operation index
    /// @return result Result of the hooks call
    function _beforeOperationHooks(address operationHooks, bytes memory data, uint256 i)
        internal
        returns (bytes memory result)
    {
        if (_hasBeforeHooks(operationHooks)) {
            // Effects: set the hook call type to before
            _setHookCallType(HookCallType.BEFORE);

            // Interactions: call the before operation hooks
            (bool success, bytes memory returnValue) = operationHooks.call(data);
            // Requirements: check that the hooks call succeeded
            require(success, Aera__BeforeOperationHooksFailed(i, returnValue));

            // Requirements: check that the return data length is a multiple of 32
            require(returnValue.length % WORD_SIZE == 0, Aera__InvalidBeforeOperationHooksReturnDataLength());

            // Effects: set the hook call type to none
            _setHookCallType(HookCallType.NONE);

            // Return value is ABI encoded so we need to decode it to get to the actual
            // bytes value that we returned from the hooks
            (result) = abi.decode(returnValue, (bytes));
        }
    }

    /// @notice Call the after operation hooks if defined
    /// @param operationHooks Address of the operation-specific hooks
    /// @param data Operation calldata
    /// @param i Operation index
    function _afterOperationHooks(address operationHooks, bytes memory data, uint256 i) internal {
        if (_hasAfterHooks(operationHooks)) {
            // Effects: set the hook call type to after
            _setHookCallType(HookCallType.AFTER);

            // Interactions: call the after operation hooks
            (bool success, bytes memory result) = operationHooks.call(data);
            // Requirements: check that the hooks call succeeded
            require(success, Aera__AfterOperationHooksFailed(i, result));

            // Effects: set the hook call type to none
            _setHookCallType(HookCallType.NONE);
        }
    }

    /// @notice Executes a series of operations
    /// @param root The merkle root of the active guardian that triggered the callback
    /// @param reader Current position in the calldata
    /// @param isCalledFromCallback Whether the submit is called from a callback
    /// @return approvals Array of outgoing approvals created during execution
    /// @return approvalsLength Length of approvals array
    /// @return results Array of results from the operations
    /// @return newReader Updated cursor position
    /// @dev Approvals are tracked so we can verify if they have been zeroed out at the end of submit
    function _executeSubmit(bytes32 root, CalldataReader reader, bool isCalledFromCallback)
        internal
        returns (Approval[] memory approvals, uint256 approvalsLength, bytes[] memory results, CalldataReader newReader)
    {
        uint256 operationsLength;
        (reader, operationsLength) = reader.readU8();

        results = new bytes[](operationsLength);

        // There cannot be more approvals than operations
        approvals = new Approval[](operationsLength);

        // Safe to reuse the same variable because all its parameters get overwritten every time, except in static call
        // branch where we don't verify against the merkle root
        OperationContext memory ctx;
        for (uint256 i = 0; i < operationsLength; ++i) {
            (reader, ctx.target) = reader.readAddr();

            bytes memory callData;
            (reader, callData) = reader.readBytesToMemory();

            reader = callData.pipe(reader, results);

            bool isStaticCall;
            (reader, isStaticCall) = reader.readBool();
            if (isStaticCall) {
                // Interactions: perform external static call
                (bool success, bytes memory result) = ctx.target.staticcall(callData);
                // Requirements: verify static call succeeded
                require(success, Aera__SubmissionFailed(i, result));

                results[i] = result;
            } else {
                ctx.selector = bytes4(callData);
                if (_isAllowanceSelector(ctx.selector)) {
                    unchecked {
                        approvals[approvalsLength++] =
                            Approval({ token: ctx.target, spender: _extractApprovalSpender(callData) });
                    }
                }
                // Requirements + Effects: prepare to handle a callback if defined
                (reader, ctx.callbackData) = _processExpectedCallback(reader, root);

                bytes memory extractedData;
                // Requirements + possible Interactions: process the operation hooks
                (reader, extractedData, ctx.configurableOperationHooks, ctx.operationHooks) =
                    _processBeforeOperationHooks(reader, callData, i);

                bytes32[] memory proof;
                (reader, proof) = reader.readBytes32Array();

                (reader, ctx.value) = reader.readOptionalU256();

                // Requirements: verify merkle proof
                _verifyOperation(proof, root, _createMerkleLeaf(ctx, extractedData));

                //slither-disable-next-line arbitrary-send-eth
                (bool success, bytes memory result) = ctx.target.call{ value: ctx.value }(callData);
                // Requirements: check that the submission succeeded
                require(success, Aera__SubmissionFailed(i, result));

                if (ctx.callbackData != 0) {
                    // Requirements: check that the callback was received
                    require(_hasCallbackBeenCalled(), Aera__ExpectedCallbackNotReceived());

                    if (!isCalledFromCallback) {
                        // Effects: get the callback approvals and clear the transient storage
                        Approval[] memory callbackApprovals = _getCallbackApprovals();

                        // Invariants: verify no pending approvals from the callback
                        _noPendingApprovalsInvariant(callbackApprovals, callbackApprovals.length);
                    }
                }

                // possible Interactions + Requirements: call the after operation hooks if defined
                _afterOperationHooks(ctx.operationHooks, callData, i);

                results[i] = result;
            }
        }

        return (approvals, approvalsLength, results, reader);
    }

    /// @notice Processes all hooks for operation
    /// @notice Returns extracted data if configurable or contract before operation hooks is defined
    /// @param reader Current position in the calldata
    /// @param callData Operation calldata
    /// @param i Operation index
    /// @return reader Updated reader position
    /// @return extractedData Extracted chunks of calldata
    /// @return hooksConfigBytes hooks configuration bytes
    /// @return operationHooks Operation hooks address
    /// @dev Custom hooks (with contracts) can run before and after each operation but a configurable hooks
    /// can only run before an operation. This function processes all of the possible configurations of hooks
    /// which doesn't allow using both a custom before hook and a configurable before hook
    function _processBeforeOperationHooks(CalldataReader reader, bytes memory callData, uint256 i)
        internal
        returns (CalldataReader, bytes memory, uint256, address)
    {
        uint8 hooksConfigFlag;
        (reader, hooksConfigFlag) = reader.readU8();

        if (hooksConfigFlag == 0) {
            return (reader, "", 0, address(0));
        }

        uint256 calldataOffsetsCount = hooksConfigFlag & CONFIGURABLE_HOOKS_LENGTH_MASK;

        // Case A: Only configurable hooks defined
        if (hooksConfigFlag & HOOKS_FLAG_MASK == 0) {
            uint256 calldataOffsetsPacked;
            (reader, calldataOffsetsPacked) = reader.readU256();

            return (
                reader, callData.extract(calldataOffsetsPacked, calldataOffsetsCount), calldataOffsetsPacked, address(0)
            );
        }

        address operationHooks;
        // Case B: Both configurable and custom hooks defined
        if (calldataOffsetsCount != 0) {
            uint256 calldataOffsetsPacked;
            (reader, calldataOffsetsPacked) = reader.readU256();

            (reader, operationHooks) = reader.readAddr();
            // Requirements: check that the operation hooks is not a before submit hooks
            require(!_hasBeforeHooks(operationHooks), Aera__BeforeOperationHooksWithConfigurableHooks());

            return (
                reader,
                callData.extract(calldataOffsetsPacked, calldataOffsetsCount),
                calldataOffsetsPacked,
                operationHooks
            );
        }

        // Case C: only a custom hooks defined
        (reader, operationHooks) = reader.readAddr();

        return (
            reader,
            // Requirements + Interactions: call the before operation hooks if defined
            _beforeOperationHooks(operationHooks, callData, i),
            0,
            operationHooks
        );
    }

    /// @notice Set the submit hooks address
    /// @param submitHooks_ Address of the submit hooks contract
    function _setSubmitHooks(ISubmitHooks submitHooks_) internal {
        // Effects: set submit hooks address
        submitHooks = submitHooks_;

        // Log submit hooks set
        emit SubmitHooksSet(address(submitHooks_));
    }

    /// @notice Set the guardian root
    /// @param guardian Address of the guardian
    /// @param root Merkle root
    function _setGuardianRoot(address guardian, bytes32 root) internal virtual {
        // Requirements: check that the guardian address is not zero
        require(guardian != address(0), Aera__ZeroAddressGuardian());

        // Requirements: check that the guardian is whitelisted
        require(WHITELIST.isWhitelisted(guardian), Aera__GuardianNotWhitelisted());

        // Requirements: check that root is not zero
        require(root != bytes32(0), Aera__ZeroAddressMerkleRoot());

        // Effects: set guardian root
        guardianRoots.set(guardian, root);

        // Log guardian root set
        emit GuardianRootSet(guardian, root);
    }

    /// @notice Set the hook call type
    /// @param hookCallType The hook call type
    function _setHookCallType(HookCallType hookCallType) internal {
        // Effects: store the hook call type
        HOOK_CALL_TYPE_SLOT.asUint256().tstore(uint8(hookCallType));
    }

    /// @notice Verify no pending approvals remain at the end of a submit
    /// @param approvals Array of approvals to check
    /// @param approvalsLength Length of approvals array
    /// @dev We iterate backwards to avoid extra i variable
    /// @dev While loop is preferred over for(;approvalsLength != 0;)
    /// @dev Iterator variable is not used because it's not needed and decrement needs to be unchecked
    function _noPendingApprovalsInvariant(Approval[] memory approvals, uint256 approvalsLength) internal view {
        Approval memory approval;
        while (approvalsLength != 0) {
            unchecked {
                --approvalsLength;
            }

            approval = approvals[approvalsLength];

            // Requirements: verify allowance is zero
            require(
                // Interactions: get allowance
                IERC20(approval.token).allowance(address(this), approval.spender) == 0,
                Aera__AllowanceIsNotZero(approval.token, approval.spender)
            );
        }
    }

    /// @notice Get the return value from the operations
    /// @param reader Current position in the calldata
    /// @param results Array of results from the operations
    /// @return newReader Updated reader position
    /// @return returnValue Return value from the operations
    function _getReturnValue(CalldataReader reader, bytes[] memory results)
        internal
        pure
        returns (CalldataReader newReader, bytes memory returnValue)
    {
        uint8 returnTypeFlag;
        (reader, returnTypeFlag) = reader.readU8();

        if (returnTypeFlag == uint8(ReturnValueType.STATIC_RETURN)) {
            (reader, returnValue) = reader.readBytesToMemory();
        } else if (returnTypeFlag == uint8(ReturnValueType.DYNAMIC_RETURN)) {
            uint256 length = results.length;
            require(length > 0, Aera__NoResults());

            unchecked {
                returnValue = results[length - 1];
            }
        }

        return (reader, returnValue);
    }

    /// @notice Verify an operation by validating the merkle proof
    /// @param proof The merkle proof
    /// @param root The merkle root
    /// @param leaf The merkle leaf to verify
    function _verifyOperation(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure {
        require(MerkleProof.verify(proof, root, leaf), Aera__ProofVerificationFailed());
    }

    /// @notice Create a merkle leaf
    /// @param ctx The operation context
    /// @param extractedData The extracted data
    /// @return leaf The merkle leaf
    function _createMerkleLeaf(OperationContext memory ctx, bytes memory extractedData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                ctx.target,
                ctx.selector,
                ctx.value > 0,
                ctx.operationHooks,
                ctx.configurableOperationHooks,
                ctx.callbackData,
                extractedData
            )
        );
    }

    /// @notice Extract spender address from approval data
    /// @dev Extract spender address from approval data
    /// @param data Approval calldata
    /// @return spender Address of the spender
    function _extractApprovalSpender(bytes memory data) internal pure returns (address spender) {
        // Length check skipped intentionally, call reverts on misuse
        // "memory-safe" retained for compiler optimization
        assembly ("memory-safe") {
            let offset := add(data, ERC20_SPENDER_OFFSET)
            spender := mload(offset)
        }
    }

    /// @notice Check if hooks needs to be called before the submit/operation
    /// @dev Check if hooks needs to be called before the submit/operation
    /// @param hooks Hooks address to check
    /// @return True if hooks needs to be called before the submit/operation
    function _hasBeforeHooks(address hooks) internal pure returns (bool) {
        /// least significant bit is 1 indicating it's a before hooks
        return uint160(hooks) & BEFORE_HOOK_MASK != 0;
    }

    /// @notice Check if submit hooks needs to be called after the submit/operation
    /// @dev Check if submit hooks needs to be called after the submit/operation
    /// @param hooks Submit hooks address to check
    /// @return True if submit hooks needs to be called after the submit/operation
    function _hasAfterHooks(address hooks) internal pure returns (bool) {
        /// second least significant bit is 1 indicating it's a after hooks
        return uint160(hooks) & AFTER_HOOK_MASK != 0;
    }

    /// @notice Check if the selector is an allowance handling selector
    /// @dev Check if the selector is an allowance handling selector
    /// @param selector Selector to check
    /// @return True if the selector is an allowance handling selector
    function _isAllowanceSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20.approve.selector || selector == IERC20WithAllowance.increaseAllowance.selector;
    }
}
