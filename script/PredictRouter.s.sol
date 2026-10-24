// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AggregatorRouter } from "src/AggregatorRouter.sol";

/**
 * @notice Prints what the Safe deploys and where. Nothing is sent: the router is deployed by the Safe through
 *         Safe's CreateCall library (CREATE2 from the Safe's own address), proposed and signed in the Safe console.
 *
 *         forge script script/PredictRouter.s.sol
 *
 *         Each signer runs this on their own checkout and compares the init code hash and the address with the
 *         ones the console shows before signing.
 */
contract PredictRouter is Script {
    address constant SAFE = 0x868b8B48db5DDE602D24960A606A5A8F93333bf9; // LitVM 2-of-3 Safe, the router's owner
    address constant WZKLTC = 0x315374AA9b5536037Cc1Efeea2439CCC0913A77e;
    address constant V2_FACTORY = 0x4680BCe1632824d30D2F53656dD610736c3e312e;
    address constant V3_FACTORY = 0xDE6763A041f8Fc94CA2EE5933736F78f6D1A11c5;
    bytes32 constant SALT = keccak256("litvm-aggregator-router-v2");

    function run() external pure {
        bytes memory initCode = abi.encodePacked(
            type(AggregatorRouter).creationCode, abi.encode(WZKLTC, V2_FACTORY, V3_FACTORY, SAFE)
        );
        bytes32 initCodeHash = keccak256(initCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE, SALT, initCodeHash)))));

        console.log("AggregatorRouter 2.0.0, deployed by the Safe with CreateCall.performCreate2");
        console.log("salt:          ", vm.toString(SALT));
        console.log("init code hash:", vm.toString(initCodeHash));
        console.log("address:       ", predicted);
    }
}
