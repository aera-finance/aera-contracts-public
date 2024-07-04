// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/IERC20.sol";
import {ILlamaPay} from "periphery/dependencies/llamapay/ILlamaPay.sol";

/// @title ILlamaPayRouterOracleTypes.
/// @notice The types used by the ILlamaPayRouterOracle.
interface ILlamaPayRouterOracleTypes {
    /// STRUCTS ///

    struct LlamaPayInfo {
        ILlamaPay llamaPay;
        address priceFeed;
        bool invertPrice;
    }

    /// ERRORS ///

    /// @dev Thrown when the llamaPayCount is zero.
    error AeraPeriphery__LlamaPayInfoCountIsZero();
    /// @dev Thrown when the llamaPayCount exceeds the maximum.
    error AeraPeriphery__LlamaPayInfoCountExceedsMax(uint256 maxLlamaPayCount);
    /// @dev Thrown when the caller is not the Vault owner.
    error AeraPeriphery__CallerIsNotVaultOwner(address caller);
    /// @dev Thrown when the caller is not the Vault.
    error AeraPeriphery__CallerIsNotVault(address caller);
    /// @dev Thrown when the token is invalid.
    error AeraPeriphery__InvalidToken(IERC20 token);
    /// @dev Thrown when the duration is zero when creating a new stream.
    error AeraPeriphery__DurationIsZero();
    /// @dev Thrown when the endDate is in the future when trying to cancel stream or stream does not exist.
    error AeraPeriphery__StreamNotExpired(uint256 endDate);
    /// @dev Thrown when stream does not exist.
    error AeraPeriphery__StreamDoesNotExist(
        IERC20 token, address to, uint216 amountPerSec
    );

    /// EVENTS ///

    /// @dev Emitted when a new LlamaPay stream is created.
    event ExpiringStreamCreated(
        IERC20 indexed token,
        address indexed to,
        uint216 indexed amountPerSec,
        uint256 duration
    );
}