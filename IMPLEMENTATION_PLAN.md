# fUSD Testnet Stablecoin Implementation Plan

## Overview
Deploy a testnet stablecoin (fUSD) on Fluent testnet using a modular controller architecture with oracle-based mint/burn mechanism and AMM integration for price stability through arbitrage.

## Phase 1: Core Infrastructure

### 1.1 Token & Registry Setup

**USD.sol**

```solidity
// ERC20 with 6 decimals (USDC-style)
// Minimal token that delegates minting/burning to authorized controllers
contract USD is ERC20, AccessControl {
    uint8 public constant decimals = 6;
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    
    // Controllers can mint/burn
    function mint(address to, uint256 amount) external onlyRole(CONTROLLER_ROLE);
    function burn(address from, uint256 amount) external onlyRole(CONTROLLER_ROLE);
}
```

**ControllerRegistry.sol**

```solidity
// Registry to manage multiple controllers and admin addresses
contract ControllerRegistry is AccessControl {
    // Support multiple admins
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // Track active controllers with metadata
    struct ControllerInfo {
        bool active;
        string name;
        uint256 dailyLimit;
        uint256 totalMinted;
    }
    
    mapping(address => ControllerInfo) public controllers;
    
    // Global safety limits
    uint256 public globalDailyLimit = 10_000_000 * 1e6; // 10M fUSD
    
    function addController(address controller, string memory name, uint256 limit) external onlyRole(ADMIN_ROLE);
    function removeController(address controller) external onlyRole(ADMIN_ROLE);
}
```

### 1.2 Mock Oracle

**MockOracle.sol**

```solidity
interface IOracle {
    function getETHUSD() external view returns (uint256);
    function isHealthy() external view returns (bool);
}

contract MockOracle is IOracle {
    uint256 public constant ETH_PRICE = 4500 * 1e6; // $4500 with 6 decimals
    bool public enableFluctuations = false;
    uint256 public fluctuationRange = 50; // 0.5% = 50 basis points
    
    function getETHUSD() external view returns (uint256) {
        if (!enableFluctuations) return ETH_PRICE;
        
        // Deterministic fluctuations for testing
        uint256 seed = uint256(keccak256(abi.encode(block.timestamp / 300)));
        int256 deviation = int256(seed % (fluctuationRange * 2)) - int256(fluctuationRange);
        return uint256(int256(ETH_PRICE) + (int256(ETH_PRICE) * deviation / 10000));
    }
}
```

### 1.3 Trading Desk Controller

**DeskController.sol**

```solidity
contract DeskController is IController, Pausable {
    IOracle public oracle;
    IERC20 public immutable fUSD;
    
    // Rate limiting: once per day per account
    mapping(address => uint256) public lastActionTime;
    uint256 public constant ACTION_COOLDOWN = 1 days;
    
    // Minimum amounts (6 decimals)
    uint256 public constant MIN_MINT = 1 * 1e6; // 1 fUSD
    uint256 public constant MIN_ETH = 0.0001 ether; // Dust prevention
    
    // Events for monitoring
    event Mint(address indexed user, uint256 ethIn, uint256 fusdOut, uint256 ethPrice);
    event Burn(address indexed user, uint256 fusdIn, uint256 ethOut, uint256 ethPrice);
    
    // Mint: Send ETH, receive fUSD at oracle price
    function mint() external payable whenNotPaused {
        require(block.timestamp >= lastActionTime[msg.sender] + ACTION_COOLDOWN, "Cooldown active");
        require(msg.value >= MIN_ETH, "ETH amount too small");
        
        uint256 ethPrice = oracle.getETHUSD(); // Returns price in 6 decimals
        // ETH has 18 decimals, fUSD has 6 decimals, price has 6 decimals
        // fusdAmount = ethAmount * price / 1e18
        uint256 fusdAmount = (msg.value * ethPrice) / 1e18;
        
        require(fusdAmount >= MIN_MINT, "Mint amount too small");
        
        lastActionTime[msg.sender] = block.timestamp;
        IUSD(address(fUSD)).mint(msg.sender, fusdAmount);
        
        emit Mint(msg.sender, msg.value, fusdAmount, ethPrice);
    }
    
    // Burn: Send fUSD, receive ETH at oracle price
    function burn(uint256 fusdAmount) external whenNotPaused {
        require(block.timestamp >= lastActionTime[msg.sender] + ACTION_COOLDOWN, "Cooldown active");
        require(fusdAmount >= MIN_MINT, "Burn amount too small");
        
        uint256 ethPrice = oracle.getETHUSD();
        // ethAmount = fusdAmount * 1e18 / price
        uint256 ethAmount = (fusdAmount * 1e18) / ethPrice;
        
        require(ethAmount <= address(this).balance, "Insufficient ETH reserves");
        
        lastActionTime[msg.sender] = block.timestamp;
        fUSD.transferFrom(msg.sender, address(this), fusdAmount);
        IUSD(address(fUSD)).burn(address(this), fusdAmount);
        
        (bool success, ) = msg.sender.call{value: ethAmount}("");
        require(success, "ETH transfer failed");
        
        emit Burn(msg.sender, fusdAmount, ethAmount, ethPrice);
    }
    
    // View functions for arbitrageurs
    function getMintQuote(uint256 ethAmount) external view returns (uint256);
    function getBurnQuote(uint256 fusdAmount) external view returns (uint256);
}
```

