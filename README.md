# UniSolid

Chainlink Automation contract that arbitrages price discrepancies between
[Solid](https://uniteum.one/solid/) tokens and Uniswap V2 pairs.

## How It Works

Every Solid token has a built-in constant-product AMM (ETH/token). When the
same token also trades on Uniswap V2, prices can diverge. UniSolid detects
the discrepancy and executes the arbitrage atomically.

**Two directions:**

| Direction | Buy side | Sell side |
|-----------|----------|-----------|
| Solid → Uniswap | `solid.buy{value}()` | `router.swapExactTokensForETH()` |
| Uniswap → Solid | `router.swapExactETHForTokens()` | `solid.sell(amount)` |

## Usage

1. Deploy `UniSolid`.
2. Fund the contract with ETH via `deposit()`.
3. Register a Chainlink Automation upkeep with `checkData` set to:

```solidity
abi.encode(UniSolid.Params({
    solid: ISolid(solidAddress),
    router: IUniswapV2Router(routerAddress),
    ethIn: 0.1 ether,
    minProfit: 0.001 ether
}))
```

The keeper calls `checkUpkeep` off-chain each block. When a profitable
arb exists above `minProfit`, it triggers `performUpkeep` to execute.

Register multiple upkeeps with different Solid tokens or trade sizes
against the same contract.

## Owner Functions

- `deposit()` — fund the contract with ETH
- `withdraw(amount)` — withdraw ETH
- `recover(token, amount)` — recover ERC-20 tokens

## Build

```bash
forge build
forge test
forge test -vvv   # verbose
```

## Dependencies

- [isolid](https://github.com/uniteum/isolid) — Solid protocol interface
- [iautomation](https://github.com/uniteum/iautomation) — Chainlink Automation interface
- [ierc20](https://github.com/uniteum/ierc20) — ERC-20 interface
- [forge-std](https://github.com/foundry-rs/forge-std) — Foundry test framework
- [crucible](https://github.com/uniteum/crucible) — Shared Foundry configuration

## License

MIT
