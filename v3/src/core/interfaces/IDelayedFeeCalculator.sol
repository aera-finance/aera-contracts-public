// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { VaultAccruals, VaultSnapshot } from "src/core/Types.sol";

/// @title IDelayedFeeCalculator
/// @notice Interface for a contract that calculates fee inputs for a single-depositor vault
interface IDelayedFeeCalculator {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when a new snapshot of fee inputs is submitted for a vault
    /// @param vault The vault address
    /// @param averageValue The average value of the vault during the period since last snapshot
    /// @param highestProfit The highest profit achieved during the period since last snapshot
    /// @param timestamp The timestamp of the snapshot
    /// @dev highestProfit is equivalent to a high water mark but could be applicable to a subset of the vault
    event SnapshotSubmitted(address indexed vault, uint160 averageValue, uint128 highestProfit, uint32 timestamp);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when a snapshot's timestamp is older than the last fee accrual
    error Aera__SnapshotTooOld();

    /// @notice Thrown when a snapshot's timestamp is in the future
    error Aera__SnapshotInFuture();

    /// @notice Thrown when attempting to accrue fees with a highest profit that is less than the last highest profit
    error Aera__HighestProfitDecreased();

    /// @notice Thrown when the dispute period is greater than the maximum allowed
    error Aera__DisputePeriodTooLong();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Submit a new snapshot for fee calculation
    /// @param vault The address of the vault
    /// @param averageValue The average value during the period since last snapshot to this snapshot timestamp
    /// @param highestProfit The highest profit achieved up to the snapshot timestamp
    /// @param timestamp The timestamp of the snapshot
    function submitSnapshot(address vault, uint160 averageValue, uint128 highestProfit, uint32 timestamp) external;

    /// @notice Process fee accrual for a vault
    /// @param vault The address of the vault
    /// @return tvlFeesEarned The earned TVL fees for the vault and the protocol
    /// @return performanceFeesEarned The earned performance fees for the vault and the protocol
    function accrueFees(address vault) external returns (uint256 tvlFeesEarned, uint256 performanceFeesEarned);

    /// @notice The fee state of a vault
    /// @param vault The address of the vault
    /// @return vaultSnapshotFeeState The snapshot fee state of the vault
    /// @return baseVaultFeeState The base fee state of the vault
    function vaultFeeState(address vault) external view returns (VaultSnapshot memory, VaultAccruals memory);
}
