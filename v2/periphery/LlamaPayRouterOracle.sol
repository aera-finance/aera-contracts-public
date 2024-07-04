// SPDX-License-Identifier: BUSL-1.1
// slither-disable-start similar-names
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/IERC20.sol";
import {Ownable} from "@openzeppelin/Ownable.sol";
import {SafeERC20} from "@openzeppelin/SafeERC20.sol";
import {AggregatorV2V3Interface} from
    "@chainlink/interfaces/AggregatorV2V3Interface.sol";
import {Operation} from "src/v2/Types.sol";
import {ILlamaPay} from "./dependencies/llamapay/ILlamaPay.sol";
import {ILlamaPayRouterOracle} from "./interfaces/ILlamaPayRouterOracle.sol";
import {Executor} from "./Executor.sol";
import {AbstractAssetOracle} from "./AbstractAssetOracle.sol";

/// @title LlamaPayRouterOracle.
/// @notice An router/oracle that calculates the value of LlamaPay streams.
///         The router/oracle can create, cancel, pause, modify, deposit and withdraw LlamaPay streams.
/// @notice Note 1: The contract does not check for LlamaPay contract duplicates in constructor.
/// @notice Note 2: All "amountPerSec" arguments should use 20 decimals.
/// @notice Note 3: In the withdrawPayer() function, "amount" argument should use 20 decimals.
/// @notice ### Audit Note: L-01 Vault Value Can Go Below Daily Lower Bound
/// @notice Since a withdrawal action by the beneficiary of a LlamaPay instance does not affect the daily
///         multiplier of a vault, the value locked within a vault over any 24-hour period can reach a lower
///         value than would be expected, given the `minDailyValue`.
///         Assume the following scenario:
///         * The vault holds `X` amount of value and has a `minDailyValue` multiplier of `0.9`.
///         * There is `Y = 0.03 * X` amount of value sitting in a LlamaPay contract managed by
///         the `LlamaPayRouterOracle` contract.
///         * The beneficiary of the LlamaPay stream withdraws `Y` value. Now there is `X - Y =
///         0.97 * X` value in the vault, but the `cumulativeDailyMultiplier` stays at `1`.
///         * The guardian submits a batch of actions which reduces the amount of value in the vault
///         by `0.09 * X`. This would put the vault at `0.88 * X` value which is below the
///         threshold of `0.9 * X`. Since the `cumulativeDailyMultiplier` did not account for
///         the withdrawal of funds from the LlamaPay stream, the calculation of the
///         `newMultiplier` in the `afterSubmit` hook results in a value greater than `0.9` and
///         therefore allows it. The exact calculation of `newMultiplier`
///         in this case is the following: `(1 * (0.88 * X)) / (0.97 * X)`,
///         which results in `~0.907 > 0.9`. Therefore, the daily multiplier check passes.
contract LlamaPayRouterOracle is
    ILlamaPayRouterOracle,
    AbstractAssetOracle,
    Executor
{
    using SafeERC20 for IERC20;

    /// CONSTANTS ///

    /// @notice The maximum number of LlamaPay contracts.
    uint256 private constant _MAX_LLAMAPAY_COUNT = 10;
    /// @notice Downscale factor from LlamaPay balance to 18 decimals.
    uint256 private constant _LLAMAPAY_DOWNSCALE_FACTOR = 1e2;
    /// @notice The number of decimals of the LlamaPay payer balance.
    uint256 private constant _LLAMAPAY_DECIMALS = 20;
    /// @notice The name of the token.
    string private constant _NAME = "LlamaPayRouterOracle";
    /// @notice The symbol of the token.
    string private constant _SYMBOL = "LPRO";

    /// IMMUTABLES ///

    /// @notice Number of LlamaPay contracts.
    uint256 public immutable llamaPayCount;

    /// @notice Decomposed list of LlamaPay contracts (one for each token).
    ILlamaPay private immutable _llamaPay0;
    ILlamaPay private immutable _llamaPay1;
    ILlamaPay private immutable _llamaPay2;
    ILlamaPay private immutable _llamaPay3;
    ILlamaPay private immutable _llamaPay4;
    ILlamaPay private immutable _llamaPay5;
    ILlamaPay private immutable _llamaPay6;
    ILlamaPay private immutable _llamaPay7;
    ILlamaPay private immutable _llamaPay8;
    ILlamaPay private immutable _llamaPay9;

    /// @notice Decomposed decimals divisor list.
    uint256 private immutable _decimalsDivisor0;
    uint256 private immutable _decimalsDivisor1;
    uint256 private immutable _decimalsDivisor2;
    uint256 private immutable _decimalsDivisor3;
    uint256 private immutable _decimalsDivisor4;
    uint256 private immutable _decimalsDivisor5;
    uint256 private immutable _decimalsDivisor6;
    uint256 private immutable _decimalsDivisor7;
    uint256 private immutable _decimalsDivisor8;
    uint256 private immutable _decimalsDivisor9;

    /// @notice Decomposed price feed list.
    address private immutable _priceFeed0;
    address private immutable _priceFeed1;
    address private immutable _priceFeed2;
    address private immutable _priceFeed3;
    address private immutable _priceFeed4;
    address private immutable _priceFeed5;
    address private immutable _priceFeed6;
    address private immutable _priceFeed7;
    address private immutable _priceFeed8;
    address private immutable _priceFeed9;

    /// @notice Decomposed LlamaPay token list.
    IERC20 private immutable _token0;
    IERC20 private immutable _token1;
    IERC20 private immutable _token2;
    IERC20 private immutable _token3;
    IERC20 private immutable _token4;
    IERC20 private immutable _token5;
    IERC20 private immutable _token6;
    IERC20 private immutable _token7;
    IERC20 private immutable _token8;
    IERC20 private immutable _token9;

    /// @notice Decomposed rescale factor list.
    uint256 private immutable _rescaleFactor0;
    uint256 private immutable _rescaleFactor1;
    uint256 private immutable _rescaleFactor2;
    uint256 private immutable _rescaleFactor3;
    uint256 private immutable _rescaleFactor4;
    uint256 private immutable _rescaleFactor5;
    uint256 private immutable _rescaleFactor6;
    uint256 private immutable _rescaleFactor7;
    uint256 private immutable _rescaleFactor8;
    uint256 private immutable _rescaleFactor9;

    /// @notice Decomposed inverted price numerator list.
    uint256 private immutable _invertedPriceNumerator0;
    uint256 private immutable _invertedPriceNumerator1;
    uint256 private immutable _invertedPriceNumerator2;
    uint256 private immutable _invertedPriceNumerator3;
    uint256 private immutable _invertedPriceNumerator4;
    uint256 private immutable _invertedPriceNumerator5;
    uint256 private immutable _invertedPriceNumerator6;
    uint256 private immutable _invertedPriceNumerator7;
    uint256 private immutable _invertedPriceNumerator8;
    uint256 private immutable _invertedPriceNumerator9;

    /// MODIFIERS ///

    /// @notice Check that the caller is the Vault owner.
    modifier onlyVaultOwner() {
        // Requirements: check that the caller is the Vault owner.
        if (msg.sender != Ownable(_vault).owner()) {
            revert AeraPeriphery__CallerIsNotVaultOwner(msg.sender);
        }
        _;
    }

    /// @notice Check that the caller is the Vault.
    modifier onlyVault() {
        // Requirements: check that the caller is the Vault.
        if (msg.sender != _vault) {
            revert AeraPeriphery__CallerIsNotVault(msg.sender);
        }
        _;
    }

    /// STORAGE ///

    /// @notice Mapping of stream end dates.
    mapping(bytes32 streamId => uint256 endDate) internal _streamEndDate;

    /// FUNCTIONS ///

    /// @notice The constructor for the LlamaPayRouterOracle. The contract does not check for LlamaPay contract duplicates.
    /// @notice It is deployer responsibility to ensure that there are no LlamaPay contract duplicates in provided llamaPayInfoList.
    constructor(
        address vault_,
        LlamaPayInfo[] memory llamaPayInfoList_
    ) AbstractAssetOracle(vault_) {
        // Effects: set llamaPay count.
        llamaPayCount = llamaPayInfoList_.length;

        // Requirements: check that the llamaPay count is not zero.
        if (llamaPayCount == 0) {
            revert AeraPeriphery__LlamaPayInfoCountIsZero();
        }

        // Requirements: check that the llamaPay count does not exceed the maximum.
        if (llamaPayCount > _MAX_LLAMAPAY_COUNT) {
            revert AeraPeriphery__LlamaPayInfoCountExceedsMax(
                _MAX_LLAMAPAY_COUNT
            );
        }

        // Effects: initialize immutable variables
        (
            _llamaPay0,
            _token0,
            _priceFeed0,
            _decimalsDivisor0,
            _invertedPriceNumerator0,
            _rescaleFactor0
        ) = _getLlamaPayInfo(llamaPayInfoList_[0]);
        if (llamaPayCount == 1) return;

        (
            _llamaPay1,
            _token1,
            _priceFeed1,
            _decimalsDivisor1,
            _invertedPriceNumerator1,
            _rescaleFactor1
        ) = _getLlamaPayInfo(llamaPayInfoList_[1]);
        if (llamaPayCount == 2) return;

        (
            _llamaPay2,
            _token2,
            _priceFeed2,
            _decimalsDivisor2,
            _invertedPriceNumerator2,
            _rescaleFactor2
        ) = _getLlamaPayInfo(llamaPayInfoList_[2]);
        if (llamaPayCount == 3) return;

        (
            _llamaPay3,
            _token3,
            _priceFeed3,
            _decimalsDivisor3,
            _invertedPriceNumerator3,
            _rescaleFactor3
        ) = _getLlamaPayInfo(llamaPayInfoList_[3]);
        if (llamaPayCount == 4) return;

        (
            _llamaPay4,
            _token4,
            _priceFeed4,
            _decimalsDivisor4,
            _invertedPriceNumerator4,
            _rescaleFactor4
        ) = _getLlamaPayInfo(llamaPayInfoList_[4]);
        if (llamaPayCount == 5) return;

        (
            _llamaPay5,
            _token5,
            _priceFeed5,
            _decimalsDivisor5,
            _invertedPriceNumerator5,
            _rescaleFactor5
        ) = _getLlamaPayInfo(llamaPayInfoList_[5]);
        if (llamaPayCount == 6) return;

        (
            _llamaPay6,
            _token6,
            _priceFeed6,
            _decimalsDivisor6,
            _invertedPriceNumerator6,
            _rescaleFactor6
        ) = _getLlamaPayInfo(llamaPayInfoList_[6]);
        if (llamaPayCount == 7) return;

        (
            _llamaPay7,
            _token7,
            _priceFeed7,
            _decimalsDivisor7,
            _invertedPriceNumerator7,
            _rescaleFactor7
        ) = _getLlamaPayInfo(llamaPayInfoList_[7]);
        if (llamaPayCount == 8) return;

        (
            _llamaPay8,
            _token8,
            _priceFeed8,
            _decimalsDivisor8,
            _invertedPriceNumerator8,
            _rescaleFactor8
        ) = _getLlamaPayInfo(llamaPayInfoList_[8]);
        if (llamaPayCount == 9) return;

        (
            _llamaPay9,
            _token9,
            _priceFeed9,
            _decimalsDivisor9,
            _invertedPriceNumerator9,
            _rescaleFactor9
        ) = _getLlamaPayInfo(llamaPayInfoList_[9]);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function createStream(
        IERC20 token,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external onlyVault {
        // Requirements: check that the duration is not zero.
        if (duration == 0) {
            revert AeraPeriphery__DurationIsZero();
        }

        // Effects: remember the end date.
        _streamEndDate[_streamId(token, to, amountPerSec)] =
            block.timestamp + duration;

        // Log that a new expiring stream was created.
        // Note: event is emitted before the interaction with LlamaPay contract to avoid reentrancy issues
        // and make slither happy.
        // https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3
        emit ExpiringStreamCreated(token, to, amountPerSec, duration);

        // Interactions: create stream on LlamaPay contract.
        _getLlamaPay(token).createStream(to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function cancelStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external onlyVault {
        ILlamaPay llamaPay = _getLlamaPay(token);

        bytes32 streamId = _streamId(token, to, amountPerSec);

        // Requirements: check that the stream exists.
        if (_streamEndDate[streamId] == 0) {
            revert AeraPeriphery__StreamDoesNotExist(token, to, amountPerSec);
        }

        // Effects & Interactions: delete endDate and cancel stream on LlamaPay contract.
        _cancelStream(llamaPay, streamId, to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function pauseStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external onlyVault {
        ILlamaPay llamaPay = _getLlamaPay(token);
        bytes32 streamId = _streamId(token, to, amountPerSec);

        // Requirements: check that the stream exists.
        if (_streamEndDate[streamId] == 0) {
            revert AeraPeriphery__StreamDoesNotExist(token, to, amountPerSec);
        }

        // Interactions: pause stream on LlamaPay contract.
        llamaPay.pauseStream(to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function cancelExpiredStream(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external {
        ILlamaPay llamaPay = _getLlamaPay(token);
        bytes32 streamId = _streamId(token, to, amountPerSec);
        // Cache the end date to avoid SLOAD.
        uint256 streamEndDate = _streamEndDate[streamId];

        // Requirements: check that the stream exists.
        if (streamEndDate == 0) {
            revert AeraPeriphery__StreamDoesNotExist(token, to, amountPerSec);
        }

        // Requirements: check that the stream is expired.
        if (streamEndDate > block.timestamp) {
            revert AeraPeriphery__StreamNotExpired(streamEndDate);
        }

        // Effects & Interactions: delete endDate and cancel stream on LlamaPay contract.
        _cancelStream(llamaPay, streamId, to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function modifyStream(
        IERC20 token,
        address oldTo,
        uint216 oldAmountPerSec,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external onlyVault {
        ILlamaPay llamaPay = _getLlamaPay(token);

        // Requirements: check that the endDate is not in the past.
        if (duration == 0) {
            revert AeraPeriphery__DurationIsZero();
        }
        bytes32 oldStreamId = _streamId(token, oldTo, oldAmountPerSec);

        // Requirements: check that the old stream exists.
        if (_streamEndDate[oldStreamId] == 0) {
            revert AeraPeriphery__StreamDoesNotExist(
                token, oldTo, oldAmountPerSec
            );
        }

        // Effects: delete old end date.
        delete _streamEndDate[oldStreamId];

        // Effects: remember the end date.
        _streamEndDate[_streamId(token, to, amountPerSec)] =
            block.timestamp + duration;

        // Log that a new expiring stream was created.
        // Note: event is emitted before the interaction with LlamaPay contract to avoid reentrancy issues
        // and make slither happy.
        // https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3
        emit ExpiringStreamCreated(token, to, amountPerSec, duration);

        // Interactions: modify the stream on LlamaPay contract.
        llamaPay.modifyStream(oldTo, oldAmountPerSec, to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function deposit(
        IERC20 token,
        uint256 amount
    ) external onlyVault nonReentrant {
        ILlamaPay llamaPay = _getLlamaPay(token);

        // Interactions: transfer the tokens from the Vault to this contract.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(_vault, address(this), amount);

        // Interactions: increase the allowance of the LlamaPay contract.
        token.safeIncreaseAllowance(address(llamaPay), amount);

        // Interactions: deposit the tokens to the LlamaPay contract.
        llamaPay.deposit(amount);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function depositAndCreate(
        IERC20 token,
        uint256 amountToDeposit,
        address to,
        uint216 amountPerSec,
        uint256 duration
    ) external onlyVault nonReentrant {
        ILlamaPay llamaPay = _getLlamaPay(token);

        // Requirements: check that the duration is not zero.
        if (duration == 0) {
            revert AeraPeriphery__DurationIsZero();
        }

        // Effects: remember the end date.
        _streamEndDate[_streamId(token, to, amountPerSec)] =
            block.timestamp + duration;

        // Interactions: transfer the tokens from the Vault to this contract.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(_vault, address(this), amountToDeposit);

        // Interactions: increase the allowance of the LlamaPay contract.
        token.safeIncreaseAllowance(address(llamaPay), amountToDeposit);

        // Log that a new expiring stream was created.
        // Note: event is emitted before the interaction with LlamaPay to be consistent with the
        // createStream and modifyStream functions.
        emit ExpiringStreamCreated(token, to, amountPerSec, duration);

        // Interactions: deposit the tokens to the LlamaPay contract and create a stream.
        llamaPay.depositAndCreate(amountToDeposit, to, amountPerSec);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function withdrawPayer(IERC20 token, uint256 amount) external onlyVault {
        // Interactions: withdraw tokens from the LlamaPay contract.
        _getLlamaPay(token).withdrawPayer(amount);

        uint256 decimalsDivisor = _getDecimalsDivisor(token);

        // Interactions: transfer the tokens from this contract to the Vault.
        token.safeTransfer(_vault, amount / decimalsDivisor);
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function withdrawPayerAll(IERC20 token) external onlyVault {
        // Interactions: withdraw all tokens from the LlamaPay contract.
        _getLlamaPay(token).withdrawPayerAll();

        // Interactions: transfer the tokens from this contract to the Vault.
        token.safeTransfer(_vault, token.balanceOf(address(this)));
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function endDate(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) external view returns (uint256) {
        return _streamEndDate[_streamId(token, to, amountPerSec)];
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function llamaPayInfoList()
        external
        view
        returns (LlamaPayInfo[] memory)
    {
        // Create a new array with the LlamaPayInfo.
        LlamaPayInfo[] memory result = new LlamaPayInfo[](llamaPayCount);
        // Fill the array with the LlamaPayInfo.
        result[0] = LlamaPayInfo({
            llamaPay: _llamaPay0,
            priceFeed: _priceFeed0,
            invertPrice: _invertedPriceNumerator0 > 0
        });
        if (llamaPayCount == 1) return result;

        result[1] = LlamaPayInfo({
            llamaPay: _llamaPay1,
            priceFeed: _priceFeed1,
            invertPrice: _invertedPriceNumerator1 > 0
        });
        if (llamaPayCount == 2) return result;

        result[2] = LlamaPayInfo({
            llamaPay: _llamaPay2,
            priceFeed: _priceFeed2,
            invertPrice: _invertedPriceNumerator2 > 0
        });
        if (llamaPayCount == 3) return result;

        result[3] = LlamaPayInfo({
            llamaPay: _llamaPay3,
            priceFeed: _priceFeed3,
            invertPrice: _invertedPriceNumerator3 > 0
        });
        if (llamaPayCount == 4) return result;

        result[4] = LlamaPayInfo({
            llamaPay: _llamaPay4,
            priceFeed: _priceFeed4,
            invertPrice: _invertedPriceNumerator4 > 0
        });
        if (llamaPayCount == 5) return result;

        result[5] = LlamaPayInfo({
            llamaPay: _llamaPay5,
            priceFeed: _priceFeed5,
            invertPrice: _invertedPriceNumerator5 > 0
        });
        if (llamaPayCount == 6) return result;

        result[6] = LlamaPayInfo({
            llamaPay: _llamaPay6,
            priceFeed: _priceFeed6,
            invertPrice: _invertedPriceNumerator6 > 0
        });
        if (llamaPayCount == 7) return result;

        result[7] = LlamaPayInfo({
            llamaPay: _llamaPay7,
            priceFeed: _priceFeed7,
            invertPrice: _invertedPriceNumerator7 > 0
        });
        if (llamaPayCount == 8) return result;

        result[8] = LlamaPayInfo({
            llamaPay: _llamaPay8,
            priceFeed: _priceFeed8,
            invertPrice: _invertedPriceNumerator8 > 0
        });
        if (llamaPayCount == 9) return result;

        result[9] = LlamaPayInfo({
            llamaPay: _llamaPay9,
            priceFeed: _priceFeed9,
            invertPrice: _invertedPriceNumerator9 > 0
        });
        return result;
    }

    /// @inheritdoc ILlamaPayRouterOracle
    function vault()
        external
        view
        override(ILlamaPayRouterOracle, AbstractAssetOracle)
        returns (address)
    {
        return _vault;
    }

    /// @inheritdoc AbstractAssetOracle
    function name() external pure override returns (string memory) {
        return _NAME;
    }

    /// @inheritdoc AbstractAssetOracle
    function symbol() external pure override returns (string memory) {
        return _SYMBOL;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Delete stream end date and cancel the stream.
    function _cancelStream(
        ILlamaPay llamaPay,
        bytes32 streamId,
        address to,
        uint216 amountPerSec
    ) internal {
        // Effects: delete the end date.
        delete _streamEndDate[streamId];

        // Interactions: cancel the stream on LlamaPay contract.
        llamaPay.cancelStream(to, amountPerSec);
    }

    /// @inheritdoc AbstractAssetOracle
    function _getValue() internal view override returns (uint256 balance) {
        balance = _llamaPayBalance(
            _llamaPay0, _priceFeed0, _rescaleFactor0, _invertedPriceNumerator0
        );
        if (llamaPayCount == 1) return balance;

        balance += _llamaPayBalance(
            _llamaPay1, _priceFeed1, _rescaleFactor1, _invertedPriceNumerator1
        );
        if (llamaPayCount == 2) return balance;

        balance += _llamaPayBalance(
            _llamaPay2, _priceFeed2, _rescaleFactor2, _invertedPriceNumerator2
        );
        if (llamaPayCount == 3) return balance;

        balance += _llamaPayBalance(
            _llamaPay3, _priceFeed3, _rescaleFactor3, _invertedPriceNumerator3
        );
        if (llamaPayCount == 4) return balance;

        balance += _llamaPayBalance(
            _llamaPay4, _priceFeed4, _rescaleFactor4, _invertedPriceNumerator4
        );
        if (llamaPayCount == 5) return balance;

        balance += _llamaPayBalance(
            _llamaPay5, _priceFeed5, _rescaleFactor5, _invertedPriceNumerator5
        );
        if (llamaPayCount == 6) return balance;

        balance += _llamaPayBalance(
            _llamaPay6, _priceFeed6, _rescaleFactor6, _invertedPriceNumerator6
        );
        if (llamaPayCount == 7) return balance;

        balance += _llamaPayBalance(
            _llamaPay7, _priceFeed7, _rescaleFactor7, _invertedPriceNumerator7
        );
        if (llamaPayCount == 8) return balance;

        balance += _llamaPayBalance(
            _llamaPay8, _priceFeed8, _rescaleFactor8, _invertedPriceNumerator8
        );
        if (llamaPayCount == 9) return balance;

        balance += _llamaPayBalance(
            _llamaPay9, _priceFeed9, _rescaleFactor9, _invertedPriceNumerator9
        );
    }

    /// @notice Get the LlamaPay balance in numerator terms scaled to 18 decimals.
    function _llamaPayBalance(
        ILlamaPay llamaPay,
        address priceFeed,
        uint256 rescaleFactor,
        uint256 invertedPriceNumerator
    ) internal view returns (uint256) {
        // Get the balance of this contract from LlamaPay contract.
        // Note: balance is always 20 decimals.
        uint256 balance = llamaPay.balances(address(this));
        // If the balance is zero, return zero.
        if (balance == 0) return 0;
        // If the price feed is absent, return balance downscaled to 18 decimals.
        if (priceFeed == address(0)) {
            return balance / _LLAMAPAY_DOWNSCALE_FACTOR;
        }

        uint256 price = _getPrice(priceFeed);
        // Invert the price if necessary.
        if (invertedPriceNumerator > 0) {
            price = invertedPriceNumerator / price;
        }

        // Multiply balance by the price and rescale to 18 decimals.
        return _mulDiv(balance, price, rescaleFactor);
    }

    /// @notice Return decomposed LlamaPayInfo, rescale factor, invertedPriceNumerator, token and decimalsDivisor.
    /// @return llamaPay The LlamaPay contract.
    /// @return token LlamaPay stream token.
    /// @return priceFeed The price feed address.
    /// @return decimalsDivisor The decimals divisor. DECIMALS_DIVISOR from LlamaPay contract. Signifies the scale to scale the balance to 20 decimals.
    /// @return invertedPriceNumerator The invert price numerator.
    /// @return rescaleFactor The rescale factor.
    function _getLlamaPayInfo(LlamaPayInfo memory llamaPayInfo)
        internal
        view
        returns (
            ILlamaPay llamaPay,
            IERC20 token,
            address priceFeed,
            uint256 decimalsDivisor,
            uint256 invertedPriceNumerator,
            uint256 rescaleFactor
        )
    {
        llamaPay = llamaPayInfo.llamaPay;
        decimalsDivisor = ILlamaPay(llamaPay).DECIMALS_DIVISOR();
        priceFeed = llamaPayInfo.priceFeed;
        token = llamaPay.token();

        // Get price feed decimals
        uint8 priceFeedDecimals = (
            priceFeed == address(0)
                ? 0
                : AggregatorV2V3Interface(priceFeed).decimals()
        );

        uint256 totalDecimals = _LLAMAPAY_DECIMALS + priceFeedDecimals;
        // Since this oracle is designed to work with 18 decimals, we need to rescale the value.
        // _LLAMAPAY_DECIMALS is 20, totalDecimals will always be >= 20.
        rescaleFactor = 10 ** (totalDecimals - 18);

        // Inverted price numerator to be used in value calculation.
        invertedPriceNumerator = (
            priceFeed != address(0) && llamaPayInfo.invertPrice
                ? 100 ** priceFeedDecimals // 10 ** (priceFeedDecimals * 2)
                : 0
        );
    }

    /// @notice Returns the LlamaPay contract for a given token.
    function _getLlamaPay(IERC20 token) internal view returns (ILlamaPay) {
        if (address(token) == address(0)) {
            revert AeraPeriphery__InvalidToken(token);
        }

        // Generally we would use a mapping here, but SHA3 operation costs 30+ units of gas and
        // EQ operation costs 3 units of gas. Roughly, one SHA3 = 10 comparisons.
        // We have maximum 10 tokens, so it's cheaper (or the same in worst case) to compare them manually.
        if (token == _token0) return _llamaPay0;
        if (token == _token1) return _llamaPay1;
        if (token == _token2) return _llamaPay2;
        if (token == _token3) return _llamaPay3;
        if (token == _token4) return _llamaPay4;
        if (token == _token5) return _llamaPay5;
        if (token == _token6) return _llamaPay6;
        if (token == _token7) return _llamaPay7;
        if (token == _token8) return _llamaPay8;
        if (token == _token9) return _llamaPay9;

        revert AeraPeriphery__InvalidToken(token);
    }

    /// @notice Returns cached decimals divisor for a given token.
    function _getDecimalsDivisor(IERC20 token)
        internal
        view
        returns (uint256)
    {
        if (address(token) == address(0)) {
            revert AeraPeriphery__InvalidToken(token);
        }
        // Note: see _getLlamaPay() for explanation.
        if (token == _token0) return _decimalsDivisor0;
        if (token == _token1) return _decimalsDivisor1;
        if (token == _token2) return _decimalsDivisor2;
        if (token == _token3) return _decimalsDivisor3;
        if (token == _token4) return _decimalsDivisor4;
        if (token == _token5) return _decimalsDivisor5;
        if (token == _token6) return _decimalsDivisor6;
        if (token == _token7) return _decimalsDivisor7;
        if (token == _token8) return _decimalsDivisor8;
        if (token == _token9) return _decimalsDivisor9;

        revert AeraPeriphery__InvalidToken(token);
    }

    /// @inheritdoc Executor
    function _checkOperations(Operation[] calldata operations)
        internal
        view
        override
        onlyVaultOwner
    {}

    /// @inheritdoc Executor
    function _checkOperation(Operation calldata operation)
        internal
        view
        override
    {}

    /// @notice Returns the stream ID.
    function _streamId(
        IERC20 token,
        address to,
        uint216 amountPerSec
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, to, amountPerSec));
    }
}
// slither-disable-end similar-names