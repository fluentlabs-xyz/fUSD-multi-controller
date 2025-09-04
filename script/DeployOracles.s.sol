// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {MockOracle} from "src/oracles/MockOracle.sol";
import {PythOracle} from "src/oracles/PythOracle.sol";

contract DeployOracles is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Load admin addresses from config JSON: script/config/admins.json
        string memory configPath = string.concat(vm.projectRoot(), "/script/config/admins.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(configPath);
        address[] memory admins = abi.decode(vm.parseJson(json, ".admins"), (address[]));
        address[] memory emergency = abi.decode(vm.parseJson(json, ".emergency"), (address[]));

        // Load existing deployments
        string memory deploymentsPath = string.concat(vm.projectRoot(), "/script/config/deployments.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory deploymentsJson = vm.readFile(deploymentsPath);
        address deployer = abi.decode(vm.parseJson(deploymentsJson, ".deployer"), (address));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockOracle
        MockOracle mockOracle = new MockOracle(deployer);
        console.log("MockOracle deployed at:", address(mockOracle));

        // 2. Deploy PythOracle (if PYTH env var is set)
        address pythAddress = vm.envOr("PYTH", address(0));
        PythOracle pythOracle;
        
        if (pythAddress != address(0)) {
            console.log("Deploying PythOracle using Pyth address:", pythAddress);
            pythOracle = new PythOracle(pythAddress, deployer);
            console.log("PythOracle deployed at:", address(pythOracle));
        } else {
            console.log("PYTH env var not set, skipping PythOracle deployment");
        }

        // 3. Grant oracle admin and emergency roles
        for (uint256 i = 0; i < admins.length; i++) {
            mockOracle.grantRole(mockOracle.ADMIN_ROLE(), admins[i]);
            console.log("Granted MockOracle admin role to:", admins[i]);
            
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.ADMIN_ROLE(), admins[i]);
                console.log("Granted PythOracle admin role to:", admins[i]);
            }
        }
        
        for (uint256 i = 0; i < emergency.length; i++) {
            mockOracle.grantRole(mockOracle.EMERGENCY_ROLE(), emergency[i]);
            console.log("Granted MockOracle emergency role to:", emergency[i]);
            
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.EMERGENCY_ROLE(), emergency[i]);
                console.log("Granted PythOracle emergency role to:", emergency[i]);
            }
        }

        vm.stopBroadcast();

        // Update deployments JSON file
        string memory existingJson = vm.readFile(deploymentsPath);
        string memory newJson = existingJson;
        
        // Add MockOracle
        newJson = vm.serializeAddress(newJson, "mockOracle", address(mockOracle));
        
        // Add PythOracle if deployed
        if (address(pythOracle) != address(0)) {
            newJson = vm.serializeAddress(newJson, "pythOracle", address(pythOracle));
            newJson = vm.serializeAddress(newJson, "pythAddress", pythAddress);
        }

        // Write updated deployments to file
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(deploymentsPath, newJson);

        console.log("Oracles deployed successfully!");
        console.log("Deployments updated in:", deploymentsPath);
    }
}
