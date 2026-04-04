// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "ierc20/IERC20.sol";

/**
 * @notice Mock Uniswap V2 Router + Factory + Pair for testing.
 * @dev Acts as router, factory, and pair all in one contract.
 *      Also acts as its own LP token (pair == router).
 *      Supports multiple token pools keyed by token address.
 */
contract UnswapV2Router01Mock {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable weth;
    address public token;

    mapping(address => uint256) public poolETH;
    mapping(address => uint256) public poolToken;

    uint256 public lpSupply;
    mapping(address => uint256) public lpBalanceOf;
    mapping(address => mapping(address => uint256)) public lpAllowance;

    constructor(address weth_) {
        weth = weth_;
    }

    // forge-lint: disable-next-line(screaming-snake-case-const)
    function WETH() external view returns (address) {
        return weth;
    }

    /**
     * @notice Primary pool reserves (backward compat)
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function reserveETH() external view returns (uint256) {
        return poolETH[token];
    }

    function reserveToken() external view returns (uint256) {
        return poolToken[token];
    }

    // ---- Factory interface ----

    function factory() external view returns (address) {
        return address(this);
    }

    function getPair(address tokenA, address) external view returns (address) {
        if (tokenA == token || tokenA == weth) return address(this);
        return address(0);
    }

    function createPair(address tokenA, address) external returns (address) {
        token = tokenA;
        return address(this);
    }

    // ---- Pair interface ----

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 ts) {
        ts = 0;
        // token0 is the lower address
        if (token < weth) {
            // casting to 'uint112' is safe because test reserves are set within uint112 range
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve0 = uint112(poolToken[token]);
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve1 = uint112(poolETH[token]);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve0 = uint112(poolETH[token]);
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve1 = uint112(poolToken[token]);
        }
    }

    function token0() external view returns (address) {
        return token < weth ? token : weth;
    }

    // ---- Router interface ----

    /**
     * @notice Set up a mock pool's reserves
     */
    function setPool(address token_, uint256 ethReserve, uint256 tokenReserve) external payable {
        token = token_;
        poolETH[token_] = ethReserve;
        poolToken[token_] = tokenReserve;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        address t = path[0] == weth ? path[1] : path[0];
        if (path[0] == weth) {
            amounts[1] = _getAmountOut(amountIn, poolETH[t], poolToken[t]);
        } else {
            amounts[1] = _getAmountOut(amountIn, poolToken[t], poolETH[t]);
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function swapExactETHForTokens(uint256, address[] calldata path, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        address t = path[1];
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = _getAmountOut(msg.value, poolETH[t], poolToken[t]);

        poolETH[t] += msg.value;
        poolToken[t] -= amounts[1];

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(t).transfer(to, amounts[1]);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function swapExactTokensForETH(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        address t = path[0];
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = _getAmountOut(amountIn, poolToken[t], poolETH[t]);

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(t).transferFrom(msg.sender, address(this), amountIn);
        poolToken[t] += amountIn;
        poolETH[t] -= amounts[1];

        (bool ok,) = to.call{value: amounts[1]}("");
        require(ok);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function addLiquidityETH(address token_, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (
            uint256 amountToken,
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 amountETH,
            uint256 liquidity
        )
    {
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value;

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token_).transferFrom(msg.sender, address(this), amountToken);
        poolETH[token_] += amountETH;
        poolToken[token_] += amountToken;
        lpSupply += liquidity;
        lpBalanceOf[to] += liquidity;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function removeLiquidityETH(address token_, uint256 liquidity_, uint256, uint256, address to, uint256)
        external
        returns (
            uint256 amountToken,
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 amountETH
        )
    {
        amountETH = (liquidity_ * poolETH[token_]) / lpSupply;
        amountToken = (liquidity_ * poolToken[token_]) / lpSupply;

        lpAllowance[msg.sender][address(this)] -= liquidity_;
        lpBalanceOf[msg.sender] -= liquidity_;
        lpSupply -= liquidity_;
        poolETH[token_] -= amountETH;
        poolToken[token_] -= amountToken;

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
