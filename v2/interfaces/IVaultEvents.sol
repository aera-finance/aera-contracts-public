// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/IERC20.sol";

import {AssetValue, Operation} from "../Types.sol";

/// @title Interface for vault events.
interface IVaultEvents {
    /// @notice Emitted when deposit is called.
    /// @param owner Owner address.
    /// @param asset Deposited asset.
    /// @param amount Deposited asset amount.
    event Deposit(address indexed owner, IERC20 indexed asset, uint256 amount);

    /// @notice Emitted when withdraw is called.
    /// @param owner Owner address.
    /// @param asset Withdrawn asset.
    /// @param amount Withdrawn asset amount.
    event Withdraw(
        address indexed owner, IERC20 indexed asset, uint256 amount
    );

    /// @notice Emitted when guardian is set.
    /// @param guardian Address of new guardian.
    /// @param feeRecipient Address of new fee recipient.
    event SetGuardianAndFeeRecipient(
        address indexed guardian, address indexed feeRecipient
    );

    /// @notice Emitted when asset registry is set.
    /// @param assetRegistry Address of new asset registry.
    event SetAssetRegistry(address assetRegistry);

    /// @notice Emitted when hooks is set.
    /// @param hooks Address of new hooks.
    event SetHooks(address hooks);

    /// @notice Emitted when execute is called.
    /// @param owner Owner address.
    /// @param operation Struct details for target and calldata.
    event Executed(address indexed owner, Operation operation);

    /// @notice Emitted when vault is finalized.
    /// @param owner Owner address.
    /// @param withdrawnAmounts Struct details for withdrawn assets and amounts (sent to owner).
    event Finalized(address indexed owner, AssetValue[] withdrawnAmounts);

    /// @notice Emitted when submit is called.
    /// @param guardian Guardian address.
    /// @param operations Array of struct details for targets and calldatas.
    event Submitted(address indexed guardian, Operation[] operations);

    /// @notice Emitted when guardian fees are claimed.
    /// @param feeRecipient Fee recipient address.
    /// @param claimedFee Claimed amount of fee token.
    /// @param unclaimedFee Unclaimed amount of fee token (unclaimed because Vault does not have enough balance of feeToken).
    /// @param feeTotal New total reserved fee value.
    event Claimed(
        address indexed feeRecipient,
        uint256 claimedFee,
        uint256 unclaimedFee,
        uint256 feeTotal
    );

    /// @notice Emitted when new fees are reserved for recipient.
    /// @param feeRecipient Fee recipient address.
    /// @param newFee Fee amount reserved.
    /// @param lastFeeCheckpoint Updated fee checkpoint.
    /// @param lastValue Last registered vault value.
    /// @param lastFeeTokenPrice Last registered fee token price.
    /// @param feeTotal New total reserved fee value.
    event FeesReserved(
        address indexed feeRecipient,
        uint256 newFee,
        uint256 lastFeeCheckpoint,
        uint256 lastValue,
        uint256 lastFeeTokenPrice,
        uint256 feeTotal
    );

    /// @notice Emitted when no fees are reserved.
    /// @param lastFeeCheckpoint Updated fee checkpoint.
    /// @param lastValue Last registered vault value.
    /// @param feeTotal New total reserved fee value.
    event NoFeesReserved(
        uint256 lastFeeCheckpoint,
        uint256 lastValue,
        uint256 feeTotal
    );

    /// @notice Emitted when the call to get spot prices from the asset registry reverts.
    /// @param reason Revert reason.
    event SpotPricesReverted(bytes reason);
}
