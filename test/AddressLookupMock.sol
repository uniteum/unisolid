// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";

contract AddressLookupMock is IAddressLookup {
    address public immutable value;

    constructor(address value_) {
        value = value_;
    }
}
