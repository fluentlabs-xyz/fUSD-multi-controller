# Fluent Testnet Stablecoin (fUSD)

**Navigation**: [README](README.md) | [Controller Architecture](docs/controller-architecture.md) | [Access Control](docs/access-control.md) | [Oracle Integration](docs/oracle-integration.md) | [AMM Pool Integration](docs/amm-pool-integration.md) | [Arbitrage Bot](docs/arbitrage-bot.md)

---

A testnet stablecoin system with a mint/burn trading desk, designed for testing DeFi protocols and arbitrage strategies on Fluent's testnet environment.

## Overview

fUSD is an ETH-collateralized stablecoin that maintains a soft peg to USD through a trading desk mechanism. Users can mint fUSD by depositing ETH and burn fUSD to redeem ETH at current oracle prices. The system is designed for testnet environments and includes features for testing various DeFi scenarios.

## Key Features

- **6-Decimal Stablecoin**: USDC-style decimal precision for compatibility
- **Trading Desk Model**: Direct mint/burn mechanism through ETH collateral
- **Modular Controller Architecture**: Extensible design supporting multiple controller types
- **Swappable Oracle System**: Currently using MockOracle with planned Pyth Network integration
- **Multi-Admin Access Control**: Support for administrators across different time zones
- **Built-in Safety Features**:
  - Rate limiting per user (configurable cooldown)
  - Minimum transaction amounts
  - Price movement validation
  - Daily minting limits (per controller and global)
  - Emergency pause functionality
- **Arbitrage Testing**: Designed to create arbitrage opportunities for bot testing

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│    Users    │────▶│  DeskController  │────▶│  fUSD Token  │
└─────────────┘     └──────────────────┘     └──────────────┘
                             │                        │
                             ▼                        ▼
                    ┌──────────────────┐     ┌──────────────┐
                    │   MockOracle     │     │   Registry   │
                    └──────────────────┘     └──────────────┘
```

### Core Components

1. **fUSD Token** (`src/fUSD.sol`)
   - ERC20 token with 6 decimals
   - Role-based minting/burning permissions
   - Only authorized controllers can mint/burn

2. **DeskController** (`src/controller/DeskController.sol`)
   - Primary trading desk for ETH ↔ fUSD conversion
   - Implements rate limiting and safety checks
   - Handles price validation and oracle queries

3. **ControllerRegistry** (`src/controller/ControllerRegistry.sol`)
   - Manages multiple controllers
   - Enforces daily minting limits
   - Tracks controller metadata and statistics

4. **MockOracle** (`src/MockOracle.sol`)
   - Configurable price feed for testing
   - Supports price fluctuations and health status
   - Will be replaced with Pyth Network in production

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for offchain scripts)
- ETH on testnet for deployment

### Installation

```bash
git clone <repository>
cd testnet-stablecoin
forge install
```

### Configuration

1. Create `.env` file:
```bash
PRIVATE_KEY=your_private_key
RPC_URL=your_rpc_url
```

2. Configure admin addresses in `script/config/admins.json`:
```json
{
    "admins": ["0x..."],
    "emergency": ["0x..."]
}
```

### Deployment

```bash
forge script script/DeployFUSD.s.sol --rpc-url $RPC_URL --broadcast
```

### Basic Usage

#### Minting fUSD
```solidity
// Send ETH to mint fUSD at current oracle price
deskController.mint{value: 1 ether}();
```

#### Burning fUSD
```solidity
// Approve and burn fUSD to receive ETH
fusd.approve(address(deskController), amount);
deskController.burn(amount);
```

## Testing

Run the comprehensive test suite:
```bash
forge test
```

Run with verbosity:
```bash
forge test -vvv
```

## Documentation

Detailed documentation is available in the `/docs` folder:

- [Controller Architecture](docs/controller-architecture.md) - Modular controller design
- [Access Control](docs/access-control.md) - Role-based permission system
- [Oracle Integration](docs/oracle-integration.md) - Price feed system and migration plans
- [AMM Pool Integration](docs/amm-pool-integration.md) - Future AMM integration (placeholder)
- [Arbitrage Bot](docs/arbitrage-bot.md) - Offchain arbitrage monitoring and execution

## Project Structure

```
testnet-stablecoin/
├── src/
│   ├── fUSD.sol                    # Main stablecoin token
│   ├── MockOracle.sol              # Test oracle implementation
│   ├── controller/
│   │   ├── DeskController.sol      # Trading desk controller
│   │   └── ControllerRegistry.sol  # Controller management
│   └── interfaces/
│       ├── IController.sol         # Controller interface
│       ├── IOracle.sol            # Oracle interface
│       └── IUSD.sol               # Token interface
├── script/
│   ├── DeployFUSD.s.sol           # Deployment script
│   └── config/
│       └── admins.json            # Admin configuration
├── test/
│   └── FUSD.t.sol                 # Comprehensive test suite
├── offchain/
│   └── arbitrage.js               # Arbitrage bot implementation
└── docs/                          # Detailed documentation
```

## Security

### Built-in Security Measures

The fUSD system implements multiple layers of security:

1. **Smart Contract Security**
   - **ReentrancyGuard**: All state-changing functions in DeskController are protected against reentrancy attacks
   - **Pausable**: Global pause functionality for emergency situations
   - **Access Control**: Role-based permissions with DEFAULT_ADMIN_ROLE as the root authority
   - **Input Validation**: All functions validate inputs (zero address checks, amount checks, etc.)

2. **Operational Security**
   - **Rate Limiting**: Configurable cooldown periods prevent rapid mint/burn cycles
   - **Price Validation**: Maximum price movement checks (default 5%) prevent oracle manipulation
   - **Minimum Amounts**: Prevents dust attacks and ensures economic viability
   - **Daily Limits**: Both per-controller and global daily minting limits

3. **Oracle Security**
   - **Health Checks**: Every operation verifies oracle health before proceeding
   - **Price Staleness Protection**: Planned for production oracle integration
   - **Fallback Mechanisms**: Emergency procedures when oracle fails

4. **Administrative Security**
   - **Multi-Admin Support**: Distributed control across multiple addresses
   - **Role Separation**: Different roles for routine operations vs emergency actions
   - **Time-locked Operations**: Critical changes can implement time delays

### Emergency Procedures

Emergency role holders can execute critical interventions using Foundry's cast commands:

#### 1. Pause All Operations
```bash
# Pause the controller globally
cast send $DESK_CONTROLLER "pause()" --private-key $EMERGENCY_KEY --rpc-url $RPC_URL

