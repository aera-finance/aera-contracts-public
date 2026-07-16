// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/interfaces/IERC20.sol";
import { Authority } from "@solmate/auth/Auth.sol";

import { IFeeCalculator } from "src/core/interfaces/IFeeCalculator.sol";
import { ISubmitHooks } from "src/core/interfaces/ISubmitHooks.sol";
import { IWhitelist } from "src/core/interfaces/IWhitelist.sol";
import { IOracle } from "src/dependencies/oracles/IOracle.sol";

/// @notice Type of request: deposit/redeem and auto/fixed price
/// @dev
/// - The order is chosen so each bit encodes a property:
///   - Bit 0: 0 = deposit, 1 = redeem
///   - Bit 1: 0 = auto price, 1 = fixed price
enum RequestType {
    DEPOSIT_AUTO_PRICE, // 00: deposit, auto price
    REDEEM_AUTO_PRICE, // 01: redeem, auto price
    DEPOSIT_FIXED_PRICE, // 10: deposit, fixed price
    REDEEM_FIXED_PRICE // 11: redeem, fixed price
}

/// @notice Type of return value: no return, static return, dynamic return
/// @dev
/// - 00: no return
/// - 01: static return - hardcoded return data
/// - 10: dynamic return - return data is extracted from the results array
enum ReturnValueType {
    NO_RETURN,
    STATIC_RETURN,
    DYNAMIC_RETURN
}

/// @notice Type of hook call: before, after, or none
enum HookCallType {
    NONE,
    BEFORE,
    AFTER
}

/// @notice Operation struct for vault operations
/// @dev This struct is not used directly in core logic, but included for reference and clarity
///      It illustrates the full structure of an operation without storage packing
struct Operation {
    /// @notice Target contract address to call
    address target;
    /// @notice Calldata for the target contract
    bytes data;
    /// @notice Array of clipboard operations for copying return data
    Clipboard[] clipboards;
    /// @notice Whether to perform a static call
    bool isStaticCall;
    /// @notice Callback data for post-operation processing
    CallbackData callbackData;
    /// @notice Address of the hooks contract
    address hooks;
    /// @notice Array of offsets for extracting calldata
    uint16[] configurableHooksOffsets;
    /// @notice Merkle proof for operation verification
    bytes32[] proof;
    /// @notice ETH value to send with the call
    uint256 value;
}

/// @notice Operation execution context data
/// @dev Used to avoid stack too deep in BaseVault._executeSubmit function
struct OperationContext {
    /// @notice Address of the target contract to call
    address target;
    /// @notice Function selector extracted from calldata
    bytes4 selector;
    /// @notice Callback data packed
    uint208 callbackData;
    /// @notice ETH value to send with the call
    uint256 value;
    /// @notice Address of the operation-specific hooks contract
    address operationHooks;
    /// @notice Offset of the calldata extraction offsets packed in uint256
    uint256 configurableOperationHooks;
}

/// @notice Struct for payable operations
struct OperationPayable {
    /// @notice Target contract address
    address target;
    /// @notice Calldata for the target contract
    bytes data;
    /// @notice ETH value to send with the call
    uint256 value;
}

/// @notice Struct for token approvals
struct Approval {
    /// @notice Token address to approve
    address token;
    /// @notice Address to approve spending for
    address spender;
}

/// @notice Struct for token amounts
struct TokenAmount {
    /// @notice ERC20 token address
    IERC20 token;
    /// @notice Amount of tokens
    uint256 amount;
}

/// @notice Struct for clipboard operations
struct Clipboard {
    /// @notice Index of the result to copy from
    uint8 resultIndex;
    /// @notice Which word to copy from the result
    uint8 copyWord;
    /// @notice Offset to paste the copied data
    uint16 pasteOffset;
}

/// @notice Struct for callback data
struct CallbackData {
    /// @notice Address allowed to execute the callback
    address caller;
    /// @notice Function selector for the callback
    bytes4 selector;
    /// @notice Offset in calldata for the callback
    uint16 calldataOffset;
}

/// @notice Vault parameters for vault deployment
struct BaseVaultParameters {
    /// @notice Initial owner address
    address owner;
    /// @notice Initial authority address
    Authority authority;
    /// @notice Submit hooks address
    ISubmitHooks submitHooks;
    /// @notice Whitelist contract address
    IWhitelist whitelist;
}

/// @notice Parameters for fee vault deployment
struct FeeVaultParameters {
    /// @notice The fee calculator address
    IFeeCalculator feeCalculator;
    /// @notice The fee token address
    IERC20 feeToken;
    /// @notice The fee recipient address
    address feeRecipient;
}

/// @notice Parameters for ERC20 deployment
struct ERC20Parameters {
    /// @notice ERC20 token name
    string name;
    /// @notice ERC20 token symbol
    string symbol;
}

/// @notice Fee structure for TVL and performance fees
/// @dev All fees are in basis points (1/10000)
struct Fee {
    /// @notice TVL fee in basis points
    uint16 tvl;
    /// @notice Performance fee in basis points
    uint16 performance;
}

