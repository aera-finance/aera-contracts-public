// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Address } from "@oz/utils/Address.sol";
import { ShortString, ShortStrings } from "@oz/utils/ShortStrings.sol";
import { TransientSlot } from "@oz/utils/TransientSlot.sol";
import { Authority } from "@solmate/auth/Auth.sol";

import { FeeVaultDeployer } from "src/core/FeeVaultDeployer.sol";
import { Sweepable } from "src/core/Sweepable.sol";
import { BaseVaultParameters, ERC20Parameters, FeeVaultParameters } from "src/core/Types.sol";
import { IBeforeTransferHook } from "src/core/interfaces/IBeforeTransferHook.sol";

import { IMultiDepositorVaultFactory } from "src/core/interfaces/IMultiDepositorVaultFactory.sol";
import { IVaultDeployDelegate } from "src/core/interfaces/IVaultDeployDelegate.sol";

/// @title MultiDepositorVaultFactory
/// @notice Used to create new multi-depositor vaults using delegate call
/// @dev Only one instance of the factory will be required per chain
contract MultiDepositorVaultFactory is IMultiDepositorVaultFactory, FeeVaultDeployer, Sweepable {
    using TransientSlot for *;

    ////////////////////////////////////////////////////////////
    //                       Constants                        //
    ////////////////////////////////////////////////////////////

    /// @notice ERC7201-compliant transient storage slot for storing vault token erc20 name during deployment
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.factory.erc20.name")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant ERC20_NAME_SLOT = 0x79a9bb099f009196aa3acc685f15554a8e8fd10fee7019652e2c9a6d65a86500;

    /// @notice ERC7201-compliant transient storage slot for storing vault token erc20 symbol during deployment
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.factory.erc20.symbol")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant ERC20_SYMBOL_SLOT = 0xab25fe6ab1c05d9a94c8d6727a857804585a85a98c2bb360f69300eb1a356300;

    /// @notice ERC7201-compliant transient storage slot for storing multi depositor vault parameters during deployment
    /// @dev Equal to keccak256(abi.encode(uint256(keccak256("aera.factory.multiDepositorVaultParameters")) - 1)) &
    ///      ~bytes32(uint256(0xff));
    bytes32 internal constant MULTI_DEPOSITOR_VAULT_PARAMETERS_SLOT =
        0xe5669a0cf4b353071b0fa74e3cea85f64b33cd9eee158e4f6614aca797ff3a00;

    ////////////////////////////////////////////////////////////
    //                       Immutables                       //
    ////////////////////////////////////////////////////////////

    /// @notice Address of the deploy delegate
    address internal immutable _DEPLOY_DELEGATE;

    constructor(address initialOwner, Authority initialAuthority, address deployDelegate)
        Sweepable(initialOwner, initialAuthority)
    {
        // Requirements: check that deploy delegate is not the zero address
        require(deployDelegate != address(0), Aera__ZeroAddressDeployDelegate());

        // Effects: store deploy delegate
        _DEPLOY_DELEGATE = deployDelegate;
    }

    ////////////////////////////////////////////////////////////
    //              Public / External Functions               //
    ////////////////////////////////////////////////////////////

    /// @inheritdoc IMultiDepositorVaultFactory
    function create(
        bytes32 salt,
        string calldata description,
        ERC20Parameters calldata erc20Params,
        BaseVaultParameters calldata baseVaultParams,
        FeeVaultParameters calldata feeVaultParams,
        IBeforeTransferHook beforeTransferHook,
        address expectedVaultAddress
    ) external override requiresAuth returns (address deployedVault) {
        // Requirements: confirm that vault has a nonempty description
        require(bytes(description).length != 0, Aera__DescriptionIsEmpty());

        // Effects: deploy the vault
        deployedVault =
            _deployVault(salt, description, erc20Params, baseVaultParams, feeVaultParams, beforeTransferHook);

        // Invariants: check that deployed address matches expected address
        require(deployedVault == expectedVaultAddress, Aera__VaultAddressMismatch(deployedVault, expectedVaultAddress));
    }

    /// @inheritdoc IMultiDepositorVaultFactory
    function getERC20Name() external view returns (string memory name) {
        name = _loadStringFromSlot(uint256(ERC20_NAME_SLOT));
    }

    /// @inheritdoc IMultiDepositorVaultFactory
    function getERC20Symbol() external view returns (string memory symbol) {
        symbol = _loadStringFromSlot(uint256(ERC20_SYMBOL_SLOT));
    }

    /// @inheritdoc IMultiDepositorVaultFactory
    function multiDepositorVaultParameters() external view returns (IBeforeTransferHook beforeTransferHook) {
        beforeTransferHook = IBeforeTransferHook(MULTI_DEPOSITOR_VAULT_PARAMETERS_SLOT.asAddress().tload());
    }

    ////////////////////////////////////////////////////////////
    //              Private / Internal Functions              //
    ////////////////////////////////////////////////////////////

    /// @notice Deploy vault
    /// @param salt The salt value to create vault
    /// @param description Vault description
    /// @param erc20Params ERC20 parameters for vault deployment used in MultiDepositorVault
    /// @param baseVaultParams Parameters for vault deployment used in BaseVault
    /// @param feeVaultParams Parameters for vault deployment specific to FeeVault
    /// @param beforeTransferHook Parameters for vault deployment specific to MultiDepositorVault
    /// @return deployed Deployed vault address
    function _deployVault(
        bytes32 salt,
        string calldata description,
        ERC20Parameters calldata erc20Params,
        BaseVaultParameters calldata baseVaultParams,
        FeeVaultParameters calldata feeVaultParams,
        IBeforeTransferHook beforeTransferHook
    ) internal returns (address deployed) {
        // Effects: store parameters in transient storage
        _storeBaseVaultParameters(baseVaultParams);
        _storeFeeVaultParameters(feeVaultParams);
        _storeERC20Parameters(erc20Params);
        _storeMultiDepositorVaultParameters(beforeTransferHook);

        // Interactions: deploy vault with the delegate call
        deployed = _createVault(salt);

        // Log vault creation
        emit VaultCreated(
            deployed,
            baseVaultParams.owner,
            address(baseVaultParams.submitHooks),
            erc20Params,
            feeVaultParams,
            beforeTransferHook,
            description
        );
    }

    /// @notice Store ERC20 name and symbol in transient storage
    /// @param params Struct containing ERC20 name and symbol
    function _storeERC20Parameters(ERC20Parameters calldata params) internal {
        // Requirements: ensure name and symbol are under 32 characters
        ShortString name = ShortStrings.toShortString(params.name);
        ShortString symbol = ShortStrings.toShortString(params.symbol);

        // Effects: store erc20 parameters in transient storage
        ERC20_NAME_SLOT.asBytes32().tstore(ShortString.unwrap(name));
        ERC20_SYMBOL_SLOT.asBytes32().tstore(ShortString.unwrap(symbol));
    }

    /// @notice Store beforeTransferHook address in transient storage
    /// @param beforeTransferHook The hooks called before token transfers
    function _storeMultiDepositorVaultParameters(IBeforeTransferHook beforeTransferHook) internal {
        // Effects: store multi depositor vault parameters in transient storage
        MULTI_DEPOSITOR_VAULT_PARAMETERS_SLOT.asAddress().tstore(address(beforeTransferHook));
    }

    /// @notice Create a new vault with delegate call
    /// @param salt The salt value to create vault
    /// @return deployed Deployed vault address
    function _createVault(bytes32 salt) internal returns (address deployed) {
        // Interactions: create vault with delegate call
        bytes memory data =
            Address.functionDelegateCall(_DEPLOY_DELEGATE, abi.encodeCall(IVaultDeployDelegate.createVault, (salt)));
        deployed = abi.decode(data, (address));
    }

    /// @notice Load a short string from the given storage slot
    /// @param slot Storage slot to read from
    /// @return Decoded string
    function _loadStringFromSlot(uint256 slot) internal view returns (string memory) {
        bytes32 raw = bytes32(slot).asBytes32().tload();
        return ShortStrings.toString(ShortString.wrap(raw));
    }
}
