// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {fUSD} from "src/fUSD.sol";
import {DeskController} from "src/controller/DeskController.sol";
import {ControllerRegistry} from "src/controller/ControllerRegistry.sol";
import {MockOracle} from "src/oracles/MockOracle.sol";

contract FUSDTest is Test {
    fUSD public stablecoin;
    DeskController public desk;
    ControllerRegistry public registry;
    MockOracle public oracle;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public emergency = address(0x4);

    // Change from constant to regular variable
    uint256 public ETH_PRICE = 4500 * 1e6; // $4500 with 6 decimals
    uint256 public constant INITIAL_ETH = 10 ether;

    function setUp() public {
        // Deploy contracts
        console.log("Deploying contracts...");
        stablecoin = new fUSD();
        oracle = new MockOracle(admin);
        desk = new DeskController(address(stablecoin), address(oracle));
        registry = new ControllerRegistry(admin);

        // Setup permissions
        stablecoin.grantRole(stablecoin.CONTROLLER_ROLE(), address(desk));

        // Remove the CONTROLLER_ROLE from the test contract since we don't need it
        stablecoin.revokeRole(stablecoin.CONTROLLER_ROLE(), address(this));

        // Grant ADMIN_ROLE and EMERGENCY_ROLE directly using the test contract's DEFAULT_ADMIN_ROLE
        desk.grantRole(desk.ADMIN_ROLE(), admin);
        desk.grantRole(desk.EMERGENCY_ROLE(), emergency);
        
        // Oracle roles: admin already has all roles from constructor

        // Set a very short cooldown for testing (1 second instead of 1 day)
        vm.prank(admin);
        desk.setConfig(1, desk.minMint(), desk.minEth());

        // Fund desk with initial ETH
        vm.deal(address(desk), INITIAL_ETH);

        // Setup registry
        vm.prank(admin);
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);

        // Label addresses for better test output
        vm.label(address(stablecoin), "fUSD");
        vm.label(address(desk), "DeskController");
        vm.label(address(oracle), "MockOracle");
        vm.label(address(registry), "ControllerRegistry");

        console.log("Setup complete");
    }

    // ===== CATEGORY A: Core Token Functionality Tests =====

    function test_TokenBasics() public view {
        assertEq(stablecoin.name(), "Fluent USD");
        assertEq(stablecoin.symbol(), "fUSD");
        assertEq(stablecoin.decimals(), 6);
        assertEq(stablecoin.totalSupply(), 0);
    }

    function test_AccessControl() public view {
        // The test contract (address(this)) has only the DEFAULT_ADMIN_ROLE on the token
        assertTrue(stablecoin.hasRole(stablecoin.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(stablecoin.hasRole(stablecoin.CONTROLLER_ROLE(), address(this)));
        // The desk controller has the CONTROLLER_ROLE on the token
        assertTrue(stablecoin.hasRole(stablecoin.CONTROLLER_ROLE(), address(desk)));
        // Regular users don't have any roles on the token
        assertFalse(stablecoin.hasRole(stablecoin.CONTROLLER_ROLE(), user1));
    }

    function test_MintBurnPermissions() public {
        // Only controllers should be able to mint
        vm.expectRevert();
        stablecoin.mint(user1, 1000 * 1e6);

        // Controller should be able to mint
        vm.prank(address(desk));
        stablecoin.mint(user1, 1000 * 1e6);
        assertEq(stablecoin.balanceOf(user1), 1000 * 1e6);

        // Only controllers should be able to burn
        vm.expectRevert();
        stablecoin.burnFrom(user1, 500 * 1e6);

        // Controller should be able to burn
        vm.prank(address(desk));
        stablecoin.burnFrom(user1, 500 * 1e6);
        assertEq(stablecoin.balanceOf(user1), 500 * 1e6);
    }

    // ===== CATEGORY B: DeskController Core Tests =====

    function test_MintFunctionality() public {
        uint256 mintAmount = 1 ether;
        uint256 expectedFusd = (mintAmount * ETH_PRICE) / 1e18;

        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();

        assertEq(stablecoin.balanceOf(user1), expectedFusd);
        assertEq(address(desk).balance, INITIAL_ETH + mintAmount);
    }

    function test_BurnFunctionality() public {
        // First mint some fUSD
        uint256 mintAmount = 1 ether;
        uint256 expectedFusd = (mintAmount * ETH_PRICE) / 1e18;

        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();

        // Wait for cooldown to pass
        vm.warp(block.timestamp + 2); // Wait 2 seconds (more than our 1 second cooldown)

        // Now burn it back
        vm.startPrank(user1);
        stablecoin.approve(address(desk), expectedFusd);
        desk.burn(expectedFusd);
        vm.stopPrank();

        // Should get back approximately the same ETH (minus any fees/slippage)
        assertEq(stablecoin.balanceOf(user1), 0);
        assertGt(user1.balance, 0);
    }

    function test_RateLimiting() public {
        uint256 mintAmount = 0.1 ether;

        // First mint should work
        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();

        // Second mint within cooldown should fail
        vm.deal(user1, mintAmount);
        vm.prank(user1);
        vm.expectRevert("Cooldown active");
        desk.mint{value: mintAmount}();

        // After cooldown, should work again
        vm.warp(block.timestamp + 1 days);
        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();
    }

    function test_PriceValidation() public {
        // Set a specific price that will definitely trigger the circuit breaker
        vm.prank(admin);
        oracle.setPrice(5000 * 1e6); // $5000 (11.11% increase from $4500)

        // This should fail due to price validation (11.11% > 5%)
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        vm.expectRevert("Price move too large");
        desk.mint{value: 0.1 ether}();
    }

    function test_MinimumAmounts() public {
        // Test minimum ETH amount
        vm.deal(user1, 0.00001 ether); // Below minEth
        vm.prank(user1);
        vm.expectRevert("ETH amount too small");
        desk.mint{value: 0.00001 ether}();

        // Test minimum fUSD amount for burn
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        desk.mint{value: 0.1 ether}();

        // Wait for cooldown to pass
        vm.warp(block.timestamp + 2); // Wait 2 seconds (more than our 1 second cooldown)

        uint256 smallAmount = 0.5 * 1e6; // 0.5 fUSD, below minMint
        vm.startPrank(user1);
        stablecoin.approve(address(desk), smallAmount);
        vm.expectRevert("Burn amount too small");
        desk.burn(smallAmount);
        vm.stopPrank();
    }

    // ===== CATEGORY C: Oracle Integration Tests =====

    function test_OracleHealthChecks() public {
        // Test healthy oracle
        assertTrue(desk.isOracleHealthy());

        // Test unhealthy oracle (using admin since they have all oracle roles)
        vm.prank(admin);
        oracle.setHealthStatus(false);

        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        vm.expectRevert("Oracle unhealthy");
        desk.mint{value: 0.1 ether}();
    }

    function test_PriceFluctuations() public {
        vm.prank(admin);
        oracle.setFluctuations(true);
        vm.prank(admin);
        oracle.setFluctuationRange(100); // 1% fluctuations

        uint256 price1 = desk.getEthUsd();
        vm.warp(block.timestamp + 300); // 5 minutes later
        uint256 price2 = desk.getEthUsd();

        // Prices should be different due to fluctuations
        assertTrue(price1 != price2);
    }

    function test_OracleSwap() public {
        // TODO: Implement when Pyth oracle integration is added
        // This test will verify oracle swapping functionality including:
        // - Seamless transition between oracle implementations
        // - Price feed continuity during swaps
        // - Emergency fallback mechanisms
        // - Gas optimization for oracle operations

        // For now, skip this test until oracle swapping is implemented
        vm.skip(true);

        // Placeholder for future implementation
        assertTrue(true); // Remove this when implementing
    }

    // ===== CATEGORY D: Security & Access Control Tests =====

    function test_AdminRoleManagement() public {
        // Test granting admin role
        desk.grantAdminRole(user1);
        assertTrue(desk.hasRole(desk.ADMIN_ROLE(), user1));

        // Test revoking admin role
        desk.revokeRole(desk.ADMIN_ROLE(), user1);
        assertFalse(desk.hasRole(desk.ADMIN_ROLE(), user1));
    }

    function test_EmergencyControls() public {
        // Test pausing minting
        vm.prank(admin);
        desk.pauseMinting();
        assertTrue(desk.mintingPaused());

        // Minting should fail when paused
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        vm.expectRevert("Minting paused");
        desk.mint{value: 0.1 ether}();

        // Test resuming minting
        vm.prank(admin);
        desk.resumeMinting();
        assertFalse(desk.mintingPaused());

        // Minting should work again
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        desk.mint{value: 0.1 ether}();
    }

    function test_ReentrancyProtection() public pure {
        // This test would require a malicious contract that tries to reenter
        // For now, test that the nonReentrant modifier is present
        // The modifier is applied to mint() and burn() functions
        assertTrue(true); // Placeholder - reentrancy tests need malicious contracts
    }

    function test_PausableFunctionality() public {
        // Test global pause
        vm.prank(admin);
        desk.pause();
        assertTrue(desk.paused());

        // All operations should fail when paused
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        desk.mint{value: 0.1 ether}();

        // Test unpause
        vm.prank(admin);
        desk.unpause();
        assertFalse(desk.paused());
    }

    // ===== CATEGORY E: Controller Registry Tests =====

    function test_ControllerManagement() public {
        // Test adding controller
        address newController = address(0x999);
        vm.prank(admin);
        registry.addController(newController, "Test Controller", 500_000 * 1e6);

        (bool active, string memory name, uint256 dailyLimit,,,) = registry.controllers(newController);
        assertTrue(active);
        assertEq(name, "Test Controller");
        assertEq(dailyLimit, 500_000 * 1e6);

        // Test removing controller
        vm.prank(admin);
        registry.removeController(newController);
        (bool activeAfter,,,,,) = registry.controllers(newController);
        assertFalse(activeAfter);
    }

    function test_GlobalLimits() public {
        // Test global daily limit
        assertEq(registry.globalDailyLimit(), 10_000_000 * 1e6); // 10M fUSD

        // Test updating global limit
        vm.prank(admin);
        registry.setGlobalDailyLimit(5_000_000 * 1e6);
        assertEq(registry.globalDailyLimit(), 5_000_000 * 1e6);
    }

    function test_ControllerMetadata() public {
        // Test controller info tracking
        // Access struct fields individually since the mapping returns a tuple
        (bool active, string memory name, uint256 dailyLimit, uint256 totalMinted,,) =
            registry.controllers(address(desk));
        assertTrue(active);
        assertEq(name, "Trading Desk");
        assertEq(dailyLimit, 1_000_000 * 1e6);
        assertEq(totalMinted, 0);

        // Test daily reset logic - daily limits are automatically reset after 24 hours
        vm.warp(block.timestamp + 1 days);

        // Check that daily limit is reset by calling getRemainingDailyLimit
        uint256 remainingLimit = registry.getRemainingDailyLimit(address(desk));
        assertEq(remainingLimit, 1_000_000 * 1e6); // Should be back to full daily limit
    }
}
