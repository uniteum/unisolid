// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";

/**
 * @notice Buy Uniteum1 tokens on Uniswap V2
 * @dev Usage: forge script script/UniswapForUniteum1.s.sol -f $chain --private-key $tx_key --broadcast
 *
 * Reads from .env:
 *   Uniteum1 — Uniteum1 token address
 *   UniswapV2RouterLookup — Uniswap V2 Router AddressLookup
 *   EthForUniteum1 — Amount of ETH to swap in wei (e.g. 10000000000000000 = 0.01 ETH)
 */
contract UniswapForUniteum1 is Script {
    function run() external {
        uint256 ethAmount = vm.envUint("EthForUniteum1");
        address uniteum1 = vm.envAddress("Uniteum1");
        address routerLookup = vm.envAddress("UniswapV2RouterLookup");

        IUniswapV2Router01 router = IUniswapV2Router01(IAddressLookup(routerLookup).value());
        address weth = router.WETH();

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = uniteum1;

        vm.startBroadcast();

        router.swapExactETHForTokens{value: ethAmount}(0, path, msg.sender, block.timestamp);

        vm.stopBroadcast();

        console2.log("Bought Uniteum1 with", ethAmount, "ETH");
    }
}