## Phase 2: AMM Integration

### 2.1 Pool Setup

**PoolInitializer.sol**

```solidity
contract PoolInitializer {
    function initializeUniV2Pool(
        address factory,
        address fUSD,
        address weth,
        address desk,
        uint256 initialETH
    ) external payable {
        // Get oracle price for correct ratio
        uint256 ethPrice = IOracle(desk.oracle()).getETHUSD();
        uint256 fusdAmount = (initialETH * ethPrice) / 1e18;
        
        // Create pair if doesn't exist
        address pair = IUniswapV2Factory(factory).createPair(fUSD, weth);
        
        // Wrap ETH
        IWETH(weth).deposit{value: initialETH}();
        
        // Add liquidity at oracle price
        IERC20(fUSD).approve(router, fusdAmount);
        IWETH(weth).approve(router, initialETH);
        
        IUniswapV2Router.addLiquidity(
            fUSD,
            weth,
            fusdAmount,
            initialETH,
            fusdAmount * 99 / 100,  // 1% slippage
            initialETH * 99 / 100,
            address(this),
            block.timestamp
        );
    }
}
```

### 2.2 Arbitrage Bot (Off-chain)

**scripts/arbitrage.js**

```javascript
// Monitor and execute arbitrage opportunities
async function monitorArbitrage() {
    const deskPrice = await desk.getETHUSD();
    const poolReserves = await pair.getReserves();
    const poolPrice = calculatePrice(poolReserves);
    
    const threshold = 0.002; // 0.2% profit minimum
    
    if (poolPrice < deskPrice * (1 - threshold)) {
        // fUSD cheap in pool: buy from pool, burn at desk
        await executeBurnArbitrage();
    } else if (poolPrice > deskPrice * (1 + threshold)) {
        // fUSD expensive in pool: mint at desk, sell to pool
        await executeMintArbitrage();
    }
}
```

## Phase 3: Deployment & Testing

### 3.1 Deployment Script (Foundry)

**script/DeployFUSD.s.sol**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

contract DeployFUSD is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address[] memory admins = vm.envAddress("ADMIN_ADDRESSES", ",");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy token
        USD fUSD = new USD();
        
        // 2. Deploy registry
        ControllerRegistry registry = new ControllerRegistry();
        
        // 3. Setup multiple admins
        for (uint i = 0; i < admins.length; i++) {
            registry.grantRole(registry.ADMIN_ROLE(), admins[i]);
        }
        
        // 4. Deploy mock oracle
        MockOracle oracle = new MockOracle();
        
        // 5. Deploy desk controller
        DeskController desk = new DeskController(
            address(fUSD),
            address(oracle)
        );
        
        // 6. Wire up permissions
        fUSD.grantRole(fUSD.CONTROLLER_ROLE(), address(desk));
        registry.addController(address(desk), "Trading Desk", 1_000_000 * 1e6);
        
        // 7. Fund desk with initial ETH
        payable(address(desk)).transfer(10 ether);
        
        // 8. Initialize AMM pool
        PoolInitializer poolInit = new PoolInitializer();
        poolInit.initializeUniV2Pool{value: 5 ether}(
            UNISWAP_FACTORY,
            address(fUSD),
            WETH,
            address(desk),
            5 ether
        );
        
        vm.stopBroadcast();
        
        // Log deployed addresses
        console.log("fUSD Token:", address(fUSD));
        console.log("Registry:", address(registry));
        console.log("Oracle:", address(oracle));
        console.log("Desk:", address(desk));
        console.log("Pool:", IUniswapV2Factory(UNISWAP_FACTORY).getPair(address(fUSD), WETH));
    }
}
```

### 3.2 Testing Suite

**test/FUSD.t.sol**

```solidity
contract FUSDTest is Test {
    function setUp() public {
        // Deploy system
    }
    
    function test_MintBurnParity() public {
        // Test mint → burn returns same ETH
    }
    
    function test_RateLimiting() public {
        // Test once-per-day restriction
    }
    
    function test_ArbitrageConvergence() public {
        // Test AMM price converges to oracle price
    }
    
    function test_OracleSwap() public {
        // Test switching from mock to Pyth oracle
    }
}
```

### 3.3 Monitoring & Analytics

**Deployment Checklist:**

```bash
# Environment setup
cp .env.example .env
# Add PRIVATE_KEY and ADMIN_ADDRESSES (comma-separated)

