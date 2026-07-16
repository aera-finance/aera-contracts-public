// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { RequestV2, TokenDetailsV2 } from "src/core/Types.sol";
import { IVersioned } from "src/core/interfaces/IVersioned.sol";

/// @title IProvisioner
/// @notice Interface for the contract that can mint and burn vault units in exchange for tokens
interface IProvisionerV2 is IVersioned {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when a user deposits tokens directly into the vault
    /// @param user The address of the depositor
    /// @param token The token being deposited
    /// @param tokensIn The amount of tokens deposited
    /// @param unitsOut The amount of units minted
    /// @param depositHash Unique identifier for this deposit
    event Deposited(
        address indexed user, IERC20 indexed token, uint256 tokensIn, uint256 unitsOut, bytes32 depositHash
    );

    /// @notice Emitted when a user deposits tokens directly into the vault
    /// @param user The address of the depositor
    /// @param receiver The address receiving the units
    /// @param token The token being deposited
    /// @param tokensIn The amount of tokens deposited
    /// @param unitsOut The amount of units minted
    /// @param depositHash Unique identifier for this deposit
    event Deposited(
        address indexed user,
        address indexed receiver,
        IERC20 indexed token,
        uint256 tokensIn,
        uint256 unitsOut,
        bytes32 depositHash
    );

    /// @notice Emitted when a deposit is refunded
    /// @param depositHash The hash of the deposit being refunded
    event DepositRefunded(bytes32 indexed depositHash);

    /// @notice Emitted when a direct (sync) deposit is refunded
    /// @param depositHash The hash of the deposit being refunded
    event DirectDepositRefunded(bytes32 indexed depositHash);

    /// @notice Emitted when a user creates a deposit request
    /// @param user The address requesting the deposit
    /// @param token The token being deposited
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param solverTip The tip offered to the solver in deposit token terms
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param depositRequestHash The hash of the deposit request
    event DepositRequested(
        address indexed user,
        IERC20 indexed token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        bytes32 depositRequestHash
    );

    /// @notice Emitted when a user creates a redeem request
    /// @param user The address requesting the redemption
    /// @param token The token requested in return for units
    /// @param minTokensOut The minimum amount of tokens the user expects to receive
    /// @param unitsIn The amount of units being redeemed
    /// @param solverTip The tip offered to the solver in redeem token terms
    /// @param deadline The timestamp until which this request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param redeemRequestHash The hash of the redeem request
    event RedeemRequested(
        address indexed user,
        IERC20 indexed token,
        uint256 minTokensOut,
        uint256 unitsIn,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        bytes32 redeemRequestHash
    );

    /// @notice Emitted when a deposit request is solved successfully
    /// @param depositHash The unique identifier of the deposit request that was solved
    event DepositSolved(bytes32 indexed depositHash);

    /// @notice Emitted when a redeem request is solved successfully
    /// @param redeemHash The unique identifier of the redeem request that was solved
    event RedeemSolved(bytes32 indexed redeemHash);

    /// @notice Emitted when an unrecognized async deposit hash is used
    /// @param depositHash The deposit hash that was not found in async records
    event InvalidRequestHash(bytes32 indexed depositHash);

    /// @notice Emitted when async deposits are disabled and a deposit request cannot be processed
    /// @param index The index of the deposit request that was rejected
    event AsyncDepositDisabled(uint256 indexed index);

    /// @notice Emitted when async redeems are disabled and a redeem request cannot be processed
    /// @param index The index of the redeem request that was rejected
    event AsyncRedeemDisabled(uint256 indexed index);

    /// @notice Emitted when the price age exceeds the maximum allowed for a request
    /// @param index The index of the request that was rejected
    event PriceAgeExceeded(uint256 indexed index);

    /// @notice Emitted when a deposit exceeds the vault's configured deposit cap
    /// @param index The index of the request that was rejected
    event DepositCapExceeded(uint256 indexed index);

    /// @notice Emitted when there are not enough tokens to cover the required solver tip
    /// @param index The index of the request that was rejected
    event InsufficientTokensForTip(uint256 indexed index);

