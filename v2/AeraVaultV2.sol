// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/ERC165.sol";
import "@openzeppelin/ERC165Checker.sol";
import "@openzeppelin/IERC4626.sol";
import "@openzeppelin/Math.sol";
import "@openzeppelin/Ownable2Step.sol";
import "@openzeppelin/Pausable.sol";
import "@openzeppelin/ReentrancyGuard.sol";
import "@openzeppelin/SafeERC20.sol";
import "./interfaces/IAeraV2Factory.sol";
import "./interfaces/IHooks.sol";
import "./interfaces/IVault.sol";
import {ONE} from "./Constants.sol";

/// @title AeraVaultV2.
/// @notice Aera Vault V2 Vault contract.
contract AeraVaultV2 is
    IVault,
    ERC165,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @notice Largest possible fee earned proportion per one second.
    /// @dev 0.0000001% per second, i.e. 3.1536% per year.
    ///      0.0000001% * (365 * 24 * 60 * 60) = 3.1536%
    ///      or 3.16224% per year in leap years.
    uint256 private constant _MAX_FEE = 10 ** 9;

    /// @notice Number of decimals for fee token.
    uint256 private immutable _feeTokenDecimals;

    /// @notice Number of decimals for numeraire token.
    uint256 private immutable _numeraireTokenDecimals;

    /// @notice Fee token used by asset registry.
    IERC20 private immutable _feeToken;

    /// @notice Fee per second in 18 decimal fixed point format.
    uint256 public immutable fee;

    /// @notice Asset registry address.
    IAssetRegistry public immutable assetRegistry;

    /// @notice The address of wrapped native token.
    address public immutable wrappedNativeToken;

    /// STORAGE ///

    /// @notice Hooks module address.
    IHooks public hooks;

    /// @notice Guardian address.
    address public guardian;

    /// @notice Fee recipient address.
    address public feeRecipient;

    /// @notice True if vault has been finalized.
    bool public finalized;

    /// @notice Last measured value of assets in vault.
    uint256 public lastValue;

    /// @notice Last spot price of fee token.
    uint256 public lastFeeTokenPrice;

    /// @notice Fee earned amount for each prior fee recipient.
    mapping(address => uint256) public fees;

    /// @notice Total fee earned and unclaimed amount by all fee recipients.
    uint256 public feeTotal;

    /// @notice Last timestamp when fee index was reserved.
    uint256 public lastFeeCheckpoint;

    /// MODIFIERS ///

    /// @dev Throws if called by any account other than the owner or guardian.
    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) {
            revert Aera__CallerIsNotOwnerAndGuardian();
        }
        _;
    }

    /// @dev Throws if called by any account other than the guardian.
    modifier onlyGuardian() {
        if (msg.sender != guardian) {
            revert Aera__CallerIsNotGuardian();
        }
        _;
    }

    /// @dev Throws if called after the vault is finalized.
    modifier whenNotFinalized() {
        if (finalized) {
            revert Aera__VaultIsFinalized();
        }
        _;
    }

    /// @dev Throws if hooks is not set
    modifier whenHooksSet() {
        if (address(hooks) == address(0)) {
            revert Aera__HooksIsZeroAddress();
        }
        _;
    }

    /// @dev Calculate current guardian fees.
    modifier reserveFees() {
        _reserveFees();
        _;
    }

    /// @dev Check insolvency of fee token was not made worse.
    modifier checkReservedFees() {
        uint256 prevFeeTokenBalance =
            IERC20(_feeToken).balanceOf(address(this));
        _;
        _checkReservedFees(prevFeeTokenBalance);
    }

    /// FUNCTIONS ///

    constructor() Ownable() ReentrancyGuard() {
        (
            address owner_,
            address assetRegistry_,
            address hooks_,
            address guardian_,
            address feeRecipient_,
            uint256 fee_
        ) = IAeraV2Factory(msg.sender).parameters();

        // Requirements: check provided addresses.
        _checkAssetRegistryAddress(assetRegistry_);
        _checkHooksAddress(hooks_);
        _checkGuardianAddress(guardian_, owner_);
        _checkFeeRecipientAddress(feeRecipient_, owner_);

        // Requirements: check that initial owner is not zero address.
        if (owner_ == address(0)) {
            revert Aera__InitialOwnerIsZeroAddress();
        }
        // Requirements: check if fee is within bounds.
        if (fee_ > _MAX_FEE) {
            revert Aera__FeeIsAboveMax(fee_, _MAX_FEE);
        }

        // Effects: initialize vault state.
        wrappedNativeToken = IAeraV2Factory(msg.sender).wrappedNativeToken();
        assetRegistry = IAssetRegistry(assetRegistry_);
        hooks = IHooks(hooks_);
        guardian = guardian_;
        feeRecipient = feeRecipient_;
        fee = fee_;
        lastFeeCheckpoint = block.timestamp;

        // Effects: cache numeraire and fee token decimals.
        _feeToken = IAssetRegistry(assetRegistry_).feeToken();
        _feeTokenDecimals = IERC20Metadata(address(_feeToken)).decimals();
        _numeraireTokenDecimals =
            IERC20Metadata(address(assetRegistry.numeraireToken())).decimals();

        // Effects: set new owner.
        _transferOwnership(owner_);

        // Effects: pause vault.
        _pause();

        // Log setting of asset registry.
        emit SetAssetRegistry(assetRegistry_);

        // Log new hooks address.
        emit SetHooks(hooks_);

        // Log the current guardian and fee recipient.
        emit SetGuardianAndFeeRecipient(guardian_, feeRecipient_);
    }

    /// @inheritdoc IVault
    function deposit(AssetValue[] calldata amounts)
        external
        override
        nonReentrant
        onlyOwner
        whenHooksSet
        whenNotFinalized
        reserveFees
    {
        // Hooks: before transferring assets.
        hooks.beforeDeposit(amounts);

        // Requirements: check that provided amounts are sorted by asset and unique.
        _checkAmountsSorted(amounts);

        IAssetRegistry.AssetInformation[] memory assets =
            assetRegistry.assets();

        uint256 numAmounts = amounts.length;
        AssetValue memory assetValue;
        bool isRegistered;

        for (uint256 i = 0; i < numAmounts;) {
            assetValue = amounts[i];
            (isRegistered,) = _isAssetRegistered(assetValue.asset, assets);

            // Requirements: check that deposited assets are registered.
            if (!isRegistered) {
                revert Aera__AssetIsNotRegistered(assetValue.asset);
            }

            // Interactions: transfer asset from owner to vault.
            assetValue.asset.safeTransferFrom(
                msg.sender, address(this), assetValue.value
            );

            unchecked {
                i++; // gas savings
            }

            // Log deposit for this asset.
            emit Deposit(msg.sender, assetValue.asset, assetValue.value);
        }

        // Hooks: after transferring assets.
        hooks.afterDeposit(amounts);
    }

    /// @inheritdoc IVault
    function withdraw(AssetValue[] calldata amounts)
        external
        override
        nonReentrant
        onlyOwner
        whenHooksSet
        whenNotFinalized
        reserveFees
    {
        IAssetRegistry.AssetInformation[] memory assets =
            assetRegistry.assets();

        // Requirements: check the withdraw request.
        _checkWithdrawRequest(assets, amounts);

        // Requirements: check that provided amounts are sorted by asset and unique.
        _checkAmountsSorted(amounts);

        // Hooks: before transferring assets.
        hooks.beforeWithdraw(amounts);

        uint256 numAmounts = amounts.length;
        AssetValue memory assetValue;

        for (uint256 i = 0; i < numAmounts;) {
            assetValue = amounts[i];

            if (assetValue.value == 0) {
                unchecked {
                    i++; // gas savings
                }

                continue;
            }

            // Interactions: withdraw assets.
            assetValue.asset.safeTransfer(msg.sender, assetValue.value);

            // Log withdrawal for this asset.
            emit Withdraw(msg.sender, assetValue.asset, assetValue.value);

            unchecked {
                i++; // gas savings
            }
        }

        // Hooks: after transferring assets.
        hooks.afterWithdraw(amounts);
    }

    /// @inheritdoc IVault
    function setGuardianAndFeeRecipient(
        address newGuardian,
        address newFeeRecipient
    ) external override onlyOwner whenNotFinalized reserveFees {
        // Requirements: check guardian and fee recipient addresses.
        _checkGuardianAddress(newGuardian, msg.sender);
        _checkFeeRecipientAddress(newFeeRecipient, msg.sender);

        // Effects: update guardian and fee recipient addresses.
        guardian = newGuardian;
        feeRecipient = newFeeRecipient;

        // Log new guardian and fee recipient addresses.
        emit SetGuardianAndFeeRecipient(newGuardian, newFeeRecipient);
    }

    /// @inheritdoc IVault
    function setHooks(address newHooks)
        external
        override
        nonReentrant
        onlyOwner
        whenNotFinalized
        reserveFees
    {
        // Requirements: validate hooks address.
        _checkHooksAddress(newHooks);

        // Effects: decommission old hooks contract.
        if (address(hooks) != address(0)) {
            hooks.decommission();
        }

        // Effects: set new hooks address.
        hooks = IHooks(newHooks);

        // Log new hooks address.
        emit SetHooks(newHooks);
    }

    /// @inheritdoc IVault
    /// @dev reserveFees modifier is not used to avoid reverts.
    function execute(Operation calldata operation)
        external
        override
        nonReentrant
        onlyOwner
    {
        // Requirements: check that the target contract is not hooks.
        if (operation.target == address(hooks)) {
            revert Aera__ExecuteTargetIsHooksAddress();
        }
        // Requirements: check that the target contract is not vault itself.
        if (operation.target == address(this)) {
            revert Aera__ExecuteTargetIsVaultAddress();
        }

        // Interactions: execute operation.
        (bool success, bytes memory result) =
            operation.target.call{value: operation.value}(operation.data);

        // Invariants: check that the operation was successful.
        if (!success) {
            revert Aera__ExecutionFailed(result);
        }

        // Log that the operation was executed.
        emit Executed(msg.sender, operation);
    }

    /// @inheritdoc IVault
    function finalize()
        external
        override
        nonReentrant
        onlyOwner
        whenHooksSet
        whenNotFinalized
        reserveFees
    {
        // Hooks: before finalizing.
        hooks.beforeFinalize();

        // Effects: mark the vault as finalized.
        finalized = true;

        IAssetRegistry.AssetInformation[] memory assets =
            assetRegistry.assets();
        AssetValue[] memory assetAmounts = _getHoldings(assets);
        uint256 numAssetAmounts = assetAmounts.length;

        for (uint256 i = 0; i < numAssetAmounts;) {
            // Effects: transfer registered assets to owner.
            // Excludes reserved fee tokens and native token (e.g., ETH).
            if (assetAmounts[i].value > 0) {
                assetAmounts[i].asset.safeTransfer(
                    msg.sender, assetAmounts[i].value
                );
            }
            unchecked {
                i++; // gas savings
            }
        }

        // Hooks: after finalizing.
        hooks.afterFinalize();

        // Log finalization.
        emit Finalized(msg.sender, assetAmounts);
    }

    /// @inheritdoc IVault
    function pause()
        external
        override
        nonReentrant
        onlyOwnerOrGuardian
        whenNotFinalized
        reserveFees
    {
        // Requirements and Effects: checks contract is unpaused and pauses it.
        _pause();
    }

    /// @inheritdoc IVault
    function resume()
        external
        override
        onlyOwner
        whenHooksSet
        whenNotFinalized
    {
        // Effects: start a new fee checkpoint.
        lastFeeCheckpoint = block.timestamp;

        // Requirements and Effects: checks contract is paused and unpauses it.
        _unpause();
    }

    /// @inheritdoc IVault
    function submit(Operation[] calldata operations)
        external
        override
        nonReentrant
        onlyGuardian
        whenHooksSet
        whenNotFinalized
        whenNotPaused
        reserveFees
        checkReservedFees
    {
        // Hooks: before executing operations.
        hooks.beforeSubmit(operations);

        uint256 numOperations = operations.length;

        Operation calldata operation;
        bytes4 selector;
        bool success;
        bytes memory result;
        address hooksAddress = address(hooks);

        for (uint256 i = 0; i < numOperations;) {
            operation = operations[i];
            selector = bytes4(operation.data[0:4]);

            // Requirements: validate that it doesn't transfer asset from owner.
            if (
                selector == IERC20.transferFrom.selector
                    && abi.decode(operation.data[4:], (address)) == owner()
            ) {
                revert Aera__SubmitTransfersAssetFromOwner();
            }

            // Requirements: check that operation is not trying to redeem ERC4626 shares from owner.
            // This could occur if the owner had a pre-existing allowance introduced during deposit.
            if (
                selector == IERC4626.withdraw.selector
                    || selector == IERC4626.redeem.selector
            ) {
                (,, address assetOwner) =
                    abi.decode(operation.data[4:], (uint256, address, address));

                if (assetOwner == owner()) {
                    revert Aera__SubmitRedeemERC4626AssetFromOwner();
                }
            }

            // Requirements: check that the target contract is not hooks.
            if (operation.target == hooksAddress) {
                revert Aera__SubmitTargetIsHooksAddress(i);
            }
            // Requirements: check that the target contract is not vault itself.
            if (operation.target == address(this)) {
                revert Aera__SubmitTargetIsVaultAddress();
            }

            // Interactions: execute operation.
            (success, result) =
                operation.target.call{value: operation.value}(operation.data);

            // Invariants: confirm that operation succeeded.
            if (!success) {
                revert Aera__SubmissionFailed(i, result);
            }
            unchecked {
                i++; // gas savings
            }
        }

        if (address(this).balance > 0) {
            wrappedNativeToken.call{value: address(this).balance}("");
        }

        // Hooks: after executing operations.
        hooks.afterSubmit(operations);

        // Log submission.
        emit Submitted(guardian, operations);
    }

    /// @inheritdoc IVault
    function claim() external override nonReentrant reserveFees {
        uint256 reservedFee = fees[msg.sender];

        // Requirements: check that there are fees to claim.
        if (reservedFee == 0) {
            revert Aera__NoClaimableFeesForCaller(msg.sender);
        }

        uint256 availableFee =
            Math.min(_feeToken.balanceOf(address(this)), reservedFee);

        // Requirements: check that fees are available to claim.
        if (availableFee == 0) {
            revert Aera__NoAvailableFeesForCaller(msg.sender);
        }

        // Effects: update fee total.
        feeTotal -= availableFee;
        reservedFee -= availableFee;

        // Effects: update leftover fee.
        fees[msg.sender] = reservedFee;

        // Interactions: transfer fee to caller.
        _feeToken.safeTransfer(msg.sender, availableFee);

        // Log the claim.
        emit Claimed(msg.sender, availableFee, reservedFee, feeTotal);
    }

    /// @inheritdoc IVault
    function holdings() external view override returns (AssetValue[] memory) {
        IAssetRegistry.AssetInformation[] memory assets =
            assetRegistry.assets();

        return _getHoldings(assets);
    }

    /// @inheritdoc IVault
    function value() external view override returns (uint256 vaultValue) {
        IAssetRegistry.AssetPriceReading[] memory erc20SpotPrices =
            assetRegistry.spotPrices();

        (vaultValue,) = _value(erc20SpotPrices);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return interfaceId == type(IVault).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc Ownable
    function renounceOwnership() public view override onlyOwner {
        revert Aera__CannotRenounceOwnership();
    }

    /// @inheritdoc Ownable2Step
    function transferOwnership(address newOwner) public override onlyOwner {
        // Requirements: check that new owner is disaffiliated from existing roles.
        if (newOwner == guardian) {
            revert Aera__GuardianIsOwner();
        }
        if (newOwner == feeRecipient) {
            revert Aera__FeeRecipientIsOwner();
        }

        // Effects: initiate ownership transfer.
        super.transferOwnership(newOwner);
    }

    /// @notice Only accept native token from the wrapped native token contract
    ///         when burning wrapped native tokens.
    receive() external payable {
        // Requirements: verify that the sender is wrapped native token.
        if (msg.sender != wrappedNativeToken) {
            revert Aera__NotWrappedNativeTokenContract();
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculate guardian fee index.
    /// @return feeIndex Guardian fee index.
    function _getFeeIndex() internal view returns (uint256 feeIndex) {
        if (block.timestamp > lastFeeCheckpoint) {
            unchecked {
                feeIndex = block.timestamp - lastFeeCheckpoint;
            }
        }

        return feeIndex;
    }

    /// @notice Calculate current guardian fees.
    function _reserveFees() internal {
        // Requirements: check if fees are being accrued.
        if (fee == 0 || paused() || finalized) {
            return;
        }

        uint256 feeIndex = _getFeeIndex();

        // Requirements: check if fees have been accruing.
        if (feeIndex == 0) {
            return;
        }

        // Calculate vault value using oracle or backup value if oracle is reverting.
        try assetRegistry.spotPrices() returns (
            IAssetRegistry.AssetPriceReading[] memory erc20SpotPrices
        ) {
            (lastValue, lastFeeTokenPrice) = _value(erc20SpotPrices);
        } catch (bytes memory reason) {
            // Check if there is a clear reason for the revert.
            if (reason.length == 0) {
                revert Aera__SpotPricesReverted();
            }
            emit SpotPricesReverted(reason);
        }

        // Requirements: check that fee token has a positive price.
        if (lastFeeTokenPrice == 0) {
            emit NoFeesReserved(lastFeeCheckpoint, lastValue, feeTotal);
            return;
        }

        // Calculate new fee for current fee recipient.
        // It calculates the fee in fee token decimals.
        uint256 newFee = lastValue * feeIndex * fee;

        if (_numeraireTokenDecimals < _feeTokenDecimals) {
            newFee =
                newFee * (10 ** (_feeTokenDecimals - _numeraireTokenDecimals));
        } else if (_numeraireTokenDecimals > _feeTokenDecimals) {
            newFee =
                newFee / (10 ** (_numeraireTokenDecimals - _feeTokenDecimals));
        }

        newFee /= lastFeeTokenPrice;

        if (newFee == 0) {
            return;
        }

        // Move fee checkpoint only if fee is nonzero
        lastFeeCheckpoint = block.timestamp;

        // Effects: accrue fee to fee recipient and remember new fee total.
        fees[feeRecipient] += newFee;
        feeTotal += newFee;

        // Log fee reservation.
        emit FeesReserved(
            feeRecipient,
            newFee,
            lastFeeCheckpoint,
            lastValue,
            lastFeeTokenPrice,
            feeTotal
        );
    }

    /// @notice Get current total value of assets in vault and price of fee token.
    /// @dev It calculates the value in Numeraire token decimals.
    /// @param erc20SpotPrices Spot prices of ERC20 assets.
    /// @return vaultValue Current total value.
    /// @return feeTokenPrice Fee token price.
    function _value(IAssetRegistry.AssetPriceReading[] memory erc20SpotPrices)
        internal
        view
        returns (uint256 vaultValue, uint256 feeTokenPrice)
    {
        IAssetRegistry.AssetInformation[] memory assets =
            assetRegistry.assets();
        AssetValue[] memory assetAmounts = _getHoldings(assets);

        (uint256[] memory spotPrices, uint256[] memory assetUnits) =
            _getSpotPricesAndUnits(assets, erc20SpotPrices);

        uint256 numAssets = assets.length;
        uint256 balance;

        for (uint256 i = 0; i < numAssets;) {
            if (assets[i].isERC4626) {
                balance = IERC4626(address(assets[i].asset)).convertToAssets(
                    assetAmounts[i].value
                );
            } else {
                balance = assetAmounts[i].value;
            }

            if (assets[i].asset == _feeToken) {
                feeTokenPrice = spotPrices[i];
            }

            vaultValue += (balance * spotPrices[i]) / assetUnits[i];
            unchecked {
                i++; // gas savings
            }
        }

        uint256 numeraireUnit = 10 ** _numeraireTokenDecimals;

        if (numeraireUnit != ONE) {
            vaultValue = vaultValue * numeraireUnit / ONE;
        }
    }

    /// @notice Check that assets in provided amounts are sorted and unique.
    /// @param amounts Struct details for assets and amounts to withdraw.
    function _checkAmountsSorted(AssetValue[] memory amounts) internal pure {
        uint256 numAssets = amounts.length;

        for (uint256 i = 1; i < numAssets;) {
            if (amounts[i - 1].asset >= amounts[i].asset) {
                revert Aera__AmountsOrderIsIncorrect(i);
            }
            unchecked {
                i++; // gas savings
            }
        }
    }

    /// @notice Check request to withdraw.
    /// @param assets Struct details for asset information from asset registry.
    /// @param amounts Struct details for assets and amounts to withdraw.
    function _checkWithdrawRequest(
        IAssetRegistry.AssetInformation[] memory assets,
        AssetValue[] memory amounts
    ) internal view {
        uint256 numAmounts = amounts.length;

        AssetValue[] memory assetAmounts = _getHoldings(assets);

        bool isRegistered;
        AssetValue memory assetValue;
        uint256 assetIndex;

        for (uint256 i = 0; i < numAmounts;) {
            assetValue = amounts[i];
            (isRegistered, assetIndex) =
                _isAssetRegistered(assetValue.asset, assets);

            if (!isRegistered) {
                revert Aera__AssetIsNotRegistered(assetValue.asset);
            }

            if (assetAmounts[assetIndex].value < assetValue.value) {
                revert Aera__AmountExceedsAvailable(
                    assetValue.asset,
                    assetValue.value,
                    assetAmounts[assetIndex].value
                );
            }
            unchecked {
                i++; // gas savings
            }
        }
    }

    /// @notice Get spot prices and units of requested assets.
    /// @dev Spot prices are scaled to 18 decimals.
    /// @param assets Registered assets in asset registry and their information.
    /// @param erc20SpotPrices Struct details for spot prices of ERC20 assets.
    /// @return spotPrices Spot prices of assets.
    /// @return assetUnits Units of assets.
    function _getSpotPricesAndUnits(
        IAssetRegistry.AssetInformation[] memory assets,
        IAssetRegistry.AssetPriceReading[] memory erc20SpotPrices
    )
        internal
        view
        returns (uint256[] memory spotPrices, uint256[] memory assetUnits)
    {
        uint256 numAssets = assets.length;
        uint256 numERC20SpotPrices = erc20SpotPrices.length;

        spotPrices = new uint256[](numAssets);
        assetUnits = new uint256[](numAssets);

        IAssetRegistry.AssetInformation memory asset;

        for (uint256 i = 0; i < numAssets;) {
            asset = assets[i];

            IERC20 assetToFind = (
                asset.isERC4626
                    ? IERC20(IERC4626(address(asset.asset)).asset())
                    : asset.asset
            );
            uint256 j = 0;
            for (; j < numERC20SpotPrices;) {
                if (assetToFind == erc20SpotPrices[j].asset) {
                    break;
                }
                unchecked {
                    j++; // gas savings
                }
            }
            spotPrices[i] = erc20SpotPrices[j].spotPrice;
            assetUnits[i] =
                10 ** IERC20Metadata(address(assetToFind)).decimals();

            unchecked {
                i++; // gas savings
            }
        }
    }

    /// @notice Get total amount of assets in vault.
    /// @param assets Struct details for registered assets in asset registry.
    /// @return assetAmounts Amount of assets.
    function _getHoldings(IAssetRegistry.AssetInformation[] memory assets)
        internal
        view
        returns (AssetValue[] memory assetAmounts)
    {
        uint256 numAssets = assets.length;

        assetAmounts = new AssetValue[](numAssets);
        IAssetRegistry.AssetInformation memory assetInfo;

        for (uint256 i = 0; i < numAssets;) {
            assetInfo = assets[i];
            assetAmounts[i] = AssetValue({
                asset: assetInfo.asset,
                value: assetInfo.asset.balanceOf(address(this))
            });

            if (assetInfo.asset == _feeToken) {
                assetAmounts[i].value -=
                    Math.min(feeTotal, assetAmounts[i].value);
            }

            unchecked {
                i++; //gas savings
            }
        }
    }

    /// @notice Check if balance of fee becomes insolvent or becomes more insolvent.
    /// @param prevFeeTokenBalance Balance of fee token before action.
    function _checkReservedFees(uint256 prevFeeTokenBalance) internal view {
        uint256 feeTokenBalance = IERC20(_feeToken).balanceOf(address(this));

        if (
            feeTokenBalance < feeTotal && feeTokenBalance < prevFeeTokenBalance
        ) {
            revert Aera__CannotUseReservedFees();
        }
    }

    /// @notice Check if the address can be a guardian.
    /// @param newGuardian Address to check.
    /// @param owner_ Owner address.
    function _checkGuardianAddress(
        address newGuardian,
        address owner_
    ) internal pure {
        if (newGuardian == address(0)) {
            revert Aera__GuardianIsZeroAddress();
        }
        if (newGuardian == owner_) {
            revert Aera__GuardianIsOwner();
        }
    }

    /// @notice Check if the address can be a fee recipient.
    /// @param newFeeRecipient Address to check.
    /// @param owner_ Owner address.
    function _checkFeeRecipientAddress(
        address newFeeRecipient,
        address owner_
    ) internal pure {
        if (newFeeRecipient == address(0)) {
            revert Aera__FeeRecipientIsZeroAddress();
        }
        if (newFeeRecipient == owner_) {
            revert Aera__FeeRecipientIsOwner();
        }
    }

    /// @notice Check if the address can be an asset registry.
    /// @param newAssetRegistry Address to check.
    function _checkAssetRegistryAddress(address newAssetRegistry)
        internal
        view
    {
        if (newAssetRegistry == address(0)) {
            revert Aera__AssetRegistryIsZeroAddress();
        }
        if (
            !ERC165Checker.supportsInterface(
                newAssetRegistry, type(IAssetRegistry).interfaceId
            )
        ) {
            revert Aera__AssetRegistryIsNotValid(newAssetRegistry);
        }
        if (IAssetRegistry(newAssetRegistry).vault() != address(this)) {
            revert Aera__AssetRegistryHasInvalidVault();
        }
    }

    /// @notice Check if the address can be a hooks contract.
    /// @param newHooks Address to check.
    function _checkHooksAddress(address newHooks) internal view {
        if (newHooks == address(0)) {
            revert Aera__HooksIsZeroAddress();
        }
        if (
            !ERC165Checker.supportsInterface(newHooks, type(IHooks).interfaceId)
        ) {
            revert Aera__HooksIsNotValid(newHooks);
        }
        if (IHooks(newHooks).vault() != address(this)) {
            revert Aera__HooksHasInvalidVault();
        }
    }

    /// @notice Check whether asset is registered to asset registry or not.
    /// @param asset Asset to check.
    /// @param registeredAssets Array of registered assets.
    /// @return isRegistered True if asset is registered.
    /// @return index Index of asset in asset registry.
    function _isAssetRegistered(
        IERC20 asset,
        IAssetRegistry.AssetInformation[] memory registeredAssets
    ) internal pure returns (bool isRegistered, uint256 index) {
        uint256 numAssets = registeredAssets.length;

        for (uint256 i = 0; i < numAssets;) {
            if (registeredAssets[i].asset < asset) {
                unchecked {
                    i++; // gas savings
                }

                continue;
            }

            if (registeredAssets[i].asset == asset) {
                return (true, i);
            }

            break;
        }
    }
}
