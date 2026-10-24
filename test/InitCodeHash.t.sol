// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AggregatorRouter } from "src/AggregatorRouter.sol";

/// @dev A clean checkout must build exactly the router the Safe deploys (DEPLOYMENTS.md). Any change to the source,
///      the compiler settings or a dependency changes this hash; then the Safe proposal must be renewed with it.
contract InitCodeHashTest is Test {
    bytes32 internal constant DEPLOYED_INIT_CODE_HASH =
        0x08ec60f3ffd2e009a0635f80456812ba8bc568d98602015de908acf79ad04234;

    function test_InitCodeIsWhatTheSafeDeploys() public pure {
        bytes memory initCode = abi.encodePacked(
            type(AggregatorRouter).creationCode,
            abi.encode(
                0x315374AA9b5536037Cc1Efeea2439CCC0913A77e, // wzkLTC
                0x4680BCe1632824d30D2F53656dD610736c3e312e, // V2 factory
                0xDE6763A041f8Fc94CA2EE5933736F78f6D1A11c5, // V3 factory
                0x868b8B48db5DDE602D24960A606A5A8F93333bf9 // owner: the LitVM Safe
            )
        );
        assertEq(keccak256(initCode), DEPLOYED_INIT_CODE_HASH);
    }
}
