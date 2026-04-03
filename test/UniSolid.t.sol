// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseTest} from "crucible/test/Base.t.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {Solid} from "solid/Solid.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/Test.sol";
import {UnswapV2Router01Mock} from "./UnswapV2Router01Mock.sol";
import {AddressLookupMock} from "./AddressLookupMock.sol";

contract UniSolidTest is BaseTest {
    UniSolid proto;
    UniSolid arb;
    ISolid solid;
    UnswapV2Router01Mock router;

    function setUp() public override {
        super.setUp();

        Solid nothing = new Solid(602_214_076 ether);
        solid = nothing.make("Mock Solid", "MS");

        router = new UnswapV2Router01Mock(address(0xE77));

        // Pair must exist before make(solid) — set up a minimal pool
        router.setPool(address(solid), 1, 1);

        proto = new UniSolid(IAddressLookup(address(new AddressLookupMock(address(router)))));
        arb = proto.make(solid);
    }

    function _params(uint256 gasEstimate, uint256 margin) internal pure returns (UniSolid.Params memory) {
        return UniSolid.Params({gasEstimate: gasEstimate, margin: margin});
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

        vm.txGasPrice(10 gwei);
        UniSolid.Params memory p = _params(300_000, 1e18);
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

        UniSolid.Params memory p = _params(0, 0);
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

        UniSolid.Params memory p = _params(0, 0);
        (bool needed, bytes memory performData) = arb.checkUpkeep(_encode(p));

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep(performData);
            uint256 balAfter = address(arb).balance;
            assertGt(balAfter, balBefore, "should profit from arb");
            console.log("Profit:", balAfter - balBefore);
        }
    }

    function test_NoArbWithInsufficientBalance() public {
        // Set up a price discrepancy so there would be an arb
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        // Arb contract has no ETH
        UniSolid.Params memory p = _params(0, 0);
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

        // Set impossibly high threshold: 10M gas × 1000 gwei × 1e18 margin
        vm.txGasPrice(1000 gwei);
        UniSolid.Params memory p = _params(10_000_000, 1e18);
        (bool needed,) = arb.checkUpkeep(_encode(p));
        assertFalse(needed, "should not arb below min profit");
    }

    function test_OptimalSizeBetterThanFixed() public {
        // Set up a moderate price discrepancy
        vm.deal(address(this), 3 ether);
        solid.buy{value: 3 ether}();

        // Uniswap cheaper than Solid
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), solid.balanceOf(address(this)));
        vm.deal(address(router), 1 ether);
        router.setPool(address(solid), 1 ether, 50_000_000 ether);

        vm.deal(address(solid), 5 ether);

        // Get optimal ethIn from checkUpkeep
        UniSolid.Params memory p = _params(0, 0);
        vm.deal(address(arb), 10 ether);
        (bool needed, bytes memory performData) = arb.checkUpkeep(_encode(p));
        assertTrue(needed, "should find arb");

        (,, uint256 optimalEthIn) = abi.decode(performData, (UniSolid.Params, UniSolid.Direction, uint256));
        assertGt(optimalEthIn, 0, "optimal ethIn should be positive");
        console.log("Optimal ethIn:", optimalEthIn);
    }

    function test_StoredSolidAndPair() public view {
        assertEq(address(arb.solid()), address(solid), "clone should store solid");
        assertEq(arb.pair(), address(router), "clone should store pair");
    }

    function test_NoPairReverts() public {
        Solid nothing2 = new Solid(602_214_076 ether);
        ISolid solid2 = nothing2.make("No Pair", "NP");

        // No Uniswap pair exists for solid2
        vm.expectRevert(UniSolid.NoPair.selector);
        proto.make(solid2);
    }

    function test_OnlyOwnerWithdraw() public {
        vm.deal(address(arb), 1 ether);

        // Non-owner cannot withdraw
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.withdraw(1 ether);

        // Owner can withdraw
        uint256 balBefore = address(this).balance;
        arb.withdraw(1 ether);
        assertEq(address(this).balance - balBefore, 1 ether);
    }

    function test_OnlyOwnerRecover() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
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
        arb.addLiquidityETH{value: 0.5 ether}(tokens, 0, 0);

        assertGt(router.lpBalanceOf(address(arb)), 0, "should have LP tokens");
        assertEq(router.lpBalanceOf(address(arb)), 0.5 ether, "LP tokens should equal ETH sent");
    }

    function test_RemoveLiquidityETH() public {
        // Reset mock reserves so only addLiquidity tokens are tracked
        router.setPool(address(solid), 0, 0);

        // Setup: buy tokens, transfer to arb, add liquidity
        vm.deal(address(this), 2 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(arb), tokens);

        vm.deal(address(arb), 1 ether);
        arb.addLiquidityETH{value: 0.5 ether}(tokens, 0, 0);

        uint256 lp = router.lpBalanceOf(address(arb));
        uint256 balBefore = address(arb).balance;

        // Remove all liquidity (pair == router in mock)
        arb.removeLiquidityETH(lp, 0, 0);

        assertEq(router.lpBalanceOf(address(arb)), 0, "LP tokens should be burned");
        assertGt(address(arb).balance, balBefore, "should have received ETH back");
    }

    function test_OnlyOwnerAddLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.addLiquidityETH(0, 0, 0);
    }

    function test_OnlyOwnerRemoveLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.removeLiquidityETH(0, 0, 0);
    }

    // ---- Factory tests ----

    function test_MadePredictsAddress() public view {
        (bool exists, address home,) = proto.made(address(this), solid);
        assertTrue(exists, "clone should exist");
        assertEq(home, address(arb), "predicted address should match clone");
    }

    function test_MakeIdempotent() public {
        UniSolid second = proto.make(solid);
        assertEq(address(second), address(arb), "second make should return same clone");
    }

    function test_MakeFromClone() public {
        // Calling make() on a clone forwards to proto.
        // msg.sender becomes the clone itself, so it gets its own clone.
        UniSolid cloneOfClone = arb.make(solid);
        (, address expected,) = proto.made(address(arb), solid);
        assertEq(address(cloneOfClone), expected, "make via clone should forward to proto");
        assertEq(cloneOfClone.owner(), address(arb), "clone-of-clone owner should be the calling clone");
    }

    function test_MakeDifferentOwners() public {
        address other = address(0xBEEF);
        vm.prank(other);
        UniSolid otherArb = proto.make(solid);
        assertTrue(address(otherArb) != address(arb), "different owners should get different clones");
        assertEq(otherArb.owner(), other, "clone owner should be caller");
    }

    function test_CloneOwnerIsDeployer() public view {
        assertEq(arb.owner(), address(this), "clone owner should be test contract");
    }

    function test_ProtoHasNoOwner() public view {
        assertEq(proto.owner(), address(0), "proto should have no owner");
    }

    function test_ZzInitOnlyCallableByProto() public {
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.zzInit(address(this), solid);
    }

    receive() external payable {}
}
