//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/IERC20.sol";

interface ILlamaPay {
    struct Payer {
        uint40 lastPayerUpdate;
        uint216 totalPaidPerSec;
    }

    // solhint-disable-next-line func-name-mixedcase
    function DECIMALS_DIVISOR() external view returns (uint256);
    function token() external view returns (IERC20);
    function balances(address) external view returns (uint256);

    function createStream(address to, uint216 amountPerSec) external;

    function withdrawable(
        address from,
        address to,
        uint216 amountPerSec
    )
        external
        view
        returns (uint256 withdrawableAmount, uint256 lastUpdate, uint256 owed);

    function withdraw(
        address from,
        address to,
        uint216 amountPerSec
    ) external;

    function cancelStream(address to, uint216 amountPerSec) external;

    function pauseStream(address to, uint216 amountPerSec) external;

    function modifyStream(
        address oldTo,
        uint216 oldAmountPerSec,
        address to,
        uint216 amountPerSec
    ) external;

    function deposit(uint256 amountToDeposit) external;

    function depositAndCreate(
        uint256 amountToDeposit,
        address to,
        uint216 amountPerSec
    ) external;

    function withdrawPayer(uint256 amount) external;

    function withdrawPayerAll() external;
}