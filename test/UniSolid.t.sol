// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseTest} from "crucible/test/Base.t.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {Solid} from "solid/Solid.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UnswapV2Router01Mock} from "./UnswapV2Router01Mock.sol";
import {AddressLookupMock} from "./AddressLookupMock.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {Math} from "math/Math.sol";

contract ProfitHarness is UniSolid {
    constructor(IAddressLookup routerLookup, IAddressLookup linkLookup) UniSolid(routerLookup, linkLookup, 0, 0, 0) {}

    function profitA(uint256 x, uint256 S, uint256 E, uint256 T, uint256 W) external pure returns (uint256) {
        return _profitSolidToUniswap(x, S, E, T, W);
    }

    function profitB(uint256 x, uint256 S, uint256 E, uint256 T, uint256 W) external pure returns (uint256) {
        return _profitUniswapToSolid(x, S, E, T, W);
    }
}

contract UniSolidTest is BaseTest {
    UniSolid proto;
    UniSolid arb;
    ISolid solid;
    UnswapV2Router01Mock router;
    ERC20Mock link;
    ProfitHarness harness;

    function setUp() public override {
        super.setUp();

        Solid nothing = new Solid(602_214_076 ether);
        solid = nothing.make("Mock Solid", "MS");

        router = new UnswapV2Router01Mock(address(0xE77));

        // Pair must exist before make(solid) — set up a minimal pool
        router.setPool(address(solid), 1, 1);

        link = new ERC20Mock();

        AddressLookupMock lookup = new AddressLookupMock(address(router));
        AddressLookupMock linkLookup = new AddressLookupMock(address(link));
        proto = new UniSolid(IAddressLookup(address(lookup)), IAddressLookup(address(linkLookup)), 0, 0, 0);
        arb = proto.make(solid);
        harness = new ProfitHarness(IAddressLookup(address(lookup)), IAddressLookup(address(linkLookup)));
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
        (bool needed,) = arb.checkUpkeep("");
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

        (bool needed,) = arb.checkUpkeep("");

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep("");
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

        (bool needed,) = arb.checkUpkeep("");

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep("");
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
        (bool needed,) = arb.checkUpkeep("");
        assertFalse(needed, "should not arb without balance");
    }

    function test_ArbWithPartialBalance() public {
        // Solid is cheap, Uniswap is expensive
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);

        // Fund arb with less than optimal trade size
        vm.deal(address(arb), 0.01 ether);

        (bool needed,) = arb.checkUpkeep("");

        if (needed) {
            uint256 balBefore = address(arb).balance;
            arb.performUpkeep("");
            uint256 balAfter = address(arb).balance;
            assertGt(balAfter, balBefore, "should profit even with partial balance");
        }
    }

    function test_MinProfitThreshold() public {
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);

        // Deploy a proto with impossibly high threshold
        UniSolid highProto = new UniSolid(
            IAddressLookup(address(new AddressLookupMock(address(router)))),
            IAddressLookup(address(new AddressLookupMock(address(link)))),
            10_000_000,
            0,
            0
        );
        UniSolid highArb = highProto.make(solid);
        vm.deal(address(highArb), 1 ether);

        vm.txGasPrice(1000 gwei);
        (bool needed,) = highArb.checkUpkeep("");
        assertFalse(needed, "should not arb below min profit");
    }

    function test_OptimalSizeExecutes() public {
        // Set up a moderate price discrepancy
        vm.deal(address(this), 3 ether);
        solid.buy{value: 3 ether}();

        // Uniswap cheaper than Solid
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), solid.balanceOf(address(this)));
        vm.deal(address(router), 1 ether);
        router.setPool(address(solid), 1 ether, 50_000_000 ether);

        vm.deal(address(solid), 5 ether);

        // Verify arb is found and executes profitably
        vm.deal(address(arb), 10 ether);
        (bool needed,) = arb.checkUpkeep("");
        assertTrue(needed, "should find arb");

        uint256 balBefore = address(arb).balance;
        arb.performUpkeep("");
        assertGt(address(arb).balance, balBefore, "should profit from optimal arb");
    }

    function test_StoredSolidAndPair() public view {
        assertEq(address(arb.solid()), address(solid), "clone should store solid");
        assertEq(arb.pair(), address(router), "clone should store pair");
    }

    function test_CreatesPairIfMissing() public {
        Solid nothing2 = new Solid(602_214_076 ether);
        ISolid solid2 = nothing2.make("No Pair", "NP");

        // No Uniswap pair exists yet
        assertEq(proto.FACTORY().getPair(address(solid2), proto.WETH()), address(0));

        // make creates the pair
        UniSolid arb2 = proto.make(solid2);
        assertTrue(arb2.pair() != address(0));
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

    // ---- Liquidity tests ----

    function test_GiveLiquidity() public {
        // Set up Uniswap pool
        (uint256 S, uint256 E) = solid.pool();
        vm.deal(address(router), E);
        router.setPool(address(solid), E, S);

        // Fund arb with ETH
        vm.deal(address(arb), 5 ether);

        // Execute giveLiquidity
        uint256 lpBefore = router.lpBalanceOf(address(arb));
        arb.giveLiquidity(4 ether);
        uint256 lpAfter = router.lpBalanceOf(address(arb));

        assertGt(lpAfter, lpBefore, "should receive LP tokens");
    }

    function test_TakeLiquidity() public {
        // Start with empty pool so all liquidity comes from giveLiquidity
        router.setPool(address(solid), 0, 0);

        // Fund arb and add liquidity
        vm.deal(address(arb), 5 ether);
        arb.giveLiquidity(4 ether);
        uint256 lp = router.lpBalanceOf(address(arb));
        assertGt(lp, 0, "should have LP tokens");

        // Now convert back — should end up with ETH, not Solid
        uint256 ethBefore = address(arb).balance;
        arb.takeLiquidity(lp);
        uint256 ethAfter = address(arb).balance;

        assertGt(ethAfter, ethBefore, "should receive ETH back");
        assertEq(router.lpBalanceOf(address(arb)), 0, "should burn all LP tokens");
    }

    function test_OnlyOwnerGiveLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.giveLiquidity(1 ether);
    }

    function test_OnlyOwnerTakeLiquidity() public {
        vm.prank(address(0xdead));
        vm.expectRevert(UniSolid.Unauthorized.selector);
        arb.takeLiquidity(1 ether);
    }

    function _captureEthIn() internal view returns (uint256 eth) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == UniSolid.Arb.selector) {
                (, eth,) = abi.decode(logs[i].data, (uint8, uint256, uint256));
                return eth;
            }
        }
        revert("Arb event not found");
    }

    function _assertOptimal(uint256 eth, uint256 optProfit, uint256 S, uint256 E, uint256 T, uint256 W, bool dirA)
        internal
        view
    {
        // Sweep a fine grid: the optimal should beat every sample point
        uint256[] memory trials = new uint256[](10);
        trials[0] = eth > 0 ? eth - 1 : 0;
        trials[1] = eth + 1;
        trials[2] = eth * 95 / 100;
        trials[3] = eth * 105 / 100;
        trials[4] = eth * 80 / 100;
        trials[5] = eth * 120 / 100;
        trials[6] = eth * 50 / 100;
        trials[7] = eth * 150 / 100;
        trials[8] = eth * 200 / 100;
        trials[9] = eth * 10 / 100;

        for (uint256 i = 0; i < trials.length; i++) {
            if (trials[i] == 0 || trials[i] == eth) continue;
            uint256 alt = dirA ? harness.profitA(trials[i], S, E, T, W) : harness.profitB(trials[i], S, E, T, W);
            assertGe(optProfit, alt, "optimal eth should beat perturbed amount");
        }

        // Cross-check: verify eth matches the closed-form formula independently
        // (see OPTIMAL.md for derivation)
        // dirA: x* = (sqrt(997_000*S*E*W*T) - 1000*E*T) / (1000*T + 997*S)
        // dirB: x* = (sqrt(997_000*S*E*W*T) - 1000*S*W) / (997*S + 997*T)
        uint256 expected;
        uint256 sqrtProduct = Math.sqrt(997_000 * S * E) * Math.sqrt(W * T);
        if (dirA) {
            uint256 cross = E * T * 1000;
            if (sqrtProduct > cross) expected = (sqrtProduct - cross) / (T * 1000 + 997 * S);
        } else {
            uint256 cross = S * W * 1000;
            if (sqrtProduct > cross) expected = (sqrtProduct - cross) / (997 * S + 997 * T);
        }
        assertEq(eth, expected, "eth should match closed-form optimal");
    }

    function test_OptimalAmount_SolidToUniswap() public {
        // Solid cheap, Uniswap expensive
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);

        vm.deal(address(arb), 10 ether);

        // Read pre-trade reserves
        (uint256 S, uint256 E) = solid.pool();
        uint256 T = router.reserveToken();
        uint256 W = router.reserveETH();

        // Execute and capture eth
        vm.recordLogs();
        arb.performUpkeep("");
        uint256 eth = _captureEthIn();

        assertTrue(eth > 0, "should have positive eth");
        uint256 optProfit = harness.profitA(eth, S, E, T, W);
        assertTrue(optProfit > 0, "should have positive profit");

        _assertOptimal(eth, optProfit, S, E, T, W, true);
        console.log("Direction A optimal eth:", eth);
        console.log("Direction A optimal profit:", optProfit);
    }

    function test_OptimalAmount_UniswapToSolid() public {
        // Solid expensive, Uniswap cheap
        vm.deal(address(this), 10 ether);
        solid.buy{value: 10 ether}();

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), solid.balanceOf(address(this)));
        vm.deal(address(router), 1 ether);
        router.setPool(address(solid), 1 ether, 100_000_000 ether);

        vm.deal(address(solid), 5 ether);
        vm.deal(address(arb), 10 ether);

        // Read pre-trade reserves
        (uint256 S, uint256 E) = solid.pool();
        uint256 T = router.reserveToken();
        uint256 W = router.reserveETH();

        // Execute and capture eth
        vm.recordLogs();
        arb.performUpkeep("");
        uint256 eth = _captureEthIn();

        assertTrue(eth > 0, "should have positive eth");
        uint256 optProfit = harness.profitB(eth, S, E, T, W);
        assertTrue(optProfit > 0, "should have positive profit");

        _assertOptimal(eth, optProfit, S, E, T, W, false);
        console.log("Direction B optimal eth:", eth);
        console.log("Direction B optimal profit:", optProfit);
    }

    // ---- LINK top-off tests ----

    function _linkProto(uint256 linkMin, uint256 linkEth) internal returns (UniSolid) {
        return new UniSolid(
            IAddressLookup(address(new AddressLookupMock(address(router)))),
            IAddressLookup(address(new AddressLookupMock(address(link)))),
            0,
            linkMin,
            linkEth
        );
    }

    function _setupArb() internal {
        // Solid cheap, Uniswap expensive
        vm.deal(address(router), 10 ether);
        router.setPool(address(solid), 10 ether, 1_000_000 ether);

        vm.deal(address(this), 1 ether);
        uint256 tokens = solid.buy{value: 1 ether}();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        solid.transfer(address(router), tokens);
    }

    function _setupLinkPool(uint256 ethReserve, uint256 tokenReserve) internal {
        link.mint(address(router), tokenReserve);
        vm.deal(address(router), address(router).balance + ethReserve);
        router.setPool(address(link), ethReserve, tokenReserve);
        // Restore primary token for pair interface
        router.setPool(address(solid), router.poolETH(address(solid)), router.poolToken(address(solid)));
    }

    function test_LinkTopOff() public {
        _setupArb();
        _setupLinkPool(10 ether, 10_000 ether);

        UniSolid linkProto = _linkProto(100 ether, 0.01 ether);
        UniSolid linkArb = linkProto.make(solid);
        vm.deal(address(linkArb), 1 ether);

        // LINK balance is 0, below LINK_MIN — performUpkeep should arb and top off
        assertEq(link.balanceOf(address(linkArb)), 0);
        linkArb.performUpkeep("");
        assertGt(link.balanceOf(address(linkArb)), 0, "should have acquired LINK");
    }

    function test_LinkTopOffSkipsWhenAboveMin() public {
        _setupArb();
        _setupLinkPool(10 ether, 10_000 ether);

        UniSolid linkProto = _linkProto(100 ether, 0.01 ether);
        UniSolid linkArb = linkProto.make(solid);
        vm.deal(address(linkArb), 1 ether);

        // Pre-fund with enough LINK
        link.mint(address(linkArb), 200 ether);
        uint256 linkBefore = link.balanceOf(address(linkArb));

        linkArb.performUpkeep("");
        assertEq(link.balanceOf(address(linkArb)), linkBefore, "should not buy more LINK");
    }

    function test_LinkBootstrap() public {
        // Deploy with LINK top-off enabled, no initial LINK balance
        _setupArb();
        _setupLinkPool(10 ether, 10_000 ether);

        UniSolid linkProto = _linkProto(100 ether, 0.01 ether);
        UniSolid linkArb = linkProto.make(solid);

        // Bootstrap: just send ETH, then performUpkeep should arb + acquire LINK
        vm.deal(address(linkArb), 1 ether);
        assertEq(link.balanceOf(address(linkArb)), 0, "no LINK before bootstrap");

        uint256 ethBefore = address(linkArb).balance;
        linkArb.performUpkeep("");
        assertGt(address(linkArb).balance, ethBefore - 1 ether, "should still have ETH after arb");
        assertGt(link.balanceOf(address(linkArb)), 0, "should have LINK after bootstrap");
    }

    function test_ConstructorRevertsIfNoLink() public {
        AddressLookupMock routerLookup_ = new AddressLookupMock(address(router));
        AddressLookupMock zeroLookup = new AddressLookupMock(address(0));
        vm.expectRevert(UniSolid.NoLink.selector);
        new UniSolid(IAddressLookup(address(routerLookup_)), IAddressLookup(address(zeroLookup)), 0, 0, 0);
    }

    receive() external payable {}
}
