// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title MockOracle
 * @dev Mock oracle for testing fUSD with configurable ETH/USD pricing
 * Includes deterministic fluctuations and health status for testing various scenarios
 */
contract MockOracle is IOracle, AccessControl {
    uint256 public ethPrice = 4500 * 1e6; // $4500 with 6 decimals
    bool public enableFluctuations = false;
    uint256 public fluctuationRange = 50; // 0.5% = 50 basis points

    // Oracle health status
    bool public isOracleHealthy = true;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Events
    event FluctuationsToggled(bool enabled);
    event FluctuationRangeUpdated(uint256 oldRange, uint256 newRange);
    event HealthStatusUpdated(bool oldStatus, bool newStatus);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    /**
     * @dev Constructor
     * @param _admin Initial admin address
     */
    constructor(address _admin) {
        require(_admin != address(0), "MockOracle: zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    /**
     * @dev Internal function to calculate price with fluctuations
     * @param timestamp Timestamp to calculate price for
     * @return Price with fluctuations applied
     */
    function _calculatePriceWithFluctuations(uint256 timestamp) internal view returns (uint256) {
        if (!enableFluctuations) return ethPrice;

        // Deterministic fluctuations for testing
        // Changes every 5 minutes (300 seconds) for predictable testing
        uint256 seed = uint256(keccak256(abi.encode(timestamp / 300)));

        // Generate a more meaningful deviation that actually uses the full range
        // Convert basis points to actual percentage and apply to price
        uint256 maxDeviation = (ethPrice * fluctuationRange) / 10000; // Convert basis points to actual price deviation
        uint256 deviation = seed % (maxDeviation * 2 + 1); // +1 to include maxDeviation
        uint256 priceChange = deviation > maxDeviation ? maxDeviation : deviation;

        // Randomly decide if price goes up or down
        bool priceGoesUp = (seed % 2) == 0;

        if (priceGoesUp) {
            return ethPrice + priceChange;
        } else {
            return ethPrice > priceChange ? ethPrice - priceChange : ethPrice / 2; // Prevent negative prices
        }
    }

    /**
     * @dev Get current ETH/USD price
     * @return Current ETH price in 6 decimals
     */
    function getEthUsd() external view returns (uint256) {
        require(isOracleHealthy, "MockOracle: oracle unhealthy");

        if (!enableFluctuations) return ethPrice;

        return _calculatePriceWithFluctuations(block.timestamp);
    }

    /**
     * @dev Check if oracle is healthy
     * @return True if oracle is functioning normally
     */
    function isHealthy() external view returns (bool) {
        return isOracleHealthy;
    }

    /**
     * @dev Toggle price fluctuations on/off
     * @param enabled Whether to enable fluctuations
     */
    function setFluctuations(bool enabled) external onlyRole(ADMIN_ROLE) {
        enableFluctuations = enabled;

        emit FluctuationsToggled(enabled);
    }

    /**
     * @dev Update fluctuation range
     * @param newRange New fluctuation range in basis points (1 = 0.01%)
     */
    function setFluctuationRange(uint256 newRange) external onlyRole(ADMIN_ROLE) {
        require(newRange <= 1000, "MockOracle: range too high"); // Max 10%

        uint256 oldRange = fluctuationRange;
        fluctuationRange = newRange;

        emit FluctuationRangeUpdated(oldRange, newRange);
    }

    /**
     * @dev Set oracle health status
     * @param healthy Whether oracle should be healthy
     */
    function setHealthStatus(bool healthy) external onlyRole(EMERGENCY_ROLE) {
        bool oldStatus = isOracleHealthy;
        isOracleHealthy = healthy;

        emit HealthStatusUpdated(oldStatus, healthy);
    }

    /**
     * @dev Get current price with fluctuations (if enabled)
     * @return Current price with any fluctuations applied
     */
    function getCurrentPrice() external view returns (uint256) {
        return _calculatePriceWithFluctuations(block.timestamp);
    }

    /**
     * @dev Get price at a specific timestamp (for testing)
     * @param timestamp Timestamp to get price for
     * @return Price at that timestamp
     */
    function getPriceAtTime(uint256 timestamp) external view returns (uint256) {
        return _calculatePriceWithFluctuations(timestamp);
    }

    /**
     * @dev Get oracle configuration
     * @return basePrice Base ETH price
     * @return fluctuationsEnabled Whether fluctuations are enabled
     * @return range Current fluctuation range
     * @return healthy Oracle health status
     */
    function getOracleConfig()
        external
        view
        returns (uint256 basePrice, bool fluctuationsEnabled, uint256 range, bool healthy)
    {
        return (ethPrice, enableFluctuations, fluctuationRange, isOracleHealthy);
    }

    /**
     * @dev Simulate oracle failure (for testing error scenarios)
     */
    function simulateFailure() external onlyRole(EMERGENCY_ROLE) {
        isOracleHealthy = false;
        emit HealthStatusUpdated(true, false);
    }

    /**
     * @dev Simulate oracle recovery
     */
    function simulateRecovery() external onlyRole(EMERGENCY_ROLE) {
        isOracleHealthy = true;
        emit HealthStatusUpdated(false, true);
    }

    /**
     * @dev Set a specific price for testing purposes (admin only)
     * @param newPrice New price to set
     */
    function setPrice(uint256 newPrice) external onlyRole(ADMIN_ROLE) {
        require(newPrice > 0, "MockOracle: price must be positive");

        uint256 oldPrice = ethPrice;
        ethPrice = newPrice;

        emit PriceUpdated(oldPrice, newPrice);
    }

    // ===== ROLE MANAGEMENT FUNCTIONS =====

    /**
     * @dev Grant admin role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant admin role to
     */
    function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "MockOracle: zero address");
        _grantRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Revoke admin role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke admin role from
     */
    function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "MockOracle: zero address");
        _revokeRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Grant emergency role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant emergency role to
     */
    function grantEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "MockOracle: zero address");
        _grantRole(EMERGENCY_ROLE, account);
    }

    /**
     * @dev Revoke emergency role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke emergency role from
     */
    function revokeEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "MockOracle: zero address");
        _revokeRole(EMERGENCY_ROLE, account);
    }

    /**
     * @dev Check if an address has admin role
     * @param account Address to check
     * @return True if address has admin role
     */
    function hasAdminRole(address account) external view returns (bool) {
        return hasRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Check if an address has emergency role
     * @param account Address to check
     * @return True if address has emergency role
     */
    function hasEmergencyRole(address account) external view returns (bool) {
        return hasRole(EMERGENCY_ROLE, account);
    }
}
