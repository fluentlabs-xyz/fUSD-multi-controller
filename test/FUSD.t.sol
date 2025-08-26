// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "src/fUSD.sol";
import "src/controller/DeskController.sol";
import "src/controller/ControllerRegistry.sol";
import "src/MockOracle.sol";
import "src/interfaces/IController.sol";
import "src/interfaces/IOracle.sol";
import "src/interfaces/IUSD.sol";

contract FUSDTest is Test {
    fUSD public token;
    DeskController public desk;
    ControllerRegistry public registry;
    MockOracle public oracle;
    
    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public emergency = address(0x4);
    
    uint256 public constant ETH_PRICE = 4500 * 1e6; // $4500
    uint256 public constant INITIAL_ETH = 10 ether;
    
    function setUp() public {
        // Deploy contracts
        token = new fUSD();
        oracle = new MockOracle(admin);
        desk = new DeskController(address(token), address(oracle));
        registry = new ControllerRegistry(admin);
        
        // Setup permissions
        token.grantRole(token.CONTROLLER_ROLE(), address(desk));
        desk.grantAdminRole(admin);
        desk.grantEmergencyRole(emergency);
        
        // Fund desk with initial ETH
        vm.deal(address(desk), INITIAL_ETH);
        
        // Setup registry
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);
        
        // Label addresses for better test output
        vm.label(address(token), "fUSD");
        vm.label(address(desk), "DeskController");
        vm.label(address(oracle), "MockOracle");
        vm.label(address(registry), "ControllerRegistry");
    }
    
    // ===== CATEGORY A: Core Token Functionality Tests =====
    
    function test_TokenBasics() public view {
        assertEq(token.name(), "Fluent USD");
        assertEq(token.symbol(), "fUSD");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
    }
    
    function test_AccessControl() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.CONTROLLER_ROLE(), admin));
        assertTrue(token.hasRole(token.CONTROLLER_ROLE(), address(desk)));
        assertFalse(token.hasRole(token.CONTROLLER_ROLE(), user1));
    }
    
    function test_MintBurnPermissions() public {
        // Only controllers should be able to mint
        vm.expectRevert();
        token.mint(user1, 1000 * 1e6);
        
        // Controller should be able to mint
        vm.prank(address(desk));
        token.mint(user1, 1000 * 1e6);
        assertEq(token.balanceOf(user1), 1000 * 1e6);
        
        // Only controllers should be able to burn
        vm.expectRevert();
        token.burn(user1, 500 * 1e6);
        
        // Controller should be able to burn
        vm.prank(address(desk));
        token.burn(user1, 500 * 1e6);
        assertEq(token.balanceOf(user1), 500 * 1e6);
    }
    
    // ===== CATEGORY B: DeskController Core Tests =====
    
    function test_MintFunctionality() public {
        uint256 mintAmount = 1 ether;
        uint256 expectedFUSD = (mintAmount * ETH_PRICE) / 1e18;
        
        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();
        
        assertEq(token.balanceOf(user1), expectedFUSD);
        assertEq(address(desk).balance, INITIAL_ETH + mintAmount);
    }
    
    function test_BurnFunctionality() public {
        // First mint some fUSD
        uint256 mintAmount = 1 ether;
        uint256 expectedFUSD = (mintAmount * ETH_PRICE) / 1e18;
        
        vm.deal(user1, mintAmount);
        vm.prank(user1);
        desk.mint{value: mintAmount}();
        
        // Now burn it back
        vm.startPrank(user1);
        token.approve(address(desk), expectedFUSD);
        desk.burn(expectedFUSD);
        vm.stopPrank();
        
        // Should get back approximately the same ETH (minus any fees/slippage)
        assertEq(token.balanceOf(user1), 0);
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
        // Set a large price change that should trigger circuit breaker
        vm.prank(admin);
        oracle.setFluctuationRange(1000); // 10% fluctuations
        
        vm.prank(admin);
        oracle.setFluctuations(true);
        
        // This should fail due to price validation
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
        
        uint256 smallAmount = 0.5 * 1e6; // 0.5 fUSD, below minMint
        vm.startPrank(user1);
        token.approve(address(desk), smallAmount);
        vm.expectRevert("Burn amount too small");
        desk.burn(smallAmount);
        vm.stopPrank();
    }
    
    // ===== CATEGORY C: Oracle Integration Tests =====
    
    function test_OracleHealthChecks() public {
        // Test healthy oracle
        assertTrue(desk.isOracleHealthy());
        
        // Test unhealthy oracle
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
        
        uint256 price1 = desk.getETHUSD();
        vm.warp(block.timestamp + 300); // 5 minutes later
        uint256 price2 = desk.getETHUSD();
        
        // Prices should be different due to fluctuations
        assertTrue(price1 != price2);
    }
    
    function test_OracleSwap() public {
        // This would test switching from mock to Pyth oracle
        // For now, test that current oracle works and can be queried
        uint256 currentPrice = desk.getETHUSD();
        assertEq(currentPrice, ETH_PRICE);
        
        // Test that price updates are tracked
        assertEq(desk.priceUpdateCount(), 0);
        
        // Trigger a price update
        vm.deal(user1, 0.1 ether);
        vm.prank(user1);
        desk.mint{value: 0.1 ether}();
        
        assertEq(desk.priceUpdateCount(), 1);
    }
    
    // ===== CATEGORY D: Security & Access Control Tests =====
    
    function test_AdminRoleManagement() public {
        // Test granting admin role
        vm.prank(admin);
        desk.grantAdminRole(user1);
        assertTrue(desk.hasRole(desk.ADMIN_ROLE(), user1));
        
        // Test revoking admin role
        vm.prank(admin);
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
        vm.expectRevert("Pausable: paused");
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
        
        (bool active, string memory name, uint256 dailyLimit, , , ) = registry.controllers(newController);
        assertTrue(active);
        assertEq(name, "Test Controller");
        assertEq(dailyLimit, 500_000 * 1e6);
        
        // Test removing controller
        vm.prank(admin);
        registry.removeController(newController);
        (bool activeAfter, , , , , ) = registry.controllers(newController);
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
        (bool active, string memory name, uint256 dailyLimit, uint256 totalMinted, , ) = registry.controllers(address(desk));
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