# Deploy
forge script script/DeployFUSD.s.sol --rpc-url $RPC_URL --broadcast --verify

# Verify deployment
forge verify-contract $FUSD_ADDRESS USD --chain fluent-testnet

# Run tests
forge test --fork-url $RPC_URL -vvv
```

**Key Metrics to Monitor:**

- Total fUSD supply
- Desk ETH reserves
- Oracle vs AMM price deviation
- Daily mint/burn volume
- Unique users
- Arbitrage transaction frequency

## Phase 4: Future Migrations

### 4.1 Oracle Migration to Pyth

**PythOracle.sol** (Ready to deploy when Pyth is available)

```solidity
contract PythOracle is IOracle {
    IPyth public immutable pyth;
    bytes32 public immutable ethUsdFeedId;
    
    function getETHUSD() external view returns (uint256) {
        PythStructs.Price memory price = pyth.getPriceUnsafe(ethUsdFeedId);
        // Convert Pyth format to 6 decimals
        return convertToSixDecimals(price);
    }
}

// Migration process:
// 1. Deploy PythOracle
// 2. Call desk.updateOracle(pythOracleAddress)
// 3. No other changes needed
```

### 4.2 Flash Mint Controller (If Needed)

**FlashMintController.sol**

```solidity
contract FlashMintController is IController {
    function flashMint(uint256 amount, address target, bytes calldata data) external {
        // Mint → callback → burn pattern for liquidation testing
        fUSD.mint(target, amount);
        IFlashBorrower(target).onFlashLoan(amount, data);
        require(fUSD.balanceOf(target) >= amount, "Flash mint not repaid");
        fUSD.burn(target, amount);
    }
}

// Deployment:
// 1. Deploy FlashMintController
// 2. registry.addController(flashMintAddress, "Flash Mint", 100_000 * 1e6)
// 3. fUSD.grantRole(CONTROLLER_ROLE, flashMintAddress)
```

### 4.3 Enhanced Desk with Rust Engine (Optional)

**Integration Points:**

- Dynamic fee calculation based on volatility
- TWAP price averaging
- Optimal arbitrage routing
- Advanced peg stability mechanisms

```solidity
contract EnhancedDesk is DeskController {
    IMathematicalEngine public rustEngine;
    
    function getDynamicFee() public view returns (uint256) {
        return rustEngine.calculateOptimalFee(
            getVolatility24h(),
            getTotalVolume24h()
        );
    }
}
```

## Configuration Summary

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Token Decimals | 6 | USDC/USDT compatibility |
| Oracle Price | $4,500 | Current ETH estimate |
| Min Mint | 1 fUSD | Accessible but not spammable |
| Rate Limit | 24 hours | Prevent abuse, allow testing |
| Pool Initial Liquidity | 5 ETH + 22,500 fUSD | Sufficient for testing |

## Success Criteria

- [ ] fUSD maintains peg within 1% of oracle price
- [ ] Arbitrage bots successfully correct price deviations
- [ ] Teams can mint/burn with minimal friction
- [ ] Oracle swap from mock to Pyth works seamlessly
- [ ] System handles 100+ daily users without issues

## Documentation Requirements

1. **Integration Guide** - How teams use fUSD in their dApps
2. **Arbitrage Bot Guide** - How to run arbitrage for profit
3. **API Documentation** - Contract interfaces and events
4. **Troubleshooting Guide** - Common issues and solutions