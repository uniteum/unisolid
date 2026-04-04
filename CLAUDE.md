# CLAUDE.md — UniSolid

> Context guide for AI-assisted development of the UniSolid arbitrage keeper.

## Overview

**UniSolid** is a Chainlink Automation contract that arbitrages between
[Solid](https://uniteum.one/solid/) token AMMs and Uniswap V2 pairs.

It implements `IAutomation` (Chainlink's `checkUpkeep`/`performUpkeep`
interface) to detect and execute price discrepancies atomically.

## Key Files

| File | Purpose | Lines |
|------|---------|-------|
| [src/UniSolid.sol](src/UniSolid.sol) | Main arbitrage contract | ~220 |
| [src/IUniswapV2.sol](src/IUniswapV2.sol) | Minimal Uniswap V2 Router/WETH interfaces | ~35 |
| [test/UniSolid.t.sol](test/UniSolid.t.sol) | Tests with mock Solid + mock Router | ~310 |

## Architecture

### Contract: `UniSolid`

Implements `IAutomation` from [iautomation](lib/iautomation/iautomation.sol).

**Params struct** — passed as ABI-encoded `checkData` at upkeep registration:

```solidity
struct Params {
    ISolid solid;              // Solid token to arbitrage
    IUniswapV2Router router;   // Uniswap V2 router
    uint256 eth;             // Trade size in ETH
    uint256 minProfit;         // Minimum profit threshold in ETH
}
```

Addresses are inputs, not hardcoded. One deployed contract serves
multiple Solid tokens via separate Chainlink upkeep registrations.

### Automation Flow

1. **`checkUpkeep(checkData)`** — called off-chain by Chainlink keepers
   - Decodes `Params` from `checkData`
   - Checks contract has sufficient ETH balance
   - Quotes both arbitrage directions
   - Returns `(true, performData)` if profit exceeds `minProfit`

2. **`performUpkeep(performData)`** — called on-chain when upkeep needed
   - Decodes `Params` and `Direction` from `performData`
   - Re-validates profitability on-chain (prices may have moved)
   - Executes the arbitrage
   - Emits `Arb` event with profit details

### Arbitrage Directions

**Direction A — Solid cheap, Uniswap expensive:**
```
ETH → solid.buy() → tokens → router.swapExactTokensForETH() → ETH (more)
```

**Direction B — Uniswap cheap, Solid expensive:**
```
ETH → router.swapExactETHForTokens() → tokens → solid.sell() → ETH (more)
```

### Quote Functions

```solidity
_quoteSolidToUniswap(p) → profit   // Direction A: buy Solid, sell Uniswap
_quoteUniswapToSolid(p) → profit   // Direction B: buy Uniswap, sell Solid
_quote(p) → (direction, profit)    // Best of both
```

Both quote functions use `try/catch` on the Uniswap router call to
gracefully handle missing pairs or insufficient liquidity.

### Owner Functions

- `deposit()` — fund contract with ETH (payable, onlyOwner)
- `withdraw(amount)` — withdraw ETH
- `recover(token, amount)` — recover stuck ERC-20 tokens

Owner is set to `msg.sender` in constructor. No transfer mechanism.

## Dependencies

### Protocol Interfaces

| Import | Submodule | Purpose |
|--------|-----------|---------|
| `ISolid` | [lib/isolid](lib/isolid/) | Solid token interface: `buy()`, `sell()`, `buys()`, `sells()`, `pool()` |
| `IAutomation` | [lib/iautomation](lib/iautomation/) | Chainlink `checkUpkeep`/`performUpkeep` |
| `IERC20` | [lib/ierc20](lib/ierc20/) | ERC-20 `approve`/`transfer` for token operations |

### Solid Protocol — Key Mechanics

Each Solid token is a constant-product AMM (ETH/token) with:

- **Virtual 1 ETH** — `pool()` returns `(S, E)` where `E = balance + 1 ether`
- **Buy formula**: `s = S - S * E / (E + e)` — send ETH, receive tokens
- **Sell formula**: `e = E - (E * S + E - 1) / (S + s)` — send tokens, receive ETH
- **Preview functions**: `buys(e)` and `sells(s)` — read-only quotes
- **No approval needed** for `sell()` — the Solid contract handles the transfer internally
- **Price floor** — virtual 1 ETH is permanent, price can never reach zero

See [ISolid.sol](lib/isolid/ISolid.sol) for the full interface and NatSpec.

### Uniswap V2 — Key Mechanics

Minimal interface in [src/IUniswapV2.sol](src/IUniswapV2.sol):

- `router.WETH()` — WETH address for building swap paths
- `router.getAmountsOut(amountIn, path)` — quote output amount
- `router.swapExactETHForTokens{value}(minOut, path, to, deadline)` — buy tokens with ETH
- `router.swapExactTokensForETH(amountIn, minOut, path, to, deadline)` — sell tokens for ETH

Swap paths are always `[WETH, solid]` or `[solid, WETH]` (two-hop).
The contract must `approve` the router before calling `swapExactTokensForETH`.

## Events and Errors

```solidity
event Arb(ISolid indexed solid, Direction direction, uint256 eth, uint256 profit);

error NotOwner();
error NoProfitableArb();
error InsufficientBalance();
```

## Testing

Tests use mock contracts (not forks):

- **MockSolid** — implements the constant-product AMM formulas
- **MockRouter** — implements Uniswap V2 swap logic with 0.3% fee
- **MockWETH** — minimal WETH stub

### Test Cases

| Test | What it verifies |
|------|-----------------|
| `test_NoArbWhenPricesEqual` | No false positives when pools are balanced |
| `test_ArbSolidToUniswap` | Direction A: Solid cheap → buy Solid, sell Uniswap |
| `test_ArbUniswapToSolid` | Direction B: Uniswap cheap → buy Uniswap, sell Solid |
| `test_NoArbWithInsufficientBalance` | Rejects when contract underfunded |
| `test_MinProfitThreshold` | Respects `minProfit` threshold |
| `test_OnlyOwnerWithdraw` | Access control on `withdraw()` |
| `test_OnlyOwnerRecover` | Access control on `recover()` |

### Running Tests

```bash
forge test                          # all tests
forge test --match-test test_Arb    # just arb tests
forge test -vvv                     # verbose with logs
```

## Development Notes

### Adding New DEX Support

To add another DEX (e.g., Uniswap V3, Sushiswap):

1. Add the router interface to `src/`
2. Add new quote/execution functions in `UniSolid.sol`
3. Extend `Params` with a DEX selector or create a separate contract

### Security Considerations

- `performUpkeep` is callable by anyone (per Chainlink spec) — the
  on-chain profit re-validation prevents griefing
- Token approvals are set per-trade (not infinite) to limit exposure
- `try/catch` in quotes handles missing Uniswap pairs gracefully
- No flash loans — the contract trades with its own ETH balance

### Build Configuration

Inherits from [crucible](lib/crucible/) via symlinks:

- Solidity 0.8.30, Cancun EVM, optimizer 200 runs, via_ir
- See [foundry.toml](foundry.toml) (symlinked from crucible)
- See crucible [rules](lib/crucible/.claude/rules/) for code style

### Workflow

- `forge build` — compile
- `forge test` — run tests
- `forge fmt` — format code
- Never run `forge script` or `forge create` without explicit user request
