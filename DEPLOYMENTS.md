# Deployments

## LitVM LiteForge (chain 4441, testnet)

| Contract | Address | Deployed by | Status |
|---|---|---|---|
| AggregatorRouter 2.0.0 | `0x9A3158beBDEFd2C9DD9D00e6B14F66E1c5E7d514` | the Safe, CreateCall `performCreate2` | live since 2026-10-25: Safe transaction `0xea7a3a4f4498b6181dbf7b4fcbb234496fda7683274e74b9c06c78deb4c93495` (block 64,411,045) |
| Previous router (Kuru Flow derived) | `0x0624E93350bFfc5B3570589FCae68e2CaBe6c620` | deployer EOA (`broadcast/deployAll.sol/4441`) | retired 2026-10-25: the entrypoint calls 2.0.0 since the same Safe transaction |

AggregatorRouter 2.0.0:

| | |
|---|---|
| Constructor | wrapped native `0x315374AA9b5536037Cc1Efeea2439CCC0913A77e` (wzkLTC), V2 factory `0x4680BCe1632824d30D2F53656dD610736c3e312e`, V3 factory `0xDE6763A041f8Fc94CA2EE5933736F78f6D1A11c5`, owner `0x868b8B48db5DDE602D24960A606A5A8F93333bf9` (the Safe) |
| CREATE2 salt | `keccak256("litvm-aggregator-router-v2")` = `0x23cb34e8f909aefa3400465c15c9425fe89570f2c3ff78ed3ee3741cda48b572` |
| Init code hash | `0x08ec60f3ffd2e009a0635f80456812ba8bc568d98602015de908acf79ad04234` (`forge script script/PredictRouter.s.sol`) |
| Compiler | solc 0.8.28, via-IR, optimizer 50 runs, EVM cancun, `bytecode_hash = "none"` |
| Called by | the entrypoint proxy `0x5E19EB2A6BA30892CCe33f93D7Fb24D498512266` (source: litvmswap-feevault) |
| Owner | the 48-hour timelock `0x35774e0172571314fcDa7d602ea4D3410EE37188` since 2026-10-25 (Safe transaction `0x2bb206cd7317bedf68ef253fb100898411d8eeb275748e9d82fde96aa4796d0b`, block 64,462,396) |

The previous router and entrypoint were also deployed on Soneium (1868), Somnia (5031) and Ink (57073); see
`broadcast/deployAll.sol/<chain id>/run-latest.json`.
