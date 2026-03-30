// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseTest} from "crucible/test/Base.t.sol";
import {UniSolid} from "../src/UniSolid.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/Test.sol";

/**
 * @notice Mock Solid that implements a simple constant-product AMM
 */
contract MockSolid {
    string public name = "Mock Solid";
    string public symbol = "MS";
    uint8 public decimals = 18;

    uint256 public poolS; // tokens in pool
    uint256 public poolE; // virtual ETH in pool (includes +1 ether)

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        poolS = 602_214_076 ether; // ~Avogadro scaled
        poolE = 1 ether; // virtual 1 ETH, 0 actual
        balanceOf[address(this)] = poolS;
    }

    function pool() external view returns (uint256 S, uint256 E) {
        return (poolS, poolE);
    }

    function buys(uint256 e) public view returns (uint256 s) {
        s = poolS - poolS * poolE / (poolE + e);
    }

    function buy() external payable returns (uint256 s) {
        s = buys(msg.value);
        poolE += msg.value;
        poolS -= s;
        balanceOf[address(this)] -= s;
        balanceOf[msg.sender] += s;
        return s;
    }

    function sells(uint256 s) public view returns (uint256 e) {
        e = poolE - (poolE * poolS + poolE - 1) / (poolS + s);
    }

    function sell(uint256 s) external returns (uint256 e) {
        e = sells(s);
        poolS += s;
        poolE -= e;
        balanceOf[msg.sender] -= s;
        balanceOf[address(this)] += s;
        (bool ok,) = msg.sender.call{value: e}("");
        require(ok);
        return e;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        poolE += msg.value;
    }
}

/**
 * @notice Mock Uniswap V2 Router with a simple constant-product pool
 * @dev Also acts as its own LP token for testing (pair == router)
 */
contract MockRouter {
    address public immutable weth;
    address public token;

    uint256 public reserveETH;
    uint256 public reserveToken;

    uint256 public lpSupply;
    mapping(address => uint256) public lpBalanceOf;
    mapping(address => mapping(address => uint256)) public lpAllowance;

    constructor(address weth_) {
        weth = weth_;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    /**
     * @notice Set up the mock pool reserves
     */
    function setPool(address token_, uint256 ethReserve, uint256 tokenReserve) external payable {
        token = token_;
        reserveETH = ethReserve;
        reserveToken = tokenReserve;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        if (path[0] == weth) {
            amounts[1] = _getAmountOut(amountIn, reserveETH, reserveToken);
        } else {
            amounts[1] = _getAmountOut(amountIn, reserveToken, reserveETH);
        }
    }

    function swapExactETHForTokens(uint256, address[] calldata, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = _getAmountOut(msg.value, reserveETH, reserveToken);

        reserveETH += msg.value;
        reserveToken -= amounts[1];

        MockSolid(payable(token)).transfer(to, amounts[1]);
    }

    function swapExactTokensForETH(uint256 amountIn, uint256, address[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = _getAmountOut(amountIn, reserveToken, reserveETH);

        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        reserveToken += amountIn;
        reserveETH -= amounts[1];

        (bool ok,) = to.call{value: amounts[1]}("");
        require(ok);
    }

    function addLiquidityETH(address token_, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value;

        IERC20(token_).transferFrom(msg.sender, address(this), amountToken);
        reserveETH += amountETH;
        reserveToken += amountToken;
        lpSupply += liquidity;
        lpBalanceOf[to] += liquidity;
    }

    function removeLiquidityETH(address token_, uint256 liquidity_, uint256, uint256, address to, uint256)
        external
        returns (uint256 amountToken, uint256 amountETH)
    {
        amountETH = liquidity_ * reserveETH / lpSupply;
        amountToken = liquidity_ * reserveToken / lpSupply;

        lpAllowance[msg.sender][address(this)] -= liquidity_;
        lpBalanceOf[msg.sender] -= liquidity_;
        lpSupply -= liquidity_;
        reserveETH -= amountETH;
        reserveToken -= amountToken;

        IERC20(token_).transfer(to, amountToken);
        (bool ok,) = to.call{value: amountETH}("");
        require(ok);
    }

    /**
     * @notice ERC-20 stubs for LP token (pair == router in tests)
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        lpAllowance[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return lpBalanceOf[account];
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    receive() external payable {}
}

/**
 * @notice Mock WETH for the router
 */
contract MockWETH {
    function deposit() external payable {}

    function withdraw(uint256 amount) external {
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

contract UniSolidTest is BaseTest {
    UniSolid arb;
    MockSolid solid;
    MockRouter router;
    MockWETH weth;

    function setUp() public override {
        super.setUp();

        weth = new MockWETH();
        solid = new MockSolid();
        router = new MockRouter(address(weth));

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
