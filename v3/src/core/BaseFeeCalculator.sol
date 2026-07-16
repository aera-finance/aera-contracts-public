// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Math } from "@oz/utils/math/Math.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Auth2Step } from "src/core/Auth2Step.sol";
import { MAX_PERFORMANCE_FEE, MAX_TVL_FEE, ONE_IN_BPS, SECONDS_PER_YEAR } from "src/core/Constants.sol";
import { Fee, VaultAccruals } from "src/core/Types.sol";
import { VaultAuth } from "src/core/VaultAuth.sol";
import { IBaseFeeCalculator } from "src/core/interfaces/IBaseFeeCalculator.sol";
import { IFeeCalculator } from "src/core/interfaces/IFeeCalculator.sol";

/// @title BaseFeeCalculator
/// @notice Module used with FeeVault to allow an off-chain accountant to submit necessary inputs that help
/// compute TVL and performance fees owed to the vault. Serves as a central registry for all vaults
/// and their associated fees
abstract contract BaseFeeCalculator is IBaseFeeCalculator, IFeeCalculator, Auth2Step, VaultAuth {
    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice The protocol's fee configuration
    Fee public protocolFees;
    /// @notice The address that receives the protocol's fees
    address public protocolFeeRecipient;
    /// @notice A mapping of vault addresses to their associated state
    mapping(address vault => VaultAccruals vaultAccruals) internal _vaultAccruals;
    /// @notice A mapping of vault addresses to their assigned accountant
    mapping(address vault => address accountant) public vaultAccountant;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    /// @notice Modifier that checks the caller is the accountant assigned to the specified vault
    /// @param vault The address of the vault
    modifier onlyVaultAccountant(address vault) {
        require(msg.sender == vaultAccountant[vault], Aera__CallerIsNotVaultAccountant());
        _;
    }

    constructor(address initialOwner, Authority initialAuthority) Auth2Step(initialOwner, initialAuthority) { }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IBaseFeeCalculator
    function setProtocolFeeRecipient(address feeRecipient) external requiresAuth {
        // Requirements: check that the fee recipient is not the zero address
        require(feeRecipient != address(0), Aera__ZeroAddressProtocolFeeRecipient());

        // Effects: set the protocol fee recipient
        protocolFeeRecipient = feeRecipient;

        // Log new protocol fee recipient
        emit ProtocolFeeRecipientSet(feeRecipient);
    }

    /// @inheritdoc IBaseFeeCalculator
    function setProtocolFees(uint16 tvl, uint16 performance) external requiresAuth {
        // Requirements: check that the fees are less than the maximum allowed
        require(tvl <= MAX_TVL_FEE, Aera__TvlFeeTooHigh());
        require(performance <= MAX_PERFORMANCE_FEE, Aera__PerformanceFeeTooHigh());
        require(protocolFeeRecipient != address(0), Aera__ZeroAddressProtocolFeeRecipient());

        // Effects: set the protocol fees
        protocolFees = Fee({ tvl: tvl, performance: performance });

        // Log new protocol fees
        emit ProtocolFeesSet(tvl, performance);
    }

    /// @inheritdoc IBaseFeeCalculator
    function setVaultAccountant(address vault, address accountant) external requiresVaultAuth(vault) {
        // Effects: update the vault's accountant
        vaultAccountant[vault] = accountant;

        // Log the updated accountant for the vault
        emit VaultAccountantSet(vault, accountant);
    }

    /// @inheritdoc IFeeCalculator
    function registerVault() external virtual { }

    /// @inheritdoc IBaseFeeCalculator
    function setVaultFees(address vault, uint16 tvl, uint16 performance) external requiresVaultAuth(vault) {
        // Requirements: check that the fees are less than the maximum allowed
        require(tvl <= MAX_TVL_FEE, Aera__TvlFeeTooHigh());
        require(performance <= MAX_PERFORMANCE_FEE, Aera__PerformanceFeeTooHigh());

        // Effects: set the vault fees
        VaultAccruals storage vaultAccruals = _vaultAccruals[vault];
        vaultAccruals.fees = Fee({ tvl: tvl, performance: performance });

        // Log new vault fees
        emit VaultFeesSet(vault, tvl, performance);
    }

    /// @inheritdoc IFeeCalculator
    function claimFees(uint256 feeTokenBalance) external virtual returns (uint256, uint256, address) {
        // Effects: hook called before claiming fees
        _beforeClaimFees();

        VaultAccruals storage vaultAccruals = _vaultAccruals[msg.sender];

        uint256 vaultEarnedFees = vaultAccruals.accruedFees;
        uint256 protocolEarnedFees = vaultAccruals.accruedProtocolFees;
        uint256 claimableProtocolFee = Math.min(feeTokenBalance, protocolEarnedFees);
        uint256 claimableVaultFee;
        unchecked {
            claimableVaultFee = Math.min(feeTokenBalance - claimableProtocolFee, vaultEarnedFees);
        }

        // Effects: update accrued fees
        unchecked {
            vaultAccruals.accruedProtocolFees = uint112(protocolEarnedFees - claimableProtocolFee);
            vaultAccruals.accruedFees = uint112(vaultEarnedFees - claimableVaultFee);
        }

        return (claimableVaultFee, claimableProtocolFee, protocolFeeRecipient);
    }

    /// @inheritdoc IFeeCalculator
    function claimProtocolFees(uint256 feeTokenBalance) external virtual returns (uint256, address) {
        // Effects: hook called before claiming protocol fees
        _beforeClaimProtocolFees();

        VaultAccruals storage vaultAccruals = _vaultAccruals[msg.sender];
        uint256 accruedFees = vaultAccruals.accruedProtocolFees;
        uint256 claimableProtocolFee = Math.min(feeTokenBalance, accruedFees);

        // Effects: update accrued protocol fees
        unchecked {
            vaultAccruals.accruedProtocolFees = uint112(accruedFees - claimableProtocolFee);
        }

        return (claimableProtocolFee, protocolFeeRecipient);
    }

    /// @inheritdoc IFeeCalculator
    function previewFees(address vault, uint256 feeTokenBalance) external view virtual returns (uint256, uint256);

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Hook called before claiming fees
    /// @dev Can be overridden by child contracts to add custom logic
    function _beforeClaimFees() internal virtual { }

    /// @notice Hook called before claiming protocol fees
    /// @dev Can be overridden by child contracts to add custom logic
    function _beforeClaimProtocolFees() internal virtual { }

    /// @notice Calculates the TVL fee for a given period
    /// @dev Fee is annualized and prorated for the time period
    /// @param averageValue The average value during the period
    /// @param tvlFee The TVL fee rate in basis points
    /// @param timeDelta The duration of the fee period in seconds
    /// @return The earned TVL fee
    function _calculateTvlFee(uint256 averageValue, uint256 tvlFee, uint256 timeDelta)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            // safe because averageValue is uint160, tvlFee is uint16, timeDelta is uint32
            return averageValue * tvlFee * timeDelta / ONE_IN_BPS / SECONDS_PER_YEAR;
        }
    }

    /// @notice Calculates the performance fee for a given period
    /// @param profit The profit during the period
    /// @param feeRate The performance fee rate in basis points
    /// @return The earned performance fee
    function _calculatePerformanceFee(uint256 profit, uint256 feeRate) internal pure returns (uint256) {
        unchecked {
            // safe because profit is uint128, feeRate is uint16
            return profit * feeRate / ONE_IN_BPS;
        }
    }
}
