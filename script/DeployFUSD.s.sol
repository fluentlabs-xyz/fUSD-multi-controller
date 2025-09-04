// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
// Import the individual deployment contracts
import {DeployCore} from "./DeployCore.s.sol";
import {DeployOracles} from "./DeployOracles.s.sol";
import {DeployControllers} from "./DeployControllers.s.sol";

/**
 * @title DeployFUSD
 * @dev Orchestrates the complete deployment process by running all phases
 * This script runs the individual deployment phases in sequence:
 * 1. DeployCore - fUSD token and ControllerRegistry
 * 2. DeployOracles - MockOracle and PythOracle (if PYTH env var is set)
 * 3. DeployControllers - DeskController
 */
contract DeployFUSD is Script {
    function run() external {
        console.log("=== Starting Complete fUSD Deployment ===");

        // Phase 1: Deploy Core Contracts
        console.log("\n--- Phase 1: Deploying Core Contracts ---");
        vm.broadcast();
        (bool success1,) = address(new DeployCore()).call(abi.encodeWithSignature("run()"));
        require(success1, "Core deployment failed");

        // Phase 2: Deploy Oracles
        console.log("\n--- Phase 2: Deploying Oracles ---");
        vm.broadcast();
        (bool success2,) = address(new DeployOracles()).call(abi.encodeWithSignature("run()"));
        require(success2, "Oracles deployment failed");

        // Phase 3: Deploy Controllers
        console.log("\n--- Phase 3: Deploying Controllers ---");
        vm.broadcast();
        (bool success3,) = address(new DeployControllers()).call(abi.encodeWithSignature("run()"));
        require(success3, "Controllers deployment failed");

        console.log("\n=== Complete fUSD Deployment Finished Successfully! ===");
        console.log("All contracts deployed and configured.");
        console.log("Check script/config/deployments.json for all addresses.");
    }
}
