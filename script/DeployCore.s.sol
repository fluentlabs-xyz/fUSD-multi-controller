// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {fUSD} from "src/fUSD.sol";
import {ControllerRegistry} from "src/controller/ControllerRegistry.sol";

contract DeployCore is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Load admin addresses from config JSON: script/config/admins.json
        string memory configPath = string.concat(vm.projectRoot(), "/script/config/admins.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(configPath);
        address[] memory admins = abi.decode(vm.parseJson(json, ".admins"), (address[]));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy token
        fUSD token = new fUSD();

        // 2. Deploy registry
        address deployer = vm.addr(deployerPrivateKey);
        ControllerRegistry registry = new ControllerRegistry(deployer);

        // 3. Setup multiple admins
        for (uint256 i = 0; i < admins.length; i++) {
            registry.grantRole(registry.ADMIN_ROLE(), admins[i]);
            console.log("Granted admin role to:", admins[i]);
        }

        vm.stopBroadcast();

        // Log addresses for manual deployment.json update
        console.log("=== Add these addresses to script/config/deployments.json ===");
        console.log("fUSD Token:", address(token));
        console.log("ControllerRegistry:", address(registry));
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Example deployments.json:");
        console.log("{");
        console.log('  "fusd": "', address(token), '",');
        console.log('  "controllerRegistry": "', address(registry), '",');
        console.log('  "deployer": "', deployer, '",');
        console.log("}");

        console.log("Core contracts deployed successfully!");
    }
}
