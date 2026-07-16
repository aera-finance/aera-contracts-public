// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OracleData } from "src/core/Types.sol";
import { IOracle } from "src/dependencies/oracles/IOracle.sol";

/// @title IOracleRegistry
/// @notice Interface for an Oracle Registry
interface IOracleRegistry is IOracle {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when an oracle is added
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Added oracle
    event OracleSet(address indexed base, address indexed quote, IOracle indexed oracle);

    /// @notice Emitted when an oracle update is scheduled
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param pendingOracle Pending oracle
    /// @param commitTimestamp The timestamp when the oracle data can be commited
    event OracleScheduled(
        address indexed base, address indexed quote, IOracle indexed pendingOracle, uint32 commitTimestamp
    );

    /// @notice Emitted when an oracle update is cancelled
    /// @param base Base asset address
    /// @param quote Quote asset address
    event OracleUpdateCancelled(address indexed base, address indexed quote);

    /// @notice Emitted when an oracle is disabled
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Oracle that is disabled
    event OracleDisabled(address indexed base, address indexed quote, IOracle indexed oracle);

    /// @notice Emitted when a user accepts an oracle update early
    /// @param user Address of the user which accepted the oracle data
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Oracle which was accepted
    event PendingOracleAccepted(address indexed user, address indexed base, address indexed quote, IOracle oracle);

    /// @notice Emitted when an oracle override is removed
    /// @param user Address of the user which removed the oracle override
    /// @param base Base asset address
    /// @param quote Quote asset address
    event OracleOverrideRemoved(address indexed user, address indexed base, address indexed quote);

    error AeraPeriphery__CallerIsNotAuthorized();
    error AeraPeriphery__OracleMismatch();
    error AeraPeriphery__CommitTimestampNotReached();
    error AeraPeriphery__OracleUpdateDelayTooLong();
    error AeraPeriphery__OracleConvertsOneBaseTokenToZeroQuoteTokens(address base, address quote);
    error AeraPeriphery__NoPendingOracleUpdate();
    error AeraPeriphery__OracleIsDisabled(address base, address quote, IOracle oracle);
    error AeraPeriphery__CannotScheduleOracleUpdateForTheSameOracle();
    error AeraPeriphery__OracleUpdateAlreadyScheduled();
    error AeraPeriphery__ZeroAddressOracle();
    error AeraPeriphery__OracleNotSet();
    error AeraPeriphery__OracleAlreadySet();
    error AeraPeriphery__OracleAlreadyDisabled();
    error AeraPeriphery__ZeroAddressOwner();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Adds an oracle for the provided base and quote assets
    /// @dev MUST REVERT if not called by the authorized address
    /// @dev MUST REVERT if the oracle is already set
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Oracle to add
    function addOracle(address base, address quote, IOracle oracle) external;

    /// @notice Schedules an oracle update for the base/quote asset pair
    ///         The update process is a two-step process: first, the new oracle data is set using
    ///         this function; second, the update is committed using the commitOracleUpdate function
    /// @dev MUST REVERT if not called by the authorized address
    /// @dev MUST REVERT if the oracle data is already scheduled for an update
    /// @dev MUST REVERT if the oracle data is the same as the current oracle
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Oracle to schedule
    function scheduleOracleUpdate(address base, address quote, IOracle oracle) external;

    /// @notice Commits the oracle update for the base/quote asset pair
    ///         Can be called by anyone after the update process is initiated using `scheduleOracleUpdate`
    ///         and the update delay has passed
    /// @dev MUST REVERT if the update is not initiated
    /// @dev MUST REVERT if the update delay has not passed
    /// @param base Base asset address
    /// @param quote Quote asset address
    function commitOracleUpdate(address base, address quote) external;

    /// @notice Cancels the scheduled update for the base/quote asset pair
    /// @dev MUST REVERT if not called by the authorized address
    /// @dev MUST REVERT if the update is not initiated
    /// @param base Base asset address
    /// @param quote Quote asset address
    function cancelScheduledOracleUpdate(address base, address quote) external;

    /// @notice Disables the oracle for the base/quote asset pair
    /// @dev Performs a soft delete to forbid calling `addOracle` with the same base and quote assets and
    ///      avoid front-running attack
    /// @dev MUST REVERT if not called by the authorized address
    /// @dev MUST REVERT if the oracle data is not set
    /// @dev MUST REVERT if the oracle data is already disabled
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param oracle Oracle that is to be disabled
    function disableOracle(address base, address quote, IOracle oracle) external;

    /// @notice Allows a user to accept the pending oracle for a given base/quote pair during the delay period
    ///         Can be called by the user to use the new oracle early
    /// @dev MUST REVERT if the caller is not the user or its owner
    /// @dev MUST REVERT if the oracle is not set
    /// @dev MUST REVERT if current pending oracle doesn't match the oracle to be accepted
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param user Vault that is accepting the pending oracle
    /// @param oracle Oracle that is to be accepted
    function acceptPendingOracle(address base, address quote, address user, IOracle oracle) external;

    /// @notice Allows a user to remove the oracle override for a given base/quote pair
    /// @dev MUST REVERT if the caller is not the user or its owner
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param user The vault address removing the override
    function removeOracleOverride(address base, address quote, address user) external;

    /// @notice Returns the value of the base asset in terms of the quote asset with using the provided
    /// oracle data for the provided user (respects user-specific overrides)
    /// @param baseAmount Amount of base asset
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @param user Vault address
    /// @return value of the base asset in terms of the quote asset
    function getQuoteForUser(uint256 baseAmount, address base, address quote, address user)
        external
        view
        returns (uint256);

    /// @notice Return oracle metadata for base/quote
    /// @param base Base asset address
    /// @param quote Quote asset address
    /// @return data Oracle data
    function getOracleData(address base, address quote) external view returns (OracleData memory data);
}
