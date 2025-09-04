// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {fUSD} from "src/fUSD.sol";
import {DeskController} from "src/controller/DeskController.sol";
import {MockOracle} from "src/oracles/MockOracle.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

/**
 * @title BadOracle
 * @dev Oracle that doesn't implement IOracle properly for testing validation
 */
contract BadOracle {
    // Doesn't implement IOracle interface
    function badFunction() external pure returns (uint256) {
        return 1000;
    }
}

/**
 * @title UnhealthyOracle
 * @dev Oracle that reports as unhealthy for testing
 */
contract UnhealthyOracle is IOracle {
    function getEthUsd() external pure override returns (uint256) {
        return 4500 * 1e6;
    }

    function isHealthy() external pure override returns (bool) {
        return false; // Always unhealthy
    }
}

/**
 * @title OracleSwitchingTest
 * @dev Tests oracle switching functionality and timelock mechanism in DeskController
 */
contract OracleSwitchingTest is Test {
    fUSD public stablecoin;
    DeskController public deskController;
    MockOracle public mockOracle1;
    MockOracle public mockOracle2;
    BadOracle public badOracle;
    UnhealthyOracle public unhealthyOracle;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public unauthorized = address(0x3);

    uint256 public constant ORACLE_UPDATE_DELAY = 2 days;

    function setUp() public {
        stablecoin = new fUSD();
        mockOracle1 = new MockOracle(admin);
        deskController = new DeskController(address(stablecoin), address(mockOracle1));

        // Deploy additional oracles for testing
        mockOracle2 = new MockOracle(admin);
        badOracle = new BadOracle();
        unhealthyOracle = new UnhealthyOracle();

        // Set different price for second oracle to distinguish them
        vm.prank(admin);
        mockOracle2.setPrice(5000 * 1e6); // $5000

        // Setup permissions
        stablecoin.grantRole(stablecoin.CONTROLLER_ROLE(), address(deskController));
        deskController.grantRole(deskController.ADMIN_ROLE(), admin);

        // Set short cooldown for testing
        vm.prank(admin);
        deskController.setConfig(1, deskController.minMint(), deskController.minEth());

        vm.label(address(stablecoin), "fUSD");
        vm.label(address(deskController), "DeskController");
        vm.label(address(mockOracle1), "MockOracle1");
        vm.label(address(mockOracle2), "MockOracle2");
        vm.label(admin, "Admin");
        vm.label(user, "User");
        vm.label(unauthorized, "Unauthorized");
    }

    // ===== INITIAL STATE TESTS =====

    function test_InitialOracleState() public view {
        assertEq(address(deskController.oracle()), address(mockOracle1));
        assertEq(deskController.pendingOracle(), address(0));
        assertEq(deskController.oracleUpdateTimestamp(), 0);
    }

    function test_InitialPriceFromOracle() public view {
        assertEq(deskController.getEthUsd(), 4500 * 1e6); // mockOracle1 price
    }

    // ===== ORACLE PROPOSAL TESTS =====

    function test_ProposeOracleUpdate() public {
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        assertEq(deskController.pendingOracle(), address(mockOracle2));
        assertEq(deskController.oracleUpdateTimestamp(), block.timestamp + ORACLE_UPDATE_DELAY);

        // Current oracle should still be the old one
        assertEq(address(deskController.oracle()), address(mockOracle1));
    }

    function test_ProposeOracleUpdateUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        deskController.proposeOracleUpdate(address(mockOracle2));
    }

    function test_ProposeOracleUpdateZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Oracle: zero address");
        deskController.proposeOracleUpdate(address(0));
    }

    function test_ProposeOracleUpdateSameAddress() public {
        vm.prank(admin);
        vm.expectRevert("Oracle: same address");
        deskController.proposeOracleUpdate(address(mockOracle1));
    }

    function test_ProposeOracleUpdateInvalidInterface() public {
        vm.prank(admin);
        vm.expectRevert("Oracle: invalid interface");
        deskController.proposeOracleUpdate(address(badOracle));
    }

    function test_ProposeOracleUpdateUnhealthy() public {
        vm.prank(admin);
        vm.expectRevert("Oracle: not healthy");
        deskController.proposeOracleUpdate(address(unhealthyOracle));
    }

    function test_ProposeOracleUpdateInvalidPrice() public {
        // Create oracle that returns 0 price
        vm.mockCall(address(mockOracle2), abi.encodeWithSelector(IOracle.getEthUsd.selector), abi.encode(0));

        vm.prank(admin);
        vm.expectRevert("Oracle: invalid price");
        deskController.proposeOracleUpdate(address(mockOracle2));

        vm.clearMockedCalls();
    }

    function test_ProposeOracleUpdateEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DeskController.OracleUpdateProposed(
            address(mockOracle1), address(mockOracle2), block.timestamp + ORACLE_UPDATE_DELAY
        );
        deskController.proposeOracleUpdate(address(mockOracle2));
    }

    // ===== ORACLE EXECUTION TESTS =====

    function test_ExecuteOracleUpdate() public {
        // First propose
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        // Wait for timelock
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);

        // Execute
        vm.prank(admin);
        deskController.executeOracleUpdate();

        // Verify switch
        assertEq(address(deskController.oracle()), address(mockOracle2));
        assertEq(deskController.pendingOracle(), address(0));
        assertEq(deskController.oracleUpdateTimestamp(), 0);

        // Price should now come from new oracle
        assertEq(deskController.getEthUsd(), 5000 * 1e6); // mockOracle2 price
    }

    function test_ExecuteOracleUpdateUnauthorized() public {
        // Propose and wait
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);

        vm.prank(unauthorized);
        vm.expectRevert();
        deskController.executeOracleUpdate();
    }

    function test_ExecuteOracleUpdateNoPending() public {
        vm.prank(admin);
        vm.expectRevert("No pending oracle");
        deskController.executeOracleUpdate();
    }

    function test_ExecuteOracleUpdateTimelockNotExpired() public {
        // Propose but don't wait
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        vm.prank(admin);
        vm.expectRevert("Timelock not expired");
        deskController.executeOracleUpdate();
    }

    function test_ExecuteOracleUpdateExpired() public {
        // Propose and wait too long
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY + 1 days + 1); // 1 second past expiration

        vm.prank(admin);
        vm.expectRevert("Update expired");
        deskController.executeOracleUpdate();
    }

    function test_ExecuteOracleUpdateEmitsEvent() public {
        // Propose and wait
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DeskController.OracleUpdated(address(mockOracle1), address(mockOracle2));
        deskController.executeOracleUpdate();
    }

    // ===== ORACLE CANCELLATION TESTS =====

    function test_CancelOracleUpdate() public {
        // Propose update
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        // Cancel it
        vm.prank(admin);
        deskController.cancelOracleUpdate();

        // Should clear pending state
        assertEq(deskController.pendingOracle(), address(0));
        assertEq(deskController.oracleUpdateTimestamp(), 0);

        // Original oracle should still be active
        assertEq(address(deskController.oracle()), address(mockOracle1));
    }

    function test_CancelOracleUpdateUnauthorized() public {
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        vm.prank(unauthorized);
        vm.expectRevert();
        deskController.cancelOracleUpdate();
    }

    function test_CancelOracleUpdateNoPending() public {
        vm.prank(admin);
        vm.expectRevert("No pending oracle");
        deskController.cancelOracleUpdate();
    }

    function test_CancelOracleUpdateEmitsEvent() public {
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DeskController.OracleUpdateCancelled(address(mockOracle2));
        deskController.cancelOracleUpdate();
    }

    // ===== PRICE CONTINUITY TESTS =====

    function test_PriceContinuityAfterSwitch() public {
        // Record price from original oracle
        uint256 originalPrice = deskController.getEthUsd();
        assertEq(originalPrice, 4500 * 1e6);

        // Propose and execute switch
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        // Price should immediately reflect new oracle
        uint256 newPrice = deskController.getEthUsd();
        assertEq(newPrice, 5000 * 1e6);

        // Price tracking should be updated
        (uint256 lastPrice,,) = deskController.getPriceInfo();
        assertEq(lastPrice, 5000 * 1e6);
    }

    function test_LastPriceUpdateOnSwitch() public {
        uint256 timeBefore = block.timestamp;

        // Propose and execute switch
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        // lastPriceUpdate should be updated to switch time
        (, uint256 lastUpdate,) = deskController.getPriceInfo();
        assertGe(lastUpdate, timeBefore + ORACLE_UPDATE_DELAY);
    }

    // ===== FUNCTIONALITY DURING SWITCHING TESTS =====

    function test_MintingWorksDuringPendingUpdate() public {
        // Propose update but don't execute
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        // Minting should still work with original oracle
        vm.deal(user, 1 ether);
        vm.prank(user);
        deskController.mint{value: 0.1 ether}();

        assertTrue(stablecoin.balanceOf(user) > 0);
    }

    function test_OracleHealthChecksDuringSwitch() public {
        // Propose update
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        // Health checks should still use original oracle
        assertTrue(deskController.isOracleHealthy());

        // Make original oracle unhealthy
        vm.prank(admin);
        mockOracle1.setHealthStatus(false);

        assertFalse(deskController.isOracleHealthy());
    }

    // ===== MULTIPLE PROPOSAL TESTS =====

    function test_OverwritePendingProposal() public {
        // First proposal
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));

        MockOracle mockOracle3 = new MockOracle(admin);
        vm.prank(admin);
        mockOracle3.setPrice(6000 * 1e6);

        // Second proposal (should overwrite first)
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle3));

        assertEq(deskController.pendingOracle(), address(mockOracle3));
    }

    function test_ExecuteAfterNewProposal() public {
        // First proposal
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        uint256 firstTimestamp = deskController.oracleUpdateTimestamp();

        // Wait halfway through timelock
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY / 2);

        MockOracle mockOracle3 = new MockOracle(admin);
        vm.prank(admin);
        mockOracle3.setPrice(6000 * 1e6);

        // New proposal resets timelock
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle3));
        uint256 secondTimestamp = deskController.oracleUpdateTimestamp();

        assertGt(secondTimestamp, firstTimestamp);

        // Can't execute with first timelock
        vm.warp(firstTimestamp);
        vm.prank(admin);
        vm.expectRevert("Timelock not expired");
        deskController.executeOracleUpdate();

        // Can execute with second timelock
        vm.warp(secondTimestamp);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        assertEq(address(deskController.oracle()), address(mockOracle3));
    }

    // ===== EDGE CASE TESTS =====

    function test_SwitchBackToOriginalOracle() public {
        // Switch to oracle 2
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle2));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        assertEq(address(deskController.oracle()), address(mockOracle2));

        // Switch back to oracle 1
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(mockOracle1));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        assertEq(address(deskController.oracle()), address(mockOracle1));
        assertEq(deskController.getEthUsd(), 4500 * 1e6);
    }

    function test_MultipleSequentialSwitches() public {
        MockOracle[] memory oracles = new MockOracle[](3);
        uint256[] memory prices = new uint256[](3);

        // Create multiple oracles with different prices
        for (uint256 i = 0; i < 3; i++) {
            oracles[i] = new MockOracle(admin);
            prices[i] = (4500 + i * 500) * 1e6;
            vm.prank(admin);
            oracles[i].setPrice(prices[i]);
        }

        // Switch through all oracles sequentially
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(admin);
            deskController.proposeOracleUpdate(address(oracles[i]));
            vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
            vm.prank(admin);
            deskController.executeOracleUpdate();

            assertEq(address(deskController.oracle()), address(oracles[i]));
            assertEq(deskController.getEthUsd(), prices[i]);
        }
    }

    function test_SwitchWithDifferentOracleTypes() public {
        // This test would be expanded when we have PythOracle integration
        // For now, just test with different MockOracle configurations

        MockOracle specialOracle = new MockOracle(admin);
        vm.startPrank(admin);
        specialOracle.setPrice(7500 * 1e6);
        specialOracle.setFluctuations(true);
        specialOracle.setFluctuationRange(200); // 2%
        vm.stopPrank();

        // Switch to special oracle
        vm.prank(admin);
        deskController.proposeOracleUpdate(address(specialOracle));
        vm.warp(block.timestamp + ORACLE_UPDATE_DELAY);
        vm.prank(admin);
        deskController.executeOracleUpdate();

        // Verify it works with fluctuations
        assertEq(address(deskController.oracle()), address(specialOracle));
        uint256 price = deskController.getEthUsd();
        assertGt(price, 7000 * 1e6); // Should be around 7500 with fluctuations
        assertLt(price, 8000 * 1e6);
    }
}