# Pause only minting
cast send $DESK_CONTROLLER "pauseMinting()" --private-key $EMERGENCY_KEY --rpc-url $RPC_URL

# Pause only burning
cast send $DESK_CONTROLLER "pauseBurning()" --private-key $EMERGENCY_KEY --rpc-url $RPC_URL
```

#### 2. Emergency Withdrawals
```bash
# Withdraw ETH from controller
cast send $DESK_CONTROLLER "emergencyWithdraw(uint256)" "1000000000000000000" --private-key $EMERGENCY_KEY --rpc-url $RPC_URL

# Withdraw fUSD from controller
cast send $DESK_CONTROLLER "emergencyWithdrawFusd(uint256)" "1000000" --private-key $EMERGENCY_KEY --rpc-url $RPC_URL
```

#### 3. Resume Operations (Admin Role)
```bash
# Unpause globally
cast send $DESK_CONTROLLER "unpause()" --private-key $ADMIN_KEY --rpc-url $RPC_URL

# Resume minting
cast send $DESK_CONTROLLER "resumeMinting()" --private-key $ADMIN_KEY --rpc-url $RPC_URL

# Resume burning  
cast send $DESK_CONTROLLER "resumeBurning()" --private-key $ADMIN_KEY --rpc-url $RPC_URL
```

#### 4. Update Critical Parameters
```bash
# Update configuration (cooldown, minMint, minEth)
cast send $DESK_CONTROLLER "setConfig(uint256,uint256,uint256)" "3600" "1000000" "100000000000000" --private-key $ADMIN_KEY --rpc-url $RPC_URL

# Update max price movement (5% = 5e16)
cast send $DESK_CONTROLLER "setMaxPriceMove(uint256)" "50000000000000000" --private-key $ADMIN_KEY --rpc-url $RPC_URL
```

#### 5. Check System Status
```bash
# Check if paused
cast call $DESK_CONTROLLER "paused()" --rpc-url $RPC_URL

# Check minting/burning status
cast call $DESK_CONTROLLER "mintingPaused()" --rpc-url $RPC_URL
cast call $DESK_CONTROLLER "burningPaused()" --rpc-url $RPC_URL

# Check oracle health
cast call $DESK_CONTROLLER "isOracleHealthy()" --rpc-url $RPC_URL

# Check balances
cast call $DESK_CONTROLLER "getBalance()" --rpc-url $RPC_URL
cast call $DESK_CONTROLLER "getFusdBalance()" --rpc-url $RPC_URL
```

### Security Best Practices

1. **Key Management**
   - Use hardware wallets for admin and emergency keys
   - Implement key rotation policies
   - Never share private keys

2. **Monitoring**
   - Set up alerts for unusual activity
   - Monitor gas prices for emergency transactions
   - Track all admin actions

3. **Incident Response**
   - Have emergency contacts readily available
   - Practice emergency procedures regularly
   - Maintain runbooks for common scenarios

4. **Upgrade Safety**
   - Always test on testnet first
   - Use gradual rollouts
   - Maintain ability to pause and rollback

## Future Enhancements

1. **Pyth Network Integration**: Replace MockOracle with production oracle
2. **AMM Pool Creation**: Automated liquidity pool deployment
3. **Additional Controllers**: Migration tools, bridge controllers
4. **Enhanced Monitoring**: Real-time analytics dashboard
5. **Governance Module**: Decentralized parameter updates

## License

MIT

---

**Navigation**: [README](README.md) | [Controller Architecture](docs/controller-architecture.md) | [Access Control](docs/access-control.md) | [Oracle Integration](docs/oracle-integration.md) | [AMM Pool Integration](docs/amm-pool-integration.md) | [Arbitrage Bot](docs/arbitrage-bot.md)
