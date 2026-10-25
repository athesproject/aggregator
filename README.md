# aggregator

The LitVMSwap aggregator router: it executes a swap route over LitVMSwap's own Uniswap V2 pairs and V3 pools, with
wrapping and unwrapping of the native token, in one transaction. It is called by the fee-enforcing
`AggregatorEntrypoint` (source in [litvmswap-feevault](https://github.com/athesproject/litvmswap-feevault)), which
takes the user's tokens, charges the protocol fee and delivers the output.

## Contents

| Path | What |
|---|---|
| `src/AggregatorRouter.sol` | Router 2.0.0 (MIT) |
| `test/AggregatorRouter.t.sol` | Unit tests with malicious pools and tokens, a pre-funded router, fuzzed programs |
| `test/fork/AggregatorRouterFork.t.sol` | Fork tests on live LitVM: the routes the website sends, through the live entrypoint |
| `script/PredictRouter.s.sol` | Prints the init code hash and the address the Safe deploys the router to |

## How the router keeps funds safe

- **Only this call's funds.** A route can spend only what the caller brought in or what its own swaps produced,
  both measured as balance changes. Tokens already in the router are never spent or paid out, a route must end
  holding nothing but its output token, and exactly that amount is paid to the caller.
- **Only LitVMSwap pools.** Every V2 pair must be the V2 factory's pair for its tokens and every V3 pool the V3
  factory's pool for its tokens and fee. A V3 pool may ask for payment once, in the input token, for at most the
  amount of its leg.
- **Strict decoding.** Every read of the route checks its length; a malformed, truncated or oversized route fails
  with a defined error before anything moves.
- **Never send tokens to the router directly.** It does not hold balances between transactions. Tokens sent to it
  by mistake can only be returned by its owner (the LitVM Safe, later the 48 h timelock) through `recover`.

Supported tokens: standard ERC-20 tokens. Fee-on-transfer tokens work through V2 pairs (amounts are measured);
Uniswap V3 pools do not support them, so such a swap reverts. Rebasing tokens are not supported.

## Route format

The byte format built by the website (`litvmswap/utils/programBuilder.js`) and the partner API:

```
op   0x01 <token:20>   spend what this call holds of `token`
     0x02 <token:20>   spend the caller's input (`token` = tokenIn)
     0x03              spend what this call holds of the native token
then <legs:1> and per leg <share:2> <leg>; a share is out of 65535 and the last leg takes the rest
leg  0x00 <pair:20> <direction:1> <fee:3>   V2 swap, direction 0 = token0 -> token1 (fee field not used: 0.3%)
     0x01 <pool:20> <zeroForOne:1>          V3 exact-input swap
     0x02 <wrap:1>                          1 = wrap native, 0 = unwrap
```

## Build and test

```shell
git clone --recursive https://github.com/athesproject/aggregator && cd aggregator
forge build
forge test --no-match-path "test/fork/*"   # unit tests
forge test --match-path "test/fork/*"      # fork tests (LITVM_RPC_URL, LITVM_FORK_BLOCK optional)
forge script script/PredictRouter.s.sol    # init code hash and address of the Safe deployment
```

Compiler settings (`foundry.toml`): solc 0.8.28, via-IR, optimizer 50 runs, EVM cancun, no metadata hash.
Dependencies are git submodules pinned to exact commits: forge-std `59e4cc3` (v1.15.0 plus 3 commits) and
OpenZeppelin Contracts `c1edd06` (master, 2026-02-23); every OpenZeppelin file the router imports is identical to
the v5.5.0 release. CI checks that every submodule is pinned to a commit over HTTPS and every action to a commit
(`.github/policy.py`).

## Deployments on LitVM (chain 4441)

| Contract | Address | Status |
|---|---|---|
| AggregatorRouter 2.0.0 | `0x9A3158beBDEFd2C9DD9D00e6B14F66E1c5E7d514` | live since 2026-10-25, deployed by the Safe through CreateCall ([DEPLOYMENTS.md](DEPLOYMENTS.md)) |
| Previous router | `0x0624E93350bFfc5B3570589FCae68e2CaBe6c620` | retired from the entrypoint on 2026-10-25 |

## Provenance

The previous router (`0x0624…`) and the first entrypoint were derived from Kuru's Flow aggregator
(`github.com/Kuru-Labs/Kuru-contracts-flow-public`, compared against commit `24190fc`) with LitVM changes; their
source is in this repository's first commit. Router 2.0.0 is new code written for LitVMSwap and replaces them; it
reads the same route bytes so existing clients keep working. It is MIT licensed (`LICENSE`); the submodules keep
their own licenses.

## Security

See [SECURITY.md](SECURITY.md).
