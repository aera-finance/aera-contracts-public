// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "@openzeppelin/ERC165.sol";
import "@openzeppelin/IERC4626.sol";
import "./Sweepable.sol";
import "./interfaces/IAssetRegistry.sol";
import "./interfaces/IVault.sol";
import {ONE} from "./Constants.sol";

/// @title AeraVaultAssetRegistry
/// @notice Maintains a list of registered assets and their oracles (when applicable).
contract AeraVaultAssetRegistry is IAssetRegistry, Sweepable, ERC165 {
    /// @notice Maximum number of assets.
    uint256 public constant MAX_ASSETS = 50;

    /// @notice Time to pass before accepting answers when sequencer comes back up.
    uint256 public constant GRACE_PERIOD_TIME = 3600;

    /// @notice Vault address.
    address public immutable vault;

    /// @notice Numeraire token.
    IERC20 public immutable numeraireToken;

    /// @notice Fee token.
    IERC20 public immutable feeToken;

    /// @notice Wrapped native token.
    IERC20 public immutable wrappedNativeToken;

    /// @notice Sequencer Uptime Feed address for L2.
    AggregatorV2V3Interface public immutable sequencer;

    /// STORAGE ///

    /// @notice List of currently registered assets.
    AssetInformation[] internal _assets;

    /// @notice Number of ERC4626 assets. Maintained for more efficient calculation of spotPrices.
    uint256 public numYieldAssets;

    /// EVENTS ///

    /// @notice Emitted when a new asset is added.
    /// @param asset New asset details.
    event AssetAdded(address indexed asset, AssetInformation assetInfo);

    /// @notice Emitted when an asset is removed.
    /// @param asset Address of removed asset.
    event AssetRemoved(address indexed asset);

    /// @notice Emitted in constructor.
    /// @param owner Owner address.
    /// @param vault Vault address.
    /// @param assets Initial list of registered assets.
    /// @param numeraireToken Numeraire token address.
    /// @param feeToken Fee token address.
    /// @param wrappedNativeToken Wrapped native token.
    /// @param sequencer Sequencer Uptime Feed address for L2.
    event Created(
        address indexed owner,
        address indexed vault,
        AssetInformation[] assets,
        address indexed numeraireToken,
        address feeToken,
        address wrappedNativeToken,
        address sequencer
    );

    /// ERRORS ///

    error Aera__NumberOfAssetsExceedsMaximum(uint256 max);
    error Aera__NumeraireTokenIsNotRegistered(address numeraireToken);
    error Aera__NumeraireTokenIsERC4626();
    error Aera__NumeraireOracleIsNotZeroAddress();
    error Aera__FeeTokenIsNotRegistered(address feeToken);
    error Aera__FeeTokenIsERC4626(address feeToken);
    error Aera__WrappedNativeTokenIsNotRegistered(address wrappedNativeToken);
    error Aera__WrappedNativeTokenIsERC4626(address wrappedNativeToken);
    error Aera__AssetOrderIsIncorrect(uint256 index);
    error Aera__AssetRegistryInitialOwnerIsZeroAddress();
    error Aera__AssetRegistryOwnerIsGuardian();
    error Aera__AssetRegistryOwnerIsVault();
    error Aera__ERC20OracleIsZeroAddress(address asset);
    error Aera__ERC4626OracleIsNotZeroAddress(address asset);
    error Aera__UnderlyingAssetIsNotRegistered(
        address asset, address underlyingAsset
    );
    error Aera__UnderlyingAssetIsItselfERC4626();
    error Aera__AssetIsUnderlyingAssetOfERC4626(address erc4626Asset);
    error Aera__AssetIsAlreadyRegistered(uint256 index);
    error Aera__AssetNotRegistered(address asset);
    error Aera__CannotRemoveNumeraireToken(address asset);
    error Aera__CannotRemoveFeeToken(address feeToken);
    error Aera__CannotRemoveWrappedNativeToken(address wrappedNativeToken);
    error Aera__VaultIsZeroAddress();
    error Aera__SequencerIsDown();
    error Aera__GracePeriodNotOver();
    error Aera__OraclePriceIsInvalid(AssetInformation asset, int256 actual);
    error Aera__OraclePriceIsTooOld(AssetInformation asset, uint256 updatedAt);

    /// FUNCTIONS ///

    /// @param owner_ Initial owner address.
    /// @param vault_ Vault address.
    /// @param assets_ Initial list of registered assets.
    /// @param numeraireToken_ Numeraire token address.
    /// @param feeToken_ Fee token address.
    /// @param wrappedNativeToken_ Wrapped native token address.
    /// @param sequencer_ Sequencer Uptime Feed address for L2.
    constructor(
        address owner_,
        address vault_,
        AssetInformation[] memory assets_,
        IERC20 numeraireToken_,
        IERC20 feeToken_,
        IERC20 wrappedNativeToken_,
        AggregatorV2V3Interface sequencer_
    ) Ownable() {
        // Requirements: confirm that owner is not zero address.
        if (owner_ == address(0)) {
            revert Aera__AssetRegistryInitialOwnerIsZeroAddress();
        }

        // Requirements: check that an address has been provided.
        if (vault_ == address(0)) {
            revert Aera__VaultIsZeroAddress();
        }

        // Requirements: check that asset registry initial owner is not the computed vault address.
        if (owner_ == vault_) {
            revert Aera__AssetRegistryOwnerIsVault();
        }

        uint256 numAssets = assets_.length;

        // Requirements: confirm that number of assets is within bounds.
        if (numAssets > MAX_ASSETS) {
            revert Aera__NumberOfAssetsExceedsMaximum(MAX_ASSETS);
        }

        // Calculate the Numeraire token index.
        uint256 numeraireIndex = 0;
        for (; numeraireIndex < numAssets;) {
            if (assets_[numeraireIndex].asset == numeraireToken_) {
                break;
            }
            unchecked {
                numeraireIndex++; // gas savings
            }
        }

        // Calculate the fee token index.
        uint256 feeTokenIndex = 0;
        for (; feeTokenIndex < numAssets;) {
            if (assets_[feeTokenIndex].asset == feeToken_) {
                break;
            }
            unchecked {
                feeTokenIndex++; // gas savings
            }
        }

        // Calculate the wrapped native token index.
        uint256 wrappedNativeTokenIndex = 0;
        for (; wrappedNativeTokenIndex < numAssets;) {
            if (assets_[wrappedNativeTokenIndex].asset == wrappedNativeToken_)
            {
                break;
            }
            unchecked {
                wrappedNativeTokenIndex++; // gas savings
            }
        }

        // Requirements: confirm that Numeraire token is present.
        if (numeraireIndex >= numAssets) {
            revert Aera__NumeraireTokenIsNotRegistered(
                address(numeraireToken_)
            );
        }

        // Requirements: confirm that numeraire is not an ERC4626 asset.
        if (assets_[numeraireIndex].isERC4626) {
            revert Aera__NumeraireTokenIsERC4626();
        }

        // Requirements: confirm that numeraire does not have a specified oracle.
        if (address(assets_[numeraireIndex].oracle) != address(0)) {
            revert Aera__NumeraireOracleIsNotZeroAddress();
        }

        // Requirements: confirm that fee token is present.
        if (feeTokenIndex >= numAssets) {
            revert Aera__FeeTokenIsNotRegistered(address(feeToken_));
        }

        // Requirements: check that fee token is not an ERC4626.
        if (assets_[feeTokenIndex].isERC4626) {
            revert Aera__FeeTokenIsERC4626(address(feeToken_));
        }

        // Requirements: confirm that wrapped native token is present.
        if (wrappedNativeTokenIndex >= numAssets) {
            revert Aera__WrappedNativeTokenIsNotRegistered(
                address(wrappedNativeToken_)
            );
        }

        // Requirements: check that wrapped native token is not an ERC4626.
        if (assets_[wrappedNativeTokenIndex].isERC4626) {
            revert Aera__WrappedNativeTokenIsERC4626(
                address(wrappedNativeToken_)
            );
        }

        // Requirements: confirm that assets are sorted by address.
        for (uint256 i = 1; i < numAssets;) {
            if (assets_[i - 1].asset >= assets_[i].asset) {
                revert Aera__AssetOrderIsIncorrect(i);
            }
            unchecked {
                i++; // gas savings
            }
        }

        for (uint256 i = 0; i < numAssets;) {
            if (i != numeraireIndex) {
                // Requirements: check asset oracle is correctly specified.
                _checkAssetOracle(assets_[i]);

                if (assets_[i].isERC4626) {
                    // Requirements: check that underlying asset is a registered ERC20.
                    _checkUnderlyingAsset(assets_[i], assets_);
                }
            }

            // Effects: add asset to array.
            _insertAsset(assets_[i], i);

            unchecked {
                i++; // gas savings
            }
        }

        // Effects: set vault, numeraire, fee token, wrapped native token
        //          and sequencer uptime feed.
        vault = vault_;
        numeraireToken = numeraireToken_;
        feeToken = feeToken_;
        wrappedNativeToken = wrappedNativeToken_;
        sequencer = sequencer_;

        // Effects: set new owner.
        _transferOwnership(owner_);

        // Log asset registry creation.
        emit Created(
            owner_,
            vault_,
            assets_,
            address(numeraireToken_),
            address(feeToken_),
            address(wrappedNativeToken_),
            address(sequencer)
        );
    }

    /// @notice Add a new asset.
    /// @param asset Asset information for new asset.
    /// @dev MUST revert if not called by owner.
    /// @dev MUST revert if asset with the same address exists.
    function addAsset(AssetInformation calldata asset) external onlyOwner {
        uint256 numAssets = _assets.length;

        // Requirements: validate number of assets doesn't exceed bound.
        if (numAssets >= MAX_ASSETS) {
            revert Aera__NumberOfAssetsExceedsMaximum(MAX_ASSETS);
        }

        // Requirements: validate oracle field for asset struct.
        _checkAssetOracle(asset);

        uint256 i = 0;

        // Find the index to insert the new asset.
        for (; i < numAssets;) {
            if (asset.asset < _assets[i].asset) {
                break;
            }

            // Requirements: check that asset is not already present.
            if (asset.asset == _assets[i].asset) {
                revert Aera__AssetIsAlreadyRegistered(i);
            }

            unchecked {
                i++; // gas savings
            }
        }

        // Requirements: check that underlying asset is a registered ERC20.
        if (asset.isERC4626) {
            _checkUnderlyingAsset(asset, _assets);
        }

        // Effects: insert asset at position i.
        _insertAsset(asset, i);
    }

    /// @notice Remove an asset.
    /// @param asset An asset to remove.
    /// @dev MUST revert if not called by owner.
    function removeAsset(address asset) external onlyOwner {
        // Requirements: confirm that asset to remove is not numeraire.
        if (asset == address(numeraireToken)) {
            revert Aera__CannotRemoveNumeraireToken(asset);
        }

        // Requirements: check that asset to remove is not fee token.
        if (asset == address(feeToken)) {
            revert Aera__CannotRemoveFeeToken(asset);
        }

        // Requirements: check that asset to remove is not wrapped native token.
        if (asset == address(wrappedNativeToken)) {
            revert Aera__CannotRemoveWrappedNativeToken(asset);
        }

        uint256 numAssets = _assets.length;
        uint256 oldAssetIndex = 0;
        // Find index of asset.
        for (
            ;
            oldAssetIndex < numAssets
                && address(_assets[oldAssetIndex].asset) != asset;
        ) {
            unchecked {
                oldAssetIndex++; // gas savings
            }
        }

        // Requirements: check that asset is registered.
        if (oldAssetIndex >= numAssets) {
            revert Aera__AssetNotRegistered(asset);
        }

        // Effects: adjust the number of ERC4626 assets.
        if (_assets[oldAssetIndex].isERC4626) {
            numYieldAssets--;
        } else {
            for (uint256 i = 0; i < numAssets;) {
                if (
                    i != oldAssetIndex && _assets[i].isERC4626
                        && IERC4626(address(_assets[i].asset)).asset() == asset
                ) {
                    revert Aera__AssetIsUnderlyingAssetOfERC4626(
                        address(_assets[i].asset)
                    );
                }
                unchecked {
                    i++; // gas savings
                }
            }
        }

        uint256 nextIndex;
        uint256 lastIndex = numAssets - 1;
        // Slide all elements after oldAssetIndex left.
        for (uint256 i = oldAssetIndex; i < lastIndex;) {
            nextIndex = i + 1;
            _assets[i] = _assets[nextIndex];

            unchecked {
                i++; // gas savings
            }
        }

        // Effects: remove asset from array.
        _assets.pop();

        // Log removal.
        emit AssetRemoved(asset);
    }

    /// @inheritdoc IAssetRegistry
    function assets()
        external
        view
        override
        returns (AssetInformation[] memory)
    {
        return _assets;
    }

    /// @inheritdoc IAssetRegistry
    function spotPrices()
        external
        view
        override
        returns (AssetPriceReading[] memory)
    {
        int256 answer;
        uint256 startedAt;

        // Requirements: check that sequencer is up.
        if (address(sequencer) != address(0)) {
            (, answer, startedAt,,) = sequencer.latestRoundData();

            // Answer == 0: Sequencer is up
            // Requirements: check that the sequencer is up.
            if (answer != 0) {
                revert Aera__SequencerIsDown();
            }

            // Requirements: check that the grace period has passed after the
            //               sequencer is back up.
            if (block.timestamp < startedAt + GRACE_PERIOD_TIME) {
                revert Aera__GracePeriodNotOver();
            }
        }

        // Prepare price array.
        uint256 numAssets = _assets.length;
        AssetPriceReading[] memory prices = new AssetPriceReading[](
            numAssets - numYieldAssets
        );

        uint256 oracleDecimals;
        uint256 price;
        uint256 index = 0;
        for (uint256 i = 0; i < numAssets;) {
            if (_assets[i].isERC4626) {
                unchecked {
                    i++; // gas savings
                }
                continue;
            }

            if (_assets[i].asset == numeraireToken) {
                // Numeraire has price 1 by definition.
                prices[index] = AssetPriceReading({
                    asset: _assets[i].asset,
                    spotPrice: ONE
                });
            } else {
                price = _checkOraclePrice(_assets[i]);
                oracleDecimals = _assets[i].oracle.decimals();

                if (oracleDecimals < 18) {
                    price = price * (10 ** (18 - oracleDecimals));
                } else if (oracleDecimals > 18) {
                    price = price / (10 ** (oracleDecimals - 18));
                }

                prices[index] = AssetPriceReading({
                    asset: _assets[i].asset,
                    spotPrice: price
                });
            }

            unchecked {
                // gas savings
                index++;
                i++;
            }
        }

        return prices;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return interfaceId == type(IAssetRegistry).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Ensure non-zero oracle address for ERC20
    ///         and zero oracle address for ERC4626.
    /// @param asset Asset details to check
    function _checkAssetOracle(AssetInformation memory asset) internal view {
        if (asset.isERC4626) {
            // ERC4626 asset should not have a specified oracle.
            if (address(asset.oracle) != address(0)) {
                revert Aera__ERC4626OracleIsNotZeroAddress(
                    address(asset.asset)
                );
            }
        } else {
            // ERC20 asset should have non-zero oracle address.
            if (address(asset.oracle) == address(0)) {
                revert Aera__ERC20OracleIsZeroAddress(address(asset.asset));
            }

            // Requirements: validate oracle price.
            _checkOraclePrice(asset);
        }
    }

    /// @notice Ensure oracle returns valid value and it's up to date.
    /// @param asset Asset details to check.
    /// @return price Valid oracle price.
    function _checkOraclePrice(AssetInformation memory asset)
        internal
        view
        returns (uint256 price)
    {
        (, int256 answer,, uint256 updatedAt,) = asset.oracle.latestRoundData();

        // Check price staleness
        if (answer <= 0) {
            revert Aera__OraclePriceIsInvalid(asset, answer);
        }
        if (
            asset.heartbeat > 0
                && updatedAt + asset.heartbeat + 1 hours < block.timestamp
        ) {
            revert Aera__OraclePriceIsTooOld(asset, updatedAt);
        }

        price = uint256(answer);
    }

    /// @notice Check whether the underlying asset is listed as an ERC20.
    /// @dev Will revert if underlying asset is an ERC4626.
    /// @param asset ERC4626 asset to check underlying asset.
    /// @param assetsToCheck Array of assets.
    function _checkUnderlyingAsset(
        AssetInformation memory asset,
        AssetInformation[] memory assetsToCheck
    ) internal view {
        uint256 numAssets = assetsToCheck.length;

        address underlyingAsset = IERC4626(address(asset.asset)).asset();
        uint256 underlyingIndex = 0;

        for (; underlyingIndex < numAssets;) {
            if (
                underlyingAsset
                    == address(assetsToCheck[underlyingIndex].asset)
            ) {
                break;
            }

            unchecked {
                underlyingIndex++; // gas savings
            }
        }

        if (underlyingIndex >= numAssets) {
            revert Aera__UnderlyingAssetIsNotRegistered(
                address(asset.asset), underlyingAsset
            );
        }

        if (assetsToCheck[underlyingIndex].isERC4626) {
            revert Aera__UnderlyingAssetIsItselfERC4626();
        }
    }

    /// @notice Insert asset at the given index in an array of assets.
    /// @param asset New asset details.
    /// @param index Index of the new asset in the asset array.
    function _insertAsset(
        AssetInformation memory asset,
        uint256 index
    ) internal {
        uint256 numAssets = _assets.length;

        if (index == numAssets) {
            // Effects: insert new asset at the end.
            _assets.push(asset);
        } else {
            // Effects: push last elements to the right and insert new asset.
            _assets.push(_assets[numAssets - 1]);

            uint256 prevIndex;
            for (uint256 i = numAssets - 1; i > index; i--) {
                prevIndex = i - 1;
                _assets[i] = _assets[prevIndex];
            }

            _assets[index] = asset;
        }

        // Effects: adjust the number of ERC4626 assets.
        if (asset.isERC4626) {
            numYieldAssets++;
        }

        // Log asset added.
        emit AssetAdded(address(asset.asset), asset);
    }

    /// @notice Check that owner is not the vault or the guardian.
    /// @param owner_ Asset registry owner address.
    /// @param vault_ Vault address.
    function _checkAssetRegistryOwner(
        address owner_,
        address vault_
    ) internal view {
        if (owner_ == vault_) {
            revert Aera__AssetRegistryOwnerIsVault();
        }

        address guardian = IVault(vault_).guardian();
        if (owner_ == guardian) {
            revert Aera__AssetRegistryOwnerIsGuardian();
        }
    }

    /// @inheritdoc Ownable2Step
    function transferOwnership(address newOwner) public override onlyOwner {
        // Requirements: check that new owner is disaffiliated from existing roles.
        _checkAssetRegistryOwner(newOwner, vault);

        // Effects: initiate ownership transfer.
        super.transferOwnership(newOwner);
    }
}
