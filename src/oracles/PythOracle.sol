// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracle} from "../interfaces/IOracle.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title PythOracle
 * @dev Oracle implementation using Pyth Network for ETH/USD price feeds
 * Converts Pyth prices to 6-decimal format and implements health checks
 */
contract PythOracle is IOracle, AccessControl {
    // Pyth Network ETH/USD price feed ID
    bytes32 public constant ETH_USD_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    IPyth public immutable pyth;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Configuration parameters
    uint256 public maxPriceAge = 3600; // 1 hour max staleness
    uint256 public maxConfidenceRatio = 1000; // Max 10% confidence interval (in basis points)
    bool public emergencyPause = false;

    // Events
    event PriceAgeUpdated(uint256 oldAge, uint256 newAge);
    event ConfidenceRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event EmergencyPauseToggled(bool paused);
    event PriceFeedsUpdated(address indexed updater, uint256 fee, uint256 refund);

    /**
     * @dev Constructor
     * @param _pyth Address of the Pyth contract
     * @param _admin Admin address for configuration updates
     */
    constructor(address _pyth, address _admin) {
        require(_pyth != address(0), "PythOracle: zero pyth address");
        require(_admin != address(0), "PythOracle: zero admin address");

        pyth = IPyth(_pyth);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    /**
     * @dev Get ETH/USD price in 6 decimal format
     * @return ETH price in USD with 6 decimals (e.g., 4500000000 = $4500.00)
     */
    function getEthUsd() external view override returns (uint256) {
        require(!emergencyPause, "PythOracle: emergency pause active");

        // Get price with staleness check
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(ETH_USD_PRICE_ID, maxPriceAge);

        return _convertPythPrice(price);
    }

    /**
     * @dev Check if oracle is healthy
     * @return true if oracle is healthy, false otherwise
     */
    function isHealthy() external view override returns (bool) {
        if (emergencyPause) return false;

        try pyth.getPriceNoOlderThan(ETH_USD_PRICE_ID, maxPriceAge) returns (PythStructs.Price memory price) {
            // Check price validity
            if (price.price <= 0) return false;

            // Check confidence ratio
            uint256 priceAbs = uint256(uint64(price.price));
            uint256 confidenceRatio = (price.conf * 10000) / priceAbs; // Basis points

            return confidenceRatio <= maxConfidenceRatio;
        } catch {
            return false;
        }
    }

    /**
     * @dev Convert Pyth price to 6-decimal format
     * @param price Pyth price struct
     * @return Price with 6 decimals
     */
    function _convertPythPrice(PythStructs.Price memory price) internal pure returns (uint256) {
        require(price.price > 0, "PythOracle: invalid price");

        uint256 priceAbs = uint256(uint64(price.price));
        int32 expo = price.expo;

        // Convert to 6 decimal places
        if (expo >= -6) {
            // Price has fewer decimals than needed, multiply
            return priceAbs * (10 ** uint32(6 + expo));
        } else {
            // Price has more decimals than needed, divide
            return priceAbs / (10 ** uint32(-expo - 6));
        }
    }

    /**
     * @dev Get raw Pyth price data for debugging
     * @return price Raw price from Pyth
     * @return conf Confidence interval
     * @return expo Price exponent
     * @return publishTime When price was published
     */
    function getRawPythPrice() external view returns (int64 price, uint64 conf, int32 expo, uint256 publishTime) {
        PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(ETH_USD_PRICE_ID);
        return (pythPrice.price, pythPrice.conf, pythPrice.expo, pythPrice.publishTime);
    }

    /**
     * @dev Get current price age in seconds
     * @return Age of current price in seconds
     */
    function getPriceAge() external view returns (uint256) {
        PythStructs.Price memory price = pyth.getPriceUnsafe(ETH_USD_PRICE_ID);
        return block.timestamp - price.publishTime;
    }

    /**
     * @dev Get current confidence ratio in basis points
     * @return Confidence ratio (10000 = 100%)
     */
    function getConfidenceRatio() external view returns (uint256) {
        PythStructs.Price memory price = pyth.getPriceUnsafe(ETH_USD_PRICE_ID);
        if (price.price <= 0) return type(uint256).max;

        uint256 priceAbs = uint256(uint64(price.price));
        return (price.conf * 10000) / priceAbs;
    }

    /**
     * @dev Update price feeds with fresh data from Pyth Network
     * @param priceUpdateData Encoded price update data from Pyth API
     */
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "PythOracle: insufficient fee");

        // Update prices with exact fee
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Refund excess ETH
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "PythOracle: refund failed");
        }

        emit PriceFeedsUpdated(msg.sender, fee, excess);
    }

    /**
     * @dev Update price feeds and immediately return fresh ETH/USD price
     * @param priceUpdateData Encoded price update data from Pyth API
     * @return Fresh ETH/USD price with 6 decimals
     */
    function updateAndGetPrice(bytes[] calldata priceUpdateData) external payable returns (uint256) {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "PythOracle: insufficient fee");

        // Update prices
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Refund excess
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "PythOracle: refund failed");
        }

        emit PriceFeedsUpdated(msg.sender, fee, excess);

        // Return fresh price immediately
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(ETH_USD_PRICE_ID, maxPriceAge);
        return _convertPythPrice(price);
    }

    /**
     * @dev Get the fee required to update price feeds
     * @param priceUpdateData Encoded price update data from Pyth API
     * @return Fee amount in wei required for the update
     */
    function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256) {
        return pyth.getUpdateFee(priceUpdateData);
    }

    /**
     * @dev Update maximum price age
     * @param newAge New maximum age in seconds
     */
    function setMaxPriceAge(uint256 newAge) external onlyRole(ADMIN_ROLE) {
        require(newAge > 0 && newAge <= 86400, "PythOracle: invalid age"); // Max 24 hours

        uint256 oldAge = maxPriceAge;
        maxPriceAge = newAge;

        emit PriceAgeUpdated(oldAge, newAge);
    }

    /**
     * @dev Update maximum confidence ratio
     * @param newRatio New maximum confidence ratio in basis points
     */
    function setMaxConfidenceRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) {
        require(newRatio > 0 && newRatio <= 5000, "PythOracle: invalid ratio"); // Max 50%

        uint256 oldRatio = maxConfidenceRatio;
        maxConfidenceRatio = newRatio;

        emit ConfidenceRatioUpdated(oldRatio, newRatio);
    }

    /**
     * @dev Toggle emergency pause
     * @param paused True to pause, false to unpause
     */
    function setEmergencyPause(bool paused) external onlyRole(EMERGENCY_ROLE) {
        emergencyPause = paused;
        emit EmergencyPauseToggled(paused);
    }

    /**
     * @dev Get current configuration
     * @return _maxPriceAge Maximum allowed price age
     * @return _maxConfidenceRatio Maximum allowed confidence ratio
     * @return _emergencyPause Emergency pause status
     */
    function getConfig()
        external
        view
        returns (uint256 _maxPriceAge, uint256 _maxConfidenceRatio, bool _emergencyPause)
    {
        return (maxPriceAge, maxConfidenceRatio, emergencyPause);
    }

    // ===== ROLE MANAGEMENT FUNCTIONS =====

    /**
     * @dev Grant admin role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant admin role to
     */
    function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "PythOracle: zero address");
        _grantRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Revoke admin role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke admin role from
     */
    function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "PythOracle: zero address");
        _revokeRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Grant emergency role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant emergency role to
     */
    function grantEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "PythOracle: zero address");
        _grantRole(EMERGENCY_ROLE, account);
    }

    /**
     * @dev Revoke emergency role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke emergency role from
     */
    function revokeEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "PythOracle: zero address");
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
