// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {UniSolid} from "src/UniSolid.sol";

/**
 * @notice Buy Uniteum1 tokens on Uniswap V2 via its UniSolid clone
 * @dev Usage: forge script script/UniswapForUniteum1.s.sol -f $chain --private-key $tx_key --broadcast
 *
 * Reads from .env:
 *   UniswapUniteum1 — UniSolid clone address for Uniteum1
 *   EthForUniteum1 — Amount of ETH to swap in wei (e.g. 10000000000000000 = 0.01 ETH)
 */
contract UniswapForUniteum1 is Script {
    function run() external {
        uint256 ethAmount = vm.envUint("EthForUniteum1");
        UniSolid clone = UniSolid(payable(vm.envAddress("UniswapUniteum1")));

        vm.startBroadcast();

        uint256 tokens = clone.buyFromUniswap{value: ethAmount}();

        vm.stopBroadcast();

        console2.log("Bought %d Uniteum1 with %d ETH", tokens, ethAmount);
    }
}