    /// @notice Emitted when the output units are less than the amount requested
    /// @param index The index of the request that was rejected
    /// @param amount The actual amount
    /// @param bound The minimum amount
    event AmountBoundExceeded(uint256 indexed index, uint256 amount, uint256 bound);

    /// @notice Emitted when a redeem request is refunded due to expiration or cancellation
    /// @param redeemHash The unique identifier of the redeem request that was refunded
    event RedeemRefunded(bytes32 indexed redeemHash);

    /// @notice Emitted when cancellation toggles and fee configuration are updated
    /// @param depositCancellationsEnabled Whether user-initiated deposit request cancellations are enabled
    /// @param redeemCancellationsEnabled Whether user-initiated redeem request cancellations are enabled
    /// @param depositCancellationFeeNumeraire Fixed pre-deadline deposit cancellation fee, in numeraire
    /// @param redeemCancellationFeeNumeraire Fixed pre-deadline redeem cancellation fee, in numeraire
    /// @param redeemCancellationDynamicFeeCapNumeraire Dynamic pre-deadline redeem cancellation fee cap, in numeraire
    /// @param redeemCancellationCapNumeraire Maximum redeem request size users can self-cancel, in numeraire
    event CancellationDetailsUpdated(
        bool depositCancellationsEnabled,
        bool redeemCancellationsEnabled,
        uint80 depositCancellationFeeNumeraire,
        uint80 redeemCancellationFeeNumeraire,
        uint80 redeemCancellationDynamicFeeCapNumeraire,
        uint80 redeemCancellationCapNumeraire
    );

    /// @notice Emitted when the vault's deposit limits are updated
    /// @param depositCap The new maximum total value that can be deposited into the vault
    /// @param depositRefundTimeout The new time window during which deposits can be refunded
    event DepositDetailsUpdated(uint224 depositCap, uint32 depositRefundTimeout);

    /// @notice Emitted when a token's deposit/withdrawal settings are updated
    /// @param token The token whose settings are being updated
    /// @param tokensDetails The new token details
    event TokenDetailsSet(IERC20 indexed token, TokenDetailsV2 tokensDetails);

    /// @notice Emitted when a token is removed from the provisioner
    /// @param token The token that was removed
    event TokenRemoved(IERC20 indexed token);

    /// @notice Emitted when a user creates a deposit request with a receiver
    /// @param user The address requesting the deposit
    /// @param receiver The address receiving units when solved
    /// @param token The token being deposited
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param solverTip The tip offered to the solver in deposit token terms
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param depositRequestHash The hash of the deposit request
    event DepositRequested(
        address indexed user,
        address indexed receiver,
        IERC20 indexed token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        bytes32 depositRequestHash
    );

    /// @notice Emitted when a user creates a redeem request with a receiver
    /// @param user The address requesting the redemption
    /// @param receiver The address receiving tokens when solved
    /// @param token The token requested in return for units
    /// @param minTokensOut The minimum amount of tokens the user expects to receive
    /// @param unitsIn The amount of units being redeemed
    /// @param solverTip The tip offered to the solver in redeem token terms
    /// @param deadline The timestamp until which this request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param redeemRequestHash The hash of the redeem request
    event RedeemRequested(
        address indexed user,
        address indexed receiver,
        IERC20 indexed token,
        uint256 minTokensOut,
        uint256 unitsIn,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        bytes32 redeemRequestHash
    );

    /// @notice Emitted when a user performs synchronous exit (`redeem` or `withdraw`)
    /// @param user The address of the redeemer
    /// @param receiver The address of the receiver
    /// @param token The token being redeemed
    /// @param unitsIn The amount of units burned
    /// @param tokensOut The amount of tokens sent to receiver
    event Redeemed(
        address indexed user, address indexed receiver, IERC20 indexed token, uint256 unitsIn, uint256 tokensOut
    );

    /// @notice Emitted when global sync redeem risk parameters are updated
    /// @param maxPriceAge Maximum allowed vault price age (seconds)
    /// @param relativeCapBps Relative cap in bps of epoch-start TVL (numeraire)
    /// @param absoluteCapNumeraire Absolute cap in numeraire per epoch
    /// @param maxDynamicPremiumBps Maximum global dynamic premium in bps
    event SyncRedeemDetailsUpdated(
        uint24 maxPriceAge, uint16 relativeCapBps, uint80 absoluteCapNumeraire, uint16 maxDynamicPremiumBps
    );

