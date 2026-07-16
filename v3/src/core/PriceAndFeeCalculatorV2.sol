// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@oz/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";

import { BaseFeeCalculator } from "src/core/BaseFeeCalculator.sol";
import { ONE_DAY, ONE_IN_BPS, ONE_MINUTE, UNIT_PRICE_PRECISION } from "src/core/Constants.sol";
import { HasNumeraire } from "src/core/HasNumeraire.sol";
import { VaultAccruals, VaultPriceStateV2 } from "src/core/Types.sol";
import { IPriceAndFeeCalculatorV2 } from "src/core/interfaces/IPriceAndFeeCalculatorV2.sol";
import { IVersioned } from "src/core/interfaces/IVersioned.sol";
import { IOracleRegistry } from "src/periphery/interfaces/IOracleRegistry.sol";

/// @title PriceAndFeeCalculator
/// @notice Calculates and manages anchor/drift price and fees for multiple vaults that share the same numeraire token
/// Acts as a price oracle and fee accrual engine. Vault registration workflow is:
/// 1. Register a new vault with registerVault()
/// 2. Set the thresholds for the vault with setThresholds()
/// 3. Set the initial price state with setInitialPrice()
/// Once registered, a vault can have its price updated by an authorized entity. Vault owners set thresholds for price
/// changes, update intervals, and price age. Anchor-policy violations can either pause or revert depending on
/// vault-level configuration, while drift-policy violations always revert. Paused vaults don't accrue fees, reject
/// drift updates, and unpause against the current anchor tuple. Accrues fees on each anchor update, based on TVL and
/// performance since last update
/// Supports conversion between vault units, tokens, and numeraire for deposits/withdrawals. All logic and state is
/// per-vault, supporting many vaults in parallel. Only vault owners can set thresholds and pause/unpause their vaults,
/// whereas accountants can also pause their vaults
/// Integrates with an external oracle registry for token price conversions
contract PriceAndFeeCalculatorV2 is IPriceAndFeeCalculatorV2, BaseFeeCalculator, HasNumeraire {
    using SafeCast for uint256;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Oracle registry contract for price feeds
    IOracleRegistry public immutable ORACLE_REGISTRY;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Mapping of vault addresses to their state information
    mapping(address vault => VaultPriceStateV2 vaultPriceState) internal _vaultPriceStates;

    ////////////////////////////////////////////////////////////
    //                        Modifiers                        //
    ////////////////////////////////////////////////////////////

    modifier requiresVaultAuthOrAccountant(address vault) {
        // Requirements: check that the caller is either the vault's accountant or the vault's owner or has the
        // permission to call the function
        require(
            msg.sender == vaultAccountant[vault] || msg.sender == Auth(vault).owner()
                || Auth(vault).authority().canCall(msg.sender, address(this), msg.sig),
            Aera__CallerIsNotAuthorized()
        );
        _;
    }

    constructor(IERC20 numeraire, IOracleRegistry oracleRegistry, address owner_, Authority authority_)
        BaseFeeCalculator(owner_, authority_)
        HasNumeraire(address(numeraire))
    {
        // Requirements: check that the numeraire token and oracle registry are not zero address
        require(address(oracleRegistry) != address(0), Aera__ZeroAddressOracleRegistry());

        // Effects: set the numeraire token and oracle registry
        ORACLE_REGISTRY = oracleRegistry;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @notice Register a new vault with the fee calculator
    function registerVault() external override {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[msg.sender];
        // Requirements: check that the vault is not already registered
        require(vaultPriceState.anchorTimestamp == 0, Aera__VaultAlreadyRegistered());

        // Effects: initialize the vault state
        // anchor timestamp is set to indicate vault registration
        vaultPriceState.anchorTimestamp = uint32(block.timestamp);
        // Effects: default anchor policy violations to pause mode
        vaultPriceState.pauseOnBadAnchorUpdate = true;

        // Log that vault was registered
        emit VaultRegistered(msg.sender);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function setInitialPrice(address vault, uint128 price) external requiresVaultAuth(vault) {
        require(price != 0, Aera__InvalidPrice());

        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the tresholds are set (which implies the vault is registered) and the initial price
        // is not set
        require(vaultPriceState.maxPriceAge != 0, Aera__ThresholdNotSet());
        require(vaultPriceState.anchorPrice == 0, Aera__VaultAlreadyInitialized());

        uint32 timestampU32 = uint32(block.timestamp);

        // Effects: set the initial anchor price state
        vaultPriceState.anchorPrice = price;
        vaultPriceState.highestPrice = price;
        vaultPriceState.anchorTimestamp = timestampU32;
        vaultPriceState.accrualLag = 0;
        vaultPriceState.lastTotalSupply = IERC20(vault).totalSupply().toUint128();

        // Log initial anchor price state
        emit AnchorPriceUpdated(vault, price, timestampU32);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function setThresholds(
        address vault,
        uint16 minPriceToleranceRatio,
        uint16 maxPriceToleranceRatio,
        uint16 minUpdateIntervalMinutes,
        uint16 maxPriceAge,
        uint8 maxUpdateDelayDays
    ) external requiresVaultAuth(vault) {
        // Requirements: check that the min price decrease ratio is <= 100%
        require(minPriceToleranceRatio <= ONE_IN_BPS, Aera__InvalidMinPriceToleranceRatio());
        // Requirements: check that the max price increase ratio is >= 100%
        require(maxPriceToleranceRatio >= ONE_IN_BPS, Aera__InvalidMaxPriceToleranceRatio());
        // Requirements: check that the max price age is greater than zero
        require(maxPriceAge > 0, Aera__InvalidMaxPriceAge());
        // Requirements: check that the max update delay is greater than zero
        require(maxUpdateDelayDays > 0, Aera__InvalidMaxUpdateDelayDays());

        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the vault is registered
        require(vaultPriceState.anchorTimestamp != 0, Aera__VaultNotRegistered());

        // Effects: set the thresholds
        vaultPriceState.minPriceToleranceRatio = minPriceToleranceRatio;
        vaultPriceState.maxPriceToleranceRatio = maxPriceToleranceRatio;
        vaultPriceState.minUpdateIntervalMinutes = minUpdateIntervalMinutes;
        vaultPriceState.maxPriceAge = maxPriceAge;
        vaultPriceState.maxUpdateDelayDays = maxUpdateDelayDays;

        // Log that the thresholds were set
        emit ThresholdsSet(
            vault, minPriceToleranceRatio, maxPriceToleranceRatio, minUpdateIntervalMinutes, maxPriceAge, maxUpdateDelayDays
        );
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function setPauseOnBadAnchorUpdate(address vault, bool pauseOnBadAnchorUpdate) external requiresVaultAuth(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the vault is registered
        require(vaultPriceState.anchorTimestamp != 0, Aera__VaultNotRegistered());

        // Effects: set anchor policy failure mode
        vaultPriceState.pauseOnBadAnchorUpdate = pauseOnBadAnchorUpdate;

        // Log that anchor policy failure mode was changed
        emit PauseOnBadAnchorUpdateChanged(vault, pauseOnBadAnchorUpdate);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function setAnchorPrice(address vault, uint128 price, uint32 timestamp) external onlyVaultAccountant(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];
        uint256 latestPriceTimestamp = _getLastTimestamp(vaultPriceState);

        // Requirements: validate the anchor update
        _validatePriceUpdate(vaultPriceState, price, timestamp, latestPriceTimestamp);

        uint32 oldAnchorTimestamp = vaultPriceState.anchorTimestamp;
        if (!vaultPriceState.paused) {
            bool shouldPause = _shouldPauseAnchor(vaultPriceState, price, timestamp, oldAnchorTimestamp);

            if (shouldPause) {
                // Requirements: revert if pause-on-bad-anchor is disabled
                require(vaultPriceState.pauseOnBadAnchorUpdate, Aera__BadAnchorPriceUpdate());
                // Effects + Log: pause the vault
                _setVaultPaused(vaultPriceState, vault, true);
                // Effects: write the accrual lag
                unchecked {
                    // Cant overflow because _validatePriceUpdate requires timestamp > anchorTimestamp
                    vaultPriceState.accrualLag = timestamp - oldAnchorTimestamp;
                }
            } else {
                // Effects: accrue fees
                _accrueFees(vault, price, timestamp);
            }
        } else {
            // Effects: set the accrual lag
            unchecked {
                // Cant overflow because _validatePriceUpdate requires timestamp > anchorTimestamp
                vaultPriceState.accrualLag += timestamp - oldAnchorTimestamp;
            }
        }

        // Effects: set anchor state
        vaultPriceState.anchorPrice = price;
        vaultPriceState.anchorTimestamp = timestamp;

        // Log anchor price update
        emit AnchorPriceUpdated(vault, price, timestamp);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function setDriftPrice(address vault, uint128 price, uint32 timestamp) external onlyVaultAccountant(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the vault is active and validate the drift update
        require(!vaultPriceState.paused, Aera__VaultPaused());

        // Requirements: validate the drift price update
        _validatePriceUpdate(vaultPriceState, price, timestamp, _getLastTimestamp(vaultPriceState));

        // Requirements: check that the update delay is not exceeded
        require(
            !_isUpdateDelayExceeded(vaultPriceState.anchorTimestamp, timestamp, vaultPriceState.maxUpdateDelayDays),
            Aera__MaxUpdateDelayExceeded()
        );

        // Requirements: check that the vault is initialized
        uint256 anchorPrice = vaultPriceState.anchorPrice;
        require(anchorPrice != 0, Aera__VaultNotInitialized());

        // Requirements: check that the drift price is within the anchor tolerance band
        require(_isPriceWithinAnchorBand(vaultPriceState, anchorPrice, price), Aera__DriftOutsideAnchorBand());

        // Effects: write drift state
        vaultPriceState.driftPrice = price;
        vaultPriceState.driftTimestamp = timestamp;

        // Log drift price update
        emit DriftPriceUpdated(vault, price, timestamp);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function pauseVault(address vault) external requiresVaultAuthOrAccountant(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the vault is not already paused
        require(!vaultPriceState.paused, Aera__VaultPaused());

        // Effects + Log: pause the vault
        _setVaultPaused(vaultPriceState, vault, true);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function unpauseVault(address vault, uint128 price, uint32 timestamp) external requiresVaultAuth(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        // Requirements: check that the vault is paused, and the anchor price and timestamp match what is expected
        require(vaultPriceState.paused, Aera__VaultNotPaused());
        require(vaultPriceState.anchorPrice == price, Aera__UnitPriceMismatch());
        require(vaultPriceState.anchorTimestamp == timestamp, Aera__TimestampMismatch());

        // Effects: accrue fees
        _accrueFees(vault, price, timestamp);

        // Effects + Log: unpause the vault
        _setVaultPaused(vaultPriceState, vault, false);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function resetHighestPrice(address vault) external requiresVaultAuth(vault) {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];
        uint128 currentAnchorPrice = vaultPriceState.anchorPrice;

        // Requirements: check that the vault is initialized
        require(currentAnchorPrice != 0, Aera__VaultNotInitialized());

        // Requirements: check that we're resetting from a higher mark to a lower one
        require(currentAnchorPrice < vaultPriceState.highestPrice, Aera__CurrentPriceAboveHighestPrice());

        // Effects: reset the highest price to the current anchor price
        vaultPriceState.highestPrice = currentAnchorPrice;

        // Log the highest price reset
        emit HighestPriceReset(vault, currentAnchorPrice);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertUnitsToToken(address vault, IERC20 token, uint256 unitsAmount)
        external
        view
        returns (uint256 tokenAmount)
    {
        uint128 currentPrice = _getCurrentPrice(_vaultPriceStates[vault]);
        return _convertUnitsToToken(vault, token, unitsAmount, currentPrice, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertUnitsToTokenIfActive(address vault, IERC20 token, uint256 unitsAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 tokenAmount)
    {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];
        uint128 currentPrice = _getCurrentPrice(vaultPriceState);

        // check that the vault is not paused
        require(!vaultPriceState.paused, Aera__VaultPaused());

        return _convertUnitsToToken(vault, token, unitsAmount, currentPrice, rounding);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertUnitsToNumeraire(address vault, uint256 unitsAmount) external view returns (uint256) {
        uint128 currentPrice = _getCurrentPrice(_vaultPriceStates[vault]);
        return Math.mulDiv(unitsAmount, currentPrice, UNIT_PRICE_PRECISION);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertUnitsToNumeraire(address vault, uint256 unitsAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        uint128 currentPrice = _getCurrentPrice(_vaultPriceStates[vault]);

        return Math.mulDiv(unitsAmount, currentPrice, UNIT_PRICE_PRECISION, rounding);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertNumeraireToUnits(address vault, uint256 numeraireAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        uint128 currentPrice = _getCurrentPrice(_vaultPriceStates[vault]);

        return Math.mulDiv(numeraireAmount, UNIT_PRICE_PRECISION, currentPrice, rounding);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertNumeraireToToken(address vault, IERC20 token, uint256 numeraireAmount)
        external
        view
        returns (uint256)
    {
        if (address(token) == NUMERAIRE) return numeraireAmount;

        return ORACLE_REGISTRY.getQuoteForUser(numeraireAmount, NUMERAIRE, address(token), vault);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertTokenToNumeraire(address vault, IERC20 token, uint256 tokenAmount) external view returns (uint256) {
        if (address(token) == NUMERAIRE) return tokenAmount;

        return ORACLE_REGISTRY.getQuoteForUser(tokenAmount, address(token), NUMERAIRE, vault);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertTokenToUnits(address vault, IERC20 token, uint256 tokenAmount)
        external
        view
        returns (uint256 unitsAmount)
    {
        uint128 currentPrice = _getCurrentPrice(_vaultPriceStates[vault]);
        return _convertTokenToUnits(vault, token, tokenAmount, currentPrice, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function convertTokenToUnitsIfActive(address vault, IERC20 token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 unitsAmount)
    {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];
        uint128 currentPrice = _getCurrentPrice(vaultPriceState);

        // check that the vault is not paused
        require(!vaultPriceState.paused, Aera__VaultPaused());

        return _convertTokenToUnits(vault, token, tokenAmount, currentPrice, rounding);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function getVaultState(address vault) external view returns (VaultPriceStateV2 memory, VaultAccruals memory) {
        return (_vaultPriceStates[vault], _vaultAccruals[vault]);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function getVaultPriceTimestamp(address vault) external view returns (uint256 timestamp) {
        return _getLastTimestamp(_vaultPriceStates[vault]);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function getAnchorTimestamp(address vault) external view returns (uint32 timestamp) {
        return _vaultPriceStates[vault].anchorTimestamp;
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function getVaultValueAtLastUpdate(address vault) external view returns (uint256) {
        VaultPriceStateV2 storage vaultState = _vaultPriceStates[vault];

        // Requirements: check that the vault is not paused
        require(!vaultState.paused, Aera__VaultPaused());

        return Math.mulDiv(vaultState.lastTotalSupply, vaultState.anchorPrice, UNIT_PRICE_PRECISION);
    }

    /// @inheritdoc IPriceAndFeeCalculatorV2
    function isVaultPaused(address vault) external view returns (bool) {
        return _vaultPriceStates[vault].paused;
    }

    /// @inheritdoc BaseFeeCalculator
    function previewFees(address vault, uint256 feeTokenBalance) external view override returns (uint256, uint256) {
        VaultAccruals storage vaultAccruals = _vaultAccruals[vault];

        uint256 claimableProtocolFee = Math.min(feeTokenBalance, vaultAccruals.accruedProtocolFees);
        uint256 claimableVaultFee;
        unchecked {
            claimableVaultFee = Math.min(feeTokenBalance - claimableProtocolFee, vaultAccruals.accruedFees);
        }

        return (claimableVaultFee, claimableProtocolFee);
    }

    /// @inheritdoc IVersioned
    function version() external pure returns (string memory) {
        return "2.0";
    }

    ////////////////////////////////////////////////////////////
    //              Internal / Private Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Accrues fees for a vault
    /// @param vault The address of the vault
    /// @param price The price of a single vault unit
    /// @param timestamp The timestamp of the price update
    /// @dev It is assumed that validation has already been done
    /// Tvl is calculated as the product of the minimum of the current and last price and the minimum of the current and
    /// last total supply. This is to minimize potential issues with price spikes
    function _accrueFees(address vault, uint256 price, uint256 timestamp) internal {
        VaultPriceStateV2 storage vaultPriceState = _vaultPriceStates[vault];

        uint256 timeDelta;
        unchecked {
            timeDelta = timestamp - vaultPriceState.anchorTimestamp + vaultPriceState.accrualLag;
        }

        // Interactions: get the current total supply
        uint256 currentTotalSupply = IERC20(vault).totalSupply();
        uint256 minTotalSupply = Math.min(currentTotalSupply, uint256(vaultPriceState.lastTotalSupply));
        uint256 minUnitPrice = Math.min(price, uint256(vaultPriceState.anchorPrice));

        uint256 tvl = Math.mulDiv(minUnitPrice, minTotalSupply, UNIT_PRICE_PRECISION);

        VaultAccruals storage vaultAccruals = _vaultAccruals[vault];
        uint256 vaultFeesEarned = _calculateTvlFee(tvl, vaultAccruals.fees.tvl, timeDelta);

        uint256 protocolFeesEarned = _calculateTvlFee(tvl, protocolFees.tvl, timeDelta);

        if (price > vaultPriceState.highestPrice) {
            uint256 profit = Math.mulDiv(price - vaultPriceState.highestPrice, minTotalSupply, UNIT_PRICE_PRECISION);
            vaultFeesEarned += _calculatePerformanceFee(profit, vaultAccruals.fees.performance);
            protocolFeesEarned += _calculatePerformanceFee(profit, protocolFees.performance);

            // Effects: update the highest price
            vaultPriceState.highestPrice = uint128(price);
        }

        // Effects: update the accrued fees
        vaultAccruals.accruedFees += vaultFeesEarned.toUint112();
        vaultAccruals.accruedProtocolFees += protocolFeesEarned.toUint112();

        // Effects: update the last total supply and last fee accrual
        vaultPriceState.lastTotalSupply = currentTotalSupply.toUint128();
        vaultPriceState.accrualLag = 0;
    }

    /// @notice Sets the paused state for a vault
    /// @param vaultPriceState The storage pointer to the vault's price state
    /// @param vault The address of the vault
    /// @param paused The new paused state
    function _setVaultPaused(VaultPriceStateV2 storage vaultPriceState, address vault, bool paused) internal {
        // Effects: set the vault paused state
        vaultPriceState.paused = paused;

        // Log the vault paused state change
        emit VaultPausedChanged(vault, paused);
    }

    /// @notice Converts a token amount to units
    /// @param vault The address of the vault
    /// @param token The token to convert
    /// @param tokenAmount The amount of tokens to convert
    /// @param unitPrice The price of a single vault unit
    /// @param rounding The rounding direction
    /// @return unitsAmount The amount of units
    function _convertTokenToUnits(
        address vault,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitPrice,
        Math.Rounding rounding
    ) internal view returns (uint256 unitsAmount) {
        uint256 numeraireAmount = tokenAmount;
        if (address(token) != NUMERAIRE) {
            if (rounding == Math.Rounding.Ceil) {
                numeraireAmount = _getQuoteCeil(vault, tokenAmount, token, IERC20(NUMERAIRE));
            } else {
                numeraireAmount = ORACLE_REGISTRY.getQuoteForUser(tokenAmount, address(token), NUMERAIRE, vault);
            }
        }

        return Math.mulDiv(numeraireAmount, UNIT_PRICE_PRECISION, unitPrice, rounding);
    }

    /// @notice Converts a units amount to tokens
    /// @param vault The address of the vault
    /// @param token The token to convert
    /// @param unitsAmount The amount of units to convert
    /// @param unitPrice The price of a single vault unit
    /// @param rounding The rounding direction
    /// @return tokenAmount The amount of tokens
    function _convertUnitsToToken(
        address vault,
        IERC20 token,
        uint256 unitsAmount,
        uint256 unitPrice,
        Math.Rounding rounding
    ) internal view returns (uint256 tokenAmount) {
        uint256 numeraireAmount = Math.mulDiv(unitsAmount, unitPrice, UNIT_PRICE_PRECISION, rounding);

        if (address(token) == NUMERAIRE) {
            return numeraireAmount;
        }

        if (rounding == Math.Rounding.Ceil) {
            return _getQuoteCeil(vault, numeraireAmount, IERC20(NUMERAIRE), token);
        }

        return ORACLE_REGISTRY.getQuoteForUser(numeraireAmount, NUMERAIRE, address(token), vault);
    }

    /// @notice Returns the value of `baseAmount` of `baseToken` in `quoteToken` terms for `vault`
    /// @param vault The address of the vault used for oracle override resolution
    /// @param baseAmount The amount of base token to convert
    /// @param baseToken The base token being quoted
    /// @param quoteToken The quote token to convert into
    /// @return quoteAmount The ceil-rounded quote amount
    function _getQuoteCeil(address vault, uint256 baseAmount, IERC20 baseToken, IERC20 quoteToken)
        internal
        view
        returns (uint256 quoteAmount)
    {
        // Interactions: read base token decimals for one-token unit scaling
        uint256 baseTokenUnitAmount = 10 ** IERC20Metadata(address(baseToken)).decimals();
        // Interactions: fetch floor quote for one full base token unit
        uint256 quotePerBaseTokenUnit =
            ORACLE_REGISTRY.getQuoteForUser(baseTokenUnitAmount, address(baseToken), address(quoteToken), vault);

        uint256 quoteAmountFloor = Math.mulDiv(baseAmount, quotePerBaseTokenUnit, baseTokenUnitAmount);

        return
            mulmod(baseAmount, quotePerBaseTokenUnit, baseTokenUnitAmount) == 0
                ? quoteAmountFloor
                : quoteAmountFloor + 1;
    }

    /// @notice Validates a price update
    /// @dev Price is invalid if it is 0, before the last update, in the future, or if the price age is stale
    /// @param state The storage pointer to the vault's price state
    /// @param price The price of a single vault unit
    /// @param timestamp The timestamp of the price update
    /// @param referenceTimestamp The timestamp that the candidate update MUST be after
    function _validatePriceUpdate(
        VaultPriceStateV2 storage state,
        uint256 price,
        uint256 timestamp,
        uint256 referenceTimestamp
    ) internal view {
        // Requirements: check that the price is not 0
        require(price != 0, Aera__InvalidPrice());
        // Requirements: check that the price is not before the last update
        require(timestamp > referenceTimestamp, Aera__TimestampMustBeAfterLastUpdate());
        // Requirements: check that the price is not in the future
        require(block.timestamp >= timestamp, Aera__TimestampCantBeInFuture());

        uint256 maxPriceAge = state.maxPriceAge;
        // Requirements: check that the thresholds are set
        require(maxPriceAge != 0, Aera__ThresholdNotSet());
        // Requirements: check that the update price age is not stale
        require(maxPriceAge + timestamp >= block.timestamp, Aera__StalePrice());
    }

    /// @notice Determines if a price update should pause the vault
    /// @dev Vault should pause if the price increase or decrease is too large, or if the min update interval has not
    /// passed
    /// @param state The storage pointer to the vault's price state
    /// @param price The price of a single vault unit
    /// @param timestamp The timestamp of the price update
    /// @param anchorTimestamp The previous anchor timestamp
    /// @return shouldPause True if the price update should pause the vault, false otherwise
    function _shouldPauseAnchor(VaultPriceStateV2 storage state, uint256 price, uint32 timestamp, uint256 anchorTimestamp)
        internal
        view
        returns (bool)
    {
        unchecked {
            // Cant overflow because minUpdateIntervalMinutes is uint16 and timestamp is uint32
            if (timestamp < state.minUpdateIntervalMinutes * ONE_MINUTE + anchorTimestamp) {
                return true;
            }

            if (_isUpdateDelayExceeded(anchorTimestamp, timestamp, state.maxUpdateDelayDays)) {
                return true;
            }

            return !_isPriceWithinAnchorBand(state, state.anchorPrice, price);
        }
    }

    /// @notice Returns the current price by latest update between anchor and drift
    /// @param state The storage pointer to the vault's price state
    /// @return price Current price
    function _getCurrentPrice(VaultPriceStateV2 storage state) internal view returns (uint128 price) {
        uint256 anchorTimestamp = state.anchorTimestamp;
        uint256 driftTimestamp = state.driftTimestamp;

        if (driftTimestamp > anchorTimestamp) {
            return state.driftPrice;
        }

        return state.anchorPrice;
    }

    /// @notice Returns the latest timestamp between anchor and drift updates
    /// @param state The storage pointer to the vault's price state
    /// @return timestamp Active price timestamp
    function _getLastTimestamp(VaultPriceStateV2 storage state) internal view returns (uint256 timestamp) {
        return Math.max(state.driftTimestamp, state.anchorTimestamp);
    }

    /// @notice Validates whether a candidate price stays inside the anchor tolerance band
    /// @param state The storage pointer to the vault's price state
    /// @param anchorPrice The anchor price used for band checks
    /// @param candidatePrice The proposed price to validate against the anchor band
    /// @return isWithinBand True when candidate is inside the anchor tolerance band
    function _isPriceWithinAnchorBand(VaultPriceStateV2 storage state, uint256 anchorPrice, uint256 candidatePrice)
        internal
        view
        returns (bool isWithinBand)
    {
        unchecked {
            if (candidatePrice > anchorPrice) {
                // Cant overflow because maxPriceToleranceRatio is uint16 and anchorPrice is uint128
                return candidatePrice * ONE_IN_BPS <= anchorPrice * state.maxPriceToleranceRatio;
            }

            // Cant overflow because minPriceToleranceRatio is uint16 and anchorPrice is uint128
            return candidatePrice * ONE_IN_BPS >= anchorPrice * state.minPriceToleranceRatio;
        }
    }

    /// @notice Checks whether the elapsed time between updates exceeds configured max delay
    /// @param lastTimestamp The timestamp of the prior update
    /// @param timestamp The timestamp of the proposed update
    /// @param maxUpdateDelayDays Maximum allowed delay in days
    /// @return isExceeded True when elapsed time exceeds the configured maximum
    function _isUpdateDelayExceeded(uint256 lastTimestamp, uint256 timestamp, uint256 maxUpdateDelayDays)
        internal
        pure
        returns (bool isExceeded)
    {
        unchecked {
            // Cant overflow because timestamp is required to be > lastTimestamp in _validatePriceUpdate
            return timestamp - lastTimestamp > maxUpdateDelayDays * ONE_DAY;
        }
    }
}
