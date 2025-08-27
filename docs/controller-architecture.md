# Controller Architecture

**Navigation**: [← Back](../README.md) | **Controller Architecture** | [🏠 Home](../README.md) | [Next →](access-control.md)

---

## Overview

The fUSD system employs a modular controller architecture that separates token logic from business logic. This design enables extensibility, upgradability, and the ability to support multiple minting/burning mechanisms simultaneously.

## Design Philosophy

The controller pattern provides several key benefits:

1. **Separation of Concerns**: Token contract remains minimal and focused on ERC20 functionality
2. **Flexibility**: New controllers can be added without modifying the token
3. **Risk Management**: Each controller can have independent limits and security features
4. **Upgradability**: Controllers can be replaced or upgraded without token migration
5. **Multi-Strategy Support**: Different controllers can implement different minting strategies

## Architecture Components

### 1. fUSD Token Contract

The token contract (`src/fUSD.sol`) is intentionally minimal:

```solidity
contract fUSD is ERC20, AccessControl {
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    
    function mint(address to, uint256 amount) external onlyRole(CONTROLLER_ROLE) {
        _mint(to, amount);
    }
    
    function burnFrom(address from, uint256 amount) external onlyRole(CONTROLLER_ROLE) {
        _burn(from, amount);
    }
}
```

Key features:
- Only controllers can mint/burn tokens
- 6 decimal places (USDC-style)
- Standard ERC20 functionality
- AccessControl for role management

### 2. Controller Interface

All controllers implement the `IController` interface (`src/interfaces/IController.sol`):

```solidity
interface IController {
    event Mint(address indexed user, uint256 ethIn, uint256 fusdOut, uint256 ethPrice);
    event Burn(address indexed user, uint256 fusdIn, uint256 ethOut, uint256 ethPrice);
    
    function getEthUsd() external view returns (uint256);
    function getMintQuote(uint256 ethAmount) external view returns (uint256);
    function getBurnQuote(uint256 fusdAmount) external view returns (uint256);
}
```

This standardization allows:
- Consistent interaction patterns
- Easy integration with frontend/bots
- Predictable behavior across controllers

### 3. Controller Registry

The `ControllerRegistry` (`src/controller/ControllerRegistry.sol`) acts as a central management system:

```solidity
struct ControllerInfo {
    bool active;
    string name;
    uint256 dailyLimit;
    uint256 totalMinted;
    uint256 lastResetTime;
    uint256 dailyMinted;
}
```

Key responsibilities:
- Track all authorized controllers
- Enforce daily minting limits per controller
- Enforce global daily limits across all controllers
- Provide metadata and statistics
- Enable/disable controllers dynamically

## Current Implementation: DeskController

The `DeskController` is the primary trading desk implementation with these features:

### Core Functionality
- **Mint**: Users send ETH, receive fUSD at oracle price
- **Burn**: Users burn fUSD, receive ETH at oracle price
- **Quote Functions**: Get exact amounts before transactions

### Safety Features
1. **Rate Limiting**
   ```solidity
   mapping(address => uint256) public lastActionTime;
   uint256 public actionCooldown = 1 days;
   ```

2. **Price Validation**
   ```solidity
   uint256 public maxPriceMove = 5e16; // 5% max movement
   function _validatePrice(uint256 newPrice) internal view
   ```

3. **Minimum Amounts**
   ```solidity
   uint256 public minMint = 1 * 1e6;    // 1 fUSD
   uint256 public minEth = 0.0001 ether; // Dust prevention
   ```

4. **Circuit Breakers**
   ```solidity
   bool public mintingPaused = false;
   bool public burningPaused = false;
   ```

### Access Control
- `ADMIN_ROLE`: Configuration updates, pause/unpause
- `EMERGENCY_ROLE`: Emergency withdrawals
- `DEFAULT_ADMIN_ROLE`: Role management

## Future Controller Types

The architecture supports various controller types:

### 1. Migration Controller
For upgrading from old token versions:
```solidity
contract MigrationController is IController {
    function migrateTokens(uint256 oldTokenAmount) external {
        oldToken.transferFrom(msg.sender, address(this), oldTokenAmount);
        fusd.mint(msg.sender, oldTokenAmount);
    }
}
```

