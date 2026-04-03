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

    function run() external {
        string memory path =
            string.concat("io/", vm.envString("env"), "/", vm.envString("chain"), "/UniswapV2Router.json");
        address routerLookup = vm.parseJsonAddress(vm.readFile(path), "");

        vm.startBroadcast();

        UniSolid unisolid = new UniSolid{salt: 0x0}(IAddressLookup(routerLookup), GAS_MARGIN);
        console2.log("UniSolid protofactory deployed at:", address(unisolid));

        vm.stopBroadcast();
    }
}
