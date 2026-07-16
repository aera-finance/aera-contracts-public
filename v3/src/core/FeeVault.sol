// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { BaseVault } from "src/core/BaseVault.sol";
import { FeeVaultParameters } from "src/core/Types.sol";
import { IFeeCalculator } from "src/core/interfaces/IFeeCalculator.sol";
import { IFeeVault } from "src/core/interfaces/IFeeVault.sol";
import { IFeeVaultDeployer } from "src/core/interfaces/IFeeVaultDeployer.sol";

/// @title FeeVault
/// @notice This contract extends BaseVault with fee capabilities for vaults that have a single logical owner of all
/// assets. The vault relies on an external contract called the fee calculator which is shared across multiple vaults
/// The fee calculator is responsible for calculating the TVL and performance fees for the vault, but
/// the vault has control over those fees. Fee claims are initiated via the vault, which consults and updates the fee
/// calculator upon successful claims
abstract contract FeeVault is IFeeVault, BaseVault {
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the fee token
    IERC20 public immutable FEE_TOKEN;

    ////////////////////////////////////////////////////////////
    //                       Storage                          //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the fee calculator contract
    IFeeCalculator public feeCalculator;

    /// @notice Address of the fee recipient
    address public feeRecipient;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    /// @notice Modifier to check that the caller is the fee recipient
    modifier onlyFeeRecipient() {
        // Requirements: check that the caller is the fee recipient
        require(msg.sender == feeRecipient, Aera__CallerIsNotFeeRecipient());
        _;
    }

    constructor() {
        // Interactions: get the fee vault parameters
        FeeVaultParameters memory params = IFeeVaultDeployer(msg.sender).feeVaultParameters();

        IFeeCalculator feeCalculator_ = params.feeCalculator;
        IERC20 feeToken_ = params.feeToken;

        // Requirements: check that the fee calculator and fee token are not zero addresses
        require(address(feeCalculator_) != address(0), Aera__ZeroAddressFeeCalculator());
        require(address(feeToken_) != address(0), Aera__ZeroAddressFeeToken());

        // Interactions: register the vault with the fee calculator
        feeCalculator_.registerVault();

        address feeRecipient_ = params.feeRecipient;
        // Requirements: check that the fee recipient is not the zero address
        require(feeRecipient_ != address(0), Aera__ZeroAddressFeeRecipient());

        // Effects: set the fee recipient and the fee calculator
        feeRecipient = feeRecipient_;
        feeCalculator = feeCalculator_;

        // Effects: set the fee token immutable
        FEE_TOKEN = feeToken_;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IFeeVault
    function setFeeCalculator(IFeeCalculator newFeeCalculator) external requiresAuth {
        // Effects: set the new fee calculator
        feeCalculator = newFeeCalculator;
        // Log the fee calculator updated event
        emit FeeCalculatorUpdated(address(newFeeCalculator));

        // Interactions: register vault only if the new calculator is not address(0)
        if (address(newFeeCalculator) != address(0)) {
            newFeeCalculator.registerVault();
        }
    }

    /// @inheritdoc IFeeVault
    function setFeeRecipient(address newFeeRecipient) external requiresAuth {
        // Requirements: check that the new fee recipient is not the zero address
        require(newFeeRecipient != address(0), Aera__ZeroAddressFeeRecipient());

        // Effects: set the new fee recipient
        feeRecipient = newFeeRecipient;
        // Log the fee recipient updated event
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /// @inheritdoc IFeeVault
    function claimFees() external onlyFeeRecipient returns (uint256 feeRecipientFees, uint256 protocolFees) {
        address protocolFeeRecipient;

        // Interactions: claim the fees
        (feeRecipientFees, protocolFees, protocolFeeRecipient) =
            feeCalculator.claimFees(FEE_TOKEN.balanceOf(address(this)));

        // Requirements: check that the fee recipient has earned fees
        require(feeRecipientFees != 0, Aera__NoFeesToClaim());

        // Interactions: transfer the fees to the fee recipient
        FEE_TOKEN.safeTransfer(msg.sender, feeRecipientFees);
        // Log the fees claimed event
        emit FeesClaimed(msg.sender, feeRecipientFees);

        if (protocolFees != 0) {
            // Interactions: transfer the protocol fees to the protocol fee recipient
            FEE_TOKEN.safeTransfer(protocolFeeRecipient, protocolFees);
            // Log the protocol fees claimed event
            emit ProtocolFeesClaimed(protocolFeeRecipient, protocolFees);
        }
    }

    /// @inheritdoc IFeeVault
    function claimProtocolFees() external returns (uint256 protocolFees) {
        address protocolFeeRecipient;

        // Interactions: claim the protocol fees
        (protocolFees, protocolFeeRecipient) = feeCalculator.claimProtocolFees(FEE_TOKEN.balanceOf(address(this)));

        // Requirements: check that the caller is the protocol fee recipient
        require(msg.sender == protocolFeeRecipient, Aera__CallerIsNotProtocolFeeRecipient());

        // Requirements: check that the protocol has earned fees
        require(protocolFees != 0, Aera__NoFeesToClaim());

        // Interactions: transfer the protocol fees to the protocol fee recipient
        FEE_TOKEN.safeTransfer(protocolFeeRecipient, protocolFees);
        // Log the protocol fees claimed event
        emit ProtocolFeesClaimed(protocolFeeRecipient, protocolFees);
    }
}
