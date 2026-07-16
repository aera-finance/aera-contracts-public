// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OperationPayable, TokenAmount } from "src/core/Types.sol";
import { IFeeVault } from "src/core/interfaces/IFeeVault.sol";

/// @title ISingleDepositorVault
/// @notice Interface for vaults that accept deposits/withdrawals from a single address
interface ISingleDepositorVault is IFeeVault {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when tokens are deposited into the vault
    /// @param depositor The address making the deposit
    /// @param tokenAmounts The tokens and amounts deposited
    event Deposited(address indexed depositor, TokenAmount[] tokenAmounts);
    /// @notice Emitted when tokens are withdrawn from the vault
    /// @param withdrawer The address making the withdrawal
    /// @param tokenAmounts The tokens and amounts withdrawn
    event Withdrawn(address indexed withdrawer, TokenAmount[] tokenAmounts);
    /// @notice Emitted when operations are executed
    /// @param executor The address executing the operations
    /// @param operations The operations that were executed
    event Executed(address indexed executor, OperationPayable[] operations);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__ExecutionFailed(uint256 index, bytes result);
    error Aera__UnexpectedTokenAllowance(uint256 allowance);

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Deposit assets into the vault
    /// @param tokenAmounts The assets to deposit
    function deposit(TokenAmount[] calldata tokenAmounts) external;

    /// @notice Withdraw assets from the vault
    /// @param tokenAmounts The assets to withdraw
    function withdraw(TokenAmount[] calldata tokenAmounts) external;

    /// @notice Execute operations on the vault as a trusted entity
    /// @param operations The operations to execute
    function execute(OperationPayable[] calldata operations) external;
}
