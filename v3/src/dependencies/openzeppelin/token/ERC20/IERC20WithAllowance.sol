// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Sampled from
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/63851f8de5a6e560e9774832d1a31c43645b73d2/contracts/token/ERC20/ERC20.sol

interface IERC20WithAllowance {
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function decreaseAllowance(address spender, uint256 requestedDecrease) external returns (bool);
}
