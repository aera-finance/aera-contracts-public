// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { TransientSlot } from "@oz/utils/TransientSlot.sol";

import { Math } from "@oz/utils/math/Math.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Auth2Step } from "src/core/Auth2Step.sol";

import {
    AUTO_PRICE_FIXED_PRICE_FLAG,
    DEPOSIT_REDEEM_FLAG,
    MAX_DEPOSIT_REFUND_TIMEOUT,
    MAX_SECONDS_TO_DEADLINE,
    MIN_MULTIPLIER,
    ONE_IN_BPS,
    ONE_UNIT
} from "src/core/Constants.sol";
import { RequestV2, RequestType, TokenDetailsV2 } from "src/core/Types.sol";
import { IBaseVault } from "src/core/interfaces/IBaseVault.sol";
import { IMultiDepositorVault } from "src/core/interfaces/IMultiDepositorVault.sol";
import { IPriceAndFeeCalculatorV2 } from "src/core/interfaces/IPriceAndFeeCalculatorV2.sol";
import { IProvisionerV2 } from "src/core/interfaces/IProvisionerV2.sol";
import { ISolvingGate } from "src/core/interfaces/ISolvingGate.sol";
import { IVersioned } from "src/core/interfaces/IVersioned.sol";
import { SSTORE2 } from "@solmate/SSTORE2.sol";

