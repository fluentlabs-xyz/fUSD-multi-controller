// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockOracle} from "src/oracles/MockOracle.sol";

/**
 * @title MockOracleTest
 * @dev Tests MockOracle-specific functionality and AccessControl features
 */
contract MockOracleTest is Test {
    MockOracle public oracle;

    address public admin = address(0x1);
    address public emergencyUser = address(0x2);
    address public unauthorizedUser = address(0x3);

    uint256 public constant DEFAULT_PRICE = 4500 * 1e6; // $4500 with 6 decimals

    function setUp() public {
        oracle = new MockOracle(admin);

        // Grant emergency role to emergency user
        vm.prank(admin);
        oracle.grantEmergencyRole(emergencyUser);

        vm.label(address(oracle), "MockOracle");
        vm.label(admin, "Admin");
        vm.label(emergencyUser, "Emergency");
        vm.label(unauthorizedUser, "Unauthorized");
    }

    // ===== BASIC FUNCTIONALITY TESTS =====

    function test_InitialState() public view {
        assertEq(oracle.getEthUsd(), DEFAULT_PRICE);
        assertTrue(oracle.isHealthy());
        assertFalse(oracle.enableFluctuations());
        assertEq(oracle.fluctuationRange(), 50); // 0.5% default
    }

    function test_AccessControlSetup() public view {
        // Admin has all roles
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.EMERGENCY_ROLE(), admin));

        // Emergency user only has emergency role
        assertFalse(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), emergencyUser));
        assertFalse(oracle.hasRole(oracle.ADMIN_ROLE(), emergencyUser));
        assertTrue(oracle.hasRole(oracle.EMERGENCY_ROLE(), emergencyUser));

        // Unauthorized user has no roles
        assertFalse(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), unauthorizedUser));
        assertFalse(oracle.hasRole(oracle.ADMIN_ROLE(), unauthorizedUser));
        assertFalse(oracle.hasRole(oracle.EMERGENCY_ROLE(), unauthorizedUser));
    }

    // ===== PRICE MANAGEMENT TESTS =====

    function test_SetPrice() public {
        uint256 newPrice = 5000 * 1e6; // $5000

        vm.prank(admin);
        oracle.setPrice(newPrice);

        assertEq(oracle.getEthUsd(), newPrice);
    }

    function test_SetPriceUnauthorized() public {
        uint256 newPrice = 5000 * 1e6;

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        oracle.setPrice(newPrice);
    }

    function test_SetPriceEmitsEvent() public {
        uint256 newPrice = 5000 * 1e6;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit MockOracle.PriceUpdated(DEFAULT_PRICE, newPrice);
        oracle.setPrice(newPrice);
    }

    function test_SetPriceZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("MockOracle: price must be positive");
        oracle.setPrice(0);
    }

    // ===== FLUCTUATION TESTS =====

    function test_FluctuationToggle() public {
        // Initially disabled
        assertFalse(oracle.enableFluctuations());

        // Enable fluctuations
        vm.prank(admin);
        oracle.setFluctuations(true);
        assertTrue(oracle.enableFluctuations());

        // Disable fluctuations
        vm.prank(admin);
        oracle.setFluctuations(false);
        assertFalse(oracle.enableFluctuations());
    }

    function test_FluctuationToggleUnauthorized() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        oracle.setFluctuations(true);
    }

    function test_FluctuationRangeUpdate() public {
        uint256 newRange = 100; // 1%

        vm.prank(admin);
        oracle.setFluctuationRange(newRange);

        assertEq(oracle.fluctuationRange(), newRange);
    }

    function test_FluctuationRangeUnauthorized() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        oracle.setFluctuationRange(100);
    }

    function test_FluctuationRangeTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("MockOracle: range too high");
        oracle.setFluctuationRange(1001); // >10%
    }

    function test_PriceFluctuations() public {
        // Enable fluctuations with 1% range
        vm.prank(admin);
        oracle.setFluctuations(true);
        vm.prank(admin);
        oracle.setFluctuationRange(100); // 1%

        uint256 basePrice = oracle.ETH_PRICE();

        // Get prices at different timestamps
        uint256 price1 = oracle.getPriceAtTime(300); // 5 minutes
        uint256 price2 = oracle.getPriceAtTime(600); // 10 minutes
        uint256 price3 = oracle.getPriceAtTime(900); // 15 minutes

        // Prices should be different due to deterministic fluctuations
        assertTrue(price1 != price2 || price2 != price3);

        // All prices should be within the range
        uint256 maxDeviation = (basePrice * 100) / 10000; // 1%
        assertGe(price1, basePrice - maxDeviation);
        assertLe(price1, basePrice + maxDeviation);
    }

    // ===== HEALTH STATUS TESTS =====

    function test_HealthStatusToggle() public {
        // Initially healthy
        assertTrue(oracle.isHealthy());

        // Set unhealthy (emergency role)
        vm.prank(emergencyUser);
        oracle.setHealthStatus(false);
        assertFalse(oracle.isHealthy());

        // Set healthy again (admin can also do emergency actions)
        vm.prank(admin);
        oracle.setHealthStatus(true);
        assertTrue(oracle.isHealthy());
    }

    function test_HealthStatusUnauthorized() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        oracle.setHealthStatus(false);
    }

    function test_UnhealthyOracleReverts() public {
        vm.prank(emergencyUser);
        oracle.setHealthStatus(false);

        vm.expectRevert("MockOracle: oracle unhealthy");
        oracle.getEthUsd();
    }

    function test_SimulateFailure() public {
        vm.prank(emergencyUser);
        oracle.simulateFailure();

        assertFalse(oracle.isHealthy());
        vm.expectRevert("MockOracle: oracle unhealthy");
        oracle.getEthUsd();
    }

    function test_SimulateRecovery() public {
        // First simulate failure
        vm.prank(emergencyUser);
        oracle.simulateFailure();
        assertFalse(oracle.isHealthy());

        // Then simulate recovery
        vm.prank(admin);
        oracle.simulateRecovery();
        assertTrue(oracle.isHealthy());

        // Should work again
        assertEq(oracle.getEthUsd(), DEFAULT_PRICE);
    }

    // ===== UTILITY FUNCTION TESTS =====

    function test_GetCurrentPrice() public {
        // Without fluctuations
        assertEq(oracle.getCurrentPrice(), DEFAULT_PRICE);

        // With fluctuations
        vm.prank(admin);
        oracle.setFluctuations(true);

        uint256 currentPrice = oracle.getCurrentPrice();
        assertGt(currentPrice, 0); // Should return some price
    }

    function test_GetOracleConfig() public view {
        (uint256 basePrice, bool fluctuationsEnabled, uint256 range, bool healthy) = oracle.getOracleConfig();

        assertEq(basePrice, DEFAULT_PRICE);
        assertEq(fluctuationsEnabled, false);
        assertEq(range, 50);
        assertEq(healthy, true);
    }

    // ===== ROLE MANAGEMENT TESTS =====

    function test_AdminCanGrantRoles() public {
        address newUser = address(0x4);

        vm.startPrank(admin);
        oracle.grantAdminRole(newUser);
        vm.stopPrank();

        assertTrue(oracle.hasRole(oracle.ADMIN_ROLE(), newUser));
    }

    function test_NonAdminCannotGrantRoles() public {
        address newUser = address(0x4);

        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        oracle.grantAdminRole(newUser);
        vm.stopPrank();

        assertFalse(oracle.hasRole(oracle.ADMIN_ROLE(), newUser));
    }

    function test_AdminCanRevokeRoles() public {
        // First grant role
        address newUser = address(0x4);
        vm.startPrank(admin);
        oracle.grantAdminRole(newUser);
        vm.stopPrank();
        assertTrue(oracle.hasRole(oracle.ADMIN_ROLE(), newUser));

        // Then revoke it
        vm.startPrank(admin);
        oracle.revokeAdminRole(newUser);
        vm.stopPrank();
        assertFalse(oracle.hasRole(oracle.ADMIN_ROLE(), newUser));
    }

    // ===== EDGE CASE TESTS =====

    function test_MultipleConfigChanges() public {
        vm.startPrank(admin);

        // Change price
        oracle.setPrice(5500 * 1e6);
        assertEq(oracle.getEthUsd(), 5500 * 1e6);

        // Enable fluctuations
        oracle.setFluctuations(true);
        oracle.setFluctuationRange(200); // 2%

        // Change price again
        oracle.setPrice(6000 * 1e6);

        vm.stopPrank();

        // Verify final state
        assertEq(oracle.ETH_PRICE(), 6000 * 1e6);
        assertTrue(oracle.enableFluctuations());
        assertEq(oracle.fluctuationRange(), 200);
    }

    function test_FluctuationsWithPriceChanges() public {
        vm.startPrank(admin);

        // Set new base price and enable fluctuations
        oracle.setPrice(5000 * 1e6);
        oracle.setFluctuations(true);
        oracle.setFluctuationRange(50); // 0.5%

        vm.stopPrank();

        // Test fluctuations work with new base price
        uint256 price1 = oracle.getPriceAtTime(300);
        uint256 price2 = oracle.getPriceAtTime(600);

        // Should fluctuate around new base price
        uint256 newBase = 5000 * 1e6;
        uint256 maxDev = (newBase * 50) / 10000;

        assertGe(price1, newBase - maxDev);
        assertLe(price1, newBase + maxDev);
    }
}
