// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutomation} from "iautomation/iautomation.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IUniswapV2Factory} from "iuniswap/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "iuniswap/IUniswapV2Pair.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {Clones} from "clones/Clones.sol";
import {Math} from "math/Math.sol";

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
    uint256 public immutable GAS_MARGIN;

    address public owner;
    ISolid public solid;
    address public pair;

    /**
     * @notice Direction of the arbitrage
     */
    enum Direction {
        None,
        SolidToUniswap,
        UniswapToSolid
    }

    event Make(UniSolid indexed clone, address indexed owner, ISolid indexed solid);
    event Arb(ISolid indexed solid, Direction direction, uint256 eth, uint256 profit);

    error Unauthorized();
    error NoProfitableArb();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    /**
     * @param routerLookup Lookup for Uniswap V2 router address
     * @param gasMargin Gas estimate × margin multiplier (e.g. 300_000 × 1.5 = 450_000)
     */
    constructor(IAddressLookup routerLookup, uint256 gasMargin) {
        ROUTER = IUniswapV2Router01(routerLookup.value());
        FACTORY = IUniswapV2Factory(ROUTER.factory());
        WETH = ROUTER.WETH();
        GAS_MARGIN = gasMargin;
    }

    receive() external payable {}

    // ---- Automation ----

    /**
     * @notice Check whether a profitable arbitrage exists
     * @dev The keeper calls this off-chain to determine if performUpkeep should fire.
     *      Computes the optimal trade size from both pools' reserves.
     * @return upkeepNeeded True if a profitable arb exists
     * @return performData Unused (empty); performUpkeep recomputes from on-chain state
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        (Direction dir,,) = _quote();
        return (dir != Direction.None, "");
    }

    /**
     * @notice Execute the arbitrage
     * @dev Computes direction and size from current on-chain state.
     *      Anyone can call this (per Chainlink Automation spec), but the
     *      on-chain profit check prevents griefing.
     */
    function performUpkeep(bytes calldata) external override {
        (Direction dir, uint256 eth, uint256 profit) = _quote();
        if (dir == Direction.None) {
            revert NoProfitableArb();
        } else if (dir == Direction.SolidToUniswap) {
            _arbSolidToUniswap(eth);
        } else {
            _arbUniswapToSolid(eth);
        }

        emit Arb(solid, dir, eth, profit);
    }

    /**
     * @notice Compute the optimal trade size and direction
     * @return dir The profitable direction (None if neither)
     * @return eth Optimal ETH trade size
     * @return profit Net ETH profit at optimal size
     */
    function _quote() internal view returns (Direction dir, uint256 eth, uint256 profit) {
        (uint256 S, uint256 E) = solid.pool();
        (uint256 T, uint256 W) = _uniswapReserves();

        // Compare price ratios to determine direction: S/E vs T/W → S*W vs T*E
        uint256 sw = S * W;
        uint256 te = T * E;
        if (sw == te) return (Direction.None, 0, 0);

        // Shared sqrt: sqrt(997_000 * S * E * W * T), split to avoid overflow
        uint256 sqrtProduct = Math.sqrt(997_000 * S * E) * Math.sqrt(W * T);

        uint256 balance = address(this).balance;

        if (sw > te) {
            // Direction A: Solid cheap → buy Solid, sell on Uniswap
            // Optimal x = (sqrtProduct - T*E*1000) / (T*1000 + 997*S)
            uint256 cross = te * 1000;
            if (sqrtProduct > cross) {
                eth = (sqrtProduct - cross) / (T * 1000 + 997 * S);
                if (eth > balance) eth = balance;
                if (eth > 0) {
                    profit = _profitSolidToUniswap(eth, S, E, T, W);
                    dir = Direction.SolidToUniswap;
                }
            }
        } else {
            // Direction B: Uniswap cheap → buy on Uniswap, sell on Solid
            // Optimal x = (sqrtProduct - S*W*1000) / (S*1000 + 997*T)
            uint256 cross = sw * 1000;
            if (sqrtProduct > cross) {
                eth = (sqrtProduct - cross) / (S * 1000 + 997 * T);
                if (eth > balance) eth = balance;
                if (eth > 0) {
                    profit = _profitUniswapToSolid(eth, S, E, T, W);
                    dir = Direction.UniswapToSolid;
                }
            }
        }

        if (profit < GAS_MARGIN * tx.gasprice) return (Direction.None, 0, 0);
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
    function _arbSolidToUniswap(uint256 eth) internal {
        uint256 tokensOut = solid.buy{value: eth}();

        IERC20(address(solid)).approve(address(ROUTER), tokensOut);

        address[] memory path = new address[](2);
        path[0] = address(solid);
        path[1] = WETH;

        ROUTER.swapExactTokensForETH(tokensOut, eth, path, address(this), block.timestamp);
    }

    /**
     * @notice Execute: buy on Uniswap (ETH → tokens), sell on Solid (tokens → ETH)
     */
    function _arbUniswapToSolid(uint256 eth) internal {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(solid);

        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: eth}(0, path, address(this), block.timestamp);
        uint256 tokensOut = amounts[1];

        solid.sell(tokensOut);
    }

    // ---- Liquidity ----

    /**
     * @notice Convert Solid tokens to Uniswap LP: sell half for ETH, add liquidity with the rest
     * @param n Amount of Solid tokens to convert (contract must hold at least this many)
     */
    function solidToUniswap(uint256 n) external onlyOwner {
        uint256 half = n / 2;
        uint256 ethReceived = solid.sell(half);
        uint256 remaining = n - half;
        IERC20(address(solid)).approve(address(ROUTER), remaining);
        ROUTER.addLiquidityETH{value: ethReceived}(address(solid), remaining, 0, 0, address(this), block.timestamp);
    }

    /**
     * @notice Convert Uniswap LP to Solid tokens: remove liquidity, buy Solid with the ETH portion
     * @param n Amount of LP tokens to convert (contract must hold at least this many)
     */
    function uniswapToSolid(uint256 n) external onlyOwner {
        IERC20(pair).approve(address(ROUTER), n);

        // forge-lint: disable-next-line(mixed-case-variable)
        (, uint256 amountETH) = ROUTER.removeLiquidityETH(address(solid), n, 0, 0, address(this), block.timestamp);

        solid.buy{value: amountETH}();
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
        if (pair_ == address(0)) pair_ = FACTORY.createPair(address(solid_), WETH);
        owner = owner_;
        solid = solid_;
        pair = pair_;
    }
}
