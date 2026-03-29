// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @notice Minimal Uniswap V2 Router interface for arbitrage operations
 */
interface IUniswapV2Router {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

/**
 * @notice Minimal WETH interface for wrapping/unwrapping
 */
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
