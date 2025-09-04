// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PythOracle} from "src/oracles/PythOracle.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title MockPyth
 * @dev Simplified mock Pyth contract for testing PythOracle
 * Only implements the functions we actually use to avoid interface complexity
 */
contract MockPyth {
    mapping(bytes32 => PythStructs.Price) public prices;
    mapping(bytes32 => bool) public priceExists;
    uint256 public updateFee = 0.001 ether;
    
    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint publishTime) external {
        prices[id] = PythStructs.Price(price, conf, expo, publishTime);
        priceExists[id] = true;
    }
    
    function setUpdateFee(uint256 fee) external {
        updateFee = fee;
    }
    
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        require(priceExists[id], "Price not found");
        return prices[id];
    }
    
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythStructs.Price memory) {
        require(priceExists[id], "Price not found");
        PythStructs.Price memory price = prices[id];
        require(block.timestamp - price.publishTime <= age, "Price too old");
        return price;
    }
    
    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }
    
    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFee, "Insufficient fee");
        // Mock implementation - just accept the payment
    }
}

/**
 * @title PythOracleTest
 * @dev Tests PythOracle-specific functionality including price updates and fee handling
 */
contract PythOracleTest is Test {
    PythOracle public pythOracle;
    MockPyth public mockPyth;
    
    address public admin = address(0x1);
    address public emergencyUser = address(0x2);
    address public user = address(0x3);
    
    bytes32 public constant ETH_USD_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    
    // Default test price: $4500 with Pyth's -8 exponent
    int64 public constant DEFAULT_PYTH_PRICE = 450000000000; // $4500 * 10^8
    uint64 public constant DEFAULT_CONFIDENCE = 1000000000; // $10 confidence * 10^8
    int32 public constant DEFAULT_EXPO = -8;

    function setUp() public {
        mockPyth = new MockPyth();
        pythOracle = new PythOracle(address(mockPyth), admin);
        
        // Grant emergency role to emergency user
        vm.prank(admin);
        pythOracle.grantEmergencyRole(emergencyUser);
        
        // Set default price in mock Pyth
        mockPyth.setPrice(
            ETH_USD_PRICE_ID,
            DEFAULT_PYTH_PRICE,
            DEFAULT_CONFIDENCE,
            DEFAULT_EXPO,
            block.timestamp
        );
        
        // Fund user for fee payments
        vm.deal(user, 10 ether);
        
        vm.label(address(pythOracle), "PythOracle");
        vm.label(address(mockPyth), "MockPyth");
        vm.label(admin, "Admin");
        vm.label(emergencyUser, "Emergency");
        vm.label(user, "User");
    }

    // ===== BASIC FUNCTIONALITY TESTS =====

    function test_InitialState() public view {
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6); // Should convert to 6 decimals
        assertTrue(pythOracle.isHealthy());
        assertEq(pythOracle.maxPriceAge(), 3600); // 1 hour default
        assertEq(pythOracle.maxConfidenceRatio(), 1000); // 10% default
        assertFalse(pythOracle.emergencyPause());
    }

    function test_AccessControlSetup() public view {
        // Admin has all roles
        assertTrue(pythOracle.hasRole(pythOracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pythOracle.hasRole(pythOracle.ADMIN_ROLE(), admin));
        assertTrue(pythOracle.hasRole(pythOracle.EMERGENCY_ROLE(), admin));
        
        // Emergency user only has emergency role
        assertFalse(pythOracle.hasRole(pythOracle.DEFAULT_ADMIN_ROLE(), emergencyUser));
        assertFalse(pythOracle.hasRole(pythOracle.ADMIN_ROLE(), emergencyUser));
        assertTrue(pythOracle.hasRole(pythOracle.EMERGENCY_ROLE(), emergencyUser));
    }

    // ===== PRICE CONVERSION TESTS =====

    function test_PriceConversionDifferentExponents() public {
        // Test different Pyth exponents
        
        // Test -6 exponent (should multiply by 1)
        mockPyth.setPrice(ETH_USD_PRICE_ID, 4500000000, DEFAULT_CONFIDENCE, -6, block.timestamp);
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
        
        // Test -10 exponent (should divide by 10000)
        mockPyth.setPrice(ETH_USD_PRICE_ID, 45000000000000, DEFAULT_CONFIDENCE, -10, block.timestamp);
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
        
        // Test -4 exponent (should multiply by 100)
        mockPyth.setPrice(ETH_USD_PRICE_ID, 45000000, DEFAULT_CONFIDENCE, -4, block.timestamp);
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
    }

    function test_PriceConversionZeroPrice() public {
        mockPyth.setPrice(ETH_USD_PRICE_ID, 0, DEFAULT_CONFIDENCE, DEFAULT_EXPO, block.timestamp);
        
        vm.expectRevert("PythOracle: invalid price");
        pythOracle.getEthUsd();
    }

    function test_PriceConversionNegativePrice() public {
        mockPyth.setPrice(ETH_USD_PRICE_ID, -450000000000, DEFAULT_CONFIDENCE, DEFAULT_EXPO, block.timestamp);
        
        vm.expectRevert("PythOracle: invalid price");
        pythOracle.getEthUsd();
    }

    // ===== PRICE STALENESS TESTS =====

    function test_StalePriceReverts() public {
        // Warp to ensure we have a reasonable timestamp
        vm.warp(1000000);
        
        // Set price older than max age
        mockPyth.setPrice(
            ETH_USD_PRICE_ID,
            DEFAULT_PYTH_PRICE,
            DEFAULT_CONFIDENCE,
            DEFAULT_EXPO,
            block.timestamp - 3601 // 1 hour + 1 second old
        );
        
        vm.expectRevert("Price too old");
        pythOracle.getEthUsd();
    }

    function test_FreshPriceWorks() public {
        // Warp to ensure we have a reasonable timestamp
        vm.warp(1000000);
        
        // Set fresh price
        mockPyth.setPrice(
            ETH_USD_PRICE_ID,
            DEFAULT_PYTH_PRICE,
            DEFAULT_CONFIDENCE,
            DEFAULT_EXPO,
            block.timestamp - 1800 // 30 minutes old
        );
        
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
    }

    // ===== CONFIDENCE RATIO TESTS =====

    function test_HighConfidenceRatioUnhealthy() public {
        // Set very high confidence (low quality price) 
        // For a price of 450000000000 (4.5e11), confidence > 10% threshold (1000 basis points)
        // Need conf > (price * 1000) / 10000 = price * 0.1
        // So conf > 45000000000, let's use 50000000000 for clear unhealthy state
        mockPyth.setPrice(
            ETH_USD_PRICE_ID,
            DEFAULT_PYTH_PRICE, // 450000000000 (4.5e11)
            50000000000, // 50000000000 (5e10) - >10% confidence ratio = >1000 basis points
            DEFAULT_EXPO,
            block.timestamp
        );
        
        // Price should work but oracle should be unhealthy due to high confidence ratio
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
        assertFalse(pythOracle.isHealthy());
    }

    function test_LowConfidenceRatioHealthy() public {
        // Set low confidence (high quality price)
        mockPyth.setPrice(
            ETH_USD_PRICE_ID,
            DEFAULT_PYTH_PRICE,
            2250000000, // $22.5 confidence (0.5% of price)
            DEFAULT_EXPO,
            block.timestamp
        );
        
        assertTrue(pythOracle.isHealthy());
    }

    // ===== CONFIGURATION TESTS =====

    function test_SetMaxPriceAge() public {
        uint256 newAge = 7200; // 2 hours
        
        vm.prank(admin);
        pythOracle.setMaxPriceAge(newAge);
        
        assertEq(pythOracle.maxPriceAge(), newAge);
    }

    function test_SetMaxPriceAgeUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        pythOracle.setMaxPriceAge(7200);
    }

    function test_SetMaxPriceAgeInvalid() public {
        vm.prank(admin);
        vm.expectRevert("PythOracle: invalid age");
        pythOracle.setMaxPriceAge(86401); // >24 hours
        
        vm.prank(admin);
        vm.expectRevert("PythOracle: invalid age");
        pythOracle.setMaxPriceAge(0);
    }

    function test_SetMaxConfidenceRatio() public {
        uint256 newRatio = 2000; // 20%
        
        vm.prank(admin);
        pythOracle.setMaxConfidenceRatio(newRatio);
        
        assertEq(pythOracle.maxConfidenceRatio(), newRatio);
    }

    function test_SetMaxConfidenceRatioInvalid() public {
        vm.prank(admin);
        vm.expectRevert("PythOracle: invalid ratio");
        pythOracle.setMaxConfidenceRatio(5001); // >50%
        
        vm.prank(admin);
        vm.expectRevert("PythOracle: invalid ratio");
        pythOracle.setMaxConfidenceRatio(0);
    }

    // ===== EMERGENCY PAUSE TESTS =====

    function test_EmergencyPause() public {
        vm.prank(emergencyUser);
        pythOracle.setEmergencyPause(true);
        
        assertTrue(pythOracle.emergencyPause());
        assertFalse(pythOracle.isHealthy());
        
        vm.expectRevert("PythOracle: emergency pause active");
        pythOracle.getEthUsd();
    }

    function test_EmergencyUnpause() public {
        // Pause first
        vm.prank(emergencyUser);
        pythOracle.setEmergencyPause(true);
        
        // Then unpause
        vm.prank(admin);
        pythOracle.setEmergencyPause(false);
        
        assertFalse(pythOracle.emergencyPause());
        assertTrue(pythOracle.isHealthy());
        assertEq(pythOracle.getEthUsd(), 4500 * 1e6);
    }

    // ===== PRICE UPDATE TESTS =====

    function test_UpdatePriceFeeds() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "mock_update_data";
        
        uint256 fee = pythOracle.getUpdateFee(updateData);
        
        vm.prank(user);
        pythOracle.updatePriceFeeds{value: fee}(updateData);
        
        // Should complete without reverting
    }

    function test_UpdatePriceFeedsInsufficientFee() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "mock_update_data";
        
        uint256 fee = pythOracle.getUpdateFee(updateData);
        
        vm.prank(user);
        vm.expectRevert("PythOracle: insufficient fee");
        pythOracle.updatePriceFeeds{value: fee - 1}(updateData);
    }

    function test_UpdatePriceFeedsRefundsExcess() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "mock_update_data";
        
        uint256 fee = pythOracle.getUpdateFee(updateData);
        uint256 excessFee = fee + 0.01 ether;
        
        uint256 balanceBefore = user.balance;
        
        vm.prank(user);
        pythOracle.updatePriceFeeds{value: excessFee}(updateData);
        
        uint256 balanceAfter = user.balance;
        assertEq(balanceBefore - balanceAfter, fee); // Only charged the exact fee
    }

    function test_UpdateAndGetPrice() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "mock_update_data";
        
        uint256 fee = pythOracle.getUpdateFee(updateData);
        
        vm.prank(user);
        uint256 price = pythOracle.updateAndGetPrice{value: fee}(updateData);
        
        assertEq(price, 4500 * 1e6);
    }

    // ===== UTILITY FUNCTION TESTS =====

    function test_GetRawPythPrice() public view {
        (int64 price, uint64 conf, int32 expo, uint256 publishTime) = pythOracle.getRawPythPrice();
        
        assertEq(price, DEFAULT_PYTH_PRICE);
        assertEq(conf, DEFAULT_CONFIDENCE);
        assertEq(expo, DEFAULT_EXPO);
        assertEq(publishTime, block.timestamp);
    }

    function test_GetPriceAge() public {
        // Fresh price
        uint256 age = pythOracle.getPriceAge();
        assertEq(age, 0); // Just set in setUp
        
        // Warp time and check age
        vm.warp(block.timestamp + 1800); // 30 minutes
        age = pythOracle.getPriceAge();
        assertEq(age, 1800);
    }

    function test_GetConfidenceRatio() public view {
        uint256 ratio = pythOracle.getConfidenceRatio();
        // DEFAULT_CONFIDENCE (1e9) / DEFAULT_PYTH_PRICE (4.5e11) * 10000 = ~22 basis points
        assertApproxEqAbs(ratio, 22, 5);
    }

    function test_GetConfig() public view {
        (uint256 maxAge, uint256 maxRatio, bool isPaused) = pythOracle.getConfig();
        
        assertEq(maxAge, 3600);
        assertEq(maxRatio, 1000);
        assertEq(isPaused, false);
    }


    // ===== EDGE CASE TESTS =====

    function test_MultipleUpdatesWithDifferentFees() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "mock_data";
        
        // First update with exact fee
        uint256 fee1 = mockPyth.updateFee();
        vm.prank(user);
        pythOracle.updatePriceFeeds{value: fee1}(updateData);
        
        // Change fee and update again
        mockPyth.setUpdateFee(0.002 ether);
        uint256 fee2 = pythOracle.getUpdateFee(updateData);
        
        vm.prank(user);
        pythOracle.updatePriceFeeds{value: fee2}(updateData);
        
        // Both should succeed
    }

    function test_ConfigurationChangesAffectBehavior() public {
        // Set very strict confidence ratio (lower than current ~22 basis points)
        vm.prank(admin);
        pythOracle.setMaxConfidenceRatio(10); // 0.1%
        
        // Current price should make oracle unhealthy
        assertFalse(pythOracle.isHealthy());
        
        // Set more lenient ratio  
        vm.prank(admin);
        pythOracle.setMaxConfidenceRatio(100); // 1%
        
        // Now should be healthy
        assertTrue(pythOracle.isHealthy());
    }
}