// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { VaultAccruals, VaultPriceStateV2 } from "src/core/Types.sol";
import { IVersioned } from "src/core/interfaces/IVersioned.sol";

/// @title IPriceAndFeeCalculator
/// @notice Interface for the unit price provider
interface IPriceAndFeeCalculatorV2 is IVersioned {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when thresholds are set for a vault
    /// @param vault The address of the vault
    /// @param minPriceToleranceRatio Minimum ratio (of a price decrease) in basis points
    /// @param maxPriceToleranceRatio Maximum ratio (of a price increase) in basis points
    /// @param minUpdateIntervalMinutes The minimum interval between updates in minutes
    /// @param maxPriceAge Max delay between when a vault was priced and when the price is acceptable
    /// @param maxUpdateDelayDays Max delay between two price updates in days
    event ThresholdsSet(
        address indexed vault,
        uint16 minPriceToleranceRatio,
        uint16 maxPriceToleranceRatio,
        uint16 minUpdateIntervalMinutes,
        uint16 maxPriceAge,
        uint8 maxUpdateDelayDays
    );

    /// @notice Emitted when we change whether out-of-range updates should pause or revert
    /// @param vault The address of the vault
    /// @param pauseOnBadAnchorUpdate True to pause on bad anchor update, false to revert
    event PauseOnBadAnchorUpdateChanged(address indexed vault, bool pauseOnBadAnchorUpdate);

    /// @notice Emitted when a vault's anchor price is updated
    /// @param vault The address of the vault
    /// @param price The new anchor price
    /// @param timestamp The timestamp of the new anchor price
    event AnchorPriceUpdated(address indexed vault, uint128 price, uint32 timestamp);

    /// @notice Emitted when a vault's drift price is updated
    /// @param vault The address of the vault
    /// @param price The new drift price
    /// @param timestamp The timestamp of the new drift price
    event DriftPriceUpdated(address indexed vault, uint128 price, uint32 timestamp);

    /// @notice Emitted when a vault's paused state is changed
    /// @param vault The address of the vault
    /// @param paused Whether the vault is paused
    event VaultPausedChanged(address indexed vault, bool paused);

    /// @notice Emitted when a vault's highest price is reset
    /// @param vault The address of the vault
    /// @param newHighestPrice The new highest price
    event HighestPriceReset(address indexed vault, uint128 newHighestPrice);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__StalePrice();
    error Aera__TimestampMustBeAfterLastUpdate();
    error Aera__TimestampCantBeInFuture();
    error Aera__ZeroAddressOracleRegistry();
    error Aera__InvalidMaxPriceToleranceRatio();
    error Aera__InvalidMinPriceToleranceRatio();
    error Aera__InvalidMaxPriceAge();
    error Aera__InvalidMaxUpdateDelayDays();
    error Aera__ThresholdNotSet();
    error Aera__VaultPaused();
    error Aera__VaultNotPaused();
    error Aera__UnitPriceMismatch();
    error Aera__TimestampMismatch();
    error Aera__VaultAlreadyInitialized();
    error Aera__VaultNotInitialized();
    error Aera__InvalidPrice();
    error Aera__CurrentPriceAboveHighestPrice();
    error Aera__DriftOutsideAnchorBand();
    error Aera__MaxUpdateDelayExceeded();
    error Aera__BadAnchorPriceUpdate();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Set the initial anchor price state for the vault
    /// @param vault Address of the vault
    /// @param price New initial anchor price
    function setInitialPrice(address vault, uint128 price) external;

    /// @notice Set vault thresholds
    /// @param vault Address of the vault
    /// @param minPriceToleranceRatio Minimum ratio (of a price decrease) in basis points
    /// @param maxPriceToleranceRatio Maximum ratio (of a price increase) in basis points
    /// @param minUpdateIntervalMinutes The minimum interval between updates in minutes
    /// @param maxPriceAge Max delay between when a vault was priced and when the price is acceptable
    /// @param maxUpdateDelayDays Max delay between two price updates
    function setThresholds(
        address vault,
        uint16 minPriceToleranceRatio,
        uint16 maxPriceToleranceRatio,
        uint16 minUpdateIntervalMinutes,
        uint16 maxPriceAge,
        uint8 maxUpdateDelayDays
    ) external;

    /// @notice Set whether out-of-range updates should pause or revert
    /// @param vault Address of the vault
    /// @param pauseOnBadAnchorUpdate True to pause on bad anchor update, false to revert atomically
    /// @dev MUST be configurable by vault owner/authority
    function setPauseOnBadAnchorUpdate(address vault, bool pauseOnBadAnchorUpdate) external;

    /// @notice Set the anchor price for the vault in numeraire terms
    /// @param vault Address of the vault
    /// @param price New anchor price
    /// @param timestamp Timestamp when the anchor price was measured
    function setAnchorPrice(address vault, uint128 price, uint32 timestamp) external;