### 2. Bridge Controller
For cross-chain minting:
```solidity
contract BridgeController is IController {
    function mintFromBridge(address user, uint256 amount, bytes32 txHash) external onlyBridge {
        require(!processedTxs[txHash], "Already processed");
        fusd.mint(user, amount);
    }
}
```

### 3. Collateral Controller
For multi-asset collateral:
```solidity
contract CollateralController is IController {
    function mintWithToken(address token, uint256 amount) external {
        uint256 tokenValue = oracle.getTokenValue(token, amount);
        collateral[token].transferFrom(msg.sender, address(this), amount);
        fusd.mint(msg.sender, tokenValue);
    }
}
```

### 4. Yield Controller
For productive collateral:
```solidity
contract YieldController is IController {
    function stake(uint256 amount) external {
        fusd.transferFrom(msg.sender, address(this), amount);
        // Deposit to yield protocol
        yieldToken.deposit(amount);
    }
}
```

## Controller Lifecycle

### 1. Deployment
```solidity
DeskController desk = new DeskController(
    address(fusd),
    address(oracle)
);
```

### 2. Authorization
```solidity
// Grant controller role on token
fusd.grantRole(fusd.CONTROLLER_ROLE(), address(desk));

// Register in registry
registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);
```

### 3. Configuration
```solidity
desk.setConfig(cooldown, minMint, minEth);
desk.grantAdminRole(adminAddress);
```

### 4. Operation
- Users interact directly with controller
- Controller validates and processes requests
- Controller mints/burns through token contract

### 5. Decommissioning
```solidity
// Remove from registry
registry.removeController(address(desk));

// Revoke token permissions
fusd.revokeRole(fusd.CONTROLLER_ROLE(), address(desk));
```

## Best Practices

### For Controller Development

1. **Always Validate Input**
   - Check oracle health
   - Validate price movements
   - Enforce minimums

2. **Implement Emergency Controls**
   - Pause functionality
   - Emergency withdrawal
   - Circuit breakers

3. **Use Reentrancy Guards**
   ```solidity
   function mint() external nonReentrant {
       // Implementation
   }
   ```

4. **Emit Comprehensive Events**
   ```solidity
   emit Mint(msg.sender, msg.value, fusdAmount, ethPrice);
   ```

### For Registry Management

1. **Set Appropriate Limits**
   - Per-controller daily limits
   - Global daily limits
   - Consider market conditions

2. **Monitor Controller Health**
   - Track minting volumes
   - Watch for anomalies
   - Regular audits

3. **Plan Migrations**
   - Test new controllers thoroughly
   - Gradual rollout
   - Keep old controllers active during transition

## Security Considerations

1. **Controller Compromise**
   - Limited by daily minting limits
   - Registry can disable compromised controllers
   - Token contract remains secure

2. **Oracle Manipulation**
   - Price validation in controllers
   - Oracle health checks
   - Multiple oracle support planned

3. **Admin Key Management**
   - Multi-signature recommended
   - Role separation (admin vs emergency)
   - Time-locked operations for critical changes

## Integration Guide

### For Frontend Developers
```javascript
// Get available controllers
const controllers = await registry.getActiveControllers();

// Interact with specific controller
const desk = new ethers.Contract(controllerAddress, DeskControllerABI, signer);
const quote = await desk.getMintQuote(ethAmount);
await desk.mint({ value: ethAmount });
```

### For Bot Developers
```javascript
// Monitor all controllers
for (const controller of controllers) {
    const contract = new ethers.Contract(controller, IControllerABI, provider);
    contract.on('Mint', (user, ethIn, fusdOut, price) => {
        // Arbitrage logic
    });
}
```

## Summary

The controller architecture provides a robust foundation for the fUSD system:
- **Modularity**: Clean separation between token and business logic
- **Extensibility**: Easy to add new minting mechanisms
- **Security**: Multiple layers of protection and limits
- **Flexibility**: Supports various use cases and future enhancements

This design ensures the system can evolve to meet changing requirements while maintaining security and stability.

---

**Navigation**: [← Back](../README.md) | **Controller Architecture** | [🏠 Home](../README.md) | [Next →](access-control.md)