// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseTest} from "crucible/test/Base.t.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {Solid} from "solid/Solid.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/Test.sol";
import {UnswapV2Router01Mock} from "./UnswapV2Router01Mock.sol";

contract UniSolidTest is BaseTest {
    UniSolid arb;
    ISolid solid;
    UnswapV2Router01Mock router;

    function setUp() public override {
        super.setUp();

        Solid nothing = new Solid(602_214_076 ether);
        solid = nothing.make("Mock Solid", "MS");

        router = new UnswapV2Router01Mock(address(0xE77));

        arb = new UniSolid();
    }

    function _params(uint256 ethIn, uint256 minProfit) internal view returns (UniSolid.Params memory) {
        return UniSolid.Params({
            solid: ISolid(address(solid)),
            router: IUniswapV2Router01(address(router)),
            ethIn: ethIn,
            minProfit: minProfit
        });
    }

    function _encode(UniSolid.Params memory p) internal pure returns (bytes memory) {
        return abi.encode(p);
    }

    function test_NoArbWhenPricesEqual() public {
        // Buy 5 ETH of tokens on Solid to move its price
        vm.deal(address(this), 5 ether);
        solid.buy{value: 5 ether}();

        // Set Uniswap pool to same price ratio as Solid
        (uint256 S, uint256 E) = solid.pool();
        vm.deal(address(router), E);
        router.setPool(address(solid), E, S);

        // Give the router tokens to trade with
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), solid.balanceOf(address(this)));

        // Fund arb contract
        vm.deal(address(arb), 1 ether);

        UniSolid.Params memory p = _params(0.1 ether, 0.001 ether);
        (bool needed,) = arb.checkUpkeep(_encode(p));
        assertFalse(needed, "should not arb when prices equal");
    }

    function test_ArbSolidToUniswap() public {
        // Solid is cheap (fresh pool, price ~0), Uniswap is expensive
        // Set Uniswap with higher token price (less tokens per ETH)
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        // Give router some tokens to sell
        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);

        // Fund arb contract
        vm.deal(address(arb), 1 ether);

        UniSolid.Params memory p = _params(0.1 ether, 0);
        (bool needed, bytes memory performData) = arb.checkUpkeep(_encode(p));

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep(performData);
            uint256 balAfter = address(arb).balance;
            assertGt(balAfter, balBefore, "should profit from arb");
            console.log("Profit:", balAfter - balBefore);
        }
    }

    function test_ArbUniswapToSolid() public {
        // Make Solid expensive by buying a lot
        vm.deal(address(this), 10 ether);
        solid.buy{value: 10 ether}();

        // Uniswap is cheap — lots of tokens, little ETH
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), solid.balanceOf(address(this)));
        vm.deal(address(router), 1 ether);
        router.setPool(address(solid), 1 ether, 100_000_000 ether);

        // Fund arb contract and Solid contract for ETH payouts
        vm.deal(address(arb), 0.5 ether);
        vm.deal(address(solid), 5 ether);

        UniSolid.Params memory p = _params(0.1 ether, 0);
        (bool needed, bytes memory performData) = arb.checkUpkeep(_encode(p));

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep(performData);
            uint256 balAfter = address(arb).balance;
            assertGt(balAfter, balBefore, "should profit from arb");
            console.log("Profit:", balAfter - balBefore);
        }
    }

    function test_NoArbWithInsufficientBalance() public view {
        // Arb contract has no ETH
        UniSolid.Params memory p = _params(1 ether, 0);
        (bool needed,) = arb.checkUpkeep(_encode(p));
        assertFalse(needed, "should not arb without balance");
    }

    function test_MinProfitThreshold() public {
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);

        vm.deal(address(arb), 1 ether);

        // Set impossibly high min profit
        UniSolid.Params memory p = _params(0.1 ether, 1000 ether);
        (bool needed,) = arb.checkUpkeep(_encode(p));
        assertFalse(needed, "should not arb below min profit");
    }

    function test_OnlyOwnerWithdraw() public {
        vm.deal(address(arb), 1 ether);

        // Non-owner cannot withdraw
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.NotOwner.selector);
        arb.withdraw(1 ether);

        // Owner can withdraw
        uint256 balBefore = address(this).balance;
        arb.withdraw(1 ether);
        assertEq(address(this).balance - balBefore, 1 ether);
    }

    function test_OnlyOwnerRecover() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.NotOwner.selector);
        arb.recover(IERC20(address(solid)), 1 ether);
    }

    function test_AddLiquidityETH() public {
        // Buy tokens on Solid and transfer to arb contract
        vm.deal(address(this), 2 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(arb), tokens);

        // Add liquidity: arb sends ETH + tokens to router
        vm.deal(address(arb), 1 ether);
        arb.addLiquidityETH{value: 0.5 ether}(IUniswapV2Router01(address(router)), address(solid), tokens, 0, 0);

        assertGt(router.lpBalanceOf(address(arb)), 0, "should have LP tokens");
        assertEq(router.lpBalanceOf(address(arb)), 0.5 ether, "LP tokens should equal ETH sent");
    }

    function test_RemoveLiquidityETH() public {
        // Setup: buy tokens, transfer to arb, add liquidity
        vm.deal(address(this), 2 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(arb), tokens);

        vm.deal(address(arb), 1 ether);
        arb.addLiquidityETH{value: 0.5 ether}(IUniswapV2Router01(address(router)), address(solid), tokens, 0, 0);

        uint256 lp = router.lpBalanceOf(address(arb));
        uint256 balBefore = address(arb).balance;

        // Remove all liquidity (pair == router in mock)
        arb.removeLiquidityETH(IUniswapV2Router01(address(router)), address(solid), address(router), lp, 0, 0);

        assertEq(router.lpBalanceOf(address(arb)), 0, "LP tokens should be burned");
        assertGt(address(arb).balance, balBefore, "should have received ETH back");
    }

    function test_OnlyOwnerAddLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.NotOwner.selector);
        arb.addLiquidityETH(IUniswapV2Router01(address(router)), address(solid), 0, 0, 0);
    }

    function test_OnlyOwnerRemoveLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.NotOwner.selector);
        arb.removeLiquidityETH(IUniswapV2Router01(address(router)), address(solid), address(router), 0, 0, 0);
    }

    receive() external payable {}
}
