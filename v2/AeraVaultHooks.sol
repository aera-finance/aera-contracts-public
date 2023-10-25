// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/IERC20.sol";
import "@openzeppelin/ERC165.sol";
import "@openzeppelin/SafeERC20.sol";
import "@openzeppelin/IERC20IncreaseAllowance.sol";
import "./interfaces/IHooks.sol";
import "./interfaces/IAeraVaultHooksEvents.sol";
import "./interfaces/IVault.sol";
import "./Sweepable.sol";
import "./TargetSighashLib.sol";
import "./Types.sol";
import {ONE} from "./Constants.sol";

/// @title AeraVaultHooks
/// @notice Default hooks contract which implements several safeguards.
/// @dev Connected vault MUST only call submit with tokens that can increase allowances with approve and increaseAllowance.
contract AeraVaultHooks is IHooks, IAeraVaultHooksEvents, Sweepable, ERC165 {
    using SafeERC20 for IERC20;

    /// @notice Min bound on minimum fraction of vault value that the vault has to retain
    ///         between submissions during a single day.
    /// @dev    Loose bound to mitigate initialization error.
    uint256 private constant _LOWEST_MIN_DAILY_VALUE = ONE / 2;

    /// @notice The minimum fraction of vault value that the vault has to
    ///         retain per day during submit transactions.
    ///         e.g. 0.9 (in 18-decimal form) allows the vault to lose up to
    ///         10% in value across consecutive submissions.
    uint256 public immutable minDailyValue;

    /// STORAGE ///

    /// @notice The address of the vault.
    address public vault;

    /// @notice Current day (UTC).
    uint256 public currentDay;

    /// @notice Accumulated value multiplier during submit transactions.
    uint256 public cumulativeDailyMultiplier;

    /// @notice Allowed target contract and sighash combinations.
    mapping(TargetSighash => bool) internal _targetSighashAllowed;

    /// @notice Total value of assets in vault before submission.
    /// @dev Assigned in `beforeSubmit` and used in `afterSubmit`.
    uint256 internal _beforeValue;

    /// ERRORS ///

    error Aera__CallerIsNotVault();
    error Aera__VaultIsZeroAddress();
    error Aera__HooksOwnerIsGuardian();
    error Aera__HooksOwnerIsVault();
    error Aera__MinDailyValueTooLow();
    error Aera__MinDailyValueIsNotLessThanOne();
    error Aera__NoCodeAtTarget(address target);
    error Aera__CallIsNotAllowed(Operation operation);
    error Aera__VaultValueBelowMinDailyValue();
    error Aera__AllowanceIsNotZero(address asset, address spender);
    error Aera__HooksInitialOwnerIsZeroAddress();
    error Aera__RemovingNonexistentTargetSighash(TargetSighash targetSighash);
    error Aera__AddingDuplicateTargetSighash(TargetSighash targetSighash);

    /// MODIFIERS ///

    /// @dev Throws if called by any account other than the vault.
    modifier onlyVault() {
        if (msg.sender != vault) {
            revert Aera__CallerIsNotVault();
        }
        _;
    }

    /// FUNCTIONS ///

    /// @param owner_ Initial owner address.
    /// @param vault_ Vault address.
    /// @param minDailyValue_ The minimum fraction of value that the vault has to retain
    ///                       during the day in the course of submissions.
    /// @param targetSighashAllowlist Array of target contract and sighash combinations to allow.
    constructor(
        address owner_,
        address vault_,
        uint256 minDailyValue_,
        TargetSighashData[] memory targetSighashAllowlist
    ) Ownable() {
        // Requirements: validate vault.
        if (vault_ == address(0)) {
            revert Aera__VaultIsZeroAddress();
        }
        if (owner_ == address(0)) {
            revert Aera__HooksInitialOwnerIsZeroAddress();
        }

        // Requirements: check that hooks initial owner is disaffiliated.
        if (owner_ == vault_) {
            revert Aera__HooksOwnerIsVault();
        }
        // Only check vault if it has been deployed already.
        // This will happen if we are deploying a new Hooks contract for an existing vault.
        if (vault_.code.length > 0) {
            address guardian = IVault(vault_).guardian();
            if (owner_ == guardian) {
                revert Aera__HooksOwnerIsGuardian();
            }
        }

        // Requirements: check that minimum daily value doesn't mandate vault growth.
        if (minDailyValue_ >= ONE) {
            revert Aera__MinDailyValueIsNotLessThanOne();
        }

        // Requirements: check that minimum daily value enforces a lower bound.
        if (minDailyValue_ < _LOWEST_MIN_DAILY_VALUE) {
            revert Aera__MinDailyValueTooLow();
        }

        uint256 numTargetSighashAllowlist = targetSighashAllowlist.length;

        // Effects: initialize target sighash allowlist.
        for (uint256 i = 0; i < numTargetSighashAllowlist;) {
            _addTargetSighash(
                targetSighashAllowlist[i].target,
                targetSighashAllowlist[i].selector
            );

            unchecked {
                i++; // gas savings
            }
        }

        // Effects: initialize state variables.
        vault = vault_;
        minDailyValue = minDailyValue_;
        currentDay = block.timestamp / 1 days;
        cumulativeDailyMultiplier = ONE;

        // Effects: set new owner.
        _transferOwnership(owner_);
    }

    /// @notice Add targetSighash pair to allowlist.
    /// @param target Address of target.
    /// @param selector Selector of function.
    function addTargetSighash(
        address target,
        bytes4 selector
    ) external onlyOwner {
        _addTargetSighash(target, selector);
    }

    /// @notice Remove targetSighash pair from allowlist.
    /// @param target Address of target.
    /// @param selector Selector of function.
    function removeTargetSighash(
        address target,
        bytes4 selector
    ) external onlyOwner {
        TargetSighash targetSighash =
            TargetSighashLib.toTargetSighash(target, selector);

        // Requirements: check that current target sighash is set.
        if (!_targetSighashAllowed[targetSighash]) {
            revert Aera__RemovingNonexistentTargetSighash(targetSighash);
        }

        // Effects: remove target sighash combination from the allowlist.
        delete _targetSighashAllowed[targetSighash];

        // Log the removal.
        emit TargetSighashRemoved(target, selector);
    }

    /// @inheritdoc IHooks
    function beforeDeposit(AssetValue[] memory amounts)
        external
        override
        onlyVault
    {}

    /// @inheritdoc IHooks
    function afterDeposit(AssetValue[] memory amounts)
        external
        override
        onlyVault
    {}

    /// @inheritdoc IHooks
    function beforeWithdraw(AssetValue[] memory amounts)
        external
        override
        onlyVault
    {}

    /// @inheritdoc IHooks
    function afterWithdraw(AssetValue[] memory amounts)
        external
        override
        onlyVault
    {}

    /// @inheritdoc IHooks
    function beforeSubmit(Operation[] calldata operations)
        external
        override
        onlyVault
    {
        uint256 numOperations = operations.length;
        bytes4 selector;

        // Requirements: validate that all operations are allowed.
        for (uint256 i = 0; i < numOperations;) {
            selector = bytes4(operations[i].data[0:4]);

            TargetSighash sigHash = TargetSighashLib.toTargetSighash(
                operations[i].target, selector
            );

            // Requirements: validate that the target sighash combination is allowed.
            if (!_targetSighashAllowed[sigHash]) {
                revert Aera__CallIsNotAllowed(operations[i]);
            }

            unchecked {
                i++;
            } // gas savings
        }

        // Effects: remember current vault value and ETH balance for use in afterSubmit.
        _beforeValue = IVault(vault).value();
    }

    /// @inheritdoc IHooks
    function afterSubmit(Operation[] calldata operations)
        external
        override
        onlyVault
    {
        uint256 newMultiplier;
        uint256 currentMultiplier = cumulativeDailyMultiplier;
        uint256 day = block.timestamp / 1 days;

        if (_beforeValue > 0) {
            // Initialize new cumulative multiplier with the current submit multiplier.
            newMultiplier = currentDay == day ? currentMultiplier : ONE;
            newMultiplier =
                (newMultiplier * IVault(vault).value()) / _beforeValue;

            // Requirements: check that daily execution loss is within bounds.
            if (newMultiplier < minDailyValue) {
                revert Aera__VaultValueBelowMinDailyValue();
            }

            // Effects: update the daily multiplier.
            if (currentMultiplier != newMultiplier) {
                cumulativeDailyMultiplier = newMultiplier;
            }
        }

        // Effects: reset current day for the next submission.
        if (currentDay != day) {
            currentDay = day;
        }

        // Effects: reset prior vault value for the next submission.
        _beforeValue = 0;

        uint256 numOperations = operations.length;
        bytes4 selector;
        address spender;
        uint256 amount;
        IERC20 token;

        // Requirements: check that there are no outgoing allowances that were introduced.
        for (uint256 i = 0; i < numOperations;) {
            selector = bytes4(operations[i].data[0:4]);
            if (_isAllowanceSelector(selector)) {
                // Extract spender and amount from the allowance transaction.
                (spender, amount) =
                    abi.decode(operations[i].data[4:], (address, uint256));

                // If amount is 0 then allowance hasn't been increased.
                if (amount == 0) {
                    unchecked {
                        i++;
                    } // gas savings
                    continue;
                }

                token = IERC20(operations[i].target);

                // Requirements: check that the current outgoing allowance for this token is zero.
                if (token.allowance(vault, spender) > 0) {
                    revert Aera__AllowanceIsNotZero(address(token), spender);
                }
            }
            unchecked {
                i++;
            } // gas savings
        }
    }

    /// @inheritdoc IHooks
    function beforeFinalize() external override onlyVault {}

    /// @inheritdoc IHooks
    function afterFinalize() external override onlyVault {
        // Effects: release storage
        currentDay = 0;
        cumulativeDailyMultiplier = 0;
    }

    /// @inheritdoc IHooks
    function decommission() external override onlyVault {
        // Effects: reset vault address.
        vault = address(0);

        // Effects: release storage
        currentDay = 0;
        cumulativeDailyMultiplier = 0;

        // Log decommissioning.
        emit Decommissioned();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return interfaceId == type(IHooks).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Check whether target and sighash combination is allowed.
    /// @param target Address of target.
    /// @param selector Selector of function.
    function targetSighashAllowed(
        address target,
        bytes4 selector
    ) external view returns (bool) {
        return _targetSighashAllowed[TargetSighashLib.toTargetSighash(
            target, selector
        )];
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Add targetSighash pair to allowlist.
    /// @param target Address of target.
    /// @param selector Selector of function.
    function _addTargetSighash(address target, bytes4 selector) internal {
        // Requirements: check there is code at target.
        if (target.code.length == 0) {
            revert Aera__NoCodeAtTarget(target);
        }

        TargetSighash targetSighash =
            TargetSighashLib.toTargetSighash(target, selector);

        // Requirements: check that current target sighash is not set.
        if (_targetSighashAllowed[targetSighash]) {
            revert Aera__AddingDuplicateTargetSighash(targetSighash);
        }

        // Effects: add target sighash combination to the allowlist.
        _targetSighashAllowed[targetSighash] = true;

        // Log the addition.
        emit TargetSighashAdded(target, selector);
    }

    /// @notice Check whether selector is allowance related selector or not.
    /// @param selector Selector of calldata to check.
    /// @return isAllowanceSelector True if selector is allowance related selector.
    function _isAllowanceSelector(bytes4 selector)
        internal
        pure
        returns (bool isAllowanceSelector)
    {
        return selector == IERC20.approve.selector
            || selector == IERC20IncreaseAllowance.increaseAllowance.selector;
    }

    /// @notice Check that owner is not the vault or the guardian.
    /// @param owner_ Hooks owner address.
    /// @param vault_ Vault address.
    function _checkHooksOwner(address owner_, address vault_) internal view {
        if (owner_ == vault_) {
            revert Aera__HooksOwnerIsVault();
        }

        address guardian = IVault(vault_).guardian();
        if (owner_ == guardian) {
            revert Aera__HooksOwnerIsGuardian();
        }
    }

    /// @inheritdoc Ownable2Step
    function transferOwnership(address newOwner) public override onlyOwner {
        // Requirements: check that new owner is disaffiliated from existing roles.
        _checkHooksOwner(newOwner, vault);

        // Effects: initiate ownership transfer.
        super.transferOwnership(newOwner);
    }
}