    /// @notice Emitted when the solving gate contract is updated
    /// @param solvingGate The new solving gate address (address(0) disables gating)
    event SolvingGateUpdated(address indexed solvingGate);

    /// @notice Emitted when a receiver updates a depositor's approval to deposit on their behalf
    /// @param receiver The address that will receive units
    /// @param depositor The address being approved or revoked
    /// @param approved Whether the depositor is approved
    event DepositReceiverApprovalSet(address indexed receiver, address indexed depositor, bool approved);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__SyncDepositDisabled();
    error Aera__AsyncDepositDisabled();
    error Aera__AsyncRedeemDisabled();
    error Aera__DepositCapExceeded();
    error Aera__MinUnitsOutNotMet();
    error Aera__UnitsZero();
    error Aera__TokensZero();
    error Aera__MaxTokensInExceeded();
    error Aera__MaxDepositRefundTimeoutExceeded();
    error Aera__DepositHashNotFound();
    error Aera__HashNotFound();
    error Aera__RefundPeriodExpired();
    error Aera__DeadlineInPast();
    error Aera__DeadlineTooFarInFuture();
    error Aera__DeadlineInFutureAndUnauthorized();
    error Aera__HashCollision();
    error Aera__ZeroAddressPriceAndFeeCalculator();
    error Aera__ZeroAddressMultiDepositorVault();
    error Aera__MultiplierOutOfRange();
    error Aera__DepositCapZero();
    error Aera__PriceAndFeeCalculatorVaultPaused();
    error Aera__AutoPriceSolveNotAllowed();
    error Aera__FixedPriceSolverTipNotAllowed();
    error Aera__TokenCantBePriced();
    error Aera__CallerIsVault();
    error Aera__InvalidToken();
    error Aera__ZeroAddressReceiver();
    error Aera__SyncRedeemRelativeCapBpsTooHigh();
    error Aera__SyncRedeemMaxDynamicPremiumBpsTooHigh();
    error Aera__SyncRedeemMaxPriceAgeZero();
    error Aera__SyncRedeemRelativeCapBpsZero();
    error Aera__SyncRedeemAbsoluteCapNumeraireZero();
    error Aera__SyncRedeemNotConfigured();
    error Aera__SyncRedeemDisabled();
    error Aera__MinTokensOutNotMet();
    error Aera__SyncRedeemMaxPriceAgeExceeded();
    error Aera__SyncRedeemEpochCapExceeded();
    error Aera__MaxUnitsInExceeded();
    error Aera__CallerIsNotRequestUser();
    error Aera__DepositRequestCancellationDisabled();
    error Aera__RedeemRequestCancellationDisabled();
    error Aera__CancellationFeeExceedsRequestAmount();
    error Aera__RequestAmountExceedsRefundCap();
    error Aera__RedeemCancellationCapNumeraireZero();
    error Aera__DepositCancellationDetailsNotZero();
    error Aera__RedeemCancellationDetailsNotZero();
    error Aera__PullFundsSubmitDataNotSet();
    error Aera__SolvingPaused();
    error Aera__SolvingGateDisabled();
    error Aera__ReceiverNotApproved();
    error Aera__UnitsLocked();

    ////////////////////////////////////////////////////////////
    //                        Functions                       //
    ////////////////////////////////////////////////////////////

    /// @notice Deposit tokens directly into the vault
    /// @param token The token to deposit
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param receiver The address that receives units
    /// @return unitsOut The amount of shares minted to the receiver
    /// @dev Caller must be the receiver or approved by the receiver via {setDepositReceiverApproval}
    function deposit(IERC20 token, uint256 tokensIn, uint256 minUnitsOut, address receiver)
        external
        returns (uint256 unitsOut);

    /// @notice Mint exact amount of units by depositing required tokens
    /// @param token The token to deposit
    /// @param unitsOut The exact amount of units to mint
    /// @param maxTokensIn Maximum amount of tokens willing to deposit
    /// @param receiver The address that receives units
    /// @return tokensIn The amount of tokens used to mint the requested shares
    /// @dev Caller must be the receiver or approved by the receiver via {setDepositReceiverApproval}
    function mint(IERC20 token, uint256 unitsOut, uint256 maxTokensIn, address receiver)
        external
        returns (uint256 tokensIn);

