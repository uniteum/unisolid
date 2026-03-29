// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutomation} from "iautomation/iautomation.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IUniswapV2Router} from "./IUniswapV2.sol";

/**
 * @notice Arbitrage bot between Solid AMM and Uniswap V2.
 *
 * Implements Chainlink Automation to detect and execute price discrepancies
 * between a Solid token's built-in AMM and a Uniswap V2 pair for the same token.
 *
 * Two arbitrage directions:
 *   A) Solid cheap:   buy on Solid (ETH → token), sell on Uniswap (token → ETH)
 *   B) Uniswap cheap: buy on Uniswap (ETH → token), sell on Solid (token → ETH)
 */
contract UniSolid is IAutomation {
    address public owner;

    /**
     * @notice Parameters for a single arbitrage opportunity
     * @param solid The Solid token to arbitrage
     * @param router The Uniswap V2 router
     * @param ethIn Amount of ETH to trade
     * @param minProfit Minimum profit in ETH to execute
     */
    struct Params {
        ISolid solid;
        IUniswapV2Router router;
        uint256 ethIn;
        uint256 minProfit;
    }

    /**
     * @notice Direction of the arbitrage
     */
    enum Direction {
        None,
        SolidToUniswap,
        UniswapToSolid
    }

    event Arb(ISolid indexed solid, Direction direction, uint256 ethIn, uint256 profit);

    error NotOwner();
    error NoProfitableArb();
    error InsufficientBalance();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    /**
     * @notice Check whether a profitable arbitrage exists
     * @dev checkData encodes a Params struct. The keeper calls this off-chain
     *      to determine if performUpkeep should fire.
     * @param checkData ABI-encoded Params (solid, router, ethIn, minProfit)
     * @return upkeepNeeded True if a profitable arb exists
     * @return performData ABI-encoded (Params, Direction) for execution
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Params memory p = abi.decode(checkData, (Params));
        if (address(this).balance < p.ethIn) return (false, "");

        (Direction dir, uint256 profit) = _quote(p);
        if (dir == Direction.None || profit < p.minProfit) return (false, "");

        return (true, abi.encode(p, dir));
    }

    /**
     * @notice Execute the arbitrage
     * @dev Re-validates profitability on-chain before executing.
     *      Anyone can call this (per Chainlink Automation spec), but the
     *      on-chain profit check prevents griefing.
     * @param performData ABI-encoded (Params, Direction) from checkUpkeep
     */
    function performUpkeep(bytes calldata performData) external override {
        (Params memory p, Direction dir) = abi.decode(performData, (Params, Direction));
        if (address(this).balance < p.ethIn) revert InsufficientBalance();

        (, uint256 profit) = _quote(p);
        if (profit < p.minProfit) revert NoProfitableArb();

        if (dir == Direction.SolidToUniswap) {
            _arbSolidToUniswap(p);
        } else {
            _arbUniswapToSolid(p);
        }

        emit Arb(p.solid, dir, p.ethIn, profit);
    }

    /**
     * @notice Quote both arbitrage directions and return the profitable one
     * @param p Arbitrage parameters
     * @return dir The profitable direction (None if neither)
     * @return profit Net ETH profit
     */
    function _quote(Params memory p) internal view returns (Direction dir, uint256 profit) {
        uint256 profitA = _quoteSolidToUniswap(p);
        uint256 profitB = _quoteUniswapToSolid(p);

        if (profitA > profitB && profitA > 0) {
            return (Direction.SolidToUniswap, profitA);
        } else if (profitB > 0) {
            return (Direction.UniswapToSolid, profitB);
        }
        return (Direction.None, 0);
    }

    /**
     * @notice Quote: buy on Solid, sell on Uniswap
     * @return profit Net ETH gain (0 if unprofitable)
     */
    function _quoteSolidToUniswap(Params memory p) internal view returns (uint256 profit) {
        uint256 tokensOut = p.solid.buys(p.ethIn);
        if (tokensOut == 0) return 0;

        address[] memory path = new address[](2);
        path[0] = address(p.solid);
        path[1] = p.router.WETH();

        try p.router.getAmountsOut(tokensOut, path) returns (uint256[] memory amounts) {
            uint256 ethBack = amounts[1];
            if (ethBack > p.ethIn) profit = ethBack - p.ethIn;
        } catch {}
    }

    /**
     * @notice Quote: buy on Uniswap, sell on Solid
     * @return profit Net ETH gain (0 if unprofitable)
     */
    function _quoteUniswapToSolid(Params memory p) internal view returns (uint256 profit) {
        address[] memory path = new address[](2);
        path[0] = p.router.WETH();
        path[1] = address(p.solid);

        try p.router.getAmountsOut(p.ethIn, path) returns (uint256[] memory amounts) {
            uint256 tokensOut = amounts[1];
            if (tokensOut == 0) return 0;

            uint256 ethBack = p.solid.sells(tokensOut);
            if (ethBack > p.ethIn) profit = ethBack - p.ethIn;
        } catch {}
    }

    /**
     * @notice Execute: buy on Solid (ETH → tokens), sell on Uniswap (tokens → ETH)
     */
    function _arbSolidToUniswap(Params memory p) internal {
        uint256 tokensOut = p.solid.buy{value: p.ethIn}();

        IERC20(address(p.solid)).approve(address(p.router), tokensOut);

        address[] memory path = new address[](2);
        path[0] = address(p.solid);
        path[1] = p.router.WETH();

        p.router.swapExactTokensForETH(tokensOut, p.ethIn, path, address(this), block.timestamp);
    }

    /**
     * @notice Execute: buy on Uniswap (ETH → tokens), sell on Solid (tokens → ETH)
     */
    function _arbUniswapToSolid(Params memory p) internal {
        address[] memory path = new address[](2);
        path[0] = p.router.WETH();
        path[1] = address(p.solid);

        uint256[] memory amounts =
            p.router.swapExactETHForTokens{value: p.ethIn}(0, path, address(this), block.timestamp);
        uint256 tokensOut = amounts[1];

        p.solid.sell(tokensOut);
    }

    /**
     * @notice Deposit ETH into the contract for arbitrage capital
     */
    function deposit() external payable onlyOwner {}

    /**
     * @notice Withdraw ETH from the contract
     * @param amount Amount of ETH to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        (bool ok,) = owner.call{value: amount}("");
        require(ok);
    }

    /**
     * @notice Recover ERC-20 tokens sent to this contract
     * @param token The token to recover
     * @param amount Amount to recover
     */
    function recover(IERC20 token, uint256 amount) external onlyOwner {
        require(token.transfer(owner, amount));
    }
}
