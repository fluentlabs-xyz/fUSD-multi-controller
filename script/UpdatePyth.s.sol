// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {PythOracle} from "src/oracles/PythOracle.sol";

contract UpdatePyth is Script {
    function run() external {
        // Load pythOracle address from deployments
        string memory deploymentsPath = string.concat(vm.projectRoot(), "/script/config/deployments.json");
        string memory deploymentsJson = vm.readFile(deploymentsPath);
        address pythOracle = abi.decode(vm.parseJson(deploymentsJson, ".pythOracle"), (address));

        if (pythOracle == address(0)) {
            revert("PythOracle not found in deployments. Run DeployOracles first.");
        }

        console.log("PythOracle address:", pythOracle);

        // Read the hex data from file
        string memory jsonData = vm.readFile("pyth/pyth_update_data.json");
        string memory hexData = vm.parseJsonString(jsonData, ".binary.data[0]");

        // Convert to bytes
        bytes memory updateData = vm.parseBytes(string.concat("0x", hexData));
        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        // Get fee
        uint256 fee = PythOracle(pythOracle).getUpdateFee(updateDataArray);
        console.log("Required fee:", fee);

        // Update and get price
        uint256 price = PythOracle(pythOracle).updateAndGetPrice{value: fee}(updateDataArray);
        console.log("ETH Price (6 decimals):", price);

        // Check health
        bool isHealthy = PythOracle(pythOracle).isHealthy();
        console.log("Is healthy:", isHealthy);
    }
}
