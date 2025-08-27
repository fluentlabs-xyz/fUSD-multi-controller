# Oracle Integration

**Navigation**: [← Back](access-control.md) | **Oracle Integration** | [🏠 Home](../README.md) | [Next →](amm-pool-integration.md)

---

## Overview

The fUSD system relies on accurate price feeds to maintain its peg to USD. The oracle system is designed to be swappable, allowing seamless transitions from test oracles to production-grade solutions like Pyth Network.

## Current Implementation: MockOracle

### Purpose

The `MockOracle` provides a controlled testing environment with configurable price feeds and deterministic behavior, essential for:
- Development and testing
- Simulating market conditions
- Testing error scenarios
- Validating price movement limits

### Architecture

```solidity
contract MockOracle is IOracle {
    uint256 public ETH_PRICE = 4500 * 1e6; // $4500 with 6 decimals
    bool public enableFluctuations = false;
    uint256 public fluctuationRange = 50; // 0.5% = 50 basis points
    bool public isOracleHealthy = true;
}
```

### Key Features

1. **Configurable Base Price**
   ```solidity
   function setPrice(uint256 newPrice) external onlyAdmin {
       require(newPrice > 0, "Price must be positive");
       ETH_PRICE = newPrice;
       emit PriceUpdated(oldPrice, newPrice);
   }
   ```

2. **Deterministic Fluctuations**
   ```solidity
   function _calculatePriceWithFluctuations(uint256 timestamp) internal view returns (uint256) {
       uint256 seed = uint256(keccak256(abi.encode(timestamp / 300)));
       // Price changes every 5 minutes
   }
   ```

3. **Health Status Simulation**
   ```solidity
   function setHealthStatus(bool healthy) external onlyAdmin {
       isOracleHealthy = healthy;
   }
   ```

### Testing Scenarios

1. **Normal Operation**
   ```javascript
   await oracle.setPrice(4500 * 1e6);
   await oracle.setHealthStatus(true);
   ```

2. **Market Volatility**
   ```javascript
   await oracle.setFluctuations(true);
   await oracle.setFluctuationRange(200); // 2% swings
   ```

3. **Oracle Failure**
   ```javascript
   await oracle.simulateFailure();
   // All operations requiring oracle will fail
   ```

## Oracle Interface

All oracles must implement the `IOracle` interface:

```solidity
interface IOracle {
    function getEthUsd() external view returns (uint256);
    function isHealthy() external view returns (bool);
}
```

### Price Format
- **Decimals**: 6 (e.g., $4,500.00 = 4500000000)
- **Update Frequency**: Varies by implementation
- **Staleness Check**: Handled by oracle implementation

## Price Validation Mechanisms

### 1. Oracle Health Checks

```solidity
modifier onlyHealthyOracle() {
    require(ORACLE.isHealthy(), "Oracle unhealthy");
    _;
}
```

Every price-dependent operation checks oracle health first.

### 2. Price Movement Validation

```solidity
function _validatePrice(uint256 newPrice) internal view {
    if (lastPrice > 0) {
        uint256 priceDiff = _abs(newPrice, lastPrice);
        uint256 maxAllowedMove = (lastPrice * maxPriceMove) / 1e18;
        require(priceDiff <= maxAllowedMove, "Price move too large");
    }
}
```

Prevents extreme price movements:
- Default: 5% maximum movement
- Configurable by admins
- Tracks price history

### 3. Price Tracking

```solidity
function _updatePrice(uint256 newPrice) internal {
    if (newPrice != lastPrice) {
        lastPrice = newPrice;
        lastPriceUpdate = block.timestamp;
        priceUpdateCount++;
        emit PriceUpdated(oldPrice, newPrice);
    }
}
```

## Planned: Pyth Network Integration

### Why Pyth Network?

1. **High Frequency Updates**: Sub-second price updates
2. **Multiple Data Sources**: Aggregated from top exchanges
3. **Confidence Intervals**: Price uncertainty metrics
4. **Cross-Chain**: Same price feeds across networks
5. **Pull-Based Updates**: Gas-efficient on-demand pricing

### Implementation Plan

```solidity
contract PythOracle is IOracle {
    IPyth public immutable pythContract;
    bytes32 public immutable ethUsdPriceFeedId;
    uint256 public immutable maxStaleness = 60; // 1 minute
    
    function getEthUsd() external view returns (uint256) {
        PythStructs.Price memory price = pythContract.getPriceUnsafe(ethUsdPriceFeedId);
        
        // Check staleness
        require(block.timestamp - price.publishTime <= maxStaleness, "Price too stale");
        
        // Convert Pyth's price format to our 6 decimal format
        return _convertPythPrice(price);
    }
    
    function isHealthy() external view returns (bool) {
        try pythContract.getPriceUnsafe(ethUsdPriceFeedId) returns (PythStructs.Price memory price) {
            return block.timestamp - price.publishTime <= maxStaleness;
        } catch {
            return false;
        }
    }
}
```

### Price Conversion

Pyth uses signed integers with exponents:
```solidity
function _convertPythPrice(PythStructs.Price memory price) internal pure returns (uint256) {
    // Pyth price: price * 10^exponent
    // Our format: price * 10^6
    
    require(price.price > 0, "Invalid price");
    
    if (price.expo >= -6) {
        // Scale up
        return uint256(price.price) * 10**uint256(int256(6 + price.expo));
    } else {
        // Scale down
        return uint256(price.price) / 10**uint256(-int256(price.expo + 6));
    }
}
```

## Oracle Swapping Procedure

### 1. Deploy New Oracle