    /// @notice Refund a deposit within the refund period
    /// @param sender The original depositor
    /// @param receiver The address whose units are reclaimed
    /// @param token The deposited token
    /// @param tokenAmount The amount of tokens deposited
    /// @param unitsAmount The amount of units minted
    /// @param refundableUntil Timestamp until which refund is possible
    function refundDeposit(
        address sender,
        address receiver,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external;

    /// @notice Refund an expired deposit or redeem request
    /// @param token The token involved in the request
    /// @param request The request to refund
    function refundRequest(IERC20 token, RequestV2 calldata request) external;

    /// @notice Cancel an async deposit or redeem request
    /// @param token The token involved in the request
    /// @param request The request to cancel
    function cancelRequest(IERC20 token, RequestV2 calldata request) external;

    /// @notice Create a new deposit request to be solved by solvers
    /// @param token The token to deposit
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @return requestHash The hash identifying the created request
    function requestDeposit(
        IERC20 token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external returns (bytes32 requestHash);

    /// @notice Create a new redeem request to be solved by solvers
    /// @param token The token to receive
    /// @param unitsIn The amount of units to redeem
    /// @param minTokensOut The minimum amount of tokens expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @return requestHash The hash identifying the created request
    function requestRedeem(
        IERC20 token,
        uint256 unitsIn,
        uint256 minTokensOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external returns (bytes32 requestHash);

    /// @notice Solve multiple requests using vault's liquidity, with optional pre/post-solve
    ///         guardian submissions for automatic fund movement
    /// @param token The token for which to solve requests
    /// @param requests Array of requests to solve
    /// @param preSolveSubmitData Encoded operations to submit before solving (e.g., pull funds
    ///        from yield source). If non-empty, calls vault.submit and reverts if it fails
    ///        If empty, skipped
    /// @param postSolveSubmitData Encoded operations to submit after solving (e.g., push funds
    ///        to yield source). If non-empty, calls vault.submit via try/catch - failures are
    ///        swallowed. If empty, skipped
    /// @dev MUST revert if preSolveSubmitData is non-empty and vault.submit reverts
    function solveRequestsVault(
        IERC20 token,
        RequestV2[] calldata requests,
        bytes calldata preSolveSubmitData,
        bytes calldata postSolveSubmitData
    ) external;

    /// @notice Solve multiple requests using solver's own liquidity
    /// @dev Does not check the solving gate because direct solves are peer-to-peer and never touch
    ///      the vault's enter/exit flow, so they have no impact on underlying fund accounting
    ///      The PFC vault-pause check still applies as the full-freeze mechanism
    /// @param token The token for which to solve requests
    /// @param requests Array of requests to solve
    function solveRequestsDirect(IERC20 token, RequestV2[] calldata requests) external;

    /// @notice Update token parameters including push/pull funds SSTORE2 pointers
    /// @param token The token to update
    /// @param details The full token details struct. `pushFundsSubmitDataPointer` and
    ///        `pullFundsSubmitDataPointer` must be valid SSTORE2 pointers or `address(0)` to disable
    /// @dev Admin must create SSTORE2 pointers externally before calling this function
    function setTokenDetails(IERC20 token, TokenDetailsV2 calldata details) external;

    /// @notice Removes token from provisioner
    /// @param token The token to be removed
    function removeToken(IERC20 token) external;

    /// @notice Update deposit parameters
    /// @param depositCap_ New maximum total value that can be deposited
    /// @param depositRefundTimeout_ New time window for deposit refunds
    function setDepositDetails(uint224 depositCap_, uint32 depositRefundTimeout_) external;

    /// @notice Sets cancellation toggles and enabled-side fee configuration
    /// @dev If a deposit/redeem cancellation is disabled, params related to it must be 0
    /// @param depositCancellationsEnabled Whether user-initiated deposit requests can be cancelled
    /// @param redeemCancellationsEnabled Whether user-initiated redeem requests can be cancelled
    /// @param depositCancellationFeeNumeraire Fixed deposit cancellation fee, in numeraire
    /// @param redeemCancellationFeeNumeraire Fixed redeem cancellation fee, in numeraire
    /// @param redeemCancellationDynamicFeeCapNumeraire Dynamic redeem cancellation fee cap, in numeraire
    /// @param redeemCancellationCapNumeraire Maximum redeem request size users can self-cancel, in numeraire
    function setCancellationDetails(
        bool depositCancellationsEnabled,
        bool redeemCancellationsEnabled,
        uint80 depositCancellationFeeNumeraire,
        uint80 redeemCancellationFeeNumeraire,
        uint80 redeemCancellationDynamicFeeCapNumeraire,
        uint80 redeemCancellationCapNumeraire
    ) external;

    /// @notice Create a new deposit request to be solved by solvers
    /// @param token The token to deposit
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param receiver The address that receives units when solved
    /// @return depositRequestHash The hash of the deposit request
    function requestDeposit(
        IERC20 token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        address receiver
    ) external returns (bytes32 depositRequestHash);

    /// @notice Create a new redeem request to be solved by solvers
    /// @param token The token to receive
    /// @param unitsIn The amount of units to redeem
    /// @param minTokensOut The minimum amount of tokens expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Timestamp until which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param receiver The address that receives tokens when solved
    /// @return redeemRequestHash The hash of the redeem request
    function requestRedeem(
        IERC20 token,
        uint256 unitsIn,
        uint256 minTokensOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        address receiver
    ) external returns (bytes32 redeemRequestHash);

    /// @notice Sets global sync redeem risk parameters
    /// @param maxPriceAge Maximum allowed vault price age (seconds)
    /// @param relativeCapBps Relative cap in bps of epoch-start TVL (numeraire)
    /// @param absoluteCapNumeraire Absolute cap in numeraire per epoch
    /// @param maxDynamicPremiumBps Maximum global dynamic premium in bps
    /// @dev Only callable by authorized addresses. All parameters must be non-zero
    function setSyncRedeemDetails(
        uint24 maxPriceAge,
        uint16 relativeCapBps,
        uint80 absoluteCapNumeraire,
        uint16 maxDynamicPremiumBps
    ) external;

    /// @notice Approve or revoke a depositor's permission to deposit on behalf of the caller
    /// @param depositor The address to approve or revoke
    /// @param approved Whether the depositor is approved to deposit to the caller
    function setDepositReceiverApproval(address depositor, bool approved) external;

    /// @notice Sets the solving gate contract that controls when solving is allowed
    /// @param solvingGate_ The new solving gate address. Use address(0) to disable gating
    ///        (solving always open)
    /// @dev MUST only be callable by authorized addresses
    /// @dev MUST revert if the solving gate feature is not enabled
    function setSolvingGate(address solvingGate_) external;

    /// @notice Synchronously redeem units for tokens using latest active price
    /// @param token Token to receive
    /// @param unitsIn Units to redeem
    /// @param minTokensOut Minimum acceptable token output
    /// @param receiver Address receiving output tokens
    /// @dev Sync redeem must be enabled for token, vault must be active, and price must be fresh
    /// @return tokensOut Actual token amount sent to receiver
    function redeem(IERC20 token, uint256 unitsIn, uint256 minTokensOut, address receiver)
        external
        returns (uint256 tokensOut);

    /// @notice Synchronously withdraw exact tokens using latest active price
    /// @param token Token to receive
    /// @param tokensOut Exact token output requested
    /// @param maxUnitsIn Maximum acceptable units to burn
    /// @param receiver Address receiving output tokens
    /// @dev Sync redeem must be enabled for token, vault must be active, and price must be fresh
    /// @return unitsIn Actual units burned
    function withdraw(IERC20 token, uint256 tokensOut, uint256 maxUnitsIn, address receiver)
        external
        returns (uint256 unitsIn);

    /// @notice Returns the current solving gate address
    /// @return The solving gate contract address, or address(0) if gating is disabled
    function solvingGate() external view returns (address);

    /// @notice Read an amount relevant for current submit operation from transient storage
    /// @return The stored amount
    function getRelevantAmount() external view returns (uint256);

    /// @notice Return maximum amount that can still be deposited
    /// @return Amount of deposit capacity remaining
    function maxDeposit() external view returns (uint256);

    /// @notice Returns cancellation toggles and fee configuration
    /// @return depositCancellationsEnabled Whether user-initiated deposit request cancellations are enabled
    /// @return redeemCancellationsEnabled Whether user-initiated redeem request cancellations are enabled
    /// @return depositCancellationFeeNumeraire Fixed deposit cancellation fee, in numeraire
    /// @return redeemCancellationFeeNumeraire Fixed redeem cancellation fee, in numeraire
    /// @return redeemCancellationDynamicFeeCapNumeraire Dynamic redeem cancellation fee cap, in numeraire
    /// @return redeemCancellationCapNumeraire Maximum redeem request size users can self-cancel, in numeraire
    function getCancellationDetails()
        external
        view
        returns (
            bool depositCancellationsEnabled,
            bool redeemCancellationsEnabled,
            uint80 depositCancellationFeeNumeraire,
            uint80 redeemCancellationFeeNumeraire,
            uint80 redeemCancellationDynamicFeeCapNumeraire,
            uint80 redeemCancellationCapNumeraire
        );

    /// @notice Preview the cancellation fee for a request in numeraire terms
    /// @dev No guard checks (enable flags, cap, deadline) — those revert in cancelRequest
    /// @param request The request to preview the cancellation fee for
    /// @return The cancellation fee in numeraire
    function previewCancellationFeeNumeraire(RequestV2 calldata request) external view returns (uint256);

    /// @notice Check if a user's units are currently locked
    /// @param user The address to check
    /// @return True if user's units are locked, false otherwise
    function areUserUnitsLocked(address user) external view returns (bool);

    /// @notice Returns all sync redeem configuration and epoch state
    /// @return maxPriceAge Maximum allowed vault price age for sync redeems (seconds)
    /// @return relativeCapBps Relative cap in bps of epoch-start TVL for sync redeems
    /// @return maxDynamicPremiumBps Maximum global dynamic premium in bps for sync redeems
    /// @return epochTimestamp Timestamp of the current sync redeem epoch (from PFC vault state)
    /// @return absoluteCapNumeraire Absolute cap in numeraire per epoch for sync redeems
    /// @return epochRedeemedNumeraire Numeraire amount redeemed globally so far in the current sync redeem epoch
    function getSyncRedeemDetails()
        external
        view
        returns (
            uint24 maxPriceAge,
            uint16 relativeCapBps,
            uint16 maxDynamicPremiumBps,
            uint32 epochTimestamp,
            uint80 absoluteCapNumeraire,
            uint80 epochRedeemedNumeraire
        );

    /// @notice Returns current global sync redeem epoch state
    /// @return epochTimestamp Current anchor epoch timestamp from PFC
    /// @return epochStartTvlNumeraire Epoch-start TVL in numeraire
    /// @return epochRedeemedNumeraire Numeraire amount redeemed globally so far in current epoch
    /// @return epochCapNumeraire Effective current epoch cap in numeraire
    /// @dev MUST NOT revert; returns view-consistent epoch state
    ///      (if PFC is paused, returns zero TVL and zero cap for the current epoch)
    ///      (if PFC timestamp differs from stored, shows fresh epoch with 0 redeemed)
    function getSyncRedeemEpochState()
        external
        view
        returns (
            uint256 epochTimestamp,
            uint256 epochStartTvlNumeraire,
            uint256 epochRedeemedNumeraire,
            uint256 epochCapNumeraire
        );

    /// @notice Computes the hash for a sync deposit
    /// @param user The address making the deposit
    /// @param receiver The address receiving units from the deposit
    /// @param token The token being deposited
    /// @param tokenAmount The amount of tokens to deposit
    /// @param unitsAmount Minimum amount of units to receive
    /// @param refundableUntil The timestamp until which the deposit is refundable
    /// @return The hash of the deposit
    function getDepositHash(
        address user,
        address receiver,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external pure returns (bytes32);

    /// @notice Computes the hash for a request
    /// @param token The token in the request
    /// @param request The request to hash
    /// @return The hash of the request
    function getRequestHash(IERC20 token, RequestV2 calldata request) external pure returns (bytes32);
}
