// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
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
        string memory deploymentsJson = vm.readFile(deploymentsPath);
        address deployer = abi.decode(vm.parseJson(deploymentsJson, ".deployer"), (address));
        
        if (deployer == address(0)) {
            revert("DeployCore must be run first to set deployer address");
        }

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockOracle
        MockOracle mockOracle = new MockOracle(deployer);

        // 2. Deploy PythOracle (if PYTH env var is set)
        address pythAddress = vm.envOr("PYTH", address(0));
        PythOracle pythOracle;
        
        if (pythAddress != address(0)) {
            console2.log("Deploying PythOracle using Pyth address:", pythAddress);
            pythOracle = new PythOracle(pythAddress, deployer);
        } else {
            console2.log("PYTH env var not set, skipping PythOracle deployment");
        }

        // 3. Grant oracle admin and emergency roles
        for (uint256 i = 0; i < admins.length; i++) {
            mockOracle.grantRole(mockOracle.ADMIN_ROLE(), admins[i]);
            console2.log("Granted MockOracle admin role to:", admins[i]);
            
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.ADMIN_ROLE(), admins[i]);
                console2.log("Granted PythOracle admin role to:", admins[i]);
            }
        }
        
        for (uint256 i = 0; i < emergency.length; i++) {
            mockOracle.grantRole(mockOracle.EMERGENCY_ROLE(), emergency[i]);
            console2.log("Granted MockOracle emergency role to:", emergency[i]);
            
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.EMERGENCY_ROLE(), emergency[i]);
                console2.log("Granted PythOracle emergency role to:", emergency[i]);
            }
        }

        vm.stopBroadcast();

        // Log addresses for manual deployment.json update
        console2.log("=== Add these addresses to script/config/deployments.json ===");
        console2.log("MockOracle:", address(mockOracle));
        if (address(pythOracle) != address(0)) {
            console2.log("PythOracle:", address(pythOracle));
            console2.log("PythAddress:", pythAddress);
        }
        console2.log("");
        console2.log("Example deployments.json:");
        console2.log("{");
        console2.log('  "fusd": "0x...",');
        console2.log('  "controllerRegistry": "0x...",');
        console2.log('  "deployer": "0x...",');
        console2.log('  "mockOracle": "', address(mockOracle), '",');
        if (address(pythOracle) != address(0)) {
            console2.log('  "pythOracle": "', address(pythOracle), '",');
            console2.log('  "pythAddress": "', pythAddress, '"');
        } else {
            console2.log('  "pythAddress": "0x2880aB155794e7179c9eE2e38200202908C17B43"');
        }
        console2.log("}");

        console2.log("Oracles deployed successfully!");
    }
}
