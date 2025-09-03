// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title MockOracle
 * @dev Mock oracle for testing fUSD with configurable ETH/USD pricing
 * Includes deterministic fluctuations and health status for testing various scenarios
 */
contract MockOracle is IOracle {
    uint256 public ETH_PRICE = 4500 * 1e6; // $4500 with 6 decimals
    bool public enableFluctuations = false;
    uint256 public fluctuationRange = 50; // 0.5% = 50 basis points

    // Oracle health status
    bool public isOracleHealthy = true;

    // Admin controls
    address public admin;

    // Events
    event FluctuationsToggled(bool enabled);
    event FluctuationRangeUpdated(uint256 oldRange, uint256 newRange);
    event HealthStatusUpdated(bool oldStatus, bool newStatus);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    // Modifier for admin-only functions
    modifier onlyAdmin() {
        require(msg.sender == admin, "MockOracle: admin only");
        _;
    }

    /**
     * @dev Constructor
     * @param _admin Initial admin address
     */
    constructor(address _admin) {
        require(_admin != address(0), "MockOracle: zero address");
        admin = _admin;
    }

    /**
     * @dev Internal function to calculate price with fluctuations
     * @param timestamp Timestamp to calculate price for
     * @return Price with fluctuations applied
     */
    function _calculatePriceWithFluctuations(uint256 timestamp) internal view returns (uint256) {
        if (!enableFluctuations) return ETH_PRICE;

        // Deterministic fluctuations for testing
        // Changes every 5 minutes (300 seconds) for predictable testing
        uint256 seed = uint256(keccak256(abi.encode(timestamp / 300)));

        // Generate a more meaningful deviation that actually uses the full range
        // Convert basis points to actual percentage and apply to price
        uint256 maxDeviation = (ETH_PRICE * fluctuationRange) / 10000; // Convert basis points to actual price deviation
        uint256 deviation = seed % (maxDeviation * 2 + 1); // +1 to include maxDeviation
        uint256 priceChange = deviation > maxDeviation ? maxDeviation : deviation;

        // Randomly decide if price goes up or down
        bool priceGoesUp = (seed % 2) == 0;

        if (priceGoesUp) {
            return ETH_PRICE + priceChange;
        } else {
            return ETH_PRICE > priceChange ? ETH_PRICE - priceChange : ETH_PRICE / 2; // Prevent negative prices
        }
    }

    /**
     * @dev Get current ETH/USD price
     * @return Current ETH price in 6 decimals
     */
    function getEthUsd() external view returns (uint256) {
        require(isOracleHealthy, "MockOracle: oracle unhealthy");

        if (!enableFluctuations) return ETH_PRICE;

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
    function setFluctuations(bool enabled) external onlyAdmin {
        enableFluctuations = enabled;

        emit FluctuationsToggled(enabled);
    }

    /**
     * @dev Update fluctuation range
     * @param newRange New fluctuation range in basis points (1 = 0.01%)
     */
    function setFluctuationRange(uint256 newRange) external onlyAdmin {
        require(newRange <= 1000, "MockOracle: range too high"); // Max 10%

        uint256 oldRange = fluctuationRange;
        fluctuationRange = newRange;

        emit FluctuationRangeUpdated(oldRange, newRange);
    }

    /**
     * @dev Set oracle health status
     * @param healthy Whether oracle should be healthy
     */
    function setHealthStatus(bool healthy) external onlyAdmin {
        bool oldStatus = isOracleHealthy;
        isOracleHealthy = healthy;

        emit HealthStatusUpdated(oldStatus, healthy);
    }

    /**
     * @dev Update admin address
     * @param newAdmin New admin address
     */
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "MockOracle: zero address");

        address oldAdmin = admin;
        admin = newAdmin;

        emit AdminUpdated(oldAdmin, newAdmin);
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
        return (ETH_PRICE, enableFluctuations, fluctuationRange, isOracleHealthy);
    }

    /**
     * @dev Simulate oracle failure (for testing error scenarios)
     */
    function simulateFailure() external onlyAdmin {
        isOracleHealthy = false;
        emit HealthStatusUpdated(true, false);
    }

    /**
     * @dev Simulate oracle recovery
     */
    function simulateRecovery() external onlyAdmin {
        isOracleHealthy = true;
        emit HealthStatusUpdated(false, true);
    }

    /**
     * @dev Set a specific price for testing purposes (admin only)
     * @param newPrice New price to set
     */
    function setPrice(uint256 newPrice) external onlyAdmin {
        require(newPrice > 0, "MockOracle: price must be positive");

        uint256 oldPrice = ETH_PRICE;
        ETH_PRICE = newPrice;

        emit PriceUpdated(oldPrice, newPrice);
    }
}
