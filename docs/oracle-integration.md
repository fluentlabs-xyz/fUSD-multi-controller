# Oracle Integration

**Navigation**: [← Back](access-control.md) | **Oracle Integration** | [🏠 Home](../README.md) | [Next →](amm-pool-integration.md)

---

## Overview

The fUSD system implements a multi (dual, atm) oracle architecture providing both development/testing capabilities and production-ready Pyth Network integration. The system features secure oracle switching through a timelock mechanism, ensuring seamless transitions while maintaining security.

## Architecture

### Dual Oracle System

```
┌─────────────────┐     ┌──────────────────┐
│  DeskController │────▶│  Oracle System   │
└─────────────────┘     └──────────────────┘
                                 │
                      ┌──────────┼────────────────┐
                      ▼          ▼                ▼
              ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
              │ MockOracle  │ │ PythOracle  │ │   Timelock  │
              │  (Testing)  │ │(Production) │ │ Switching   │
              └─────────────┘ └─────────────┘ └─────────────┘
```

### Key Components

1. **Oracle Interface** (`src/interfaces/IOracle.sol`)
   - Standardized interface for all oracle implementations
   - Ensures consistent behavior across different oracle types

2. **MockOracle** (`src/oracles/MockOracle.sol`) 
   - Configurable testing oracle with deterministic behavior
   - AccessControl integration for secure admin operations

3. **PythOracle** (`src/oracles/PythOracle.sol`)
   - Production Pyth Network integration with ETH/USD feeds
   - Price update functionality with fee management
   - AccessControl integration matching system patterns

4. **Timelock Switching** (built into `DeskController`)
   - 2-day delay mechanism for secure oracle transitions
   - Propose/execute/cancel workflow for admin control

## Oracle Interface

All oracles implement the standardized `IOracle` interface:

```solidity
interface IOracle {
    function getEthUsd() external view returns (uint256);
    function isHealthy() external view returns (bool);
}
```

### Price Format

- **Decimals**: 6 (USDC-style: $4,500.00 = 4500000000)
- **Range**: Supports realistic ETH prices ($1 - $100,000)
- **Precision**: Sufficient for accurate mint/burn calculations

## MockOracle Implementation

### Purpose & Features

The MockOracle provides controlled testing environments with:

```solidity
contract MockOracle is IOracle, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public ETH_PRICE = 4500 * 1e6; // $4500 base price
    bool public enableFluctuations = false;
    uint256 public fluctuationRange = 50; // 0.5% = 50 basis points
    bool public isOracleHealthy = true;
}
```

### Key Capabilities

1. **Configurable Base Price**

   ```solidity
   function setPrice(uint256 newPrice) external onlyRole(ADMIN_ROLE) {
       require(newPrice > 0, "Price must be positive");
       uint256 oldPrice = ETH_PRICE;
       ETH_PRICE = newPrice;
       emit PriceUpdated(oldPrice, newPrice);
   }
   ```

2. **Deterministic Fluctuations**

   ```solidity
   function setFluctuations(bool enabled) external onlyRole(ADMIN_ROLE) {
       enableFluctuations = enabled;
   }
   
   function setFluctuationRange(uint256 rangeInBasisPoints) external onlyRole(ADMIN_ROLE) {
       require(rangeInBasisPoints <= 1000, "Range too high"); // Max 10%
       fluctuationRange = rangeInBasisPoints;
   }
   ```

3. **Health Status Control**

   ```solidity
   function setHealthStatus(bool healthy) external onlyRole(ADMIN_ROLE) {
       isOracleHealthy = healthy;
   }
   
   function simulateFailure() external onlyRole(EMERGENCY_ROLE) {
       isOracleHealthy = false;
   }
   ```

4. **AccessControl Integration**

   ```solidity
   function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
       _grantRole(ADMIN_ROLE, account);
   }
   
   function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
       _revokeRole(ADMIN_ROLE, account);
   }
   ```

## PythOracle Implementation

### Architecture

The PythOracle integrates with Pyth Network's pull-based pricing system:

```solidity
contract PythOracle is IOracle, AccessControl {
    IPyth public immutable pyth;
    bytes32 public constant ETH_USD_PRICE_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    
    uint256 private constant PYTH_PRECISION = 1e8;
    uint256 private constant TARGET_PRECISION = 1e6;
    uint256 public maxPriceAge = 3600; // 1 hour staleness tolerance
}
```

### Core Functions

1. **Price Retrieval**

   ```solidity
   function getEthUsd() external view returns (uint256) {
       PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(
           ETH_USD_PRICE_FEED, 
           maxPriceAge
       );
       
       require(pythPrice.price > 0, "Invalid price");
       return _convertToTargetPrecision(pythPrice);
   }
   ```

2. **Health Monitoring**

   ```solidity
   function isHealthy() external view returns (bool) {
       try pyth.getPriceNoOlderThan(ETH_USD_PRICE_FEED, maxPriceAge) returns (PythStructs.Price memory price) {
           return price.price > 0 && price.conf > 0;
       } catch {
           return false;
       }
   }
   ```

