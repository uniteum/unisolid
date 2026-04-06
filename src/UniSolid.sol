// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutomation} from "iautomation/iautomation.sol";
import {IAutomationRegistrar} from "iautomation/IAutomationRegistrar.sol";
import {IAutomationRegistry} from "iautomation/IAutomationRegistry.sol";
import {ISolid} from "isolid/ISolid.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IUniswapV2Router01} from "iuniswap/IUniswapV2Router01.sol";
import {IUniswapV2Factory} from "iuniswap/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "iuniswap/IUniswapV2Pair.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {Clones} from "clones/Clones.sol";
import {Math} from "math/Math.sol";
import {Ownable} from "ownable/Ownable.sol";

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
contract UniSolid is IAutomation, Ownable {
    UniSolid public immutable PROTO = this;
    IUniswapV2Router01 public immutable ROUTER;
    address public immutable WETH;
    IAutomationRegistrar public immutable REGISTRAR;
    uint256 public immutable GAS_MARGIN;
    uint256 public immutable LINK_MIN;
    uint256 public immutable LINK_ETH;

    ISolid public solid;
    address public pair;
    uint256 public upkeepId;
    address public forwarder;

    /**
     * @notice Direction of the arbitrage
     */
    enum Direction {
        None,
        SolidToUniswap,
        UniswapToSolid
    }

    event Make(UniSolid indexed clone, address indexed owner, ISolid indexed solid);
    event Swap(ISolid indexed solid, Direction direction, uint256 eth, uint256 profit);

    error NoProfitableSwap();
    error NotForwarder();

    /**
     * @param routerLookup Lookup for Uniswap V2 router address
     * @param registrarLookup Lookup for chain-local Chainlink Automation registrar address
     * @param gasMargin Gas estimate × margin multiplier (e.g. 300_000 × 1.5 = 450_000)
     * @param linkMin Minimum LINK balance before top-off triggers
     * @param linkEth Amount of ETH to spend topping off LINK
     */
    constructor(
        IAddressLookup routerLookup,
        IAddressLookup registrarLookup,
        uint256 gasMargin,
        uint256 linkMin,
        uint256 linkEth
    ) Ownable(address(this)) {
        ROUTER = IUniswapV2Router01(routerLookup.value());
        WETH = ROUTER.WETH();
        REGISTRAR = IAutomationRegistrar(registrarLookup.value());
        GAS_MARGIN = gasMargin;
        LINK_MIN = linkMin;
        LINK_ETH = linkEth;
    }

    receive() external payable {
        if (address(this) == address(PROTO)) revert();
    }

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
        return (dir != Direction.None || _needsLink(), "");
    }

    /**
     * @notice Execute the arbitrage and top off LINK if needed
     * @dev Only callable by the Chainlink forwarder or the contract owner.
     *      LINK top-off runs regardless of arb profitability, enabling
     *      bootstrap by simply sending ETH to the contract.
     */
    function performUpkeep(bytes calldata) external override {
        if (msg.sender != forwarder && msg.sender != owner()) revert NotForwarder();
        bool topped = _topOffLink();

        (Direction dir, uint256 eth, uint256 profit) = _quote();
        if (dir == Direction.None) {
            if (!topped) revert NoProfitableSwap();
            return;
        }

        if (dir == Direction.SolidToUniswap) {
            _arbSolidToUniswap(eth);
        } else {
            _arbUniswapToSolid(eth);
        }

        emit Swap(solid, dir, eth, profit);
    }

    /**
     * @notice Check whether LINK balance is below minimum and top-off is possible
     */
    function _needsLink() internal view returns (bool) {
        return LINK().balanceOf(address(this)) < LINK_MIN && address(this).balance >= LINK_ETH;
    }

    /**
     * @notice Buy LINK from the router if balance is below minimum
     * @return topped True if LINK was purchased
     */
    function _topOffLink() internal returns (bool topped) {
        if (!_needsLink()) return false;

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = REGISTRAR.LINK();

        ROUTER.swapExactETHForTokens{value: LINK_ETH}(0, path, address(this), block.timestamp);
        return true;
    }

    uint256 constant UNI_FEE_NUM = 997;
    uint256 constant UNI_FEE_DEN = 1000;

    /**
     * @notice Compute the optimal trade size and direction (see OPTIMAL.md)
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

        // Fee-adjusted reserves (Uniswap 0.3% fee applied once here)
        uint256 fS = S * UNI_FEE_NUM / UNI_FEE_DEN;
        uint256 fT = T * UNI_FEE_NUM / UNI_FEE_DEN;

        uint256 balance = address(this).balance;
        uint256 root = Math.sqrt(W * fS) * Math.sqrt(E * T);

        if (sw > te) {
            // Direction A: Solid cheap → buy Solid, sell on Uniswap (see OPTIMAL.md)
            if (root > te) {
                eth = (root - te) / (T + fS);
                if (eth > balance) eth = balance;
                if (eth > 0) {
                    profit = _profitSolidToUniswap(eth, S, E, T, W);
                    dir = Direction.SolidToUniswap;
                }
            }
        } else {
            // Direction B: Uniswap cheap → buy on Uniswap, sell on Solid (see OPTIMAL.md)
            if (root > sw) {
                eth = (root - sw) / (fS + fT);
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
     * @notice Compute profit for Direction A: buy on Solid (no fee), sell on Uniswap (fee)
     */
    function _profitSolidToUniswap(uint256 e, uint256 S, uint256 E, uint256 T, uint256 W)
        internal
        pure
        returns (uint256)
    {
        uint256 tokens = _swap(e, E, S);
        if (tokens == 0) return 0;
        uint256 ethBack = _uniswap(tokens, T, W);
        if (ethBack > e) return ethBack - e;
        return 0;
    }

    /**
     * @notice Compute profit for Direction B: buy on Uniswap (fee), sell on Solid (no fee)
     */
    function _profitUniswapToSolid(uint256 e, uint256 S, uint256 E, uint256 T, uint256 W)
        internal
        pure
        returns (uint256)
    {
        uint256 tokens = _uniswap(e, W, T);
        if (tokens == 0) return 0;
        uint256 ethBack = _swap(tokens, S, E);
        if (ethBack > e) return ethBack - e;
        return 0;
    }

    /**
     * @notice Constant-product swap
     */
    function _swap(uint256 e, uint256 E, uint256 S) internal pure returns (uint256) {
        return S * e / (E + e);
    }

    /**
     * @notice Uniswap V2 swap with 0.3% fee applied to input
     */
    function _uniswap(uint256 e, uint256 T, uint256 W) internal pure returns (uint256) {
        return _swap(e * UNI_FEE_NUM / UNI_FEE_DEN, T, W);
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
     * @notice Add Uniswap LP using ETH: buy Solid with half, add liquidity with both halves
     * @param eth Amount of ETH to use (contract must hold at least this much)
     */
    function giveLiquidity(uint256 eth) external onlyOwner {
        uint256 half = eth / 2;
        uint256 tokens = solid.buy{value: half}();
        IERC20(address(solid)).approve(address(ROUTER), tokens);
        ROUTER.addLiquidityETH{value: eth - half}(address(solid), tokens, 0, 0, address(this), block.timestamp);
    }

    /**
     * @notice Remove Uniswap LP and convert back to ETH: remove liquidity, sell Solid tokens
     * @param n Amount of LP tokens to convert (contract must hold at least this many)
     */
    function takeLiquidity(uint256 n) external onlyOwner {
        IERC20(pair).approve(address(ROUTER), n);
        (uint256 amountToken,) = ROUTER.removeLiquidityETH(address(solid), n, 0, 0, address(this), block.timestamp);
        solid.sell(amountToken);
    }

    // ---- Views ----

    /**
     * @notice LINK token address from the Chainlink registrar
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function LINK() public view returns (IERC20) {
        return IERC20(REGISTRAR.LINK());
    }

    /**
     * @notice ETH balance of this contract
     */
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice LINK balance of this contract
     */
    function linkBalance() external view returns (uint256) {
        return LINK().balanceOf(address(this));
    }

    /**
     * @notice LP token balance of this contract for the Solid/WETH pair
     */
    function lpBalance() external view returns (uint256) {
        return IERC20(pair).balanceOf(address(this));
    }

    /**
     * @notice Total supply of the Solid/WETH LP token
     */
    function lpTotal() external view returns (uint256) {
        return IUniswapV2Pair(pair).totalSupply();
    }

    /**
     * @notice Uniswap pair reserves ordered as (token, WETH)
     */
    function uniswapReserves() external view returns (uint256 tokenReserve, uint256 wethReserve) {
        return _uniswapReserves();
    }

    /**
     * @notice Solid pool reserves (tokenSupply, ethReserve with virtual 1 ETH)
     */
    function solidReserves() external view returns (uint256 tokenSupply, uint256 ethReserve) {
        return solid.pool();
    }

    /**
     * @notice Current best arbitrage direction, optimal trade size, and expected profit
     */
    function quote() external view returns (Direction dir, uint256 eth, uint256 profit) {
        return _quote();
    }

    // ---- Keeper registration ----

    /**
     * @notice Register a Chainlink Automation upkeep for this clone
     * @param gasLimit Gas limit for performUpkeep execution
     * @param amount LINK to fund the upkeep (must be held by this contract)
     */
    function register(uint32 gasLimit, uint96 amount) external onlyOwner {
        IERC20 link = LINK();
        link.approve(address(REGISTRAR), amount);

        uint256 id = REGISTRAR.registerUpkeep(
            IAutomationRegistrar.RegistrationParams({
                name: "",
                encryptedEmail: "",
                upkeepContract: address(this),
                gasLimit: gasLimit,
                adminAddress: address(this),
                triggerType: 0,
                checkData: "",
                triggerConfig: "",
                offchainConfig: "",
                amount: amount
            })
        );

        (address registry,) = REGISTRAR.getConfig();
        forwarder = IAutomationRegistry(registry).getForwarder(id);
        upkeepId = id;
    }

    /**
     * @notice Cancel the upkeep and withdraw remaining LINK
     */
    function unregister() external onlyOwner {
        (address registry,) = REGISTRAR.getConfig();
        IAutomationRegistry(registry).cancelUpkeep(upkeepId);
        IAutomationRegistry(registry).withdrawFunds(upkeepId, address(this));
        upkeepId = 0;
        forwarder = address(0);
    }

    // ---- Owner operations (not Bitsy) ----

    /**
     * @notice Withdraw ETH from the contract
     * @param amount Amount of ETH to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        (bool ok,) = owner().call{value: amount}("");
        require(ok);
    }

    /**
     * @notice Recover ERC-20 tokens sent to this contract
     * @param token The token to recover
     * @param amount Amount to recover
     */
    function recover(IERC20 token, uint256 amount) external onlyOwner {
        require(token.transfer(owner(), amount));
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
        if (msg.sender != address(PROTO)) revert OwnableUnauthorizedAccount(msg.sender);
        IUniswapV2Factory f = IUniswapV2Factory(ROUTER.factory());
        address pair_ = f.getPair(address(solid_), WETH);
        if (pair_ == address(0)) pair_ = f.createPair(address(solid_), WETH);
        _transferOwnership(owner_);
        solid = solid_;
        pair = pair_;
    }
}
