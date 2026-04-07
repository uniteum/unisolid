// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutomationRegistrar} from "iautomation/IAutomationRegistrar.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {RegistryMock} from "./RegistryMock.sol";

contract RegistrarMock {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable LINK;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    RegistryMock public immutable registry;

    constructor(address link_) {
        LINK = link_;
        registry = new RegistryMock(link_);
    }

    function registerUpkeep(IAutomationRegistrar.RegistrationParams calldata params) external returns (uint256) {
        // Pull LINK from caller (mirrors real registrar behavior)
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(LINK).transferFrom(msg.sender, address(this), params.amount);
        IERC20(LINK).approve(address(registry), params.amount);
        return registry.register(params.upkeepContract, params.amount);
    }

    function getConfig() external view returns (address, uint256) {
        return (address(registry), 0);
    }
}