### Price Update Functionality

The PythOracle supports updating price feeds with fee management:

```solidity
function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
    uint256 requiredFee = pyth.getUpdateFee(priceUpdateData);
    require(msg.value >= requiredFee, "Insufficient fee");
    
    // Update price feeds
    pyth.updatePriceFeeds{value: requiredFee}(priceUpdateData);
    
    // Refund overpaid fees
    uint256 refund = msg.value - requiredFee;
    if (refund > 0) {
        (bool success, ) = msg.sender.call{value: refund}("");
        require(success, "Refund failed");
    }
    
    emit PriceFeedsUpdated(priceUpdateData.length, requiredFee);
}

function updateAndGetPrice(bytes[] calldata priceUpdateData) external payable returns (uint256) {
    if (priceUpdateData.length > 0) {
        updatePriceFeeds(priceUpdateData);
    }
    return getEthUsd();
}

function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256) {
    return pyth.getUpdateFee(priceUpdateData);
}
```

### Precision Conversion

Converting between Pyth's format and our 6-decimal system:

```solidity
function _convertToTargetPrecision(PythStructs.Price memory pythPrice) internal pure returns (uint256) {
    require(pythPrice.price > 0, "Invalid price");
    
    int64 price = pythPrice.price;
    int32 expo = pythPrice.expo;
    
    // Convert to positive price
    uint256 unsignedPrice = uint256(int256(price));
    
    // Pyth ETH/USD typically uses expo = -8, we want 6 decimals
    // So we divide by 10^(8-6) = 10^2 = 100
    if (expo == -8) {
        return unsignedPrice / 100;
    }
    
    // Generic conversion for other exponents
    int256 adjustment = int256(TARGET_PRECISION) - int256(10**uint256(-expo));
    if (adjustment > 0) {
        return unsignedPrice * uint256(adjustment);
    } else {
        return unsignedPrice / uint256(-adjustment);
    }
}
```

## Timelock Oracle Switching

The DeskController implements secure oracle switching with a 2-day timelock:

### State Management

```solidity
contract DeskController {
    IOracle public oracle;
    
    // Timelock state
    address public proposedOracle;
    uint256 public oracleUpdateTime;
    uint256 public constant ORACLE_TIMELOCK = 2 days;
}
```

### Switching Process

1. **Propose Oracle Change**

   ```solidity
   function proposeOracleUpdate(address newOracle) external onlyRole(ADMIN_ROLE) {
       require(newOracle != address(0), "Invalid oracle address");
       require(newOracle != address(oracle), "Oracle already active");
       require(IOracle(newOracle).isHealthy(), "Proposed oracle unhealthy");
       
       proposedOracle = newOracle;
       oracleUpdateTime = block.timestamp + ORACLE_TIMELOCK;
       
       emit OracleUpdateProposed(address(oracle), newOracle, oracleUpdateTime);
   }
   ```

2. **Execute Oracle Change** (after timelock)

   ```solidity
   function executeOracleUpdate() external onlyRole(ADMIN_ROLE) {
       require(proposedOracle != address(0), "No proposed oracle");
       require(block.timestamp >= oracleUpdateTime, "Timelock not expired");
       require(IOracle(proposedOracle).isHealthy(), "Proposed oracle unhealthy");
       
       address oldOracle = address(oracle);
       oracle = IOracle(proposedOracle);
       
       // Clear timelock state
       proposedOracle = address(0);
       oracleUpdateTime = 0;
       
       emit OracleUpdated(oldOracle, address(oracle));
   }
   ```

3. **Cancel Proposal** (emergency)

   ```solidity
   function cancelOracleUpdate() external onlyRole(ADMIN_ROLE) {
       require(proposedOracle != address(0), "No proposed oracle");
       
       address cancelled = proposedOracle;
       proposedOracle = address(0);
       oracleUpdateTime = 0;
       
       emit OracleUpdateCancelled(cancelled);
   }
   ```

## Deployment Configuration

Oracle selection is environment-driven through the deployment script:

```solidity
contract DeployFUSD is Script {
    function run() external {
        // Deploy both oracles
        MockOracle mockOracle = new MockOracle();
        PythOracle pythOracle = new PythOracle(PYTH_CONTRACT_ADDRESS);
        
        // Choose oracle based on environment
        bool usePyth = vm.envOr("PYTH", false);
        IOracle selectedOracle = usePyth ? pythOracle : mockOracle;
        
        // Deploy controller with selected oracle
        DeskController controller = new DeskController(
            address(fusdToken),
            address(selectedOracle),
            address(registry)
        );
    }
}
```

## Price Validation & Security

### Oracle Health Checks

Every price-dependent operation validates oracle health:

