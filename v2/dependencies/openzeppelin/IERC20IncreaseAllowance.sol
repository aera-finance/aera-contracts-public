pragma solidity ^0.8.0;

/**
 * @dev ERC20 but not IERC20 defines increaseAllowance
 */
interface IERC20IncreaseAllowance {
    /** 
     *  Atomically increases the allowance granted to spender by the caller. 
     *  This is an alternative to approve that can be used as a mitigation for 
     *  problems described in IERC20.approve. 
     *  Emits an Approval event indicating the updated allowance.
     *  Requirements: 
     *  spender cannot be the zero address.
     */ 
    function increaseAllowance(address spender, uint256 amount) external returns (bool);

}
