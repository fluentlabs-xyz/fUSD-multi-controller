// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {fUSD} from "src/fUSD.sol";
import {ControllerRegistry} from "src/controller/ControllerRegistry.sol";
import {DeskController} from "src/controller/DeskController.sol";
import {MockOracle} from "src/MockOracle.sol";
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
        for (uint i = 0; i < admins.length; i++) {
            registry.grantRole(registry.ADMIN_ROLE(), admins[i]);
        }
        
        // 4. Deploy mock oracle
        MockOracle oracle = new MockOracle(deployer);
        
        // 5. Deploy desk controller
        DeskController desk = new DeskController(
            address(token),
            address(oracle)
        );
        
        // 6. Wire up permissions
        token.grantRole(token.CONTROLLER_ROLE(), address(desk));
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);

        // 6a. Grant controller admin and emergency roles
        for (uint i = 0; i < admins.length; i++) {
            desk.grantAdminRole(admins[i]);
        }
        for (uint i = 0; i < emergency.length; i++) {
            desk.grantEmergencyRole(emergency[i]);
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
        
        // Log deployed addresses
        console.log("fUSD Token:", address(token));
        console.log("ControllerRegistry:", address(registry));
        console.log("Oracle:", address(oracle));
        console.log("Trading Desk:", address(desk));
        // console.log("Pool:", IUniswapV2Factory(UNISWAP_FACTORY).getPair(address(token), WETH));
    }
}