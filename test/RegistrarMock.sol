// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract RegistrarMock {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable LINK;

    constructor(address link_) {
        LINK = link_;
    }
}
