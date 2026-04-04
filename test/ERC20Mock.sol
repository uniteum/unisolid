// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "erc20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
