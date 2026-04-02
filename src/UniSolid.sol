// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutomation} from "iautomation/iautomation.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {Clones} from "clones/Clones.sol";
import {Math} from "math/Math.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);
}

/**
 * @notice Arbitrage bot between Solid AMM and Uniswap V2.
 *
 * Implements Chainlink Automation to detect and execute price discrepancies
 * between a Solid token's built-in AMM and a Uniswap V2 pair for the same token.
 *
 * The factory (PROTO) is Bitsy — permissionless, deterministic, cloned.
 * Each clone targets a single (owner, Solid) pair and stores the Solid
 * address and Uniswap pair on-chain, avoiding repeated factory lookups.
 *
 * Two arbitrage directions:
 *   A) Solid cheap:   buy on Solid (ETH → token), sell on Uniswap (token → ETH)
 *   B) Uniswap cheap: buy on Uniswap (ETH → token), sell on Solid (token → ETH)
 *
 * The optimal trade size is computed via closed-form formula from both pools'
 * reserves, maximizing net ETH profit.
 */
contract UniSolid is IAutomation {
    UniSolid public immutable PROTO = this;
    IUniswapV2Router01 public immutable ROUTER;
    IUniswapV2Factory public immutable FACTORY;
    address public immutable WETH;

    address public owner;
    ISolid public solid;
    address public pair;

    /**
     * @notice Parameters for a single arbitrage opportunity
     * @param minProfit Minimum profit in ETH to execute
     * @param maxEthIn Cap on ETH trade size (limits exposure)
     */
    struct Params {
        uint256 minProfit;
        uint256 maxEthIn;
    }

    /**
     * @notice Direction of the arbitrage
     */
    enum Direction {
        None,
        SolidToUniswap,
        UniswapToSolid
    }

    event Make(UniSolid indexed clone, address indexed owner, ISolid indexed solid);
    event Arb(ISolid indexed solid, Direction direction, uint256 ethIn, uint256 profit);

    error Unauthorized();
    error NoProfitableArb();
    error InsufficientBalance();
    error NoPair();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    constructor(IAddressLookup routerLookup) {
        ROUTER = IUniswapV2Router01(routerLookup.value());
        FACTORY = IUniswapV2Factory(ROUTER.factory());
        WETH = ROUTER.WETH();
    }

    receive() external payable {}

    // ---- Automation ----

    /**
     * @notice Check whether a profitable arbitrage exists
     * @dev checkData encodes a Params struct. The keeper calls this off-chain
     *      to determine if performUpkeep should fire.
     *      Computes the optimal trade size from both pools' reserves.
     * @param checkData ABI-encoded Params (minProfit, maxEthIn)
     * @return upkeepNeeded True if a profitable arb exists
     * @return performData ABI-encoded (Direction, ethIn) for execution
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Params memory p = abi.decode(checkData, (Params));

        (Direction dir, uint256 ethIn, uint256 profit) = _quote(p);
        if (dir == Direction.None || profit < p.minProfit) return (false, "");
        if (address(this).balance < ethIn) return (false, "");

        return (true, abi.encode(p, dir, ethIn));
    }

    /**
     * @notice Execute the arbitrage
     * @dev Re-validates profitability on-chain before executing.
     *      Anyone can call this (per Chainlink Automation spec), but the
     *      on-chain profit check prevents griefing.
     * @param performData ABI-encoded (Params, Direction, ethIn) from checkUpkeep
     */
    function performUpkeep(bytes calldata performData) external override {
        (Params memory p, Direction dir, uint256 ethIn) = abi.decode(performData, (Params, Direction, uint256));
        if (address(this).balance < ethIn) revert InsufficientBalance();

        // Re-validate on-chain
        (,, uint256 profit) = _quote(p);
        if (profit < p.minProfit) revert NoProfitableArb();

        if (dir == Direction.SolidToUniswap) {
            _arbSolidToUniswap(ethIn);
        } else {
            _arbUniswapToSolid(ethIn);
        }

        emit Arb(solid, dir, ethIn, profit);
    }

    /**
     * @notice Compute the optimal trade size and direction
     * @param p Arbitrage parameters
     * @return dir The profitable direction (None if neither)
     * @return ethIn Optimal ETH trade size
     * @return profit Net ETH profit at optimal size
     */
    function _quote(Params memory p) internal view returns (Direction dir, uint256 ethIn, uint256 profit) {
        // Solid reserves
        (uint256 S, uint256 E) = solid.pool();

        // Uniswap reserves
        (uint256 T, uint256 W) = _uniswapReserves();

        // Direction A: Solid cheap → buy Solid, sell on Uniswap
        // Optimal x = (sqrt(997_000 * S * W * E * T) - E * T * 1000) / (T * 1000 + 997 * S)
        // Split sqrt to avoid overflow: sqrt(997_000 * S * E) * sqrt(W * T)
        uint256 ethInA;
        uint256 profitA;
        {
            uint256 sqrtSE = Math.sqrt(997_000 * S * E);
            uint256 sqrtWT = Math.sqrt(W * T);
            uint256 et1000 = E * T * 1000;
            if (sqrtSE * sqrtWT > et1000) {
                uint256 num = sqrtSE * sqrtWT - et1000;
                uint256 den = T * 1000 + 997 * S;
                ethInA = num / den;
                if (ethInA > p.maxEthIn) ethInA = p.maxEthIn;
                if (ethInA > 0) {
                    profitA = _profitSolidToUniswap(ethInA, S, E, T, W);
                }
            }
        }

        // Direction B: Uniswap cheap → buy on Uniswap, sell on Solid
        // Optimal x = (sqrt(997_000 * T * E * W * S) - W * S * 1000) / (S * 1000 + 997 * T)
        // Split sqrt: sqrt(997_000 * T * W) * sqrt(E * S)
        uint256 ethInB;
        uint256 profitB;
        {
            uint256 sqrtTW = Math.sqrt(997_000 * T * W);
            uint256 sqrtES = Math.sqrt(E * S);
            uint256 ws1000 = W * S * 1000;
            if (sqrtTW * sqrtES > ws1000) {
                uint256 num = sqrtTW * sqrtES - ws1000;
                uint256 den = S * 1000 + 997 * T;
                ethInB = num / den;
                if (ethInB > p.maxEthIn) ethInB = p.maxEthIn;
                if (ethInB > 0) {
                    profitB = _profitUniswapToSolid(ethInB, S, E, T, W);
                }
            }
        }

        if (profitA > profitB && profitA > 0) {
            return (Direction.SolidToUniswap, ethInA, profitA);
        } else if (profitB > 0) {
            return (Direction.UniswapToSolid, ethInB, profitB);
        }
        return (Direction.None, 0, 0);
    }

    /**
     * @notice Compute profit for Direction A: buy on Solid, sell on Uniswap
     */
    function _profitSolidToUniswap(uint256 x, uint256 S, uint256 E, uint256 T, uint256 W)
        internal
        pure
        returns (uint256)
    {
        // Tokens from Solid: S * x / (E + x)
        uint256 tokens = (S * x) / (E + x);
        if (tokens == 0) return 0;

        // ETH from Uniswap (0.3% fee): W * 997 * tokens / (T * 1000 + 997 * tokens)
        uint256 ethBack = (W * 997 * tokens) / (T * 1000 + 997 * tokens);
        if (ethBack > x) return ethBack - x;
        return 0;
    }

    /**
     * @notice Compute profit for Direction B: buy on Uniswap, sell on Solid
     */
    function _profitUniswapToSolid(uint256 x, uint256 S, uint256 E, uint256 T, uint256 W)
        internal
        pure
        returns (uint256)
    {
        // Tokens from Uniswap (0.3% fee): T * 997 * x / (W * 1000 + 997 * x)
        uint256 tokens = (T * 997 * x) / (W * 1000 + 997 * x);
        if (tokens == 0) return 0;

        // ETH from Solid: E * tokens / (S + tokens)
        uint256 ethBack = (E * tokens) / (S + tokens);
        if (ethBack > x) return ethBack - x;
        return 0;
    }

    /**
     * @notice Get Uniswap V2 pair reserves ordered as (token, WETH)
     */
    function _uniswapReserves() internal view returns (uint256 tokenReserve, uint256 wethReserve) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        if (IUniswapV2Pair(pair).token0() == address(solid)) {
            tokenReserve = r0;
            wethReserve = r1;
        } else {
            tokenReserve = r1;
            wethReserve = r0;
        }
    }

    /**
     * @notice Execute: buy on Solid (ETH → tokens), sell on Uniswap (tokens → ETH)
     */
    function _arbSolidToUniswap(uint256 ethIn) internal {
        uint256 tokensOut = solid.buy{value: ethIn}();

        IERC20(address(solid)).approve(address(ROUTER), tokensOut);

        address[] memory path = new address[](2);
        path[0] = address(solid);
        path[1] = WETH;

        ROUTER.swapExactTokensForETH(tokensOut, ethIn, path, address(this), block.timestamp);
    }

    /**
     * @notice Execute: buy on Uniswap (ETH → tokens), sell on Solid (tokens → ETH)
     */
    function _arbUniswapToSolid(uint256 ethIn) internal {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(solid);

        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: ethIn}(0, path, address(this), block.timestamp);
        uint256 tokensOut = amounts[1];

        solid.sell(tokensOut);
    }

    // ---- Owner operations (not Bitsy) ----

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

    /**
     * @notice Add liquidity to the Uniswap V2 ETH/Solid pair
     * @dev LP tokens are held by this contract. Use recover() to extract them if needed.
     * @param amountTokenDesired Maximum tokens to deposit
     * @param amountTokenMin Minimum tokens to deposit (slippage)
     * @param amountEthMin Minimum ETH to deposit (slippage)
     * @return amountToken Actual tokens deposited
     * @return amountEth Actual ETH deposited
     * @return liquidity LP tokens received
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function addLiquidityETH(uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountEthMin)
        external
        payable
        onlyOwner
        returns (uint256 amountToken, uint256 amountEth, uint256 liquidity)
    {
        IERC20(address(solid)).approve(address(ROUTER), amountTokenDesired);
        (amountToken, amountEth, liquidity) = ROUTER.addLiquidityETH{value: msg.value}(
            address(solid), amountTokenDesired, amountTokenMin, amountEthMin, address(this), block.timestamp
        );
    }

    /**
     * @notice Remove liquidity from the Uniswap V2 ETH/Solid pair
     * @param liquidity Amount of LP tokens to burn
     * @param amountTokenMin Minimum tokens to receive (slippage)
     * @param amountEthMin Minimum ETH to receive (slippage)
     * @return amountToken Tokens received
     * @return amountEth ETH received
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function removeLiquidityETH(uint256 liquidity, uint256 amountTokenMin, uint256 amountEthMin)
        external
        onlyOwner
        returns (uint256 amountToken, uint256 amountEth)
    {
        IERC20(pair).approve(address(ROUTER), liquidity);
        (amountToken, amountEth) = ROUTER.removeLiquidityETH(
            address(solid), liquidity, amountTokenMin, amountEthMin, address(this), block.timestamp
        );
    }

    // ---- Factory (Bitsy) ----

    /**
     * @notice Predict the deterministic address for an (owner, solid) clone.
     * @param owner_ The owner of the clone
     * @param solid_ The Solid token the clone targets
     * @return exists True if the clone is already deployed
     * @return home The deterministic clone address
     * @return salt The CREATE2 salt
     */
    function made(address owner_, ISolid solid_) public view returns (bool exists, address home, bytes32 salt) {
        salt = keccak256(abi.encode(owner_, solid_));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a deterministic clone for the caller targeting a Solid token.
     *         Idempotent — returns the existing clone if already deployed.
     *         Reverts if the Uniswap pair does not exist.
     * @param solid_ The Solid token to arbitrage
     * @return clone The deployed (or existing) clone
     */
    function make(ISolid solid_) external returns (UniSolid clone) {
        if (this != PROTO) {
            clone = PROTO.make(solid_);
        } else {
            (bool exists, address home, bytes32 salt) = made(msg.sender, solid_);
            clone = UniSolid(payable(home));
            if (!exists) {
                home = Clones.cloneDeterministic(address(PROTO), salt, 0);
                UniSolid(payable(home)).zzInit(msg.sender, solid_);
                emit Make(clone, msg.sender, solid_);
            }
        }
    }

    /**
     * @notice Initializer called by PROTO on a freshly deployed clone.
     * @param owner_ The owner of the clone
     * @param solid_ The Solid token
     */
    function zzInit(address owner_, ISolid solid_) public {
        if (msg.sender != address(PROTO)) revert Unauthorized();
        address pair_ = FACTORY.getPair(address(solid_), WETH);
        if (pair_ == address(0)) revert NoPair();
        owner = owner_;
        solid = solid_;
        pair = pair_;
    }
}
