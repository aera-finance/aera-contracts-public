// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IAuth2Step
/// @notice Interface for the Auth2Step contract
interface IAuth2Step {
    ////////////////////////////////////////////////////////////
    //                         Events                         //
    ////////////////////////////////////////////////////////////

    /// @notice Emitted when ownership transfer is initiated
    /// @param previousOwner The current owner initiating the transfer
    /// @param newOwner The new owner who needs to accept the transfer
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    ////////////////////////////////////////////////////////////
    //                         Errors                         //
    ////////////////////////////////////////////////////////////

    error Aera__ZeroAddressAuthority();
    error Aera__Unauthorized();

    ////////////////////////////////////////////////////////////
    //                       Functions                        //
    ////////////////////////////////////////////////////////////

    /// @notice Accept ownership transfer
    function acceptOwnership() external;

    /// @notice Wrapper function for backward compatibility with legacy code expecting transferOwnership
    /// @dev This function exists to maintain compatibility with contracts that were built against
    ///      the previous version of Auth where ownership transfer was named `transferOwnership`
    ///      The new Auth implementation renamed this to `setOwner` to better reflect the two-step
    ///      ownership transfer process. This wrapper ensures existing code like BaseVault continues
    ///      to work without modification
    ///      Previous version:
    /// https://github.com/transmissions11/solmate/blob/89365b880c4f3c786bdd453d4b8e8fe410344a69/src/auth/Auth.sol
    ///      New version:
    /// https://github.com/transmissions11/solmate/blob/eaa7041378f9a6c12f943de08a6c41b31a9870fc/src/auth/Auth.sol
    /// @param newOwner Address to start the ownership transfer process to
    function transferOwnership(address newOwner) external;
}
