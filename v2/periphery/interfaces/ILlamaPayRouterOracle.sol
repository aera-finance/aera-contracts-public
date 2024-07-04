// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/IERC20.sol";
import {Operation} from "src/v2/Types.sol";
import {IExecutor} from "./IExecutor.sol";
import {ILlamaPayRouterOracleTypes} from "./ILlamaPayRouterOracleTypes.sol";

/// @title ILlamaPayRouterOracle.
interface ILlamaPayRouterOracle is IExecutor, ILlamaPayRouterOracleTypes {
    /// @notice Creates a LlamaPay stream and remembers the end date.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if endDate ≤ block.timestamp.
    /// @dev MUST revert if token is not part of a supported LlamaPay contract.
    /// @param token The token of the stream.
    /// @param to The address of the stream.
    /// @param amountPerSec The amount per second of the stream. Must use 20 decimals.
    /// @param duration Duration of the stream in seconds.
    function createStream(
        IERC20 token,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external;

    /// @notice Cancel a given stream. Just calls the same function on LlamaPay.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token of the stream.
    /// @param to The address of the stream.
    /// @param amountPerSec The amount per second of the stream. Must use 20 decimals.
    function cancelStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external;

    /// @notice Pause a given stream. Just calls the same function on LlamaPay.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token of the stream.
    /// @param to The address of the stream.
    /// @param amountPerSec The amount per second of the stream. Must use 20 decimals.
    function pauseStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external;

    /// @notice Cancel a given stream if block.timestamp ≥ endDate for that stream.
    /// @dev MUST revert if endDate > block.timestamp.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token of the stream.
    /// @param to The address of the stream.
    /// @param amountPerSec The amount per second of the stream. Must use 20 decimals.
    function cancelExpiredStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external;

    /// @notice Modifies an existing LlamaPay stream.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if endDate ≤ block.timestamp.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token of the stream.
    /// @param oldTo The address of the stream.
    /// @param oldAmountPerSec The amount per second of the stream. Must use 20 decimals.
    /// @param to The new address of the stream.
    /// @param amountPerSec The new amount per second of the stream. Must use 20 decimals.
    /// @param duration Duration of the stream in seconds.
    function modifyStream(
        IERC20 token,
        address oldTo,
        uint216 oldAmountPerSec,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external;

    /// @notice Forwards a deposit on behalf of vault.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token to deposit.
    /// @param amount The amount to deposit.
    function deposit(IERC20 token, uint256 amount) external;

    /// @notice Creates a LlamaPay stream with a deposit and remembers the end date.
    /// @dev MUST revert if not called by vault.
    /// @dev MUST revert if endDate ≤ block.timestamp.
    /// @dev MUST revert if stream doesn't exist.
    /// @param token The token to deposit.
    /// @param amountToDeposit The amount to deposit.
    /// @param to The address to send the stream to.
    /// @param amountPerSec The amount per second to send. Must use 20 decimals.
    /// @param duration Duration of the stream in seconds.
    function depositAndCreate(
        IERC20 token,
        uint256 amountToDeposit,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external;

    /// @notice Recover money back to vault.
    /// @dev MUST revert if not called by vault.
    /// @param token The token to withdraw.
    /// @param amount The amount to withdraw. Must use 20 decimals.
    function withdrawPayer(IERC20 token, uint256 amount) external;

    /// @notice Recover all money back to vault.
    /// @dev MUST revert if not called by vault.
    /// @param token The token to withdraw.
    function withdrawPayerAll(IERC20 token) external;

    /// @notice Returns the end date of a given stream.
    /// @param token The token of the stream.
    /// @param to The address of the stream.
    /// @param amountPerSec The amount per second of the stream. Must use 20 decimals.
    /// @return endDate The end date of the stream.
    function endDate(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external view returns (uint256);

    /// @notice Returns Vault address.
    /// @return vault The Vault address.
    function vault() external view returns (address);

    /// @notice Returns the LlamaPay Info list.
    /// @return llamaPayInfoList The LlamaPay Info list.
    function llamaPayInfoList()
        external
        view
        returns (LlamaPayInfo[] memory);
}