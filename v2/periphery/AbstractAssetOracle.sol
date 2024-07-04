// SPDX-License-Identifier: BUSL-1.1
// slither-disable-start dead-code,unimplemented-functions
pragma solidity 0.8.21;

import {SafeCast} from "./dependencies/openzeppelin/SafeCast.sol";
import {IAeraV2Oracle} from "./interfaces/IAeraV2Oracle.sol";
import {Math} from "./Math.sol";

abstract contract AbstractAssetOracle is IAeraV2Oracle {
    using SafeCast for *;

    /// @dev The total supply of the token.
    uint256 private constant _TOTAL_SUPPLY = 1e18;
    /// @dev Vault address.
    address internal immutable _vault;

    /// ERRORS ///

    /// @notice Thrown when the vault address is zero.
    error AeraPeriphery__VaultIsZeroAddress();
    /// @notice Thrown when a user tries to transfer tokens.
    error AeraPeriphery__TransfersAreNotAllowed();
    /// @notice Thrown when a user tries to approve.
    error AeraPeriphery__ApprovalsAreNotAllowed();
    /// @notice Thrown when the price <= 0.
    error AeraPeriphery__InvalidPrice(address priceFeed, int256 price);

    /// STORAGE ///

    /// @notice Flag to check if the token is burned.
    bool public burned;

    /// FUNCTIONS ///

    /// @notice Constructor for the AbstractAssetOracle contract.
    /// @param vault_ The address of the AeraVaultV2 contract.
    constructor(address vault_) {
        // Requirements: check the vault address is not zero.
        if (vault_ == address(0)) {
            revert AeraPeriphery__VaultIsZeroAddress();
        }
        // Effects: set the vault address.
        _vault = vault_;
    }

    /// @dev When called by the vault, this function burns
    ///      the token and makes this token unusable.
    function transfer(address, uint256) external returns (bool) {
        if (msg.sender == _vault && !burned) {
            burned = true;
            return true;
        }
        revert AeraPeriphery__TransfersAreNotAllowed();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) external virtual returns (bool) {
        revert AeraPeriphery__TransfersAreNotAllowed();
    }

    function approve(address, uint256) external virtual returns (bool) {
        revert AeraPeriphery__ApprovalsAreNotAllowed();
    }

    /// @dev Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256) {
        // For everyone else, the balance is zero.
        if (account != _vault) return 0;

        // For the vault, the balance is the total supply, if not burned.
        return burned ? 0 : _TOTAL_SUPPLY;
    }

    /// @dev Returns the amount of tokens in existence.
    function totalSupply() external view returns (uint256) {
        return burned ? 0 : _TOTAL_SUPPLY;
    }

    /// @inheritdoc IAeraV2Oracle
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 0;
        // Note: since the amount of the token is fixed then 1 * answer = position value.
        answer = _getValue().toInt256();
        if (answer == 0) {
            answer = 1; // Avoid zero price, which would break AeraVaultAssetRegistry
        }
        startedAt = 0;
        updatedAt = block.timestamp;
        answeredInRound = 0;
    }

    /// @notice Returns the AeraVaultV2 address.
    function vault() external view virtual returns (address) {
        return _vault;
    }

    /// @notice Because this contract is oracle and ERC20 token at the same time,
    ///         this function represent decimals for oracle price and token decimals.
    /// @return decimals The number of decimals.
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /// @notice Name of ERC20 token.
    function name() external pure virtual returns (string memory);

    /// @notice Symbol of ERC20 token.
    function symbol() external pure virtual returns (string memory);

    /// INTERNAL FUNCTIONS ///

    /// @dev Gets and validates the price from the price feed.
    function _getPrice(address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = IAeraV2Oracle(priceFeed).latestRoundData();

        if (price <= 0) {
            revert AeraPeriphery__InvalidPrice(priceFeed, price);
        }
        return price.toUint256();
    }

    /// @dev Returns the value of the position.
    function _getValue() internal view virtual returns (uint256);

    /// @dev Multiply two quantities, then divide by a third.
    ///      Copied from solmale FixedPointMathLib.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        return Math.mulDiv(x, y, denominator);
    }
}
// slither-disable-end dead-code,unimplemented-functions