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
    uint256 constant GAS_MARGIN = 450_000;
    uint256 constant LINK_MIN = 1 ether;
    uint256 constant LINK_ETH = 0.01 ether;

    UniSolid public immutable PROTO = this;
    IUniswapV2Router01 public immutable ROUTER;
    address public immutable WETH;
    IAutomationRegistrar public immutable REGISTRAR;

    ISolid public solid;
    address public pair;
    uint256 public upkeepId;
    address public forwarder;
    uint256 public gasMargin;
    uint256 public linkMin;
    uint256 public linkEth;

    /**
     * @notice Direction of the arbitrage
     */
    enum Direction {
        None,
        ToUniswap,
        FromUniswap
    }

    event Make(UniSolid indexed clone, address indexed owner, ISolid indexed solid);
    event Swap(ISolid indexed solid, Direction direction, uint256 eth, uint256 profit);
    event TopOffLink(uint256 eth, uint256 link);
    event BuyFromUniswap(address indexed buyer, uint256 eth, uint256 tokens);
    event GiveLiquidity(uint256 amountToken, uint256 amountEth, uint256 liquidity);
    event TakeLiquidity(uint256 amountToken, uint256 amountEth, uint256 liquidity);
    event Register(uint256 upkeepId, address forwarder);
    event Unregister(uint256 upkeepId);
    event Withdraw(uint256 amount);
    event Recover(IERC20 indexed token, uint256 amount);
    event SetGasMargin(uint256 gasMargin);
    event SetLinkMin(uint256 linkMin);
    event SetLinkEth(uint256 linkEth);

    error NoProfitableSwap();
    error NotForwarder();
    error NotRegistered();
    error AlreadyRegistered();

    /**
     * @param routerLookup Lookup for Uniswap V2 router address
     * @param registrarLookup Lookup for chain-local Chainlink Automation registrar address
     */
    constructor(IAddressLookup routerLookup, IAddressLookup registrarLookup) Ownable(address(this)) {
        ROUTER = IUniswapV2Router01(routerLookup.value());
        WETH = ROUTER.WETH();
        REGISTRAR = IAutomationRegistrar(registrarLookup.value());
        gasMargin = GAS_MARGIN;
        linkMin = LINK_MIN;
        linkEth = LINK_ETH;
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
        return (dir != Direction.None || needsLink(), "");
    }

    /**
     * @notice Execute the arbitrage and top off LINK if needed
     * @dev Only callable by the Chainlink forwarder or the contract owner.
     *      LINK top-off runs regardless of arb profitability, enabling
     *      bootstrap by simply sending ETH to the contract.
     */
    function performUpkeep(bytes calldata) external override {
        if (msg.sender != forwarder && msg.sender != owner()) revert NotForwarder();
        bool topped = topOffLink();

        (Direction dir, uint256 eth, uint256 profit) = _quote();
        if (dir == Direction.None) {
            if (!topped) revert NoProfitableSwap();
            return;
        }

        if (dir == Direction.ToUniswap) {
            _arbToUniswap(eth);
        } else {
            _arbFromUniswap(eth);
        }

        emit Swap(solid, dir, eth, profit);
    }

    /**
     * @notice Check whether upkeep LINK balance is below minimum and top-off is possible
     */
    function needsLink() public view returns (bool) {
        if (forwarder == address(0) || address(this).balance < linkEth) return false;
        (address registry,) = REGISTRAR.getConfig();
        return IAutomationRegistry(registry).getBalance(upkeepId) < linkMin;
    }

    /**
     * @notice Buy LINK and add it to the upkeep if balance is below minimum
     * @return topped True if LINK was added
     */
    function topOffLink() public returns (bool topped) {
        if (!needsLink()) return false;

        uint96 amount = _buyLink();
        (address registry,) = REGISTRAR.getConfig();
        IERC20 link = LINK();
        link.approve(registry, amount);
        IAutomationRegistry(registry).addFunds(upkeepId, amount);
        emit TopOffLink(linkEth, amount);
        return true;
    }

    /**
     * @notice Buy LINK from the router with linkEth worth of ETH
     * @return amount The amount of LINK purchased
     */
    function _buyLink() internal returns (uint96 amount) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = REGISTRAR.LINK();

        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: linkEth}(0, path, address(this), block.timestamp);
        amount = uint96(amounts[1]);
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
                    profit = _profitToUniswap(eth, S, E, T, W);
                    dir = Direction.ToUniswap;
                }
            }
        } else {
            // Direction B: Uniswap cheap → buy on Uniswap, sell on Solid (see OPTIMAL.md)
            if (root > sw) {
                eth = (root - sw) / (fS + fT);
                if (eth > balance) eth = balance;
                if (eth > 0) {
                    profit = _profitFromUniswap(eth, S, E, T, W);
                    dir = Direction.FromUniswap;
                }
            }
        }

        if (profit < gasMargin * tx.gasprice) return (Direction.None, 0, 0);
    }

    /**
     * @notice Compute profit for Direction A: buy on Solid (no fee), sell on Uniswap (fee)
     */
    function _profitToUniswap(uint256 e, uint256 S, uint256 E, uint256 T, uint256 W) internal pure returns (uint256) {
        uint256 tokens = _swap(e, E, S);
        if (tokens == 0) return 0;
        uint256 ethBack = _uniswap(tokens, T, W);
        if (ethBack > e) return ethBack - e;
        return 0;
    }

    /**
     * @notice Compute profit for Direction B: buy on Uniswap (fee), sell on Solid (no fee)
     */
    function _profitFromUniswap(uint256 e, uint256 S, uint256 E, uint256 T, uint256 W) internal pure returns (uint256) {
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
    function _arbToUniswap(uint256 eth) internal {
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
    function _arbFromUniswap(uint256 eth) internal {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(solid);

        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: eth}(0, path, address(this), block.timestamp);
        uint256 tokensOut = amounts[1];

        solid.sell(tokensOut);
    }

    // ---- Buy ----

    /**
     * @notice Buy this clone's Solid token on Uniswap V2 with ETH
     * @dev Callable by anyone. Tokens are sent directly to the caller.
     */
    function buyFromUniswap() external payable returns (uint256 tokens) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(solid);
        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: msg.value}(0, path, msg.sender, block.timestamp);
        tokens = amounts[1];
        emit BuyFromUniswap(msg.sender, msg.value, tokens);
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
        (uint256 amountToken, uint256 amountEth, uint256 liquidity) =
            ROUTER.addLiquidityETH{value: eth - half}(address(solid), tokens, 0, 0, address(this), block.timestamp);
        emit GiveLiquidity(amountToken, amountEth, liquidity);
    }

    /**
     * @notice Remove Uniswap LP and convert back to ETH: remove liquidity, sell Solid tokens
     * @param n Amount of LP tokens to convert (contract must hold at least this many)
     */
    function takeLiquidity(uint256 n) public onlyOwner {
        IERC20(pair).approve(address(ROUTER), n);
        (uint256 amountToken, uint256 amountEth) =
            ROUTER.removeLiquidityETH(address(solid), n, 0, 0, address(this), block.timestamp);
        solid.sell(amountToken);
        emit TakeLiquidity(amountToken, amountEth, n);
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
     * @notice LINK balance funding this upkeep in the Chainlink registry
     */
    function linkBalance() external view returns (uint96) {
        if (upkeepId == 0) return 0;
        (address registry,) = REGISTRAR.getConfig();
        return IAutomationRegistry(registry).getBalance(upkeepId);
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
     * @dev Buys LINK with linkEth worth of ETH and uses it to fund the upkeep.
     */
    function register() external onlyOwner {
        if (upkeepId != 0) revert AlreadyRegistered();
        uint96 amount = _buyLink();

        IERC20 link = LINK();
        link.approve(address(REGISTRAR), amount);

        uint256 id = REGISTRAR.registerUpkeep(
            IAutomationRegistrar.RegistrationParams({
                name: solid.name(),
                encryptedEmail: "",
                upkeepContract: address(this),
                // casting to uint32 is safe because gasMargin is always set from a uint256 constant < 2^32
                // forge-lint: disable-next-line(unsafe-typecast)
                gasLimit: uint32(gasMargin),
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
        emit Register(id, forwarder);
    }

    /**
     * @notice Cancel the upkeep (must wait 50 blocks before calling unregister)
     */
    function cancel() external onlyOwner {
        if (upkeepId == 0) revert NotRegistered();
        (address registry,) = REGISTRAR.getConfig();
        IAutomationRegistry(registry).cancelUpkeep(upkeepId);
        forwarder = address(0);
    }

    /**
     * @notice Withdraw remaining LINK after the upkeep has been canceled
     */
    function unregister() external onlyOwner {
        if (upkeepId == 0) revert NotRegistered();
        (address registry,) = REGISTRAR.getConfig();
        IAutomationRegistry(registry).withdrawFunds(upkeepId, owner());
        emit Unregister(upkeepId);
        upkeepId = 0;
        forwarder = address(0);
    }

    // ---- Owner operations (not Bitsy) ----

    /**
     * @notice Withdraw ETH from the contract
     * @param amount Amount of ETH to withdraw
     */
    function withdraw(uint256 amount) public onlyOwner {
        (bool ok,) = owner().call{value: amount}("");
        require(ok);
        emit Withdraw(amount);
    }

    /**
     * @notice Recover ERC-20 tokens sent to this contract
     * @param token The token to recover
     * @param amount Amount to recover
     */
    function recover(IERC20 token, uint256 amount) public onlyOwner {
        require(token.transfer(owner(), amount));
        emit Recover(token, amount);
    }

    /**
     * @notice Remove all liquidity and return all ETH to the owner
     */
    function returnAll() external onlyOwner {
        uint256 lp = IERC20(pair).balanceOf(address(this));
        if (lp > 0) takeLiquidity(lp);

        uint256 ethBal = address(this).balance;
        if (ethBal > 0) withdraw(ethBal);
    }

    /**
     * @notice Set gas margin used in profit threshold calculation
     */
    function setGasMargin(uint256 gasMargin_) external onlyOwner {
        gasMargin = gasMargin_;
        emit SetGasMargin(gasMargin_);
    }

    /**
     * @notice Set minimum LINK balance before top-off triggers
     */
    function setLinkMin(uint256 linkMin_) external onlyOwner {
        linkMin = linkMin_;
        emit SetLinkMin(linkMin_);
    }

    /**
     * @notice Set amount of ETH to spend topping off LINK
     */
    function setLinkEth(uint256 linkEth_) external onlyOwner {
        linkEth = linkEth_;
        emit SetLinkEth(linkEth_);
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
        gasMargin = GAS_MARGIN;
        linkMin = LINK_MIN;
        linkEth = LINK_ETH;
    }
}
