// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Math } from "@oz/utils/math/Math.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { Authority } from "@solmate/auth/Auth.sol";

import { BaseFeeCalculator } from "src/core/BaseFeeCalculator.sol";
import { MAX_DISPUTE_PERIOD } from "src/core/Constants.sol";
import { VaultAccruals, VaultSnapshot } from "src/core/Types.sol";
import { IDelayedFeeCalculator } from "src/core/interfaces/IDelayedFeeCalculator.sol";

/// @title DelayedFeeCalculator
/// @notice To protect vault owners from inaccurate submissions, the DelayedFeeCalculator uses a dispute period and
/// pending snapshot system that only accepts submitted values after the dispute period has passed. Each vault accrues
/// fees independently but a shared protocol fee recipient accrues protocol level fees from all vaults
/// @dev All fees are calculated in the numeraire token's decimals
contract DelayedFeeCalculator is IDelayedFeeCalculator, BaseFeeCalculator {
    using SafeCast for uint256;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Dispute period for vault snapshot
    uint256 public immutable DISPUTE_PERIOD;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice A mapping of vault addresses to their associated state
    mapping(address vault => VaultSnapshot vaultSnapshot) internal _vaultSnapshots;

    constructor(address owner_, Authority authority_, uint256 disputePeriod) BaseFeeCalculator(owner_, authority_) {
        // Requirements: check that the dispute period is less than the maximum allowed
        require(disputePeriod <= MAX_DISPUTE_PERIOD, Aera__DisputePeriodTooLong());

        // Effects: set the dispute period
        DISPUTE_PERIOD = disputePeriod;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc BaseFeeCalculator
    function registerVault() external override {
        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[msg.sender];
        // Requirements: check that the vault is not already registered
        require(vaultSnapshot.lastFeeAccrual == 0, Aera__VaultAlreadyRegistered());

        // Effects: set the last fee accrual
        vaultSnapshot.lastFeeAccrual = uint32(block.timestamp);

        // Log the vault registration
        emit VaultRegistered(msg.sender);
    }

    /// @inheritdoc IDelayedFeeCalculator
    function submitSnapshot(address vault, uint160 averageValue, uint128 highestProfit, uint32 timestamp)
        external
        onlyVaultAccountant(vault)
    {
        // Requirements: check that the snapshot is not in the future
        require(timestamp <= block.timestamp, Aera__SnapshotInFuture());

        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[vault];
        VaultAccruals storage vaultAccruals = _vaultAccruals[vault];

        uint256 lastFeeAccrualCached = vaultSnapshot.lastFeeAccrual;
        require(lastFeeAccrualCached != 0, Aera__VaultNotRegistered());

        // Effects: accrue fees
        _accrueFees(vaultSnapshot, vaultAccruals, lastFeeAccrualCached);

        // Requirements: check that the snapshot is not too old
        require(timestamp > vaultSnapshot.lastFeeAccrual, Aera__SnapshotTooOld());
        // Requirements: check that highest profit hasn't decreased
        require(vaultSnapshot.lastHighestProfit <= highestProfit, Aera__HighestProfitDecreased());

        // Effects: update pending snapshot
        vaultSnapshot.timestamp = timestamp;
        unchecked {
            // safe until year 2105
            vaultSnapshot.finalizedAt = uint32(block.timestamp + DISPUTE_PERIOD);
        }
        vaultSnapshot.averageValue = averageValue;
        vaultSnapshot.highestProfit = highestProfit;

        // Log the snapshot submitted
        emit SnapshotSubmitted(vault, averageValue, highestProfit, timestamp);
    }

    /// @inheritdoc IDelayedFeeCalculator
    function accrueFees(address vault) external returns (uint256 protocolFeesEarned, uint256 vaultFeesEarned) {
        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[vault];

        // Effects: accrue fees
        (protocolFeesEarned, vaultFeesEarned) =
            _accrueFees(vaultSnapshot, _vaultAccruals[vault], vaultSnapshot.lastFeeAccrual);
    }

    /// @inheritdoc BaseFeeCalculator
    function previewFees(address vault, uint256 feeTokenBalance) external view override returns (uint256, uint256) {
        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[vault];
        VaultAccruals storage vaultAccruals = _vaultAccruals[vault];

        uint256 claimableProtocolFee = vaultAccruals.accruedProtocolFees;
        uint256 claimableVaultFee = vaultAccruals.accruedFees;

        if (vaultSnapshot.lastFeeAccrual < vaultSnapshot.timestamp && vaultSnapshot.finalizedAt <= block.timestamp) {
            // pending snapshot has become active, accrue fees
            (uint256 vaultPerformanceFeeEarned, uint256 protocolPerformanceFeeEarned) = _calculatePerformanceFees(
                vaultAccruals.fees.performance, vaultSnapshot.highestProfit, vaultSnapshot.lastHighestProfit
            );

            (uint256 vaultTvlFeeEarned, uint256 protocolTvlFeeEarned) = _calculateTvlFees(
                vaultAccruals.fees.tvl,
                vaultSnapshot.averageValue,
                vaultSnapshot.timestamp,
                vaultSnapshot.lastFeeAccrual
            );

            claimableProtocolFee += protocolPerformanceFeeEarned + protocolTvlFeeEarned;
            claimableVaultFee += vaultPerformanceFeeEarned + vaultTvlFeeEarned;
        }

        claimableProtocolFee = Math.min(feeTokenBalance, claimableProtocolFee);
        unchecked {
            claimableVaultFee = Math.min(feeTokenBalance - claimableProtocolFee, claimableVaultFee);
        }

        return (claimableVaultFee, claimableProtocolFee);
    }

    /// @notice Get the fee state for a vault
    /// @param vault The vault address to get fee state for
    /// @return The vault snapshot containing average value and highest profit
    /// @return The vault accruals containing fees and accrued amounts
    function vaultFeeState(address vault) external view returns (VaultSnapshot memory, VaultAccruals memory) {
        return (_vaultSnapshots[vault], _vaultAccruals[vault]);
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Called before claiming fees
    /// @inheritdoc BaseFeeCalculator
    function _beforeClaimFees() internal override {
        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[msg.sender];
        // Effects: accrue fees
        _accrueFees(vaultSnapshot, _vaultAccruals[msg.sender], vaultSnapshot.lastFeeAccrual);
    }

    /// @notice Called before claiming protocol fees
    /// @inheritdoc BaseFeeCalculator
    function _beforeClaimProtocolFees() internal override {
        VaultSnapshot storage vaultSnapshot = _vaultSnapshots[msg.sender];
        // Effects: accrue fees
        _accrueFees(vaultSnapshot, _vaultAccruals[msg.sender], vaultSnapshot.lastFeeAccrual);
    }

    /// @notice Accrues fees for a vault based on its pending snapshot
    /// @param vaultSnapshot The storage pointer to the vault's state
    /// @param vaultAccruals The storage pointer to the vault's accruals
    /// @param lastFeeAccrualCached The last fee accrual timestamp cached to avoid re-reading from storage
    /// @dev Updates the vault's state including lastFeeAccrual, lastHighestProfit, and accruedFees
    /// @dev Deletes pending snapshot if dispute period has passed
    /// @return protocolFeesEarned The earned protocol fees
    /// @return vaultFeesEarned The earned vault fees
    function _accrueFees(
        VaultSnapshot storage vaultSnapshot,
        VaultAccruals storage vaultAccruals,
        uint256 lastFeeAccrualCached
    ) internal returns (uint256 protocolFeesEarned, uint256 vaultFeesEarned) {
        uint256 snapshotTimestamp = vaultSnapshot.timestamp;
        if (lastFeeAccrualCached >= snapshotTimestamp || vaultSnapshot.finalizedAt > block.timestamp) {
            // nothing to accrue
            return (0, 0);
        }

        // pending snapshot has become active, accrue fees
        (uint256 vaultPerformanceFeeEarned, uint256 protocolPerformanceFeeEarned) = _calculatePerformanceFees(
            vaultAccruals.fees.performance, vaultSnapshot.highestProfit, vaultSnapshot.lastHighestProfit
        );

        (uint256 vaultTvlFeeEarned, uint256 protocolTvlFeeEarned) = _calculateTvlFees(
            vaultAccruals.fees.tvl, vaultSnapshot.averageValue, snapshotTimestamp, lastFeeAccrualCached
        );

        // Effects: update the vault's state
        vaultSnapshot.lastHighestProfit = vaultSnapshot.highestProfit;
        vaultSnapshot.lastFeeAccrual = uint32(snapshotTimestamp);
        vaultAccruals.accruedFees += (vaultPerformanceFeeEarned + vaultTvlFeeEarned).toUint112();
        vaultAccruals.accruedProtocolFees += (protocolPerformanceFeeEarned + protocolTvlFeeEarned).toUint112();

        // Effects: delete the pending snapshot
        vaultSnapshot.averageValue = 0;
        vaultSnapshot.highestProfit = 0;
        vaultSnapshot.timestamp = 0;
        vaultSnapshot.finalizedAt = 0;

        protocolFeesEarned = protocolPerformanceFeeEarned + protocolTvlFeeEarned;
        vaultFeesEarned = vaultPerformanceFeeEarned + vaultTvlFeeEarned;
    }

    /// @notice Calculates performance fees for both vault and protocol
    /// @dev Returns zero fees if no new profit has been made
    /// @param vaultPerformanceFeeRate The performance fee rate for the vault
    /// @param newHighestProfit The highest profit in the pending snapshot
    /// @param oldHighestProfit The highest profit in the previous snapshot
    /// @return vaultPerformanceFee The performance fee for the vault
    /// @return protocolPerformanceFee The performance fee for the protocol
    function _calculatePerformanceFees(
        uint256 vaultPerformanceFeeRate,
        uint256 newHighestProfit,
        uint256 oldHighestProfit
    ) internal view returns (uint256, uint256) {
        if (newHighestProfit <= oldHighestProfit) {
            return (0, 0);
        }

        uint256 profit;
        unchecked {
            profit = newHighestProfit - oldHighestProfit;
        }

        return (
            _calculatePerformanceFee(profit, vaultPerformanceFeeRate),
            _calculatePerformanceFee(profit, protocolFees.performance)
        );
    }

    /// @notice Calculates TVL fees for both vault and protocol
    /// @param vaultTvlFeeRate The TVL fee rate for the vault
    /// @param averageValue The average value of the vault
    /// @param snapshotTimestamp The timestamp of the snapshot
    /// @param lastFeeAccrual The timestamp of the last fee accrual
    /// @return vaultTvlFee The earned TVL fee for the vault
    /// @return protocolTvlFee The earned TVL fee for the protocol
    function _calculateTvlFees(
        uint256 vaultTvlFeeRate,
        uint256 averageValue,
        uint256 snapshotTimestamp,
        uint256 lastFeeAccrual
    ) internal view returns (uint256, uint256) {
        uint256 totalDuration;
        unchecked {
            totalDuration = snapshotTimestamp - lastFeeAccrual;
        }

        return (
            _calculateTvlFee(averageValue, vaultTvlFeeRate, totalDuration),
            _calculateTvlFee(averageValue, protocolFees.tvl, totalDuration)
        );
    }
}
