// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";

/**
 * @notice Deploy the UniSolid protofactory
 * @dev Usage: forge script script/UniSolid.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 *
 * Reads lookup addresses from .env:
 *   UniswapV2RouterLookup — Uniswap V2 Router AddressLookup
 *   ChainlinkRegistrarLookup — Chainlink Automation Registrar AddressLookup
 */
contract UniSolidDeploy is Script {
    function run() external {
        address routerLookup = vm.envAddress("UniswapV2RouterLookup");
        address registrarLookup = vm.envAddress("ChainlinkRegistrarLookup");

        vm.startBroadcast();

        UniSolid unisolid = new UniSolid{salt: 0x0}(IAddressLookup(routerLookup), IAddressLookup(registrarLookup));
        console2.log("UniSolid protofactory deployed at:", address(unisolid));

        vm.stopBroadcast();
    }
}
