// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

contract DeployFUSD is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address[] memory admins = vm.envAddress("ADMIN_ADDRESSES", ",");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy token
        USD fUSD = new USD();
        
        // 2. Deploy registry
        ControllerRegistry registry = new ControllerRegistry();
        
        // 3. Setup multiple admins
        for (uint i = 0; i < admins.length; i++) {
            registry.grantRole(registry.ADMIN_ROLE(), admins[i]);
        }
        
        // 4. Deploy mock oracle
        MockOracle oracle = new MockOracle();
        
        // 5. Deploy desk controller
        DeskController desk = new DeskController(
            address(fUSD),
            address(oracle)
        );
        
        // 6. Wire up permissions
        fUSD.grantRole(fUSD.CONTROLLER_ROLE(), address(desk));
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);
        
        // 7. Fund desk with initial ETH
        payable(address(desk)).transfer(10 ether);
        
        // 8. Initialize AMM pool
        PoolInitializer poolInit = new PoolInitializer();
        poolInit.initializeUniV2Pool{value: 5 ether}(
            UNISWAP_FACTORY,
            address(fUSD),
            WETH,
            address(desk),
            5 ether
        );
        
        vm.stopBroadcast();
        
        // Log deployed addresses
        console.log("fUSD Token:", address(fUSD));
        console.log("Registry:", address(registry));
        console.log("Oracle:", address(oracle));
        console.log("Desk:", address(desk));
        console.log("Pool:", IUniswapV2Factory(UNISWAP_FACTORY).getPair(address(fUSD), WETH));
    }
}