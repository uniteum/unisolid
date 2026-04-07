// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "ierc20/IERC20.sol";

contract RegistryMock {
    address public link;
    uint256 nextId = 1;
    mapping(uint256 => uint96) public balances;
    mapping(uint256 => address) public forwarders;

    constructor(address link_) {
        link = link_;
    }

    function getForwarder(uint256 id) external view returns (address) {
        return forwarders[id];
    }

    function addFunds(uint256 id, uint96 amount) external {
        IERC20(link).transferFrom(msg.sender, address(this), amount);
        balances[id] += amount;
    }

    function getBalance(uint256 id) external view returns (uint96) {
        return balances[id];
    }

    function cancelUpkeep(uint256) external {}

    function withdrawFunds(uint256 id, address to) external {
        uint96 bal = balances[id];
        balances[id] = 0;
        IERC20(link).transfer(to, bal);
    }

    function register(address, uint96 amount) external returns (uint256 id) {
        id = nextId++;
        IERC20(link).transferFrom(msg.sender, address(this), amount);
        balances[id] = amount;
        forwarders[id] = address(uint160(uint256(keccak256(abi.encode("forwarder", id)))));
    }
}
