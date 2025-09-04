# Access Control Patterns

**Navigation**: [← Back](controller-architecture.md) | **Access Control** | [🏠 Home](../README.md) | [Next →](oracle-integration.md)

---

## Overview

The fUSD system implements a sophisticated role-based access control system using OpenZeppelin's AccessControl. This enables fine-grained permissions, multi-admin support for global operations, and secure emergency procedures.

## Role Hierarchy

### System-Wide Roles

```
DEFAULT_ADMIN_ROLE (0x00)
├── Token Contract
│   └── CONTROLLER_ROLE
├── Controller Registry
│   └── ADMIN_ROLE
├── Desk Controller
│   ├── ADMIN_ROLE
│   └── EMERGENCY_ROLE
└── Oracle System
    ├── MockOracle
    │   ├── ADMIN_ROLE
    │   └── EMERGENCY_ROLE
    └── PythOracle
        ├── ADMIN_ROLE
        └── EMERGENCY_ROLE
```

### Role Definitions

#### 1. DEFAULT_ADMIN_ROLE

- **Purpose**: Root administrator with role management capabilities
- **Capabilities**:
  - Grant/revoke other roles
  - Transfer admin privileges
  - Critical system configuration
- **Best Practice**: Use multi-signature wallet

#### 2. CONTROLLER_ROLE (Token Contract)

- **Purpose**: Authorize contracts to mint/burn fUSD
- **Capabilities**:
  - Call `mint()` function
  - Call `burnFrom()` function
- **Holders**: Controller contracts only (never EOAs)

#### 3. ADMIN_ROLE (Controllers & Registry)

- **Purpose**: Operational management
- **Capabilities**:
  - Update configuration parameters
  - Pause/unpause operations
  - Add/remove controllers (Registry)
  - Set limits and thresholds
- **Holders**: Operational team members

#### 4. EMERGENCY_ROLE (Controllers)

- **Purpose**: Emergency response capabilities
- **Capabilities**:
  - Emergency ETH withdrawal
  - Emergency token withdrawal
  - Critical intervention functions
- **Holders**: Security team, emergency responders

#### 5. Oracle System Roles

Both MockOracle and PythOracle implement the same AccessControl patterns:

**ADMIN_ROLE (Oracles)**:

- **Purpose**: Oracle configuration and management
- **MockOracle Capabilities**:
  - Set ETH price
  - Configure fluctuations and ranges
  - Control health status
- **PythOracle Capabilities**:
  - Set maximum price age
  - Update price feed configurations
  - Control staleness tolerance
- **Holders**: Same administrators as controllers for consistency

**EMERGENCY_ROLE (Oracles)**:

- **Purpose**: Emergency oracle intervention
- **Capabilities**:
  - Simulate oracle failures (MockOracle)
  - Emergency price updates (PythOracle)
  - Critical health status changes
- **Holders**: Emergency response team

**AccessControl Wrapper Functions**:
Both oracles provide wrapper functions matching controller patterns:

```solidity
function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE)
function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE)
function grantEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE)
function revokeEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE)
```

## Multi-Admin Architecture

### Rationale

The system supports multiple admins to ensure:

1. **24/7 Coverage**: Admins in different time zones
2. **Redundancy**: No single point of failure
3. **Specialization**: Different admins for different responsibilities
4. **Security**: Distributed trust model

### Implementation

```solidity
// In deployment script
for (uint i = 0; i < admins.length; i++) {
    desk.grantAdminRole(admins[i]);
}

for (uint i = 0; i < emergency.length; i++) {
    desk.grantEmergencyRole(emergency[i]);
}
```

### Configuration File

`script/config/admins.json`:

```json
{
    "admins": [
        "0xAdmin1_US_Timezone",
        "0xAdmin2_EU_Timezone",
        "0xAdmin3_ASIA_Timezone"
    ],
    "emergency": [
        "0xEmergency1_Primary",
        "0xEmergency2_Backup"
    ]
}
```

## Permission Management

### Granting Roles

```solidity
// Only DEFAULT_ADMIN_ROLE can grant roles
function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _grantRole(ADMIN_ROLE, account);
}

function grantEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _grantRole(EMERGENCY_ROLE, account);
}
```

### Revoking Roles

```solidity
function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _revokeRole(ADMIN_ROLE, account);
}
```

### Checking Roles

```solidity
// Check if address has specific role
bool isAdmin = desk.hasRole(desk.ADMIN_ROLE(), userAddress);

// Public helper functions
function hasAdminRole(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
}
```

## Access Control Patterns

### 1. Function-Level Protection

```solidity
modifier onlyAdmin() {
    require(hasRole(ADMIN_ROLE, msg.sender), "Admin role required");
    _;
}

function pause() external onlyAdmin {
    _pause();
}
```

### 2. Multi-Role Requirements

