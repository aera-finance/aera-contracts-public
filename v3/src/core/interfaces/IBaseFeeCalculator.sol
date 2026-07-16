// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IBaseFeeCalculator
/// @notice Base interface for a contract that calculates TVL and performance fees for a vault and protocol
interface IBaseFeeCalculator {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when a vault's fees are updated
    /// @param vault The address of the vault
    /// @param tvlFee The new TVL fee rate in basis points
    /// @param performanceFee The new performance fee rate in basis points
    event VaultFeesSet(address indexed vault, uint16 tvlFee, uint16 performanceFee);

    /// @notice Emitted when the protocol fee recipient is updated
    /// @param feeRecipient The address of the protocol fee recipient
    event ProtocolFeeRecipientSet(address indexed feeRecipient);

    /// @notice Emitted when protocol fees are updated
    /// @param tvlFee The new protocol TVL fee rate in basis points
    /// @param performanceFee The new protocol performance fee rate in basis points
    event ProtocolFeesSet(uint16 tvlFee, uint16 performanceFee);

    /// @notice Emitted when the accountant for a vault is updated
    /// @param vault The address of the vault whose accountant is being updated
    /// @param accountant The address of the new accountant assigned to the vault
    event VaultAccountantSet(address vault, address accountant);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when attempting to set an TVL fee higher than the maximum allowed
    error Aera__TvlFeeTooHigh();

    /// @notice Thrown when attempting to set a performance fee higher than the maximum allowed
    error Aera__PerformanceFeeTooHigh();

    /// @notice Thrown when attempting to set a protocol fee recipient to the zero address
    error Aera__ZeroAddressProtocolFeeRecipient();

    /// @notice Thrown when attempting to set vault fees for a vault that is not owned by the caller
    error Aera__CallerIsNotVaultOwner();

    /// @notice Thrown when attempting to perform an action on a vault by someone who is not its assigned accountant
    error Aera__CallerIsNotVaultAccountant();

    /// @notice Thrown during a vault is not registered and action requires a registered vault
    error Aera__VaultNotRegistered();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Set the protocol fee recipient
    /// @param feeRecipient The address of the protocol fee recipient
    function setProtocolFeeRecipient(address feeRecipient) external;

    /// @notice Set the protocol fee rates
    /// @param tvl The TVL fee rate in basis points
    /// @param performance The performance fee rate in basis points
    function setProtocolFees(uint16 tvl, uint16 performance) external;

    /// @notice Set the vault-specific fee rates
    /// @param vault The address of the vault
    /// @param tvl The TVL fee rate in basis points
    /// @param performance The performance fee rate in basis points
    function setVaultFees(address vault, uint16 tvl, uint16 performance) external;

    /// @notice Set the accountant for a vault
    /// @param vault The address of the vault
    /// @param accountant The address of the new accountant
    function setVaultAccountant(address vault, address accountant) external;
}