```solidity
// Deploy Pyth oracle
PythOracle newOracle = new PythOracle(pythAddress, priceFeedId);

// Test thoroughly
assert(newOracle.isHealthy());
assert(newOracle.getEthUsd() > 0);
```

### 2. Parallel Running

```solidity
contract OracleAggregator is IOracle {
    IOracle public primaryOracle;
    IOracle public secondaryOracle;
    uint256 public maxDeviation = 2e16; // 2%
    
    function getEthUsd() external view returns (uint256) {
        uint256 price1 = primaryOracle.getEthUsd();
        uint256 price2 = secondaryOracle.getEthUsd();
        
        // Ensure prices are within acceptable deviation
        uint256 diff = _abs(price1, price2);
        require(diff <= (price1 * maxDeviation) / 1e18, "Oracle deviation");
        
        return price1; // Use primary
    }
}
```

### 3. Gradual Migration

```solidity
contract MigratableController {
    IOracle public oracle;
    address public pendingOracle;
    uint256 public oracleUpdateTime;
    
    function proposeOracleUpdate(address newOracle) external onlyAdmin {
        pendingOracle = newOracle;
        oracleUpdateTime = block.timestamp + 2 days;
    }
    
    function executeOracleUpdate() external onlyAdmin {
        require(pendingOracle != address(0), "No pending oracle");
        require(block.timestamp >= oracleUpdateTime, "Timelock active");
        
        oracle = IOracle(pendingOracle);
        pendingOracle = address(0);
    }
}
```

## Handling Oracle Failures

### 1. Graceful Degradation

```solidity
function mint() external payable whenNotPaused onlyHealthyOracle {
    // Will fail if oracle unhealthy
}
```

### 2. Emergency Fallback

```solidity
contract EmergencyPriceOracle is IOracle {
    uint256 public emergencyPrice;
    bool public useEmergencyPrice;
    
    function getEthUsd() external view returns (uint256) {
        if (useEmergencyPrice) {
            return emergencyPrice;
        }
        return primaryOracle.getEthUsd();
    }
}
```

### 3. Circuit Breakers

```solidity
function _handleOracleFailure() internal {
    mintingPaused = true;
    burningPaused = true;
    emit OracleFailureDetected(block.timestamp);
}
```

## Oracle Security Considerations

### 1. Price Manipulation Protection

- **Multiple Source Validation**: Pyth aggregates from multiple exchanges
- **Confidence Intervals**: Reject prices with high uncertainty
- **Rate Limiting**: Prevent rapid arbitrage during manipulation
- **Maximum Movement Checks**: Reject suspicious price swings

### 2. Availability Concerns

- **Fallback Oracles**: Secondary price sources
- **Caching**: Store recent valid prices
- **Health Monitoring**: Continuous oracle status checks
- **Manual Override**: Emergency admin controls

### 3. Integration Testing

```solidity
contract OracleTest {
    function testPriceManipulation() public {
        // Set extreme price
        mockOracle.setPrice(10000 * 1e6); // $10,000
        
        // Attempt mint - should fail
        vm.expectRevert("Price move too large");
        controller.mint{value: 1 ether}();
    }
    
    function testOracleFailure() public {
        // Simulate failure
        mockOracle.setHealthStatus(false);
        
        // All operations should fail
        vm.expectRevert("Oracle unhealthy");
        controller.mint{value: 1 ether}();
    }
}
```

## Future Enhancements

### 1. Multi-Oracle Aggregation

```solidity
contract MultiOracle is IOracle {
    IOracle[] public oracles;
    
    function getEthUsd() external view returns (uint256) {
        uint256[] memory prices = new uint256[](oracles.length);
        
        // Collect all prices
        for (uint i = 0; i < oracles.length; i++) {
            if (oracles[i].isHealthy()) {
                prices[i] = oracles[i].getEthUsd();
            }
        }
        
        // Return median price
        return _calculateMedian(prices);
    }
}
```

### 2. Time-Weighted Average Price (TWAP)

```solidity
contract TWAPOracle is IOracle {
    uint256[] public priceHistory;
    uint256[] public timestamps;
    uint256 public windowSize = 15 minutes;
    
    function getEthUsd() external view returns (uint256) {
        return _calculateTWAP(block.timestamp - windowSize, block.timestamp);
    }
}
```

### 3. Volatility-Adjusted Limits

```solidity
contract VolatilityOracle is IOracle {
    function getMaxPriceMove() external view returns (uint256) {
        uint256 volatility = _calculateVolatility();
        return volatility * 3; // 3 standard deviations
    }
}
```

## Integration Guide

### For Controller Developers

```solidity
contract NewController {
    IOracle public oracle;
    
    constructor(address _oracle) {
        oracle = IOracle(_oracle);
    }
    
    function getPrice() internal view returns (uint256) {
        require(oracle.isHealthy(), "Oracle unhealthy");
        return oracle.getEthUsd();
    }
}
```

### For Frontend Integration

```javascript
// Check oracle status
const isHealthy = await oracle.isHealthy();
if (!isHealthy) {
    showError("Price feed unavailable");
    return;
}

// Get current price
const ethPrice = await oracle.getEthUsd();
const formattedPrice = ethPrice / 1e6; // Convert to dollars
```

## Summary

The oracle system provides:

- **Flexibility**: Easy swapping between oracle implementations
- **Reliability**: Health checks and failure handling
- **Security**: Price validation and manipulation protection
- **Testability**: Comprehensive testing capabilities with MockOracle
- **Future-Proof**: Ready for Pyth Network and other oracle integrations

This design ensures accurate pricing while maintaining system stability and security.

---

**Navigation**: [← Back](access-control.md) | **Oracle Integration** | [🏠 Home](../README.md) | [Next →](amm-pool-integration.md)