/// @notice Tracks fee configuration and accrued fees for a vault
struct VaultAccruals {
    /// @notice Current fee rates for the vault
    Fee fees;
    /// @notice Accrued fees for the vault fee recipient
    uint112 accruedFees;
    /// @notice Total protocol fees accrued but not claimed
    uint112 accruedProtocolFees;
}

/// @notice Complete state of a vault's fee configuration and accruals
struct VaultSnapshot {
    /// @notice Timestamp of last fee accrual
    uint32 lastFeeAccrual;
    /// @notice Timestamp when snapshot was taken
    uint32 timestamp;
    /// @notice Timestamp when snapshot is finalized after dispute period
    uint32 finalizedAt;
    /// @notice Average value of vault assets during snapshot period
    uint160 averageValue;
    /// @notice Highest profit achieved during snapshot period
    uint128 highestProfit;
    /// @notice Highest profit achieved in previous periods
    uint128 lastHighestProfit;
}

/// @notice Struct for target and calldata
struct TargetCalldata {
    /// @notice Target contract address
    address target;
    /// @notice Calldata for the target contract
    bytes data;
}

/// @notice Vault price information and configuration
struct VaultPriceStateV2 {
    /// @notice Whether vault price updates are paused
    bool paused;
    /// @notice Whether policy-violating anchor updates pause (`true`) or revert (`false`)
    bool pauseOnBadAnchorUpdate;
    /// @notice Maximum age of price data in seconds before it is considered stale
    uint16 maxPriceAge;
    /// @notice Minimum time between anchor updates in minutes
    uint16 minUpdateIntervalMinutes;
    /// @notice Maximum allowed price increase ratio in basis points
    uint16 maxPriceToleranceRatio;
    /// @notice Minimum allowed price decrease ratio in basis points
    uint16 minPriceToleranceRatio;
    /// @notice Maximum allowed delay in price updates in days
    uint8 maxUpdateDelayDays;
    /// @notice Seconds between last fee accrual and last anchor update
    uint32 accrualLag;
    /// @notice Timestamp of last anchor update
    uint32 anchorTimestamp;
    /// @notice Timestamp of last drift update
    uint32 driftTimestamp;
    /// @notice Current anchor price
    uint128 anchorPrice;
    /// @notice Current drift price
    uint128 driftPrice;
    /// @notice Highest historical price
    uint128 highestPrice;
    /// @notice Total supply at last price update
    uint128 lastTotalSupply;
}

/// @notice Full token configuration stored on-chain
struct TokenDetailsV2 {
    /// @notice Whether async deposits are enabled
    bool asyncDepositEnabled;
    /// @notice Whether async redemptions are enabled
    bool asyncRedeemEnabled;
    /// @notice Whether sync deposits are enabled
    bool syncDepositEnabled;
    /// @notice Whether sync redeems are enabled
    bool syncRedeemEnabled;
    /// @notice Premium multiplier for async deposits in basis points (9999 = 0.1% premium)
    uint16 asyncDepositMultiplier;
    /// @notice Premium multiplier for async redeems in basis points (9999 = 0.1% premium)
    uint16 asyncRedeemMultiplier;
    /// @notice Premium multiplier for sync deposits in basis points (9999 = 0.1% premium)
    uint16 syncDepositMultiplier;
    /// @notice Premium multiplier for sync redeems in basis points (9999 = 0.1% premium)
    /// @dev Used as per-token flat premium component for sync redeem
    uint16 syncRedeemMultiplier;
    /// @notice SSTORE2 pointer for push-funds submit data
    /// @dev address(0) means push-funds is disabled for that token
    address pushFundsSubmitDataPointer;
    /// @notice SSTORE2 pointer for pull-funds submit data
    /// @dev address(0) means pull-funds is disabled for that token
    address pullFundsSubmitDataPointer;
}

/// @notice Request parameters for deposits and redemptions
/// @dev
/// - For deposits:
///   - units: minimum units the user wants to receive (minUnitsOut)
///   - tokens: amount of tokens the user is providing (tokensIn)
/// - For redemptions:
///   - units: amount of units the user is redeeming (unitsIn)
///   - tokens: minimum tokens the user wants to receive (minTokensOut)
struct RequestV2 {
    /// @notice Request type(deposit/redeem + auto/fixed price)
    RequestType requestType;
    /// @notice User address making the request
    address user;
    /// @notice Address that gets units/tokens when the order is solved
    address receiver;
    /// @notice Amount of vault units
    uint256 units;
    /// @notice Amount of underlying tokens
    uint256 tokens;
    /// @notice Tip paid to solver, always in tokens
    uint256 solverTip;
    /// @notice Timestamp after which request expires
    uint256 deadline;
    /// @notice Maximum age of price data allowed
    uint256 maxPriceAge;
}

/// @notice Oracle data for a base/quote pair, including current, pending, and status flags
struct OracleData {
    /// @notice True if an oracle update is scheduled
    bool isScheduledForUpdate;
    /// @notice True if the current oracle is disabled
    bool isDisabled;
    /// @notice The currently active oracle
    IOracle oracle;
    /// @notice The pending oracle to be activated after delay
    IOracle pendingOracle;
    /// @notice Timestamp at which the pending oracle can be committed
    uint32 commitTimestamp;
}