```solidity
modifier onlyHealthyOracle() {
    require(oracle.isHealthy(), "Oracle unhealthy");
    _;
}

function mint() external payable whenNotPaused onlyHealthyOracle {
    uint256 ethPrice = oracle.getEthUsd();
    // ... rest of mint logic
}
```

### Price Movement Validation

The DeskController validates price movements to prevent manipulation:

```solidity
function _validatePrice(uint256 newPrice) internal view {
    if (lastPrice > 0) {
        uint256 maxAllowedMove = (lastPrice * maxPriceMove) / 1e18;
        uint256 priceDiff = newPrice > lastPrice ? 
            newPrice - lastPrice : lastPrice - newPrice;
        require(priceDiff <= maxAllowedMove, "Price move too large");
    }
}
```

## Testing Framework

### Test Structure

```
test/oracles/
├── MockOracle.t.sol       # 24 tests covering all MockOracle functionality  
├── PythOracle.t.sol       # 26 tests covering PythOracle with MockPyth
└── OracleSwitching.t.sol  # 29 tests covering timelock mechanism
```

### Test Categories

1. **MockOracle Tests** (`MockOracle.t.sol`)
   - Price setting and retrieval
   - Fluctuation mechanisms
   - Health status management
   - AccessControl integration

2. **PythOracle Tests** (`PythOracle.t.sol`)
   - Pyth Network integration
   - Price conversion accuracy
   - Update fee calculations
   - Error handling

3. **Oracle Switching Tests** (`OracleSwitching.t.sol`)
   - Timelock propose/execute/cancel workflow
   - Security validations
   - Edge cases and error conditions

### Example Test Patterns

```solidity
function testOracleSwitchingTimelock() public {
    // Propose oracle switch
    vm.prank(admin);
    controller.proposeOracleUpdate(address(pythOracle));
    
    // Cannot execute immediately
    vm.expectRevert("Timelock not expired");
    vm.prank(admin);
    controller.executeOracleUpdate();
    
    // Execute after timelock
    vm.warp(block.timestamp + 2 days + 1);
    vm.prank(admin);
    controller.executeOracleUpdate();
    
    assertEq(address(controller.oracle()), address(pythOracle));
}
```

## Best Practices

### Oracle Integration

1. **Always Check Health**

   ```solidity
   function getPrice() internal view returns (uint256) {
       require(oracle.isHealthy(), "Oracle unhealthy");
       return oracle.getEthUsd();
   }
   ```

2. **Handle Failures Gracefully**

   ```solidity
   function mint() external payable {
       if (!oracle.isHealthy()) {
           revert("Trading paused: oracle unhealthy");
       }
       // Continue with mint logic
   }
   ```

3. **Validate Price Changes**

   ```solidity
   function _updateLastPrice(uint256 newPrice) internal {
       _validatePrice(newPrice);
       lastPrice = newPrice;
       lastPriceUpdate = block.timestamp;
   }
   ```

### Testing Strategies

1. **Test Both Oracle Types**
   - MockOracle for controlled scenarios
   - PythOracle with MockPyth for integration

2. **Test Oracle Switching**
   - Normal timelock workflow
   - Emergency cancellation
   - Invalid proposals

3. **Test Failure Scenarios**
   - Unhealthy oracle detection
   - Stale price handling
   - Network connectivity issues

## Future Enhancements

### Multi-Oracle Aggregation

```solidity
contract AggregatorOracle is IOracle {
    IOracle[] public oracles;
    uint256 public maxDeviation = 2e16; // 2%
    
    function getEthUsd() external view returns (uint256) {
        uint256[] memory prices = new uint256[](oracles.length);
        uint256 validCount = 0;
        
        for (uint i = 0; i < oracles.length; i++) {
            if (oracles[i].isHealthy()) {
                prices[validCount] = oracles[i].getEthUsd();
                validCount++;
            }
        }
        
        require(validCount >= 2, "Insufficient healthy oracles");
        return _calculateMedian(prices, validCount);
    }
}
```

### TWAP Oracle

```solidity
contract TWAPOracle is IOracle {
    struct PricePoint {
        uint256 price;
        uint256 timestamp;
    }
    
    PricePoint[] public priceHistory;
    uint256 public constant TWAP_WINDOW = 15 minutes;
    
    function getEthUsd() external view returns (uint256) {
        return _calculateTWAP(block.timestamp - TWAP_WINDOW, block.timestamp);
    }
}
```

## Summary

The multi oracle architecture provides:

- **Flexibility**: Easy testing with MockOracle, production-ready with PythOracle
- **Security**: Timelock mechanism prevents rapid oracle changes
- **Reliability**: Health checks and graceful failure handling  
- **Integration**: Consistent AccessControl patterns across all components
- **Extensibility**: Interface-based design supports future oracle types

This implementation ensures accurate, secure, and reliable price feeds for the fUSD stablecoin system while maintaining operational flexibility for different deployment environments.

---

**Navigation**: [← Back](access-control.md) | **Oracle Integration** | [🏠 Home](../README.md) | [Next →](amm-pool-integration.md)