```solidity
function criticalOperation() external {
    require(
        hasRole(ADMIN_ROLE, msg.sender) || 
        hasRole(EMERGENCY_ROLE, msg.sender),
        "Admin or Emergency role required"
    );
    // Implementation
}
```

### 3. Role-Based Configuration

```solidity
// Different limits for different operations
mapping(bytes32 => uint256) public roleLimits;

function setRoleLimit(bytes32 role, uint256 limit) external onlyRole(DEFAULT_ADMIN_ROLE) {
    roleLimits[role] = limit;
}
```

## Emergency Procedures

### Emergency Role Capabilities

1. **Emergency Withdrawal**

   ```solidity
   function emergencyWithdraw(uint256 amount) external onlyEmergency {
       require(amount <= address(this).balance, "Insufficient balance");
       (bool success, ) = msg.sender.call{value: amount}("");
       require(success, "ETH transfer failed");
       emit EmergencyAction(msg.sender, "ETH_WITHDRAW", amount);
   }
   ```

2. **Circuit Breakers**

   ```solidity
   function emergencyPause() external onlyEmergency {
       _pause();
       mintingPaused = true;
       burningPaused = true;
       emit EmergencyAction(msg.sender, "EMERGENCY_PAUSE", 0);
   }
   ```

### Emergency Response Workflow

1. **Detection**: Monitor for anomalies
2. **Assessment**: Emergency role holder evaluates situation
3. **Action**: Execute emergency functions
4. **Communication**: Notify team and users
5. **Resolution**: Admin role implements permanent fix
6. **Post-Mortem**: Review and improve procedures

## Security Best Practices

### 1. Role Assignment

- **Principle of Least Privilege**: Only grant necessary permissions
- **Regular Audits**: Review role assignments quarterly
- **Secure Storage**: Use hardware wallets for admin keys
- **Multi-Signature**: Critical roles should use multisig wallets

### 2. Operational Security

```solidity
// Time-locked admin operations
mapping(bytes32 => uint256) public pendingOperations;
uint256 public constant TIMELOCK = 2 days;

function proposeOperation(bytes32 operation) external onlyAdmin {
    pendingOperations[operation] = block.timestamp + TIMELOCK;
}

function executeOperation(bytes32 operation) external onlyAdmin {
    require(pendingOperations[operation] != 0, "Not proposed");
    require(block.timestamp >= pendingOperations[operation], "Timelock active");
    // Execute operation
}
```

### 3. Access Monitoring

```solidity
event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

function _grantRole(bytes32 role, address account) internal override {
    super._grantRole(role, account);
    emit RoleGranted(role, account, _msgSender());
}
```

## Integration Examples

### Frontend Integration

```javascript
// Check user permissions
async function checkPermissions(userAddress) {
    const isAdmin = await deskController.hasAdminRole(userAddress);
    const isEmergency = await deskController.hasEmergencyRole(userAddress);
    
    return {
        canPause: isAdmin,
        canUpdateConfig: isAdmin,
        canEmergencyWithdraw: isEmergency
    };
}

// Display admin panel based on roles
if (permissions.canUpdateConfig) {
    showAdminPanel();
}
```

### Monitoring Integration

```javascript
// Monitor role changes
deskController.on('RoleGranted', (role, account, sender) => {
    alerting.send({
        severity: 'HIGH',
        message: `Role ${role} granted to ${account} by ${sender}`
    });
});
```

## Upgrade Considerations

### Role Migration

When upgrading controllers:

```solidity
// 1. Deploy new controller
DeskControllerV2 newDesk = new DeskControllerV2();

// 2. Copy role assignments
address[] memory admins = getAdminsFromV1();
for (uint i = 0; i < admins.length; i++) {
    newDesk.grantRole(ADMIN_ROLE, admins[i]);
}

// 3. Revoke old permissions
oldToken.revokeRole(CONTROLLER_ROLE, address(oldDesk));

// 4. Grant new permissions
newToken.grantRole(CONTROLLER_ROLE, address(newDesk));
```

### Access Control Evolution

Future enhancements might include:

1. **Time-Based Roles**: Temporary permissions
2. **Conditional Roles**: Based on holdings or reputation
3. **Hierarchical Roles**: Sub-admin roles with limited scope
4. **Geographic Roles**: Region-specific administrators

## Summary

The access control system provides:

- **Flexibility**: Multiple roles for different responsibilities
- **Security**: Granular permissions and emergency procedures
- **Scalability**: Support for multiple administrators
- **Auditability**: Comprehensive event logging
- **Resilience**: No single point of failure

This design ensures secure, efficient operations while maintaining the ability to respond quickly to issues and scale the administrative team as needed.

---

**Navigation**: [← Back](controller-architecture.md) | **Access Control** | [🏠 Home](../README.md) | [Next →](oracle-integration.md)
