// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20Metadata } from "@oz/interfaces/IERC20Metadata.sol";
import { ERC165 } from "@oz/utils/introspection/ERC165.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { Auth, Auth2Step, Authority } from "src/core/Auth2Step.sol";

import { OracleData } from "src/core/Types.sol";
import { IOracle } from "src/dependencies/oracles/IOracle.sol";
import { MAXIMUM_UPDATE_DELAY } from "src/periphery/Constants.sol";
import { IOracleRegistry } from "src/periphery/interfaces/IOracleRegistry.sol";

/// @title OracleRegistry
/// @notice Canonical registry for ERC-7726-compatible price oracles
/// Registry itself conforms to ERC-7726 (exposes `getQuote`)
/// Owner seeds initial oracles on deploy; every subsequent oracle must be scheduled, then committed ≥
/// `ORACLE_UPDATE_DELAY` seconds later. A user (or its owner) may temporarily override with the pending oracle
/// until the commit executes, enabling instant adoption if desired. Owner may disable any active oracle; `getQuote`
/// then reverts unless a user override is in place
contract OracleRegistry is IOracleRegistry, Auth2Step, ERC165 {
    using SafeCast for uint256;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Mandatory delay (seconds) before a scheduled oracle can be committed
    uint256 public immutable ORACLE_UPDATE_DELAY;

    ////////////////////////////////////////////////////////////
    //                        Storage                         //
    ////////////////////////////////////////////////////////////

    /// @notice Registry mapping: base → quote → oracle data
    mapping(address base => mapping(address quote => OracleData oracleData)) internal _oracles;

    /// @notice Per‑vault oracle overrides: user → base → quote → oracle
    mapping(address user => mapping(address base => mapping(address quote => IOracle))) public oracleOverrides;

    ////////////////////////////////////////////////////////////
    //                       Modifiers                        //
    ////////////////////////////////////////////////////////////

    modifier requiresUserAuth(address user) {
        require(
            msg.sender == user || msg.sender == Auth(user).owner()
                || Auth(user).authority().canCall(msg.sender, address(this), msg.sig),
            AeraPeriphery__CallerIsNotAuthorized()
        );
        _;
    }

    constructor(address initialOwner, Authority initialAuthority, uint256 oracleUpdateDelay)
        Auth2Step(initialOwner, initialAuthority)
    {
        // Requirements: check that the owner address is not zero
        require(initialOwner != address(0), AeraPeriphery__ZeroAddressOwner());
        // Requirements: check that the update delay is not too long
        require(oracleUpdateDelay <= MAXIMUM_UPDATE_DELAY, AeraPeriphery__OracleUpdateDelayTooLong());
        // Effects: set the update delay
        ORACLE_UPDATE_DELAY = oracleUpdateDelay;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IOracleRegistry
    function addOracle(address base, address quote, IOracle oracle) external requiresAuth {
        // Requirements: check that the oracle is not set
        require(_oracles[base][quote].oracle == IOracle(address(0)), AeraPeriphery__OracleAlreadySet());

        // Effects: add oracle to registry
        _oracles[base][quote] = OracleData({
            isScheduledForUpdate: false,
            isDisabled: false,
            oracle: oracle,
            pendingOracle: IOracle(address(0)),
            commitTimestamp: 0
        });

        // Interactions + requirements: check that the oracle can convert base to quote
        _validateOracle(oracle, base, quote);

        // Log the oracle added
        emit OracleSet(base, quote, oracle);
    }

    /// @inheritdoc IOracleRegistry
    function scheduleOracleUpdate(address base, address quote, IOracle oracle) external requiresAuth {
        OracleData storage oracleData = _oracles[base][quote];

        // Requirements: check that the oracle is not already scheduled for update
        require(!oracleData.isScheduledForUpdate, AeraPeriphery__OracleUpdateAlreadyScheduled());
        // Requirements: check that the oracle is not the same as the current oracle
        require(oracleData.oracle != oracle, AeraPeriphery__CannotScheduleOracleUpdateForTheSameOracle());

        // Effects: update oracle data
        unchecked {
            oracleData.commitTimestamp = (block.timestamp + ORACLE_UPDATE_DELAY).toUint32();
        }
        oracleData.isScheduledForUpdate = true;
        oracleData.pendingOracle = oracle;

        // Interactions + requirements: check that the oracle can convert base to quote
        _validateOracle(oracle, base, quote);

        // Log the oracle scheduled event
        emit OracleScheduled(base, quote, oracle, oracleData.commitTimestamp);
    }

    /// @inheritdoc IOracleRegistry
    function commitOracleUpdate(address base, address quote) external {
        OracleData storage oracleData = _oracles[base][quote];

        IOracle pendingOracle = oracleData.pendingOracle;

        // Requirements: check that there is a pending oracle
        require(pendingOracle != IOracle(address(0)), AeraPeriphery__NoPendingOracleUpdate());
        // Requirements: check that the delay period has passed
        require(oracleData.commitTimestamp <= block.timestamp, AeraPeriphery__CommitTimestampNotReached());

        // Effects: update oracle data
        oracleData.commitTimestamp = 0;
        oracleData.pendingOracle = IOracle(address(0));
        oracleData.oracle = pendingOracle;
        oracleData.isScheduledForUpdate = false;
        oracleData.isDisabled = false;

        // Interactions + requirements: check that the oracle can convert base to quote
        _validateOracle(pendingOracle, base, quote);

        // Log oracle added event
        emit OracleSet(base, quote, oracleData.oracle);
    }

    /// @inheritdoc IOracleRegistry
    function cancelScheduledOracleUpdate(address base, address quote) external requiresAuth {
        OracleData storage oracleData = _oracles[base][quote];

        // Requirements: check that the oracle is scheduled for update
        require(oracleData.isScheduledForUpdate, AeraPeriphery__NoPendingOracleUpdate());

        // Effects: update oracle data
        oracleData.pendingOracle = IOracle(address(0));
        oracleData.isScheduledForUpdate = false;
        oracleData.commitTimestamp = 0;

        // Log oracle update cancelled event
        emit OracleUpdateCancelled(base, quote);
    }

    /// @inheritdoc IOracleRegistry
    function disableOracle(address base, address quote, IOracle oracle) external requiresAuth {
        OracleData storage oracleData = _oracles[base][quote];

        // Requirements: check that current status is not disabled
        require(!oracleData.isDisabled, AeraPeriphery__OracleAlreadyDisabled());
        // Requirements: check that current oracle matches oracle
        require(oracleData.oracle == oracle, AeraPeriphery__OracleMismatch());
        // Requirements: check that the oracle is not zero address
        require(oracle != IOracle(address(0)), AeraPeriphery__ZeroAddressOracle());

        // Effects: disable oracle
        oracleData.isDisabled = true;

        // Log oracle disabled event
        emit OracleDisabled(base, quote, oracle);
    }

    /// @inheritdoc IOracleRegistry
    function acceptPendingOracle(address base, address quote, address user, IOracle oracle)
        external
        requiresUserAuth(user)
    {
        // Requirements: check that the oracle is not zero address
        require(oracle != IOracle(address(0)), AeraPeriphery__ZeroAddressOracle());
        // Requirements: check that oracle matches pending oracle
        require(_oracles[base][quote].pendingOracle == oracle, AeraPeriphery__OracleMismatch());

        // Effects: set oracle override
        oracleOverrides[user][base][quote] = oracle;

        // Log pending oracle accepted event
        emit PendingOracleAccepted(user, base, quote, oracle);
    }

    /// @inheritdoc IOracleRegistry
    function removeOracleOverride(address base, address quote, address user) external requiresUserAuth(user) {
        // Effects: remove oracle override
        oracleOverrides[user][base][quote] = IOracle(address(0));

        // Log oracle override removed event
        emit OracleOverrideRemoved(user, base, quote);
    }

    /// @inheritdoc IOracle
    function getQuote(uint256 baseAmount, address base, address quote) external view virtual returns (uint256) {
        IOracle oracle = _getOracleForVault(msg.sender, base, quote);

        return oracle.getQuote(baseAmount, base, quote);
    }

    /// @inheritdoc IOracleRegistry
    function getQuoteForUser(uint256 baseAmount, address base, address quote, address user)
        external
        view
        virtual
        returns (uint256)
    {
        IOracle oracle = _getOracleForVault(user, base, quote);

        return oracle.getQuote(baseAmount, base, quote);
    }

    /// @inheritdoc IOracleRegistry
    function getOracleData(address base, address quote) external view virtual returns (OracleData memory) {
        return _oracles[base][quote];
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IOracleRegistry).interfaceId || interfaceId == type(IOracle).interfaceId
            || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Get the oracle for a user
    /// @dev Returns the current oracle if active or deprecated with no override
    /// reverts if the oracle is disabled and no override is set
    /// @param user The user address to get the oracle for
    /// @param base The base token address
    /// @param quote The quote token address
    /// @return The oracle instance for the given pair
    function _getOracleForVault(address user, address base, address quote) internal view returns (IOracle) {
        OracleData storage oracleData = _oracles[base][quote];

        if (oracleData.isScheduledForUpdate) {
            IOracle oracleOverride = oracleOverrides[user][base][quote];
            if (oracleOverride == oracleData.pendingOracle) {
                return oracleOverride;
            }
        }

        require(!oracleData.isDisabled, AeraPeriphery__OracleIsDisabled(base, quote, oracleData.oracle));

        IOracle oracle = oracleData.oracle;
        require(oracle != IOracle(address(0)), AeraPeriphery__OracleNotSet());

        return oracle;
    }

    /// @notice Validate that an oracle can convert one base token to a non‑zero quote token
    /// @dev Implicitly checks zero address because the getQuote call reverts
    /// @param oracle The oracle to validate
    /// @param base The base token address
    /// @param quote The quote token address
    function _validateOracle(IOracle oracle, address base, address quote) internal view {
        uint256 oneBaseToken = 10 ** _getDecimals(base);
        require(
            oracle.getQuote(oneBaseToken, base, quote) != 0,
            AeraPeriphery__OracleConvertsOneBaseTokenToZeroQuoteTokens(base, quote)
        );
    }

    /// @notice Determine the decimals of an asset
    /// @dev Defaults to 18 if the asset is not an ERC20
    /// @param asset The asset address to get decimals for
    /// @return The decimals of the asset
    function _getDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = asset.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }
}
