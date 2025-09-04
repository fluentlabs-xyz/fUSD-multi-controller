// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {fUSD} from "src/fUSD.sol";
import {ControllerRegistry} from "src/controller/ControllerRegistry.sol";
import {DeskController} from "src/controller/DeskController.sol";

contract DeployControllers is Script {
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

        address fusdAddress = abi.decode(vm.parseJson(deploymentsJson, ".fusd"), (address));
        address registryAddress = abi.decode(vm.parseJson(deploymentsJson, ".controllerRegistry"), (address));
        address mockOracleAddress = abi.decode(vm.parseJson(deploymentsJson, ".mockOracle"), (address));
        address pythOracleAddress = abi.decode(vm.parseJson(deploymentsJson, ".pythOracle"), (address));

        // Validate required deployments exist
        if (fusdAddress == address(0)) revert("fUSD not deployed. Run DeployCore first.");
        if (registryAddress == address(0)) revert("ControllerRegistry not deployed. Run DeployCore first.");
        if (mockOracleAddress == address(0)) revert("MockOracle not deployed. Run DeployOracles first.");

        if (pythOracleAddress == address(0)) {
            console.log("No PythOracle found, will use MockOracle");
        }

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DeskController with active oracle
        DeskController desk;
        if (pythOracleAddress != address(0)) {
            desk = new DeskController(fusdAddress, pythOracleAddress);
            console.log("Using PythOracle as active oracle");
        } else {
            desk = new DeskController(fusdAddress, mockOracleAddress);
            console.log("Using MockOracle as active oracle");
        }

        // 2. Wire up permissions
        fUSD(fusdAddress).grantRole(fUSD(fusdAddress).CONTROLLER_ROLE(), address(desk));
        console.log("Granted CONTROLLER_ROLE to DeskController");

        ControllerRegistry(registryAddress).addController(address(desk), "Trading Desk", 1_000_000 * 1e6);
        console.log("Added DeskController to registry");

        // 3. Grant controller admin and emergency roles
        for (uint256 i = 0; i < admins.length; i++) {
            desk.grantAdminRole(admins[i]);
            console.log("Granted DeskController admin role to:", admins[i]);
        }

        for (uint256 i = 0; i < emergency.length; i++) {
            desk.grantEmergencyRole(emergency[i]);
            console.log("Granted DeskController emergency role to:", emergency[i]);
        }

        // 4. Fund desk with initial ETH
        payable(address(desk)).transfer(0.1 ether);
        console.log("Funded DeskController with 0.1 ETH");

        vm.stopBroadcast();

        // Log addresses for manual deployment.json update
        console.log("=== Add these addresses to script/config/deployments.json ===");
        console.log("DeskController:", address(desk));
        console.log("ActiveOracle:", pythOracleAddress != address(0) ? pythOracleAddress : mockOracleAddress);
        console.log("");
        console.log("Example deployments.json:");
        console.log("{");
        console.log('  "fusd": "0x...",');
        console.log('  "controllerRegistry": "0x...",');
        console.log('  "deployer": "0x...",');
        console.log('  "mockOracle": "0x...",');
        console.log('  "pythOracle": "0x...",');
        console.log('  "pythAddress": "0x2880aB155794e7179c9eE2e38200202908C17B43",');
        console.log('  "deskController": "', address(desk), '",');
        console.log('  "activeOracle": "', pythOracleAddress != address(0) ? pythOracleAddress : mockOracleAddress, '"');
        console.log("}");

        console.log("Controllers deployed successfully!");
    }
}
