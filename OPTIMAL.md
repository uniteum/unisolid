# Optimal Trade Size Derivation

## Setup

Two constant-product AMMs hold the same token paired with ETH:

| Pool | Token reserve | ETH reserve | Fee |
|------|--------------|-------------|-----|
| Solid | S | E | none |
| Uniswap V2 | T | W | 0.3% on input |

The constant-product swap formula (no fee):

```
out = R_out * in / (R_in + in)
```

Uniswap applies its fee by scaling the input:

```
out = R_out * (in * 997) / (R_in * 1000 + in * 997)
```

which is equivalent to swapping `in * 997/1000` in a fee-free pool.

## General form

Both arbitrage directions compose two swaps into a single profit
function of the ETH input `x`. After substitution and simplification,
each reduces to:

```
P(x) = A*x / (B + C*x) - x
```

where `A`, `B`, `C` are constants determined by the reserves and which
pool charges the fee. The profit curve is concave, so the unique maximum
is found by setting `dP/dx = 0`:

```
dP/dx = A*B / (B + C*x)^2 - 1 = 0
```

Solving:

```
(B + C*x)^2 = A*B
B + C*x     = sqrt(A*B)
x*          = (sqrt(A*B) - B) / C
```

This is the closed-form optimal trade size.

## Direction A: Solid cheap, Uniswap expensive

Buy tokens on Solid (no fee), sell on Uniswap (fee).

**Leg 1 — Solid buy (no fee):**

```
tokens = S * x / (E + x)
```

**Leg 2 — Uniswap sell (0.3% fee on input):**

```
ethBack = W * 997 * tokens / (T * 1000 + 997 * tokens)
```

Substitute `tokens = S*x / (E+x)` and multiply numerator and
denominator by `(E + x)`:

```
ethBack = 997 * W * S * x / (1000*T*(E+x) + 997*S*x)
        = 997 * W * S * x / (1000*T*E + x*(1000*T + 997*S))
```

Reading off the constants:

```
A = 997 * W * S
B = 1000 * T * E
C = 1000 * T + 997 * S
```

Optimal trade:

```
x* = (sqrt(997000 * S*E*W*T) - 1000*E*T) / (1000*T + 997*S)
```

## Direction B: Uniswap cheap, Solid expensive

Buy tokens on Uniswap (fee), sell on Solid (no fee).

**Leg 1 — Uniswap buy (0.3% fee on input):**

```
tokens = T * 997 * x / (W * 1000 + 997 * x)
```

**Leg 2 — Solid sell (no fee):**

```
ethBack = E * tokens / (S + tokens)
```

Substitute `tokens = 997*T*x / (1000*W + 997*x)` and multiply
numerator and denominator by `(1000*W + 997*x)`:

```
ethBack = 997 * E * T * x / (S*(1000*W + 997*x) + 997*T*x)
        = 997 * E * T * x / (1000*S*W + 997*x*(S + T))
```

Reading off the constants:

```
A = 997 * E * T
B = 1000 * S * W
C = 997 * (S + T)
```

Optimal trade:

```
x* = (sqrt(997000 * S*E*W*T) - 1000*S*W) / (997*S + 997*T)
```

## Observations

1. **Shared radicand.** Both directions have the same value under the
   square root: `997000 * S * E * W * T`. Only one `sqrt` computation
   is needed.

2. **Direction from price ratio.** If `S*W > T*E`, Solid is cheap
   (Direction A). If `T*E > S*W`, Uniswap is cheap (Direction B).
   If equal, no arbitrage exists.

3. **Asymmetric denominators.** The fee falls on different legs, so:
   - Direction A: `C = 1000*T + 997*S` (fee on second leg)
   - Direction B: `C = 997*(S + T)` (fee on first leg)

   These are *not* symmetric swaps of `(S,E) <-> (T,W)`.

## Integer overflow

The product `S * E * W * T` can overflow `uint256` for large reserves.
Splitting the square root avoids this:

```
sqrt(997000 * S * E * W * T) = sqrt(997000 * S * E) * sqrt(W * T)
```

This holds exactly for perfect squares. For non-perfect squares the
product of two integer square roots can differ from the square root
of the product by at most 1, which is negligible at 18-decimal precision.