    /// @notice Set the drift price for the vault in numeraire terms
    /// @param vault Address of the vault
    /// @param price New drift price
    /// @param timestamp Timestamp when the drift price was measured
    /// @dev MUST revert when the vault is paused
    /// @dev MUST revert when drift update violates drift policy constraints
    function setDriftPrice(address vault, uint128 price, uint32 timestamp) external;

    /// @notice Pause the vault
    /// @param vault Address of the vault
    function pauseVault(address vault) external;

    /// @notice Unpause the vault
    /// @param vault Address of the vault
    /// @param price Expected anchor price at unpause time
    /// @param timestamp Expected anchor timestamp at unpause time
    /// @dev MUST revert if price or timestamp don't exactly match the current anchor tuple
    function unpauseVault(address vault, uint128 price, uint32 timestamp) external;

    /// @notice Resets the highest price for a vault to the current anchor price
    /// @param vault Address of the vault
    function resetHighestPrice(address vault) external;

    /// @notice Convert units to token amount
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param unitsAmount Amount of units
    /// @return tokenAmount Amount of tokens
    function convertUnitsToToken(address vault, IERC20 token, uint256 unitsAmount)
        external
        view
        returns (uint256 tokenAmount);

    /// @notice Convert units to token amount if vault is not paused
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param unitsAmount Amount of units
    /// @param rounding The rounding mode
    /// @return tokenAmount Amount of tokens
    /// @dev MUST revert if vault is paused
    function convertUnitsToTokenIfActive(address vault, IERC20 token, uint256 unitsAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 tokenAmount);

    /// @notice Convert token amount to units
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param tokenAmount Amount of tokens
    /// @return unitsAmount Amount of units
    function convertTokenToUnits(address vault, IERC20 token, uint256 tokenAmount)
        external
        view
        returns (uint256 unitsAmount);

    /// @notice Convert token amount to units if vault is not paused
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param tokenAmount Amount of tokens
    /// @param rounding The rounding mode
    /// @return unitsAmount Amount of units
    /// @dev MUST revert if vault is paused
    function convertTokenToUnitsIfActive(address vault, IERC20 token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 unitsAmount);

    /// @notice Convert units to numeraire token amount
    /// @param vault Address of the vault
    /// @param unitsAmount Amount of units
    /// @return numeraireAmount Amount of numeraire
    function convertUnitsToNumeraire(address vault, uint256 unitsAmount) external view returns (uint256 numeraireAmount);

    /// @notice Convert units to numeraire token amount with rounding control
    /// @param vault Address of the vault
    /// @param unitsAmount Amount of units
    /// @param rounding The rounding mode
    /// @return numeraireAmount Amount of numeraire
    function convertUnitsToNumeraire(address vault, uint256 unitsAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 numeraireAmount);

    /// @notice Convert numeraire amount to vault units
    /// @param vault Address of the vault
    /// @param numeraireAmount Amount of numeraire
    /// @param rounding The rounding mode
    /// @return unitsAmount Amount of units
    function convertNumeraireToUnits(address vault, uint256 numeraireAmount, Math.Rounding rounding)
        external
        view
        returns (uint256 unitsAmount);

    /// @notice Convert numeraire amount to token amount via oracle
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param numeraireAmount Amount of numeraire
    /// @return tokenAmount Amount of tokens
    /// @dev Returns numeraireAmount unchanged when token is the numeraire
    function convertNumeraireToToken(address vault, IERC20 token, uint256 numeraireAmount)
        external
        view
        returns (uint256 tokenAmount);

    /// @notice Convert token amount to numeraire via oracle
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param tokenAmount Amount of tokens
    /// @return numeraireAmount Amount of numeraire
    /// @dev Returns tokenAmount unchanged when token is the numeraire
    function convertTokenToNumeraire(address vault, IERC20 token, uint256 tokenAmount)
        external
        view
        returns (uint256 numeraireAmount);

    /// @notice Return the state of the vault
    /// @param vault Address of the vault
    /// @return vaultPriceState The price state of the vault
    /// @return vaultAccruals The accruals state of the vault
    function getVaultState(address vault) external view returns (VaultPriceStateV2 memory, VaultAccruals memory);

    /// @notice Returns the timestamp of the last submitted price for a vault
    /// @param vault Address of the vault
    /// @return timestamp The timestamp of the vault's last price update
    function getVaultPriceTimestamp(address vault) external view returns (uint256 timestamp);

    /// @notice Returns the timestamp of the last submitted anchor price for a vault
    /// @param vault Address of the vault
    /// @return timestamp The timestamp of the vault's current anchor price
    function getAnchorTimestamp(address vault) external view returns (uint32 timestamp);

    /// @notice Returns the vault value in numeraire at the last price update
    /// @param vault Address of the vault
    /// @return vaultValue The vault value in numeraire computed from lastTotalSupply and anchorPrice
    /// @dev MUST revert if the vault is paused
    function getVaultValueAtLastUpdate(address vault) external view returns (uint256 vaultValue);

    /// @notice Check if a vault is paused
    /// @param vault The address of the vault
    /// @return True if the vault is paused, false otherwise
    function isVaultPaused(address vault) external view returns (bool);
}
