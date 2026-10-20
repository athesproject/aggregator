// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AGGFlowRouter} from "../src/flow/AGGFlow.sol";
import {AGGFlowEntrypoint} from "../src/entrypoint/AGGFlowEntrypoint.sol";

/**
 * @title deployAll
 * @notice One‑command deployment script for AGGFlow on Somnia (Mainnet)
 */
contract deployAll is Script {
    function run() public {
        // ----------------------------------------------------------------------
        //  HARDCODED SOMNIA CONFIGURATION
        // ----------------------------------------------------------------------
        string memory rpcUrl = "https://liteforge.rpc.caldera.xyz/http";   // LitVM Liteforge RPC
        address wethAddress = 0x315374AA9b5536037Cc1Efeea2439CCC0913A77e; // WSOMI (Wrapped SOMI) address
        // 3-of-3 Safe on LitVM (chain 4441); owns AGGFlowEntrypoint from the moment it's deployed
        address flowOwner   = 0x868b8B48db5DDE602D24960A606A5A8F93333bf9;

        // ----------------------------------------------------------------------
        //  DEPLOYER IS AN ADDRESS SUPPLIED BY AN EXTERNAL SIGNER
        //  (forge script ... --ledger / --trezor / --unlocked / --interactive)
        //  No private key is ever read into this process.
        // ----------------------------------------------------------------------
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // ----------------------------------------------------------------------
        //  CHECKS
        // ----------------------------------------------------------------------
        require(wethAddress != address(0), "WSOMI address not set");
        require(flowOwner != address(0), "Owner address not set");

        console.log("Deploying AGGFlow to LitVM");
        console.log("Deployer:", deployer);
        console.log("Owner:   ", flowOwner);
        console.log("WSOMI:   ", wethAddress);
        console.log("RPC URL: ", rpcUrl);
        console.log("------------------------------------------------");

        vm.createSelectFork(rpcUrl);
        vm.startBroadcast(deployer);

        // 1. Deploy the AGGFlowRouter (pass WSOMI address)
        AGGFlowRouter router = new AGGFlowRouter(wethAddress);
        console.log("AGGFlowRouter deployed to: ", address(router));

        // 2. Deploy the AGGFlowEntrypoint (pass owner and router address)
        AGGFlowEntrypoint entrypoint = new AGGFlowEntrypoint(flowOwner, address(router));
        console.log("AGGFlowEntrypoint deployed to: ", address(entrypoint));

        vm.stopBroadcast();

        console.log("------------------------------------------------");
        console.log("Deployment completed successfully!");
        console.log("AGGFlowRouter:     ", address(router));
        console.log("AGGFlowEntrypoint: ", address(entrypoint));
        console.log("Owner:             ", flowOwner);
        console.log("------------------------------------------------");
    }
}