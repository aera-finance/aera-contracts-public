// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IFeeCalculator
/// @notice Interface for a contract that calculates fees for a vault and protocol
interface IFeeCalculator {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when a new vault is registered
    /// @param vault The address of the registered vault
    event VaultRegistered(address indexed vault);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    /// @notice Thrown when attempting to register an already registered vault
    error Aera__VaultAlreadyRegistered();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Register a new vault with the fee calculator
    function registerVault() external;

    /// @notice Process a fee claim for a specific vault
    /// @param feeTokenBalance Available fee token balance to distribute
    /// @return earnedFees The amount of fees to be claimed by the fee recipient
    /// @return protocolEarnedFees The amount of protocol fees to be claimed by the protocol
    /// @return protocolFeeRecipient The address of the protocol fee recipient
    /// @dev Expected to be called by the vault only when claiming fees
    /// Only accrues fees and updates stored values; does not transfer tokens
    /// Caller must perform the actual transfers to avoid permanent fee loss
    function claimFees(uint256 feeTokenBalance) external returns (uint256, uint256, address);

    /// @notice Process a protocol fee claim for a vault
    /// @param feeTokenBalance Available fee token balance to distribute
    /// @return accruedFees The amount of protocol fees claimed
    /// @return protocolFeeRecipient The address of the protocol fee recipient
    /// @dev Expected to be called by the vault only when claiming protocol fees
    /// Only accrues protocol fees and updates stored values; does not transfer tokens
    /// Caller must perform the actual transfers to avoid permanent protocol fee loss
    function claimProtocolFees(uint256 feeTokenBalance) external returns (uint256, address);

    /// @notice Returns the current claimable fees for the given vault, as if a claim was made now
    /// @param vault The address of the vault to preview fees for
    /// @param feeTokenBalance Available fee token balance to distribute
    /// If set to `type(uint256).max`, the function returns all accrued fees
    /// If set to an actual balance, the result is capped to that claimable amount
    /// @return vaultFees The amount of claimable fees for the vault
    /// @return protocolFees The amount of claimable protocol fees
    function previewFees(address vault, uint256 feeTokenBalance)
        external
        view
        returns (uint256 vaultFees, uint256 protocolFees);

    /// @notice Returns the address that receives protocol fees
    /// @return The address that receives the protocol fees
    function protocolFeeRecipient() external view returns (address);
}