/// @title Provisioner
/// @notice Entry and exit point for {MultiDepositorVault}. Handles all deposits and redemptions
/// Uses {IPriceAndFeeCalculator} to convert between tokens and vault units. Supports both sync and async deposits; only
/// async redeems. Manages deposit caps, refund timeouts, and request replay protection. All assets must flow through
/// this contract to enter or exit the vault. Sync deposits are processed instantly, but stay refundable for a period of
/// time. Async requests can either be solved by authorized solvers, going through the vault, or directly by anyone
/// willing to pay units (for deposits) or tokens (for redeems), pocketing the solver tip, always paid in tokens
contract ProvisionerV2 is IProvisionerV2, Auth2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                        Constants                       //
    ////////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for the relevant amount
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.provisioner.relevantAmount")) - 1)) &
    ///      ~bytes32(uint256(0xff))
    bytes32 internal constant RELEVANT_AMOUNT_SLOT = 0x35763d55300b221a73cb498654a5b850852575e97ef00a6947ad36dc59da0d00;

    ////////////////////////////////////////////////////////////
    //                         Immutables                     //
    ////////////////////////////////////////////////////////////

    /// @notice The price and fee calculator contract
    IPriceAndFeeCalculatorV2 public immutable PRICE_FEE_CALCULATOR;

    /// @notice The multi depositor vault contract
    address public immutable MULTI_DEPOSITOR_VAULT;

    /// @notice Whether this provisioner supports solving status gating
    bool public immutable SOLVING_GATE_ENABLED;

    ////////////////////////////////////////////////////////////
    //                         Storage                        //
    ////////////////////////////////////////////////////////////

    /// @notice Mapping of token to token details
    mapping(IERC20 token => TokenDetailsV2 details) public tokensDetails;

    /// @notice Maximum total value of deposits in numeraire terms
    uint224 public depositCap;

    /// @notice Time period in seconds during which sync deposits can be refunded
    uint32 public depositRefundTimeout;

    /// @notice Mapping of active sync deposit hashes
    /// @dev True if a sync deposit is active with the hashed parameters
    mapping(bytes32 syncDepositHash => bool exists) public syncDepositHashes;

    /// @notice Mapping of async request hash to its existence (deposits and redeems share one domain)
    /// @dev True if request exists, false if it was refunded or solved
    ///      Collision between deposit and redeem hashes is impossible because the hash includes RequestType
    mapping(bytes32 asyncRequestHash => bool exists) public asyncRequestHashes;

    /// @notice Mapping of user address to timestamp until which their units are locked
    mapping(address user => uint256 unitsLockedUntil) public userUnitsRefundableUntil;

    /// @notice Maximum allowed vault price age for sync redeems (seconds)
    uint24 internal _syncRedeemMaxPriceAge;

    /// @notice Relative cap in bps of epoch-start vault value for sync redeems
    uint16 internal _syncRedeemRelativeCapBps;

    /// @notice Maximum global dynamic premium in bps for sync redeems
    uint16 internal _syncRedeemMaxDynamicPremiumBps;

    /// @notice Timestamp of the current sync redeem epoch (from PFC vault state)
    uint32 internal _syncRedeemEpochTimestamp;

    /// @notice Absolute cap in numeraire per epoch for sync redeems
    uint80 internal _syncRedeemAbsoluteCapNumeraire;

    /// @notice Numeraire amount redeemed globally so far in the current sync redeem epoch
    uint80 internal _syncRedeemEpochRedeemedNumeraire;

    /// @notice Whether user-initiated deposit request cancellations are enabled
    bool internal _depositCancellationsEnabled;

    /// @notice Whether user-initiated redeem request cancellations are enabled
    bool internal _redeemCancellationsEnabled;

    /// @notice Maximum redeem request size eligible for user self-cancellation, in numeraire
    uint80 internal _redeemCancellationCapNumeraire;

    /// @notice Fixed deposit cancellation fee for self-cancels before deadline, in numeraire
    uint80 internal _depositCancellationFeeNumeraire;

    /// @notice Fixed redeem cancellation fee for self-cancels before deadline, in numeraire
    uint80 internal _redeemCancellationFeeNumeraire;

    /// @notice Dynamic redeem cancellation fee cap for self-cancels before deadline, in numeraire
    uint80 internal _redeemCancellationDynamicFeeCapNumeraire;

    /// @notice Whether a receiver has approved a depositor to deposit on their behalf
    mapping(address receiver => mapping(address depositor => bool approved)) public depositReceiverApprovals;

    /// @inheritdoc IProvisionerV2
    address public solvingGate;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    /// @notice Ensures the caller is not the vault
    modifier anyoneButVault() {
        _checkCallerNotVault();
        _;
    }

    /// @notice Reverts if the solving gate is set and reports that solving is paused
    /// @param token The ERC20 token being solved
    modifier solvingNotPaused(IERC20 token) {
        _checkSolvingNotPaused(token);
        _;
    }

    constructor(
        IPriceAndFeeCalculatorV2 priceAndFeeCalculator,
        address multiDepositorVault,
        bool solvingGateEnabled,
        address owner_,
        Authority authority_
    ) Auth2Step(owner_, authority_) {
        // Requirements: immutables are not zero addresses
        require(address(priceAndFeeCalculator) != address(0), Aera__ZeroAddressPriceAndFeeCalculator());
        require(multiDepositorVault != address(0), Aera__ZeroAddressMultiDepositorVault());

        // Effects: set immutables
        PRICE_FEE_CALCULATOR = priceAndFeeCalculator;
        MULTI_DEPOSITOR_VAULT = multiDepositorVault;
        SOLVING_GATE_ENABLED = solvingGateEnabled;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IProvisionerV2
    function deposit(IERC20 token, uint256 tokensIn, uint256 minUnitsOut, address receiver)
        external
        nonReentrant
        anyoneButVault
        solvingNotPaused(token)
        returns (uint256 unitsOut)
    {
        // Requirements: receiver is valid
        _requireValidReceiver(receiver);

        // Requirements: token amount and min units out are positive
        _validateNonZeroAmounts(minUnitsOut, tokensIn);

        // Requirements: sync deposits are enabled
        TokenDetailsV2 storage tokenDetails = _requireSyncDepositsEnabled(token);

        // Interactions: convert token amount to units out
        unitsOut = _tokensToUnitsFloorIfActive(token, tokensIn, tokenDetails.syncDepositMultiplier);
        // Requirements: units out meets min units out
        require(unitsOut >= minUnitsOut, Aera__MinUnitsOutNotMet());
        // Requirements + interactions: convert new total units to numeraire and check against deposit cap
        _requireDepositCapNotExceeded(unitsOut);

        // Effects + interactions: sync deposit
        _syncDeposit(token, tokensIn, unitsOut, receiver);

        // Interactions: push funds to yield source if configured (swallows failures)
        _pushFundsIfConfigured(tokenDetails, tokensIn);
    }

    /// @inheritdoc IProvisionerV2
    function mint(IERC20 token, uint256 unitsOut, uint256 maxTokensIn, address receiver)
        external
        nonReentrant
        anyoneButVault
        solvingNotPaused(token)
        returns (uint256 tokensIn)
    {
        // Requirements: receiver is valid
        _requireValidReceiver(receiver);

        // Requirements: tokens and units amount are positive
        _validateNonZeroAmounts(unitsOut, maxTokensIn);

        // Requirements: sync deposits are enabled
        TokenDetailsV2 storage tokenDetails = _requireSyncDepositsEnabled(token);

        // Requirements + interactions: convert new total units to numeraire and check against deposit cap
        _requireDepositCapNotExceeded(unitsOut);
        // Interactions: convert units to tokens
        tokensIn = _unitsToTokensCeilIfActive(token, unitsOut, tokenDetails.syncDepositMultiplier);
        // Requirements: token in is less than or equal to max tokens in
        require(tokensIn <= maxTokensIn, Aera__MaxTokensInExceeded());

        // Effects + interactions: sync deposit
        _syncDeposit(token, tokensIn, unitsOut, receiver);

        // Interactions: push funds to yield source if configured (swallows failures)
        _pushFundsIfConfigured(tokenDetails, tokensIn);
    }

    /// @inheritdoc IProvisionerV2
    function refundDeposit(
        address sender,
        address receiver,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external requiresAuth {
        // Requirements: refundable timestamp is in the future
        require(refundableUntil >= block.timestamp, Aera__RefundPeriodExpired());

        bytes32 depositHash = _getDepositHash(sender, receiver, token, tokenAmount, unitsAmount, refundableUntil);
        // Requirements: hash has been set
        require(syncDepositHashes[depositHash], Aera__DepositHashNotFound());
        // Effects: unset hash as used
        syncDepositHashes[depositHash] = false;

        // Interactions: pull funds from yield source if vault idle balance is insufficient
        _pullFundsIfNeeded(token, tokenAmount);

        // Interactions: exit vault, fallback to sender
        try IMultiDepositorVault(MULTI_DEPOSITOR_VAULT).exit(receiver, token, tokenAmount, unitsAmount, receiver) { }
        catch {
            IMultiDepositorVault(MULTI_DEPOSITOR_VAULT).exit(receiver, token, tokenAmount, unitsAmount, sender);
        }

        // Log deposit refunded event
        emit DirectDepositRefunded(depositHash);
    }

    /// @inheritdoc IProvisionerV2
    function requestDeposit(
        IERC20 token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external returns (bytes32 depositHash) {
        depositHash = requestDeposit(
            token, tokensIn, minUnitsOut, solverTip, deadline, maxPriceAge, isFixedPrice, msg.sender
        );

        // Log legacy deposit requested event for backwards-compatible consumers. Indexers should prefer
        // DepositRequested (with receiver) and can ignore this legacy duplicate for wrapper calls
        emit DepositRequested(
            msg.sender, token, tokensIn, minUnitsOut, solverTip, deadline, maxPriceAge, isFixedPrice, depositHash
        );
    }

    /// @inheritdoc IProvisionerV2
    function requestRedeem(
        IERC20 token,
        uint256 unitsIn,
        uint256 minTokensOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external returns (bytes32 redeemHash) {
        redeemHash = requestRedeem(
            token, unitsIn, minTokensOut, solverTip, deadline, maxPriceAge, isFixedPrice, msg.sender
        );

        // Log legacy redeem requested event for backwards-compatible consumers. Indexers should prefer
        // RedeemRequested (with receiver) and can ignore this legacy duplicate for wrapper calls
        emit RedeemRequested(
            msg.sender, token, minTokensOut, unitsIn, solverTip, deadline, maxPriceAge, isFixedPrice, redeemHash
        );
    }

    /// @inheritdoc IProvisionerV2
    function refundRequest(IERC20 token, RequestV2 calldata request) external nonReentrant {
        // Requirements: deadline is in the past or authorized
        require(
            request.deadline < block.timestamp || isAuthorized(msg.sender, msg.sig),
            Aera__DeadlineInFutureAndUnauthorized()
        );

        if (_isRequestTypeDeposit(request.requestType)) {
            // Effects + interactions: clear hash, emit refund event, and transfer full token amount with fallback
            _clearHashAndTransferRefund(token, request, request.user, request.tokens, token);
        } else {
            // Effects + interactions: clear hash, emit refund event, and transfer full unit amount with fallback
            _clearHashAndTransferRefund(token, request, request.user, request.units, IERC20(MULTI_DEPOSITOR_VAULT));
        }
    }

    // slither-disable-start reentrancy-no-eth,reentrancy-benign
    /// @inheritdoc IProvisionerV2
    function cancelRequest(IERC20 token, RequestV2 calldata request) external nonReentrant {
        // Requirements: self-cancel caller must be request user
        require(msg.sender == request.user, Aera__CallerIsNotRequestUser());

        if (_isRequestTypeDeposit(request.requestType)) {
            // Requirements: deposit cancellation toggle must be enabled
            require(_depositCancellationsEnabled, Aera__DepositRequestCancellationDisabled());

            uint256 refundAmount = request.tokens;
            // Requirements: pre-deadline self-cancel applies cancellation fee
            if (block.timestamp < request.deadline) {
                uint256 cancellationFee = _computeDepositCancellationFeeTokens(token);
                // Requirements: cancellation fee cannot exceed escrowed amount
                require(cancellationFee <= refundAmount, Aera__CancellationFeeExceedsRequestAmount());
                if (cancellationFee != 0) {
                    unchecked {
                        // unchecked: safe because cancellationFee <= refundAmount is enforced above
                        refundAmount -= cancellationFee;
                    }
                    // Interactions: transfer cancellation fee to vault
                    token.safeTransfer(MULTI_DEPOSITOR_VAULT, cancellationFee);
                }
            }

            // Effects + interactions: clear hash, emit refund event, and transfer net token amount with fallback
            _clearHashAndTransferRefund(token, request, msg.sender, refundAmount, token);
        } else {
            // Requirements: redeem cancellation toggle must be enabled
            require(_redeemCancellationsEnabled, Aera__RedeemRequestCancellationDisabled());

            // Interactions: compute redeem request size in numeraire with protocol-favoring rounding
            uint256 requestNumeraire = PRICE_FEE_CALCULATOR.convertUnitsToNumeraire(
                MULTI_DEPOSITOR_VAULT, request.units, Math.Rounding.Ceil
            );
            // Requirements: redeem self-cancel must not exceed configured cap
            require(requestNumeraire <= _redeemCancellationCapNumeraire, Aera__RequestAmountExceedsRefundCap());

            uint256 refundAmount = request.units;
            // Requirements: pre-deadline self-cancel applies cancellation fee
            if (block.timestamp < request.deadline) {
                uint256 cancellationFee = _computeRedeemCancellationFeeUnits(requestNumeraire);
                // Requirements: cancellation fee cannot exceed escrowed amount
                require(cancellationFee <= refundAmount, Aera__CancellationFeeExceedsRequestAmount());
                if (cancellationFee != 0) {
                    unchecked {
                        // unchecked: safe because cancellationFee <= refundAmount is enforced above
                        refundAmount -= cancellationFee;
                    }
                    // Interactions: burn cancellation fee units from provisioner escrow
                    IMultiDepositorVault(MULTI_DEPOSITOR_VAULT)
                        .exit(address(this), token, 0, cancellationFee, address(this));
                }
            }

            // Effects + interactions: clear hash, emit refund event, and transfer net unit amount with fallback
            _clearHashAndTransferRefund(token, request, msg.sender, refundAmount, IERC20(MULTI_DEPOSITOR_VAULT));
        }
    }

    // slither-disable-end reentrancy-no-eth,reentrancy-benign

    // slither-disable-start unchecked-lowlevel
    /// @inheritdoc IProvisionerV2
    function solveRequestsVault(
        IERC20 token,
        RequestV2[] calldata requests,
        bytes calldata preSolveSubmitData,
        bytes calldata postSolveSubmitData
    ) external requiresAuth nonReentrant solvingNotPaused(token) {
        // Interactions: pre-solve submit (reverts on failure)
        if (preSolveSubmitData.length > 0) {
            IBaseVault(MULTI_DEPOSITOR_VAULT).submit(preSolveSubmitData);
        }

        // Interactions: execute solve logic
        _solveRequestsVault(token, requests);

        // Interactions: post-solve submit (swallow failures)
        if (postSolveSubmitData.length > 0) {
            // solhint-disable no-unchecked-calls
            // slither-disable-next-line unchecked-lowlevel
            MULTI_DEPOSITOR_VAULT.call(abi.encodeCall(IBaseVault.submit, (postSolveSubmitData)));
            // solhint-enable no-unchecked-calls
        }
    }

    // slither-disable-end unchecked-lowlevel

    /// @inheritdoc IProvisionerV2
    function solveRequestsDirect(IERC20 token, RequestV2[] calldata requests) external nonReentrant {
        // Requirements: vault is not paused in the priceAndFeeCalculator
        require(!PRICE_FEE_CALCULATOR.isVaultPaused(MULTI_DEPOSITOR_VAULT), Aera__PriceAndFeeCalculatorVaultPaused());

        uint256 length = requests.length;
        TokenDetailsV2 storage tokenDetails = tokensDetails[token];
        for (uint256 i = 0; i < length; i++) {
            RequestV2 calldata request = requests[i];
            RequestType requestType = request.requestType;

            // Requirements: direct solves can only solve fixed price requests
            require(!_isRequestTypeAutoPrice(requestType), Aera__AutoPriceSolveNotAllowed());

            if (_isRequestTypeDeposit(requestType)) {
                // Requirements: async deposit is enabled
                require(tokenDetails.asyncDepositEnabled, Aera__AsyncDepositDisabled());
            } else {
                // Requirements: async redeem is enabled
                require(tokenDetails.asyncRedeemEnabled, Aera__AsyncRedeemDisabled());
            }

            // Requirements + Effects + Interactions: solve direct request
            _solveRequestDirect(token, request);
        }
    }

    /// @inheritdoc IProvisionerV2
    function setDepositDetails(uint224 depositCap_, uint32 depositRefundTimeout_) external requiresAuth {
        // Requirements: deposit cap is not zero
        require(depositCap_ != 0, Aera__DepositCapZero());
        // Requirements: deposit refund timeout does not exceed the safety cap
        require(depositRefundTimeout_ <= MAX_DEPOSIT_REFUND_TIMEOUT, Aera__MaxDepositRefundTimeoutExceeded());

        // Effects: set deposit cap and refund timeout
        depositCap = depositCap_;
        depositRefundTimeout = depositRefundTimeout_;

        // Log deposit details updated event
        emit DepositDetailsUpdated(depositCap_, depositRefundTimeout_);
    }

    /// @inheritdoc IProvisionerV2
    function setCancellationDetails(
        bool depositCancellationsEnabled,
        bool redeemCancellationsEnabled,
        uint80 depositCancellationFeeNumeraire,
        uint80 redeemCancellationFeeNumeraire,
        uint80 redeemCancellationDynamicFeeCapNumeraire,
        uint80 redeemCancellationCapNumeraire
    ) external requiresAuth {
        if (!depositCancellationsEnabled) {
            // Requirements: disabled deposit cancellations must have zero values for params
            require(depositCancellationFeeNumeraire == 0, Aera__DepositCancellationDetailsNotZero());
        }

        if (redeemCancellationsEnabled) {
            // Requirements: enabled redeem cancellations require a non-zero cancellation cap
            require(redeemCancellationCapNumeraire != 0, Aera__RedeemCancellationCapNumeraireZero());
        } else {
            // Requirements: disabled redeem cancellations must have zero values for params
            require(
                redeemCancellationFeeNumeraire == 0 && redeemCancellationDynamicFeeCapNumeraire == 0
                    && redeemCancellationCapNumeraire == 0,
                Aera__RedeemCancellationDetailsNotZero()
            );
        }

        // Effects: set cancellation details
        _depositCancellationsEnabled = depositCancellationsEnabled;
        _redeemCancellationsEnabled = redeemCancellationsEnabled;
        _depositCancellationFeeNumeraire = depositCancellationFeeNumeraire;
        _redeemCancellationFeeNumeraire = redeemCancellationFeeNumeraire;
        _redeemCancellationDynamicFeeCapNumeraire = redeemCancellationDynamicFeeCapNumeraire;
        _redeemCancellationCapNumeraire = redeemCancellationCapNumeraire;

        // Log cancellation details updated event
        emit CancellationDetailsUpdated(
            depositCancellationsEnabled,
            redeemCancellationsEnabled,
            depositCancellationFeeNumeraire,
            redeemCancellationFeeNumeraire,
            redeemCancellationDynamicFeeCapNumeraire,
            redeemCancellationCapNumeraire
        );
    }

    /// @inheritdoc IProvisionerV2
    function setTokenDetails(IERC20 token, TokenDetailsV2 calldata details) external requiresAuth {
        // Requirements: check that the token is not the vault's own unit token
        require(address(token) != MULTI_DEPOSITOR_VAULT, Aera__InvalidToken());

        // Requirements: all multipliers are within valid range [MIN_MULTIPLIER, ONE_IN_BPS]
        _requireValidMultiplier(details.asyncDepositMultiplier);
        _requireValidMultiplier(details.asyncRedeemMultiplier);
        _requireValidMultiplier(details.syncDepositMultiplier);
        _requireValidMultiplier(details.syncRedeemMultiplier);

        // Effects: set token details
        tokensDetails[token] = details;

        if (details.syncRedeemEnabled) {
            // Requirements: sync redeem configuration must be set before enabling sync redeems on any token
            require(_syncRedeemMaxPriceAge > 0, Aera__SyncRedeemNotConfigured());
        }

        if (
            details.asyncDepositEnabled || details.asyncRedeemEnabled || details.syncDepositEnabled
                || details.syncRedeemEnabled
        ) {
            // Requirements: check that the token can be priced
            // convertUnitsToToken instead of convertTokensToUnits to avoid having to call token.decimals()
            require(
                PRICE_FEE_CALCULATOR.convertUnitsToToken(MULTI_DEPOSITOR_VAULT, token, ONE_UNIT) != 0,
                Aera__TokenCantBePriced()
            );
        }

        // Log token details set event
        emit TokenDetailsSet(token, details);
    }

    /// @inheritdoc IProvisionerV2
    function removeToken(IERC20 token) external requiresAuth {
        // Effects: remove tokensDetails
        delete tokensDetails[token];

        // Log token removed event
        emit TokenRemoved(token);
    }

    /// @inheritdoc IProvisionerV2
    function setSyncRedeemDetails(
        uint24 maxPriceAge,
        uint16 relativeCapBps,
        uint80 absoluteCapNumeraire,
        uint16 maxDynamicPremiumBps
    ) external requiresAuth {
        // Requirements: max price age must be positive to avoid division by zero in dynamic premium calculation
        require(maxPriceAge > 0, Aera__SyncRedeemMaxPriceAgeZero());
        // Requirements: relative cap bps must be positive to avoid zero epoch cap
        require(relativeCapBps > 0, Aera__SyncRedeemRelativeCapBpsZero());
        // Requirements: relative cap bps is within valid range
        require(relativeCapBps <= ONE_IN_BPS, Aera__SyncRedeemRelativeCapBpsTooHigh());
        // Requirements: absolute cap numeraire must be positive to avoid zero epoch cap
        require(absoluteCapNumeraire > 0, Aera__SyncRedeemAbsoluteCapNumeraireZero());
        // Requirements: max dynamic premium bps must be below MIN_MULTIPLIER to guarantee
        // the effective multiplier (syncRedeemMultiplier - dynamicPremiumBps) is always positive
        require(maxDynamicPremiumBps < MIN_MULTIPLIER, Aera__SyncRedeemMaxDynamicPremiumBpsTooHigh());

        // Effects: set sync redeem parameters
        _syncRedeemMaxPriceAge = maxPriceAge;
        _syncRedeemRelativeCapBps = relativeCapBps;
        _syncRedeemAbsoluteCapNumeraire = absoluteCapNumeraire;
        _syncRedeemMaxDynamicPremiumBps = maxDynamicPremiumBps;

        // Log sync redeem details updated event
        emit SyncRedeemDetailsUpdated(maxPriceAge, relativeCapBps, absoluteCapNumeraire, maxDynamicPremiumBps);
    }

    /// @inheritdoc IProvisionerV2
    function setDepositReceiverApproval(address depositor, bool approved) external {
        // Effects: set deposit receiver approval
        depositReceiverApprovals[msg.sender][depositor] = approved;

        // Log deposit receiver approval set event
        emit DepositReceiverApprovalSet(msg.sender, depositor, approved);
    }

    /// @inheritdoc IProvisionerV2
    function setSolvingGate(address solvingGate_) external requiresAuth {
        // Requirements: solving gate must be enabled
        require(SOLVING_GATE_ENABLED, Aera__SolvingGateDisabled());

        // Effects: set solving gate
        // slither-disable-next-line missing-zero-check
        solvingGate = solvingGate_;

        // Log solving gate updated event
        emit SolvingGateUpdated(solvingGate_);
    }

    /// @inheritdoc IProvisionerV2
    function redeem(IERC20 token, uint256 unitsIn, uint256 minTokensOut, address receiver)
        external
        anyoneButVault
        nonReentrant
        solvingNotPaused(token)
        returns (uint256 tokensOut)
    {
        // Requirements: units in and min tokens out are positive
        _validateNonZeroAmounts(unitsIn, minTokensOut);
        // Requirements: receiver is not zero address
        require(receiver != address(0), Aera__ZeroAddressReceiver());
        // Requirements: check that the caller does not have its units locked
        require(userUnitsRefundableUntil[msg.sender] < block.timestamp, Aera__UnitsLocked());

        // Requirements: sync redeems are enabled
        TokenDetailsV2 storage tokenDetails = _requireSyncRedeemsEnabled(token);

        // Requirements + Interactions: validate price age and derive effective multiplier
        (uint256 effectiveMultiplier, uint256 priceTimestamp) = _prepareSyncRedeem(tokenDetails.syncRedeemMultiplier);

        // Interactions: convert units to tokens with effective multiplier (floor rounding favors protocol)
        tokensOut = _unitsToTokensFloorIfActive(token, unitsIn, effectiveMultiplier);
        // Requirements: tokens out meets min tokens out
        require(tokensOut >= minTokensOut, Aera__MinTokensOutNotMet());

        // Interactions: compute redeem value in numeraire for epoch cap accounting
        uint256 epochRedeemNumeraire =
            PRICE_FEE_CALCULATOR.convertTokenToNumeraire(MULTI_DEPOSITOR_VAULT, token, tokensOut);

        // Requirements + Effects + Interactions: sync redeem
        _syncRedeem(token, tokensOut, unitsIn, receiver, epochRedeemNumeraire, priceTimestamp);
    }

    /// @inheritdoc IProvisionerV2
    function withdraw(IERC20 token, uint256 tokensOut, uint256 maxUnitsIn, address receiver)
        external
        anyoneButVault
        nonReentrant
        solvingNotPaused(token)
        returns (uint256 unitsIn)
    {
        // Requirements: tokens out and max units in are positive
        _validateNonZeroAmounts(maxUnitsIn, tokensOut);
        // Requirements: receiver is not zero address
        require(receiver != address(0), Aera__ZeroAddressReceiver());
        // Requirements: check that the caller does not have its units locked
        require(userUnitsRefundableUntil[msg.sender] < block.timestamp, Aera__UnitsLocked());

        // Requirements: sync redeems are enabled
        TokenDetailsV2 storage tokenDetails = _requireSyncRedeemsEnabled(token);

        // Requirements + Interactions: validate price age and derive effective multiplier
        (uint256 effectiveMultiplier, uint256 priceTimestamp) = _prepareSyncRedeem(tokenDetails.syncRedeemMultiplier);

        // Interactions: convert tokens out to units in (ceil rounding favors protocol)
        unitsIn = _tokensToUnitsCeilIfActive(token, tokensOut, effectiveMultiplier);
        // Requirements: units in does not exceed max units in
        require(unitsIn <= maxUnitsIn, Aera__MaxUnitsInExceeded());

        // Interactions: compute redeem value in numeraire for epoch cap accounting
        uint256 epochRedeemNumeraire =
            PRICE_FEE_CALCULATOR.convertTokenToNumeraire(MULTI_DEPOSITOR_VAULT, token, tokensOut);

        // Requirements + Effects + Interactions: sync redeem
        _syncRedeem(token, tokensOut, unitsIn, receiver, epochRedeemNumeraire, priceTimestamp);
    }

    /// @inheritdoc IProvisionerV2
    function getSyncRedeemEpochState()
        external
        view
        returns (
            uint256 epochTimestamp,
            uint256 epochStartTvlNumeraire,
            uint256 epochRedeemedNumeraire,
            uint256 epochCapNumeraire
        )
    {
        // Interactions: read the anchor snapshot from PFC so epoch rollover and cap sizing use the same basis
        epochTimestamp = PRICE_FEE_CALCULATOR.getAnchorTimestamp(MULTI_DEPOSITOR_VAULT);
        epochRedeemedNumeraire = (epochTimestamp == _syncRedeemEpochTimestamp) ? _syncRedeemEpochRedeemedNumeraire : 0;

        // Requirements: paused vaults should expose a safe zero-cap view instead of reverting through PFC
        if (PRICE_FEE_CALCULATOR.isVaultPaused(MULTI_DEPOSITOR_VAULT)) {
            return (epochTimestamp, 0, epochRedeemedNumeraire, 0);
        }

        (epochCapNumeraire, epochStartTvlNumeraire) = _computeEpochCap();
    }

    /// @inheritdoc IProvisionerV2
    function getSyncRedeemDetails() external view returns (uint24, uint16, uint16, uint32, uint80, uint80) {
        return (
            _syncRedeemMaxPriceAge,
            _syncRedeemRelativeCapBps,
            _syncRedeemMaxDynamicPremiumBps,
            _syncRedeemEpochTimestamp,
            _syncRedeemAbsoluteCapNumeraire,
            _syncRedeemEpochRedeemedNumeraire
        );
    }

    /// @inheritdoc IProvisionerV2
    function getRelevantAmount() external view returns (uint256) {
        return RELEVANT_AMOUNT_SLOT.asUint256().tload();
    }

    /// @inheritdoc IProvisionerV2
    function maxDeposit() external view returns (uint256) {
        if (PRICE_FEE_CALCULATOR.isVaultPaused(MULTI_DEPOSITOR_VAULT)) return 0;

        // Interactions: get current total supply
        uint256 totalSupply = IERC20(MULTI_DEPOSITOR_VAULT).totalSupply();
        // Interactions: convert total supply to numeraire with protocol-favoring ceil rounding
        uint256 totalAssets =
            PRICE_FEE_CALCULATOR.convertUnitsToNumeraire(MULTI_DEPOSITOR_VAULT, totalSupply, Math.Rounding.Ceil);

        // Return max of 0 or difference between deposit cap and total assets
        return totalAssets < depositCap ? depositCap - totalAssets : 0;
    }

    /// @inheritdoc IProvisionerV2
    function previewCancellationFeeNumeraire(RequestV2 calldata request) external view returns (uint256) {
        return _isRequestTypeDeposit(request.requestType)
            ? _depositCancellationFeeNumeraire
            : _computeRedeemCancellationFeeNumeraire(
                PRICE_FEE_CALCULATOR.convertUnitsToNumeraire(MULTI_DEPOSITOR_VAULT, request.units, Math.Rounding.Ceil)
            );
    }

    /// @inheritdoc IProvisionerV2
    function getCancellationDetails() external view returns (bool, bool, uint80, uint80, uint80, uint80) {
        return (
            _depositCancellationsEnabled,
            _redeemCancellationsEnabled,
            _depositCancellationFeeNumeraire,
            _redeemCancellationFeeNumeraire,
            _redeemCancellationDynamicFeeCapNumeraire,
            _redeemCancellationCapNumeraire
        );
    }

    /// @inheritdoc IProvisionerV2
    function areUserUnitsLocked(address user) external view returns (bool) {
        return userUnitsRefundableUntil[user] >= block.timestamp;
    }

    /// @inheritdoc IProvisionerV2
    function getDepositHash(
        address user,
        address receiver,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external pure returns (bytes32) {
        return _getDepositHash(user, receiver, token, tokenAmount, unitsAmount, refundableUntil);
    }

    /// @inheritdoc IProvisionerV2
    function getRequestHash(IERC20 token, RequestV2 calldata request) external pure returns (bytes32) {
        return _getRequestHash(token, request);
    }

    /// @inheritdoc IVersioned
    function version() external pure returns (string memory) {
        return "2.0";
    }

    /// @inheritdoc IProvisionerV2
    function requestDeposit(
        IERC20 token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        address receiver
    ) public anyoneButVault returns (bytes32 depositHash) {
        // Requirements: token amount and min units out are positive, async deposits are enabled
        _validateNonZeroAmounts(minUnitsOut, tokensIn);
        require(tokensDetails[token].asyncDepositEnabled, Aera__AsyncDepositDisabled());

        // Requirements: common request validation
        _validateRequest(receiver, solverTip, deadline, isFixedPrice);

        RequestType requestType = _getRequestType(isFixedPrice, true);

        // Interactions: transfer tokens from sender to provisioner
        token.safeTransferFrom(msg.sender, address(this), tokensIn);

        depositHash = _getRequestHashParams(
            token, msg.sender, receiver, requestType, tokensIn, minUnitsOut, solverTip, deadline, maxPriceAge
        );

        // Requirements: hash has not been used
        require(!asyncRequestHashes[depositHash], Aera__HashCollision());

        // Effects: set hash as used
        asyncRequestHashes[depositHash] = true;

        // Log deposit requested event
        emit DepositRequested(
            msg.sender,
            receiver,
            token,
            tokensIn,
            minUnitsOut,
            solverTip,
            deadline,
            maxPriceAge,
            isFixedPrice,
            depositHash
        );
    }

    /// @inheritdoc IProvisionerV2
    function requestRedeem(
        IERC20 token,
        uint256 unitsIn,
        uint256 minTokensOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice,
        address receiver
    ) public anyoneButVault returns (bytes32 redeemHash) {
        // Requirements: units amount and min token out are positive, async redeems are enabled
        _validateNonZeroAmounts(unitsIn, minTokensOut);
        require(tokensDetails[token].asyncRedeemEnabled, Aera__AsyncRedeemDisabled());

        // Requirements: common request validation
        _validateRequest(receiver, solverTip, deadline, isFixedPrice);

        RequestType requestType = _getRequestType(isFixedPrice, false);

        // Interactions: transfer units from sender to provisioner
        IERC20(MULTI_DEPOSITOR_VAULT).safeTransferFrom(msg.sender, address(this), unitsIn);

        redeemHash = _getRequestHashParams(
            token, msg.sender, receiver, requestType, minTokensOut, unitsIn, solverTip, deadline, maxPriceAge
        );

        // Requirements: hash has not been used
        require(!asyncRequestHashes[redeemHash], Aera__HashCollision());

        // Effects: set hash as used
        asyncRequestHashes[redeemHash] = true;

        // Log redeem requested event
        emit RedeemRequested(
            msg.sender,
            receiver,
            token,
            minTokensOut,
            unitsIn,
            solverTip,
            deadline,
            maxPriceAge,
            isFixedPrice,
            redeemHash
        );
    }

    ////////////////////////////////////////////////////////////
    //              Internal / Private Functions              //
    ////////////////////////////////////////////////////////////

    // slither-disable-start reentrancy-no-eth,reentrancy-benign
    // solhint-disable code-complexity
    /// @notice Internal solve logic shared by both solveRequestsVault overloads
    /// @param token The token for which to solve requests
    /// @param requests Array of requests to solve
    function _solveRequestsVault(IERC20 token, RequestV2[] calldata requests) internal {
        // Requirements: vault is not paused in the priceAndFeeCalculator
        require(!PRICE_FEE_CALCULATOR.isVaultPaused(MULTI_DEPOSITOR_VAULT), Aera__PriceAndFeeCalculatorVaultPaused());

        // Interactions: get price age
        uint256 priceAge = block.timestamp - PRICE_FEE_CALCULATOR.getVaultPriceTimestamp(MULTI_DEPOSITOR_VAULT);

        uint256 solverTip;
        RequestV2 calldata request;

        uint256 length = requests.length;
        TokenDetailsV2 memory tokenDetails = tokensDetails[token];
        bool depositsExist;
        for (uint256 i = 0; i < length; i++) {
            request = requests[i];
            if (_isRequestTypeDeposit(request.requestType)) {
                // Requirements: async deposit is enabled
                if (!tokenDetails.asyncDepositEnabled) {
                    // Log async deposit disabled event
                    emit AsyncDepositDisabled(i);
                    continue;
                }

                if (!depositsExist) {
                    depositsExist = true;
                    token.forceApprove(MULTI_DEPOSITOR_VAULT, type(uint256).max);
                }

                if (_isRequestTypeAutoPrice(request.requestType)) {
                    // Requirements + Effects + Interactions: solve auto price deposit
                    solverTip += _solveDepositVaultAutoPrice(
                        token, tokenDetails.asyncDepositMultiplier, request, priceAge, i
                    );
                } else {
                    // Requirements + Effects + Interactions: solve fixed price deposit
                    solverTip += _solveDepositVaultFixedPrice(
                        token, tokenDetails.asyncDepositMultiplier, request, priceAge, i
                    );
                }
            } else {
                // Requirements: async redeem is enabled
                if (!tokenDetails.asyncRedeemEnabled) {
                    // Log async redeem disabled event
                    emit AsyncRedeemDisabled(i);
                    continue;
                }

                if (_isRequestTypeAutoPrice(request.requestType)) {
                    // Requirements + Effects + Interactions: solve auto price redeem
                    solverTip += _solveRedeemVaultAutoPrice(
                        token, tokenDetails.asyncRedeemMultiplier, request, priceAge, i
                    );
                } else {
                    // Requirements + Effects + Interactions: solve fixed price redeem
                    solverTip += _solveRedeemVaultFixedPrice(
                        token, tokenDetails.asyncRedeemMultiplier, request, priceAge, i
                    );
                }
            }
        }

        if (solverTip != 0) {
            // Interactions: transfer solver tip from provisioner to sender
            token.safeTransfer(msg.sender, solverTip);
        }

        if (depositsExist) {
            // Interactions: set approval to 0
            token.forceApprove(MULTI_DEPOSITOR_VAULT, 0);
        }
    }

    // slither-disable-end reentrancy-no-eth,reentrancy-benign

    /// @notice Pull funds from yield source if vault idle balance is insufficient
    /// @param token The redeem token
    /// @param tokensOut The amount of tokens needed for the redeem
    function _pullFundsIfNeeded(IERC20 token, uint256 tokensOut) internal {
        // Interactions: check vault's idle balance of the redeem token
        uint256 idleBalance = token.balanceOf(MULTI_DEPOSITOR_VAULT);
        if (idleBalance >= tokensOut) return;

        // Requirements: pull-funds submit data must be configured
        address pointer = tokensDetails[token].pullFundsSubmitDataPointer;
        require(pointer != address(0), Aera__PullFundsSubmitDataNotSet());

        // Effects: compute shortfall and store in transient storage
        uint256 shortfall;
        unchecked {
            // Unchecked: idleBalance < tokensOut checked above
            shortfall = tokensOut - idleBalance;
        }
        _storeAmount(shortfall);

        // Interactions: read submit data from SSTORE2 and call vault.submit (reverts on failure)
        bytes memory data = SSTORE2.read(pointer);
        IBaseVault(MULTI_DEPOSITOR_VAULT).submit(data);
    }

    /// @notice Push deposited funds to yield source if configured
    /// @param tokenDetails The token details storage reference
    /// @param tokensIn The amount of tokens deposited
    function _pushFundsIfConfigured(TokenDetailsV2 storage tokenDetails, uint256 tokensIn) internal {
        // Interactions: check if push-funds submit data is configured (packed in tokensDetails slot)
        address pointer = tokenDetails.pushFundsSubmitDataPointer;
        if (pointer == address(0)) return;

        // Effects: store amount in transient storage
        _storeAmount(tokensIn);

        // Interactions: read submit data from SSTORE2 and call vault.submit (swallow failures)
        bytes memory data = SSTORE2.read(pointer);
        // solhint-disable no-unchecked-calls
        // slither-disable-next-line unchecked-lowlevel
        MULTI_DEPOSITOR_VAULT.call(abi.encodeCall(IBaseVault.submit, (data)));
        // solhint-enable no-unchecked-calls
    }

    /// @notice Store a uint256 amount in transient storage
    /// @param amount The amount to store
    function _storeAmount(uint256 amount) internal {
        RELEVANT_AMOUNT_SLOT.asUint256().tstore(amount);
    }

    /// @notice Handles a synchronous deposit, records the deposit hash, and enters the vault
    /// @dev Reverts if the deposit hash already exists. Sets the refundable period for the user
    /// @param token The ERC20 token to deposit
    /// @param tokenAmount The amount of tokens to deposit
    /// @param unitAmount The amount of vault units to mint for the user
    /// @param receiver The address receiving the minted units
    function _syncDeposit(IERC20 token, uint256 tokenAmount, uint256 unitAmount, address receiver) internal {
        uint256 refundableUntil = block.timestamp + depositRefundTimeout;
        bytes32 depositHash = _getDepositHash(msg.sender, receiver, token, tokenAmount, unitAmount, refundableUntil);

        // Requirements: deposit hash is not set
        require(!syncDepositHashes[depositHash], Aera__HashCollision());
        // Effects: set hash as used
        syncDepositHashes[depositHash] = true;

        // Effects: set receiver's refundable until timestamp
        userUnitsRefundableUntil[receiver] = refundableUntil;

        // Interactions: enter vault
        IMultiDepositorVault(MULTI_DEPOSITOR_VAULT).enter(msg.sender, token, tokenAmount, unitAmount, receiver);

        // Log deposit event
        emit Deposited(msg.sender, receiver, token, tokenAmount, unitAmount, depositHash);
    }

    /// @notice Executes a synchronous redeem: rolls epoch, checks epoch cap, exits vault, and emits event
    /// @param token The ERC20 token to receive
    /// @param tokensOut The amount of tokens to send to the receiver
    /// @param unitsIn The amount of vault units to burn from the caller
    /// @param receiver The address to receive the tokens
    /// @param epochRedeemNumeraire The pre-computed numeraire value of this redeem for epoch cap accounting
    /// @param priceTimestamp The PFC anchor timestamp captured in _prepareSyncRedeem (used for epoch rollover)
    function _syncRedeem(
        IERC20 token,
        uint256 tokensOut,
        uint256 unitsIn,
        address receiver,
        uint256 epochRedeemNumeraire,
        uint256 priceTimestamp
    ) internal {
        // Effects: roll epoch if PFC timestamp changed
        uint256 epochRedeemedNumeraire = _rollEpochIfNeeded(priceTimestamp);

        // Interactions: compute epoch cap
        (uint256 epochCapNumeraire,) = _computeEpochCap();

        // Requirements + Effects: check epoch cap and track redemption
        _requireEpochCapNotExceeded(epochRedeemNumeraire, epochCapNumeraire, epochRedeemedNumeraire);

        // Interactions: pull funds from yield source if vault idle balance is insufficient
        _pullFundsIfNeeded(token, tokensOut);

        // Interactions: exit vault — burns units from caller, sends tokens to receiver
        IMultiDepositorVault(MULTI_DEPOSITOR_VAULT).exit(msg.sender, token, tokensOut, unitsIn, receiver);

        // Log redeemed event
        emit Redeemed(msg.sender, receiver, token, unitsIn, tokensOut);
    }

    /// @notice Solves an async deposit request for the vault, transferring tokens or refunding as needed
    /// @dev
    /// - Returns 0 if any of:
    ///   - price age is too high, emits PriceAgeExceeded
    ///   - request hash is not set, emits InvalidRequestHash
    ///   - units out is less than min required, emits AmountBoundExceeded
    ///   - deposit cap would be exceeded, emits DepositCapExceeded
    /// - If deadline not passed, processes deposit and emits DepositSolved
    /// - If deadline passed, refunds and emits DepositRefunded
    /// - Always unsets hash after processing
    /// @param token The ERC20 token being deposited
    /// @param depositMultiplier The multiplier (in BPS) applied to the deposit for premium calculation
    /// @param request The deposit request struct containing all user parameters
    /// @param priceAge The age of the price data used for conversion
    /// @param index The index of the request in the given solving batch
    /// @return solverTip The tip amount paid to the solver, or 0 if not processed
    function _solveDepositVaultAutoPrice(
        IERC20 token,
        uint256 depositMultiplier,
        RequestV2 calldata request,
        uint256 priceAge,
        uint256 index
    ) internal returns (uint256 solverTip) {
        // Requirements: price age is within user specified max price age
        if (_guardPriceAge(priceAge, request.maxPriceAge, index)) return 0;

        bytes32 depositHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        if (_guardInvalidRequestHash(depositHash)) return 0;

        if (request.deadline >= block.timestamp) {
            solverTip = request.solverTip;
            uint256 tokens = request.tokens;

            // Requirements: tokens are enough for tip
            if (_guardInsufficientTokensForTip(tokens, solverTip, index)) return 0;

            uint256 tokensAfterTip;
            unchecked {
                tokensAfterTip = tokens - solverTip;
            }

            // Interactions: apply premium and convert tokens in to units out
            uint256 unitsOut = _tokensToUnitsFloorIfActive(token, tokensAfterTip, depositMultiplier);
            // Requirements: units out meets min units out
            if (_guardAmountBound(unitsOut, request.units, index)) return 0;
            // Requirements + interactions: convert new total units to numeraire and check against deposit cap
            if (_guardDepositCapExceeded(unitsOut, index)) return 0;

            // Effects: unset hash as used
            asyncRequestHashes[depositHash] = false;
            // Interactions: enter vault and route units to receiver
            IMultiDepositorVault(MULTI_DEPOSITOR_VAULT)
                .enter(address(this), token, tokensAfterTip, unitsOut, request.receiver);

            // Log deposit solved event
            emit DepositSolved(depositHash);
        } else {
            // Effects: unset hash as used
            asyncRequestHashes[depositHash] = false;
            // Interactions: transfer tokens from provisioner to receiver, fallback to requester on transfer failure
            _transferWithFallback(token, request.user, request.receiver, request.tokens);
            // Log deposit refunded event
            emit DepositRefunded(depositHash);
        }
    }

    /// @notice Solves a fixed price deposit request for the vault, transferring tokens or refunding as needed
    /// @dev User gets exactly min units out, but may over‑fund, the difference is paid to the solver as a tip
    /// @dev
    /// - Returns 0 if any of:
    ///   - price age is too high, emits PriceAgeExceeded
    ///   - request hash is not set, emits InvalidRequestHash
    ///   - tokens needed exceed the maximum allowed, emits AmountBoundExceeded
    ///   - deposit cap would be exceeded, emits DepositCapExceeded
    /// - If deadline not passed, processes deposit and emits DepositSolved
    /// - If deadline passed, refunds and emits DepositRefunded
    /// - Always unsets hash after processing
    /// @param token The ERC20 token being deposited
    /// @param depositMultiplier The multiplier (in BPS) applied to the deposit for premium calculation
    /// @param request The deposit request struct containing all user parameters
    /// @param priceAge The age of the price data used for conversion
    /// @param index The index of the request in the given solving batch
    /// @return solverTip The tip amount paid to the solver, or 0 if not processed
    function _solveDepositVaultFixedPrice(
        IERC20 token,
        uint256 depositMultiplier,
        RequestV2 calldata request,
        uint256 priceAge,
        uint256 index
    ) internal returns (uint256 solverTip) {
        // Requirements: price age is within user specified max price age
        if (_guardPriceAge(priceAge, request.maxPriceAge, index)) return 0;

        bytes32 depositHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        if (_guardInvalidRequestHash(depositHash)) return 0;

        if (request.deadline >= block.timestamp) {
            // Interactions: convert units to tokens applying premium
            uint256 tokensNeeded = _unitsToTokensCeilIfActive(token, request.units, depositMultiplier);
            // Requirements: tokens needed is less than or equal to max tokens in
            if (_guardAmountBound(request.tokens, tokensNeeded, index)) return 0;
            // Requirements + interactions: convert new total units to numeraire and check against deposit cap
            if (_guardDepositCapExceeded(request.units, index)) return 0;

            // Effects: unset hash as used
            asyncRequestHashes[depositHash] = false;
            // Interactions: enter vault and route units to receiver
            IMultiDepositorVault(MULTI_DEPOSITOR_VAULT)
                .enter(address(this), token, tokensNeeded, request.units, request.receiver);

            unchecked {
                solverTip = request.tokens - tokensNeeded;
            }

            // Log deposit solved event
            emit DepositSolved(depositHash);
        } else {
            // Effects: unset hash as used
            asyncRequestHashes[depositHash] = false;
            // Interactions: transfer tokens from provisioner to receiver, fallback to requester on transfer failure
            _transferWithFallback(token, request.user, request.receiver, request.tokens);
            // Log deposit refunded event
            emit DepositRefunded(depositHash);
        }
    }

    /// @notice Solves an async redeem request for the vault, transferring tokens or refunding as needed
    /// @dev
    /// - Returns 0 if any of:
    ///   - price age is too high, emits PriceAgeExceeded
    ///   - request hash is not set, emits InvalidRequestHash
    ///   - token out after premium is less than min required, emits AmountBoundExceeded
    /// - If deadline not passed, processes redeem and emits RedeemSolved
    /// - If deadline passed, refunds and emits RedeemRefunded
    /// - Always unsets hash after processing
    /// @param token The ERC20 token being redeemed
    /// @param redeemMultiplier The multiplier (in BPS) applied to the redeem for premium calculation
    /// @param request The redeem request struct containing all user parameters
    /// @param priceAge The age of the price data used for conversion
    /// @param index The index of the request in the given solving batch
    /// @return solverTip The tip amount paid to the solver, or 0 if not processed
    function _solveRedeemVaultAutoPrice(
        IERC20 token,
        uint256 redeemMultiplier,
        RequestV2 calldata request,
        uint256 priceAge,
        uint256 index
    ) internal returns (uint256 solverTip) {
        // Requirements: price age is within user specified max price age
        if (_guardPriceAge(priceAge, request.maxPriceAge, index)) return 0;

        bytes32 redeemHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        if (_guardInvalidRequestHash(redeemHash)) return 0;

        if (request.deadline >= block.timestamp) {
            solverTip = request.solverTip;

            // Interactions: convert units to token amount
            uint256 tokenOut = _unitsToTokensFloorIfActive(token, request.units, redeemMultiplier);
            // Requirements: tokens are enough for tip
            if (_guardInsufficientTokensForTip(tokenOut, solverTip, index)) return 0;

            uint256 tokenOutAfterTip;
            unchecked {
                tokenOutAfterTip = tokenOut - solverTip;
            }

            // Requirements: token amount is greater than or equal to net token amount
            if (_guardAmountBound(tokenOutAfterTip, request.tokens, index)) return 0;

            // Effects: unset hash as used
            asyncRequestHashes[redeemHash] = false;
            // Interactions: exit vault
            IMultiDepositorVault(MULTI_DEPOSITOR_VAULT)
                .exit(address(this), token, tokenOut, request.units, address(this));

            // Interactions: transfer tokens from provisioner to receiver
            token.safeTransfer(request.receiver, tokenOutAfterTip);

            // Log redeem solved event
            emit RedeemSolved(redeemHash);
        } else {
            // Effects: unset hash as used
            asyncRequestHashes[redeemHash] = false;
            // Interactions: transfer units from provisioner to receiver, fallback to requester on transfer failure
            _transferWithFallback(IERC20(MULTI_DEPOSITOR_VAULT), request.user, request.receiver, request.units);
            // Log redeem refunded event
            emit RedeemRefunded(redeemHash);
        }
    }

    /// @notice Solves a fixed price redeem request for the vault, transferring tokens or refunding as needed
    /// @dev User gets exactly min tokens out, but may under‑fund, the difference is paid to the solver as a tip
    /// @dev
    /// - Returns 0 if any of:
    ///   - price age is too high, emits PriceAgeExceeded
    ///   - request hash is not set, emits InvalidRequestHash
    /// - If deadline not passed, processes redeem and emits RedeemSolved
    /// - If deadline passed, refunds and emits RedeemRefunded
    /// - Always unsets hash after processing
    /// @param token The ERC20 token being redeemed
    /// @param redeemMultiplier The multiplier (in BPS) applied to the redeem for premium calculation
    /// @param request The redeem request struct containing all user parameters
    /// @param priceAge The age of the price data used for conversion
    /// @param index The index of the request in the given solving batch
    /// @return solverTip The tip amount paid to the solver, or 0 if not processed
    function _solveRedeemVaultFixedPrice(
        IERC20 token,
        uint256 redeemMultiplier,
        RequestV2 calldata request,
        uint256 priceAge,
        uint256 index
    ) internal returns (uint256 solverTip) {
        // Requirements: price age is within user specified max price age
        if (_guardPriceAge(priceAge, request.maxPriceAge, index)) return 0;

        bytes32 redeemHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        if (_guardInvalidRequestHash(redeemHash)) return 0;

        if (request.deadline >= block.timestamp) {
            // Interactions: convert units to token amount
            uint256 tokenOut = _unitsToTokensFloorIfActive(token, request.units, redeemMultiplier);
            // Requirements: token amount is greater than or equal to net token amount
            if (_guardAmountBound(tokenOut, request.tokens, index)) return 0;

            // Effects: unset hash as used
            asyncRequestHashes[redeemHash] = false;
            // Interactions: exit vault
            IMultiDepositorVault(MULTI_DEPOSITOR_VAULT)
                .exit(address(this), token, tokenOut, request.units, address(this));
            // Interactions: transfer tokens from provisioner to receiver
            token.safeTransfer(request.receiver, request.tokens);

            unchecked {
                solverTip = tokenOut - request.tokens;
            }

            // Log redeem solved event
            emit RedeemSolved(redeemHash);
        } else {
            // Effects: unset hash as used
            asyncRequestHashes[redeemHash] = false;
            // Interactions: transfer units from provisioner to receiver, fallback to requester on transfer failure
            _transferWithFallback(IERC20(MULTI_DEPOSITOR_VAULT), request.user, request.receiver, request.units);
            // Log redeem refunded event
            emit RedeemRefunded(redeemHash);
        }
    }

    /// @notice Solves a direct request (deposit or redeem), transferring tokens and units between users
    /// @dev
    /// - Returns early if request hash is not set, emits InvalidRequestHash
    /// - If deadline not passed, transfers units and tokens, emits DepositSolved/RedeemSolved
    /// - If deadline passed, refunds escrowed asset, emits DepositRefunded/RedeemRefunded
    /// - Always unsets hash after processing
    /// @param token The ERC20 token involved in the request
    /// @param request The request struct containing all user parameters
    function _solveRequestDirect(IERC20 token, RequestV2 calldata request) internal {
        bytes32 requestHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        if (_guardInvalidRequestHash(requestHash)) return;

        // Effects: unset hash as used
        asyncRequestHashes[requestHash] = false;

        bool isDeposit = _isRequestTypeDeposit(request.requestType);

        if (request.deadline >= block.timestamp) {
            if (isDeposit) {
                // Interactions: pull units from sender(solver) to receiver
                IERC20(MULTI_DEPOSITOR_VAULT).safeTransferFrom(msg.sender, request.receiver, request.units);
                // Interactions: transfer tokens from provisioner to sender
                token.safeTransfer(msg.sender, request.tokens);

                // Log solved event
                emit DepositSolved(requestHash);
            } else {
                // Interactions: transfer units from provisioner to sender
                IERC20(MULTI_DEPOSITOR_VAULT).safeTransfer(msg.sender, request.units);
                // Interactions: pull tokens from sender(solver) to receiver
                token.safeTransferFrom(msg.sender, request.receiver, request.tokens);

                // Log solved event
                emit RedeemSolved(requestHash);
            }
        } else {
            // Interactions: transfer escrowed asset to receiver, fallback to requester on transfer failure
            if (isDeposit) {
                _transferWithFallback(token, request.user, request.receiver, request.tokens);

                // Log refunded event
                emit DepositRefunded(requestHash);
            } else {
                _transferWithFallback(IERC20(MULTI_DEPOSITOR_VAULT), request.user, request.receiver, request.units);

                // Log refunded event
                emit RedeemRefunded(requestHash);
            }
        }
    }

    /// @notice Clears request hash, emits refund event, and transfers amount with requester fallback
    /// @param token The token used to derive the request hash
    /// @param request The request to clear
    /// @param requester The fallback recipient when transfer to request.receiver fails
    /// @param amount The amount to transfer to the receiver (or requester on fallback)
    /// @param transferToken The token to transfer (deposit token for deposits, vault units for redeems)
    function _clearHashAndTransferRefund(
        IERC20 token,
        RequestV2 calldata request,
        address requester,
        uint256 amount,
        IERC20 transferToken
    ) internal {
        bytes32 requestHash = _getRequestHash(token, request);
        // Requirements: hash has been set
        require(asyncRequestHashes[requestHash], Aera__HashNotFound());
        // Effects: unset hash as used
        asyncRequestHashes[requestHash] = false;
        // Interactions: transfer amount to receiver, fallback to requester on transfer failure
        _transferWithFallback(transferToken, requester, request.receiver, amount);

        // Log refund event
        if (_isRequestTypeDeposit(request.requestType)) {
            emit DepositRefunded(requestHash);
        } else {
            emit RedeemRefunded(requestHash);
        }
    }

    /// @notice Transfers amount to receiver and falls back to requester if receiver transfer fails
    /// @param token The ERC20 token being transferred
    /// @param requester The original requester address used as fallback receiver
    /// @param receiver The intended receiver from the request
    /// @param amount The amount of tokens to transfer
    function _transferWithFallback(IERC20 token, address requester, address receiver, uint256 amount) internal {
        // Interactions: transfer to receiver, fallback to requester on transfer failure
        if (receiver == requester || !token.trySafeTransfer(receiver, amount)) {
            token.safeTransfer(requester, amount);
        }
    }

    /// @notice Checks if the price age exceeds the maximum allowed and emits an event if so
    /// @param priceAge The difference between when price was measured and submitted onchain
    /// @param maxPriceAge The maximum allowed price age
    /// @param index The index of the request in the given solving batch
    /// @return True if price age is too high, false otherwise
    function _guardPriceAge(uint256 priceAge, uint256 maxPriceAge, uint256 index) internal returns (bool) {
        if (priceAge > maxPriceAge) {
            emit PriceAgeExceeded(index);
            return true;
        }
        return false;
    }

    /// @notice Checks if the request hash exists and emits an event if not
    /// @param requestHash The request hash
    /// @return True if hash does not exist, false otherwise
    function _guardInvalidRequestHash(bytes32 requestHash) internal returns (bool) {
        if (!asyncRequestHashes[requestHash]) {
            // Log invalid request hash event
            emit InvalidRequestHash(requestHash);
            return true;
        }
        return false;
    }

    /// @notice Checks if there are enough tokens for the solver tip and emits an event if not
    /// @param tokens The number of tokens
    /// @param solverTip The solver tip amount
    /// @param index The index of the request in the given solving batch
    /// @return True if not enough tokens for tip, false otherwise
    function _guardInsufficientTokensForTip(uint256 tokens, uint256 solverTip, uint256 index) internal returns (bool) {
        if (tokens < solverTip) {
            // Log insufficient tokens for tip event
            emit InsufficientTokensForTip(index);
            return true;
        }
        return false;
    }

    /// @notice Checks if the amount is less than the bound and emits an event if so
    /// @param amount The actual amount
    /// @param bound The minimum required amount
    /// @param index The index of the request in the given solving batch
    /// @return True if amount is less than bound, false otherwise
    function _guardAmountBound(uint256 amount, uint256 bound, uint256 index) internal returns (bool) {
        if (amount < bound) {
            // Log amount bound exceeded event
            emit AmountBoundExceeded(index, amount, bound);
            return true;
        }
        return false;
    }

    /// @notice Checks if the deposit cap would be exceeded and emits an event if so
    /// @param totalUnits The total units after deposit
    /// @param index The index of the request in the given solving batch
    /// @return True if deposit cap would be exceeded, false otherwise
    function _guardDepositCapExceeded(uint256 totalUnits, uint256 index) internal returns (bool) {
        // Interactions: check if deposit cap would be exceeded
        if (_isDepositCapExceeded(totalUnits)) {
            // Log deposit cap exceeded event
            emit DepositCapExceeded(index);
            return true;
        }
        return false;
    }

    /// @notice Rolls the sync redeem epoch if the PFC timestamp has changed
    /// @param pfcTimestamp The current PFC vault state timestamp
    /// @return epochRedeemedNumeraire_ The epoch redeemed numeraire after potential roll (avoids subsequent SSLOADs)
    function _rollEpochIfNeeded(uint256 pfcTimestamp) internal returns (uint256 epochRedeemedNumeraire_) {
        if (pfcTimestamp != _syncRedeemEpochTimestamp) {
            // Effects: reset epoch state to new timestamp
            _syncRedeemEpochTimestamp = uint32(pfcTimestamp);
            _syncRedeemEpochRedeemedNumeraire = 0;
            return 0;
        }
        return _syncRedeemEpochRedeemedNumeraire;
    }

    /// @notice Checks that the sync redeem epoch cap is not exceeded and tracks the redemption
    /// @param epochRedeemNumeraire The pre-computed numeraire value of this redeem for epoch cap accounting
    /// @param epochCapNumeraire The effective epoch cap in numeraire
    /// @param epochRedeemedNumeraire The numeraire already redeemed in the current epoch (cached from _rollEpochIfNeeded)
    function _requireEpochCapNotExceeded(
        uint256 epochRedeemNumeraire,
        uint256 epochCapNumeraire,
        uint256 epochRedeemedNumeraire
    ) internal {
        epochRedeemedNumeraire += epochRedeemNumeraire;
        // Requirements: epoch cap is not exceeded
        require(epochRedeemedNumeraire <= epochCapNumeraire, Aera__SyncRedeemEpochCapExceeded());

        // Effects: increment global epoch redeemed counter
        // safe downcast because epochRedeemedNumeraire + epochRedeemNumeraire <= epochCapNumeraire
        // and epochCapNumeraire = min(relativeCap, absoluteCapNumeraire) where absoluteCapNumeraire is uint80
        _syncRedeemEpochRedeemedNumeraire = uint80(epochRedeemedNumeraire);
    }

    /// @notice Reverts if the caller is not the receiver and the receiver has not approved the caller
    /// @param receiver The address to validate
    function _requireValidReceiver(address receiver) internal view {
        // Requirements: caller is receiver or receiver has approved caller
        require(receiver == msg.sender || depositReceiverApprovals[receiver][msg.sender], Aera__ReceiverNotApproved());
    }

    /// @notice Reverts if the solving gate is set and reports that solving is paused
    /// @param token The ERC20 token being solved
    function _checkSolvingNotPaused(IERC20 token) internal view {
        if (SOLVING_GATE_ENABLED) {
            address gate = solvingGate;
            require(gate == address(0) || !ISolvingGate(gate).paused(address(this), token), Aera__SolvingPaused());
        }
    }

    /// @notice Reverts if the caller is the vault
    function _checkCallerNotVault() internal view {
        // Requirements: check that the caller is not the vault
        require(msg.sender != MULTI_DEPOSITOR_VAULT, Aera__CallerIsVault());
    }

    /// @notice Validates common request parameters shared by requestDeposit and requestRedeem
    /// @param receiver The address receiving funds when request is solved
    /// @param solverTip The tip offered to the solver
    /// @param deadline Timestamp until which the request is valid
    /// @param isFixedPrice Whether the request is a fixed price request
    function _validateRequest(address receiver, uint256 solverTip, uint256 deadline, bool isFixedPrice) internal view {
        // Requirements: receiver is not zero address
        require(receiver != address(0), Aera__ZeroAddressReceiver());
        // Requirements: deadline is in the future and not too far in the future
        require(deadline > block.timestamp, Aera__DeadlineInPast());
        unchecked {
            require(deadline - block.timestamp <= MAX_SECONDS_TO_DEADLINE, Aera__DeadlineTooFarInFuture());
        }
        // Requirements: vault is not paused in the PriceAndFeeCalculator
        require(!PRICE_FEE_CALCULATOR.isVaultPaused(MULTI_DEPOSITOR_VAULT), Aera__PriceAndFeeCalculatorVaultPaused());
        // Requirements: fixed price requests cannot have a solver tip
        require(solverTip == 0 || !isFixedPrice, Aera__FixedPriceSolverTipNotAllowed());
    }

    /// @notice Computes the pre-deadline deposit cancellation fee in request token terms
    /// @dev Oracle quoting floors and does not support rounding control, so a non-zero numeraire fee can round to zero
    /// request tokens for low-value cancellation fees
    /// @param token Request token
    /// @return feeTokens Fee amount in request token terms
    function _computeDepositCancellationFeeTokens(IERC20 token) internal view returns (uint256 feeTokens) {
        uint256 feeNumeraire = _depositCancellationFeeNumeraire;
        if (feeNumeraire == 0) return 0;

        // Interactions: convert fixed numeraire fee to token via oracle (floors; oracle does not support rounding)
        return PRICE_FEE_CALCULATOR.convertNumeraireToToken(MULTI_DEPOSITOR_VAULT, token, feeNumeraire);
    }

    /// @notice Computes the pre-deadline redeem cancellation fee in numeraire
    /// @param requestNumeraire Redeem request size in numeraire
    /// @return feeNumeraire Fee amount in numeraire
    function _computeRedeemCancellationFeeNumeraire(uint256 requestNumeraire)
        internal
        view
        returns (uint256 feeNumeraire)
    {
        feeNumeraire = _redeemCancellationFeeNumeraire;
        uint256 redeemCancellationDynamicFeeCapNumeraire = _redeemCancellationDynamicFeeCapNumeraire;

        if (redeemCancellationDynamicFeeCapNumeraire != 0) {
            // Ceil rounding favors protocol for proportional fee component
            feeNumeraire += Math.mulDiv(
                requestNumeraire,
                redeemCancellationDynamicFeeCapNumeraire,
                _redeemCancellationCapNumeraire,
                Math.Rounding.Ceil
            );
        }
    }

    /// @notice Computes the pre-deadline redeem cancellation fee in escrowed vault units
    /// @param requestNumeraire Redeem request size in numeraire
    /// @return feeUnits Fee amount in units
    function _computeRedeemCancellationFeeUnits(uint256 requestNumeraire) internal view returns (uint256 feeUnits) {
        uint256 feeNumeraire = _computeRedeemCancellationFeeNumeraire(requestNumeraire);

        // Interactions: convert total numeraire fee to units with protocol-favoring ceil rounding
        return PRICE_FEE_CALCULATOR.convertNumeraireToUnits(MULTI_DEPOSITOR_VAULT, feeNumeraire, Math.Rounding.Ceil);
    }

    /// @notice Reverts if sync deposits are not enabled for the token
    /// @param token The ERC20 token to check
    /// @return tokenDetails The token details storage reference
    function _requireSyncDepositsEnabled(IERC20 token) internal view returns (TokenDetailsV2 storage tokenDetails) {
        tokenDetails = tokensDetails[token];
        // Requirements: sync deposits are enabled
        require(tokenDetails.syncDepositEnabled, Aera__SyncDepositDisabled());
    }

    /// @notice Reverts if sync redeems are not enabled for the token
    /// @param token The ERC20 token to check
    /// @return tokenDetails The token details storage reference
    function _requireSyncRedeemsEnabled(IERC20 token) internal view returns (TokenDetailsV2 storage tokenDetails) {
        tokenDetails = tokensDetails[token];
        // Requirements: sync redeems are enabled
        require(tokenDetails.syncRedeemEnabled, Aera__SyncRedeemDisabled());
    }

    /// @notice Reverts if deposit cap would be exceeded by adding units
    /// @param units The number of units to add
    function _requireDepositCapNotExceeded(uint256 units) internal view {
        // Requirements + interactions: deposit cap not exceeded
        require(!_isDepositCapExceeded(units), Aera__DepositCapExceeded());
    }

    /// @notice Checks if deposit cap would be exceeded by adding units
    /// @param units The number of units to add
    /// @return True if deposit cap would be exceeded, false otherwise
    function _isDepositCapExceeded(uint256 units) internal view returns (bool) {
        // Interactions: get current total supply
        uint256 newTotal = IERC20(MULTI_DEPOSITOR_VAULT).totalSupply() + units;
        // Interactions: convert total supply to numeraire with protocol-favoring ceil rounding
        return
            PRICE_FEE_CALCULATOR.convertUnitsToNumeraire(MULTI_DEPOSITOR_VAULT, newTotal, Math.Rounding.Ceil)
                > depositCap;
    }

    /// @notice Converts token amount to units, applying multiplier and flooring
    /// @param token The ERC20 token
    /// @param tokens The amount of tokens
    /// @param multiplier The multiplier to apply
    /// @return The resulting units (floored)
    function _tokensToUnitsFloorIfActive(IERC20 token, uint256 tokens, uint256 multiplier)
        internal
        view
        returns (uint256)
    {
        uint256 tokensAdjusted = Math.mulDiv(tokens, multiplier, ONE_IN_BPS);
        // Interactions: convert tokens to units
        return PRICE_FEE_CALCULATOR.convertTokenToUnitsIfActive(
            MULTI_DEPOSITOR_VAULT, token, tokensAdjusted, Math.Rounding.Floor
        );
    }

    /// @notice Converts token amount to units, reversing multiplier and ceiling
    /// @param token The ERC20 token
    /// @param tokens The amount of tokens
    /// @param multiplier The multiplier to reverse
    /// @return The resulting units (ceiled)
    function _tokensToUnitsCeilIfActive(IERC20 token, uint256 tokens, uint256 multiplier)
        internal
        view
        returns (uint256)
    {
        uint256 prePremiumTokens = Math.mulDiv(tokens, ONE_IN_BPS, multiplier, Math.Rounding.Ceil);
        // Interactions: convert tokens to units
        return PRICE_FEE_CALCULATOR.convertTokenToUnitsIfActive(
            MULTI_DEPOSITOR_VAULT, token, prePremiumTokens, Math.Rounding.Ceil
        );
    }

    /// @notice Converts units to token amount, applying multiplier and flooring
    /// @param token The ERC20 token
    /// @param units The amount of units
    /// @param multiplier The multiplier to apply
    /// @return The resulting token amount (floored)
    function _unitsToTokensFloorIfActive(IERC20 token, uint256 units, uint256 multiplier)
        internal
        view
        returns (uint256)
    {
        // Interactions: convert units to tokens
        uint256 tokensAmount =
            PRICE_FEE_CALCULATOR.convertUnitsToTokenIfActive(MULTI_DEPOSITOR_VAULT, token, units, Math.Rounding.Floor);
        return Math.mulDiv(tokensAmount, multiplier, ONE_IN_BPS);
    }

    /// @notice Converts units to token amount, applying multiplier and ceiling
    /// @param token The ERC20 token
    /// @param units The amount of units
    /// @param multiplier The multiplier to apply
    /// @return The resulting token amount (ceiled)
    function _unitsToTokensCeilIfActive(IERC20 token, uint256 units, uint256 multiplier)
        internal
        view
        returns (uint256)
    {
        // Interactions: convert units to tokens
        uint256 tokensAmount =
            PRICE_FEE_CALCULATOR.convertUnitsToTokenIfActive(MULTI_DEPOSITOR_VAULT, token, units, Math.Rounding.Ceil);
        return Math.mulDiv(tokensAmount, ONE_IN_BPS, multiplier, Math.Rounding.Ceil);
    }

    /// @notice Computes the effective epoch cap in numeraire
    /// @return epochCapNumeraire The effective epoch cap (min of relative and absolute)
    /// @return epochStartTvlNumeraire The epoch-start TVL in numeraire
    function _computeEpochCap() internal view returns (uint256 epochCapNumeraire, uint256 epochStartTvlNumeraire) {
        // Interactions: compute epoch-start TVL in numeraire from PFC
        epochStartTvlNumeraire = PRICE_FEE_CALCULATOR.getVaultValueAtLastUpdate(MULTI_DEPOSITOR_VAULT);

        uint256 relativeCapNumeraire = Math.mulDiv(epochStartTvlNumeraire, _syncRedeemRelativeCapBps, ONE_IN_BPS);
        epochCapNumeraire = Math.min(relativeCapNumeraire, _syncRedeemAbsoluteCapNumeraire);
    }

    /// @notice Computes the global dynamic redeem premium in bps based on price staleness
    /// @dev Returns 0 when maxDynamicPremiumBps is 0 (dynamic premium disabled)
    ///      Callers enforce priceAge <= syncRedeemMaxPriceAge via require, so dynamicPremiumBps <= maxDynamic
    ///      Division safety: syncRedeemMaxPriceAge > 0 is enforced by setSyncRedeemDetails
    /// @param priceAge The current price age in seconds
    /// @return dynamicPremiumBps The computed dynamic premium in bps
    function _computeDynamicPremiumBps(uint256 priceAge) internal view returns (uint256 dynamicPremiumBps) {
        uint256 maxDynamic = _syncRedeemMaxDynamicPremiumBps;
        if (maxDynamic == 0) return 0;

        // Ceil rounding: protocol-favoring (higher premium → fewer tokens to redeemer)
        dynamicPremiumBps = Math.mulDiv(priceAge, maxDynamic, _syncRedeemMaxPriceAge, Math.Rounding.Ceil);
    }

    /// @notice Fetches the anchor timestamp, validates price age, and derives the effective multiplier
    /// @param syncRedeemMultiplier The base sync redeem multiplier for the token (in BPS)
    /// @return effectiveMultiplier The multiplier after dynamic premium adjustment
    /// @return priceTimestamp The PFC anchor timestamp (consumed downstream for epoch rollover)
    function _prepareSyncRedeem(uint256 syncRedeemMultiplier)
        internal
        view
        returns (uint256 effectiveMultiplier, uint256 priceTimestamp)
    {
        // Interactions: read the anchor snapshot from PFC so epoch rollover use the same basis
        priceTimestamp = PRICE_FEE_CALCULATOR.getAnchorTimestamp(MULTI_DEPOSITOR_VAULT);

        // Requirements: price age is within sync redeem max price age
        require(_syncRedeemMaxPriceAge + priceTimestamp >= block.timestamp, Aera__SyncRedeemMaxPriceAgeExceeded());

        uint256 priceAge = block.timestamp - priceTimestamp;

        unchecked {
            // unchecked: safe because setSyncRedeemDetails enforces maxDynamicPremiumBps < MIN_MULTIPLIER
            // and setTokenDetails enforces syncRedeemMultiplier >= MIN_MULTIPLIER,
            // so dynamicPremiumBps <= maxDynamicPremiumBps < MIN_MULTIPLIER <= syncRedeemMultiplier
            effectiveMultiplier = syncRedeemMultiplier - _computeDynamicPremiumBps(priceAge);
        }
    }

    /// @notice Returns the request type based on whether the request is a deposit or redeem and fixed or auto price
    /// @param isFixedPrice Whether the request is a fixed price request
    /// @param isDeposit Whether the request is a deposit (true) or redeem (false)
    /// @return The computed request type
    function _getRequestType(bool isFixedPrice, bool isDeposit) internal pure returns (RequestType) {
        if (isDeposit) {
            return isFixedPrice ? RequestType.DEPOSIT_FIXED_PRICE : RequestType.DEPOSIT_AUTO_PRICE;
        } else {
            return isFixedPrice ? RequestType.REDEEM_FIXED_PRICE : RequestType.REDEEM_AUTO_PRICE;
        }
    }

    /// @notice Reverts if a multiplier is outside [MIN_MULTIPLIER, ONE_IN_BPS]
    /// @param multiplier The multiplier to validate
    function _requireValidMultiplier(uint256 multiplier) internal pure {
        require(multiplier >= MIN_MULTIPLIER && multiplier <= ONE_IN_BPS, Aera__MultiplierOutOfRange());
    }

    /// @notice Reverts if either the units or tokens amount is zero
    /// @param units The units amount to validate
    /// @param tokens The tokens amount to validate
    function _validateNonZeroAmounts(uint256 units, uint256 tokens) internal pure {
        require(units != 0, Aera__UnitsZero());
        require(tokens != 0, Aera__TokensZero());
    }

    /// @notice Get the hash of a deposit
    /// @param sender The user who made the deposit
    /// @param receiver The user that receives units from the deposit
    /// @param token The token that was deposited
    /// @param tokenAmount The amount of tokens deposited
    /// @param unitsAmount The amount of units received
    /// @param refundableUntil The timestamp at which the deposit can be refunded
    /// @return The hash of the deposit
    /// @dev Since refundableUntil is block.timestamp + depositRefundTimeout (which is subject to change), it's
    /// theoretically possible to have a hash collision, but the probability is negligible and we optimize for the
    /// common case
    function _getDepositHash(
        address sender,
        address receiver,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, receiver, token, tokenAmount, unitsAmount, refundableUntil));
    }

    /// @notice Get the hash of a request from parameters
    /// @param token The token that was deposited or redeemed
    /// @param user The user who made the request
    /// @param receiver The user that receives funds when request is solved
    /// @param requestType The type of request
    /// @param tokens The amount of tokens in the request
    /// @param units The amount of units in the request
    /// @param solverTip The tip paid to the solver
    /// @param deadline The deadline of the request
    /// @param maxPriceAge The maximum age of the price data
    /// @return The hash of the request
    function _getRequestHashParams(
        IERC20 token,
        address user,
        address receiver,
        RequestType requestType,
        uint256 tokens,
        uint256 units,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(token, user, receiver, requestType, tokens, units, solverTip, deadline, maxPriceAge)
        );
    }

    /// @notice Get the hash of a request
    /// @param token The token that was deposited or redeemed
    /// @param request The request to get the hash of
    /// @return The hash of the request
    function _getRequestHash(IERC20 token, RequestV2 calldata request) internal pure returns (bytes32) {
        return _getRequestHashParams(
            token,
            request.user,
            request.receiver,
            request.requestType,
            request.tokens,
            request.units,
            request.solverTip,
            request.deadline,
            request.maxPriceAge
        );
    }

    /// @notice Returns true if the request type is a deposit
    /// @param requestType The request type
    /// @return True if deposit, false otherwise
    function _isRequestTypeDeposit(RequestType requestType) internal pure returns (bool) {
        return uint8(requestType) & DEPOSIT_REDEEM_FLAG == 0;
    }

    /// @notice Returns true if the request type is fixed price
    /// @param requestType The request type
    /// @return True if fixed price, false otherwise
    function _isRequestTypeAutoPrice(RequestType requestType) internal pure returns (bool) {
        return uint8(requestType) & AUTO_PRICE_FIXED_PRICE_FLAG == 0;
    }
}
