# Fluent Testnet Stablecoin (fUSD)

**Navigation**: ← Back | **README** | [🏠 Home](README.md) | [Next →](docs/controller-architecture.md)

---

A testnet stablecoin system with a mint/burn trading desk, designed for testing DeFi protocols and arbitrage strategies on Fluent's testnet environment.

## Overview

fUSD is an ETH-collateralized stablecoin that maintains a soft peg to USD through a trading desk mechanism. Users can mint fUSD by depositing ETH and burn fUSD to redeem ETH at current oracle prices. The system is designed for testnet environments and includes features for testing various DeFi scenarios.

## Key Features

- **6-Decimal Stablecoin**: USDC-style decimal precision for compatibility
- **Trading Desk Model**: Direct mint/burn mechanism through ETH collateral
- **Modular Controller Architecture**: Extensible design supporting multiple controller types
- **Dual Oracle Architecture**: MockOracle and PythOracle with timelock switching mechanism
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
                    │  Oracle System   │     │   Registry   │
                    │ ┌──────────────┐ │     └──────────────┘
                    │ │ MockOracle   │ │
                    │ └──────────────┘ │
                    │ ┌──────────────┐ │
                    │ │ PythOracle   │ │
                    │ └──────────────┘ │
                    └──────────────────┘
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

4. **Oracle System** (`src/oracles/`)
   - **MockOracle**: Configurable price feed for testing environments
   - **PythOracle**: Production-ready Pyth Network integration with ETH/USD feeds
   - **Timelock Switching**: 2-day delay mechanism for secure oracle transitions
   - **AccessControl**: Role-based permissions matching DeskController pattern

### Deployment Architecture

The deployment system is designed around a modular architecture that separates evergreen contracts from swappable components:

#### Core Contracts (Deploy Once)

- **fUSD Token**: The main stablecoin contract that remains constant
- **ControllerRegistry**: Central registry that manages all controllers

#### Swappable Components

- **Oracles**: MockOracle for testing, PythOracle for production
- **Controllers**: DeskController and future controller implementations

#### Deployment Sequence

1. **Core Deployment** (`DeployCore.s.sol`): Deploys fUSD and ControllerRegistry
2. **Oracle Deployment** (`DeployOracles.s.sol`): Deploys both MockOracle and PythOracle
3. **Pyth Update** (`UpdatePyth.s.sol`): Updates PythOracle with latest price data
4. **Controller Deployment** (`DeployControllers.s.sol`): Deploys DeskController with oracle dependencies

This modular approach enables:

- Independent upgrades of oracles without redeploying core contracts
- Testing different controller implementations
- Easier maintenance and reduced deployment costs for component updates

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for offchain scripts)
- [ETH on Fluent testnet](https://testnet.gblend.xyz/) for deployment

### Installation

```bash
git clone https://github.com/fluentlabs-xyz/fUSD-multi-controller.git
cd fUSD-multi-controller
forge install
```

### Configuration

1. Create `.env` file:

```bash
PRIVATE_KEY=your_private_key
RPC_URL=your_rpc_url
PYTH="0x2880aB155794e7179c9eE2e38200202908C17B43"
```

1. Configure admin addresses in `script/config/admins.json`:

```json
{
    "admins": ["0x..."],
    "emergency": ["0x..."]
}
```

### Deployment

The deployment process is split into four modular scripts to separate core contracts (deployed once) from swappable components (oracles and controllers):

```bash
# 1. Deploy the core contracts (fUSD + ControllerRegistry)
forge script script/DeployCore.s.sol:DeployCore --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# 2. Deploy the oracles (MockOracle + PythOracle)
forge script script/DeployOracles.s.sol:DeployOracles --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# 3. Update Pyth price feed (required for DeskController deployment)
forge script script/UpdatePyth.s.sol:UpdatePyth --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# 4. Deploy the controllers (DeskController)
forge script script/DeployControllers.s.sol:DeployControllers --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
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
│   ├── oracles/
│   │   ├── MockOracle.sol          # Test oracle implementation
│   │   └── PythOracle.sol          # Pyth Network oracle integration
│   ├── controller/
│   │   ├── DeskController.sol      # Trading desk controller
│   │   └── ControllerRegistry.sol  # Controller management
│   └── interfaces/
│       ├── IController.sol         # Controller interface
│       ├── IOracle.sol            # Oracle interface
│       └── IUSD.sol               # Token interface
├── script/
│   ├── DeployCore.s.sol           # Core contracts (fUSD + Registry)
│   ├── DeployOracles.s.sol        # Oracle deployments
│   ├── UpdatePyth.s.sol           # Pyth price feed updates
│   ├── DeployControllers.s.sol    # Controller deployments
│   └── config/
│       ├── admins.json            # Admin configuration
│       └── deployments.json       # Contract addresses
├── test/
│   ├── FUSD.t.sol                 # Main test suite
│   └── oracles/
│       ├── MockOracle.t.sol       # MockOracle tests
│       ├── PythOracle.t.sol       # PythOracle tests
│       └── OracleSwitching.t.sol  # Timelock switching tests
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

1. **AMM Pool Creation**: Automated liquidity pool deployment
1. **Additional Controllers**: Migration tools, bridge controllers
1. **Enhanced Monitoring**: Real-time analytics dashboard

## License

MIT

---

**Navigation**: ← Back | **README** | [🏠 Home](README.md) | [Next →](docs/controller-architecture.md)
