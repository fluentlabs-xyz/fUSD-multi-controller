// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {fUSD} from "src/fUSD.sol";
import {ControllerRegistry} from "src/controller/ControllerRegistry.sol";
import {DeskController} from "src/controller/DeskController.sol";
import {MockOracle} from "src/oracles/MockOracle.sol";
import {PythOracle} from "src/oracles/PythOracle.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
// import {PoolInitializer} from "src/AMM/PoolInitializer.sol";

contract DeployFUSD is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Load admin addresses from config JSON: script/config/admins.json
        // Expected format:
        // {
        //   "admins": ["0x...", "0x..."],
        //   "emergency": ["0x..."]
        // }
        string memory configPath = string.concat(vm.projectRoot(), "/script/config/admins.json");
        string memory json = vm.readFile(configPath);
        address[] memory admins = abi.decode(vm.parseJson(json, ".admins"), (address[]));
        address[] memory emergency = abi.decode(vm.parseJson(json, ".emergency"), (address[]));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy token
        fUSD token = new fUSD();

        // 2. Deploy registry
        address deployer = vm.addr(deployerPrivateKey);
        ControllerRegistry registry = new ControllerRegistry(deployer);

        // 3. Setup multiple admins
        for (uint256 i = 0; i < admins.length; i++) {
            registry.grantRole(registry.ADMIN_ROLE(), admins[i]);
        }

        // 4. Deploy oracles
        MockOracle mockOracle = new MockOracle(deployer);
        
        // Try to get Pyth address from environment, fallback to MockOracle
        address pythAddress = vm.envOr("PYTH", address(0));
        PythOracle pythOracle;
        IOracle activeOracle;
        
        if (pythAddress != address(0)) {
            console.log("Deploying with PythOracle using Pyth address:", pythAddress);
            pythOracle = new PythOracle(pythAddress, deployer);
            activeOracle = pythOracle;
        } else {
            console.log("PYTH env var not set, using MockOracle for deployment");
            activeOracle = mockOracle;
        }

        // 5. Deploy desk controller with active oracle
        DeskController desk = new DeskController(address(token), address(activeOracle));

        // 6. Wire up permissions
        token.grantRole(token.CONTROLLER_ROLE(), address(desk));
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);

        // 6a. Grant controller admin and emergency roles
        for (uint256 i = 0; i < admins.length; i++) {
            desk.grantAdminRole(admins[i]);
        }
        for (uint256 i = 0; i < emergency.length; i++) {
            desk.grantEmergencyRole(emergency[i]);
        }
        
        // 6b. Grant oracle admin and emergency roles
        for (uint256 i = 0; i < admins.length; i++) {
            mockOracle.grantRole(mockOracle.ADMIN_ROLE(), admins[i]);
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.ADMIN_ROLE(), admins[i]);
            }
        }
        for (uint256 i = 0; i < emergency.length; i++) {
            mockOracle.grantRole(mockOracle.EMERGENCY_ROLE(), emergency[i]);
            if (address(pythOracle) != address(0)) {
                pythOracle.grantRole(pythOracle.EMERGENCY_ROLE(), emergency[i]);
            }
        }

        // 7. Fund desk with initial ETH
        payable(address(desk)).transfer(0.1 ether);

        // // 8. Initialize AMM pool
        // PoolInitializer poolInit = new PoolInitializer();
        // poolInit.initializeUniV2Pool{value: 5 ether}(
        //     UNISWAP_FACTORY,
        //     address(fUSD),
        //     WETH,
        //     address(desk),
        //     5 ether
        // );

        vm.stopBroadcast();

        // Create deployments JSON file
        string memory deploymentJson = string.concat(
            "{\n",
            '  "fusd": "', vm.toString(address(token)), '",\n',
            '  "controllerRegistry": "', vm.toString(address(registry)), '",\n',
            '  "mockOracle": "', vm.toString(address(mockOracle)), '",\n'
        );
        
        if (address(pythOracle) != address(0)) {
            deploymentJson = string.concat(
                deploymentJson,
                '  "pythOracle": "', vm.toString(address(pythOracle)), '",\n',
                '  "pythAddress": "', vm.toString(pythAddress), '",\n'
            );
        }
        
        deploymentJson = string.concat(
            deploymentJson,
            '  "deskController": "', vm.toString(address(desk)), '",\n',
            '  "activeOracle": "', vm.toString(address(activeOracle)), '"\n',
            "}"
        );

        // Write deployments to file
        string memory deploymentsPath = string.concat(vm.projectRoot(), "/script/config/deployments.json");
        vm.writeFile(deploymentsPath, deploymentJson);

        // Log deployed addresses
        console.log("fUSD Token:", address(token));
        console.log("ControllerRegistry:", address(registry));
        console.log("MockOracle:", address(mockOracle));
        if (address(pythOracle) != address(0)) {
            console.log("PythOracle:", address(pythOracle));
            console.log("Pyth Contract:", pythAddress);
            console.log("Active Oracle: PythOracle");
        } else {
            console.log("Active Oracle: MockOracle");
        }
        console.log("Trading Desk:", address(desk));
        console.log("Deployments saved to:", deploymentsPath);
        // console.log("Pool:", IUniswapV2Factory(UNISWAP_FACTORY).getPair(address(token), WETH));
    }
}
