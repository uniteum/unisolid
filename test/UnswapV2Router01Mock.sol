// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "ierc20/IERC20.sol";

/**
 * @notice Mock Uniswap V2 Router with a simple constant-product pool
 * @dev Also acts as its own LP token for testing (pair == router)
 */
contract UnswapV2Router01Mock {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable weth;
    address public token;

    // forge-lint: disable-next-line(mixed-case-variable)
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

    // forge-lint: disable-next-line(mixed-case-function)
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

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transfer(to, amounts[1]);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function swapExactTokensForETH(uint256 amountIn, uint256, address[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = _getAmountOut(amountIn, reserveToken, reserveETH);

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        reserveToken += amountIn;
        reserveETH -= amounts[1];

        (bool ok,) = to.call{value: amounts[1]}("");
        require(ok);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function addLiquidityETH(address token_, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        // forge-lint: disable-next-line(mixed-case-variable)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value;

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token_).transferFrom(msg.sender, address(this), amountToken);
        reserveETH += amountETH;
        reserveToken += amountToken;
        lpSupply += liquidity;
        lpBalanceOf[to] += liquidity;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function removeLiquidityETH(address token_, uint256 liquidity_, uint256, uint256, address to, uint256)
        external
        // forge-lint: disable-next-line(mixed-case-variable)
        returns (uint256 amountToken, uint256 amountETH)
    {
        amountETH = liquidity_ * reserveETH / lpSupply;
        amountToken = liquidity_ * reserveToken / lpSupply;

        lpAllowance[msg.sender][address(this)] -= liquidity_;
        lpBalanceOf[msg.sender] -= liquidity_;
        lpSupply -= liquidity_;
        reserveETH -= amountETH;
        reserveToken -= amountToken;

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
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
