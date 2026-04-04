// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";

/**
 * @notice Deploy the UniSolid protofactory
 * @dev Usage: forge script script/UniSolid.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 *
 * Reads the Uniswap V2 Router lookup address from io/$env/$chain/UniswapV2Router.json.
 * Set env vars: env (e.g. "prod"), chain (RPC URL or chain ID).
 */
contract UniSolidDeploy is Script {
    uint256 constant GAS_MARGIN = 450_000;
    uint256 constant LINK_MIN = 1 ether;
    uint256 constant LINK_ETH = 0.01 ether;

    function run() external {
        string memory base = string.concat("io/", vm.envString("env"), "/", vm.envString("chain"), "/");
        address routerLookup = vm.parseJsonAddress(vm.readFile(string.concat(base, "UniswapV2Router.json")), "");
        address linkLookup = vm.parseJsonAddress(vm.readFile(string.concat(base, "LINK.json")), "");

        vm.startBroadcast();

        UniSolid unisolid = new UniSolid{salt: 0x0}(
            IAddressLookup(routerLookup), IAddressLookup(linkLookup), GAS_MARGIN, LINK_MIN, LINK_ETH
        );
        console2.log("UniSolid protofactory deployed at:", address(unisolid));

        vm.stopBroadcast();
    }
}
