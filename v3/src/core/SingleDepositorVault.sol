// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { FeeVault } from "src/core/FeeVault.sol";
import { OperationPayable, TokenAmount } from "src/core/Types.sol";
import { ISingleDepositorVault } from "src/core/interfaces/ISingleDepositorVault.sol";

/// @title SingleDepositorVault
/// @notice A vault that allows a single depositor to deposit and withdraw assets and allows a fee recipient and the
/// protocol to charge fees. The vault owner retains full custody of assets at all times and can take arbitrary actions
/// through the execute function. For convenience, ERC20 assets can also be withdrawn using the withdraw function and
/// deposited using the deposit function
/// @dev Fee logic is inherited from the fee vault and support for guardians is inherited from the BaseVault
contract SingleDepositorVault is ISingleDepositorVault, FeeVault {
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc ISingleDepositorVault
    function deposit(TokenAmount[] calldata tokenAmounts) external requiresAuth {
        TokenAmount calldata tokenAmount;
        uint256 length = tokenAmounts.length;
        for (uint256 i = 0; i < length; ++i) {
            tokenAmount = tokenAmounts[i];
            // Interactions: transfer tokens from the user to the vault
            tokenAmount.token.safeTransferFrom(msg.sender, address(this), tokenAmount.amount);

            // Requirements: allowance must be zero after deposit
            require(
                tokenAmount.token.allowance(msg.sender, address(this)) == 0,
                Aera__UnexpectedTokenAllowance(tokenAmount.token.allowance(msg.sender, address(this)))
            );
        }

        // Log the deposit event
        emit Deposited(msg.sender, tokenAmounts);
    }

    /// @inheritdoc ISingleDepositorVault
    function withdraw(TokenAmount[] calldata tokenAmounts) external requiresAuth {
        TokenAmount calldata tokenAmount;
        uint256 length = tokenAmounts.length;
        for (uint256 i = 0; i < length; ++i) {
            tokenAmount = tokenAmounts[i];
            // Interactions: transfer tokens from the vault to the user
            tokenAmount.token.safeTransfer(msg.sender, tokenAmount.amount);
        }

        // Log the withdraw event
        emit Withdrawn(msg.sender, tokenAmounts);
    }

    /// @inheritdoc ISingleDepositorVault
    function execute(OperationPayable[] calldata operations) external requiresAuth {
        bool success;
        bytes memory result;
        OperationPayable calldata operation;
        uint256 length = operations.length;
        for (uint256 i = 0; i < length; ++i) {
            operation = operations[i];

            // Interactions: execute the call
            //slither-disable-next-line arbitrary-send-eth
            (success, result) = operation.target.call{ value: operation.value }(operation.data);

            // Requirements: check that the execution was successful
            require(success, Aera__ExecutionFailed(i, result));
        }

        // Log the execution event
        emit Executed(msg.sender, operations);
    }
}
