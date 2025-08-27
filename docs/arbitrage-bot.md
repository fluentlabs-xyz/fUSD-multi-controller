# Arbitrage Bot Documentation

**Navigation**: [README](../README.md) | [Controller Architecture](controller-architecture.md) | [Access Control](access-control.md) | [Oracle Integration](oracle-integration.md) | [AMM Pool Integration](amm-pool-integration.md) | [Arbitrage Bot](arbitrage-bot.md)

---

## Overview

The arbitrage bot monitors price discrepancies between the fUSD trading desk and AMM pools, executing profitable trades to maintain price parity. This serves dual purposes: generating profit for operators and maintaining the fUSD peg stability.

## Current Implementation

### Basic Structure

Located in `/offchain/arbitrage.js`:

```javascript
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

## Arbitrage Strategies

### Strategy 1: Mint and Sell (Pool Premium)

When fUSD is trading above peg in the pool:

```
Condition: Pool Price > Desk Price * (1 + threshold)

Steps:
1. Calculate optimal trade size
2. Mint fUSD from desk at oracle price (send ETH)
3. Sell fUSD to pool at higher price
4. Receive ETH back
5. Profit = ETH received - ETH sent - gas costs
```

### Strategy 2: Buy and Burn (Pool Discount)

When fUSD is trading below peg in the pool:

```
Condition: Pool Price < Desk Price * (1 - threshold)

Steps:
1. Calculate optimal trade size
2. Buy fUSD from pool at lower price (send ETH)
3. Burn fUSD at desk for oracle price
4. Receive ETH back
5. Profit = ETH received - ETH sent - gas costs
```

## Detailed Implementation

### Price Calculation

```javascript
function calculatePrice(reserves) {
  const [reserveFUSD, reserveETH] = reserves;
  // Price = ETH per fUSD
  // Both reserves adjusted for decimals (fUSD: 6, ETH: 18)
  return (reserveETH * 1e6) / (reserveFUSD * 1e18);
}

function calculatePriceImpact(amountIn, reserveIn, reserveOut) {
  const k = reserveIn * reserveOut; // Constant product
  const newReserveIn = reserveIn + amountIn;
  const newReserveOut = k / newReserveIn;
  const amountOut = reserveOut - newReserveOut;
  
  const spotPrice = reserveOut / reserveIn;
  const executionPrice = amountOut / amountIn;
  const priceImpact = (spotPrice - executionPrice) / spotPrice;
  
  return { amountOut, priceImpact };
}
```

### Optimal Trade Size

```javascript
function calculateOptimalTradeSize(
  deskPrice,
  poolReserveETH,
  poolReserveFUSD,
  maxSlippage = 0.01 // 1% max price impact
) {
  // Binary search for optimal size
  let low = 0;
  let high = poolReserveETH * 0.1; // Max 10% of pool
  
  while (high - low > 1e15) { // 0.001 ETH precision
    const mid = (low + high) / 2;
    const { priceImpact } = calculatePriceImpact(
      mid,
      poolReserveETH,
      poolReserveFUSD
    );
    
    if (priceImpact > maxSlippage) {
      high = mid;
    } else {
      low = mid;
    }
  }
  
  return low;
}
```

### Transaction Execution

```javascript
async function executeMintArbitrage() {
  try {
    // 1. Get quotes
    const ethAmount = calculateOptimalTradeSize();
    const mintQuote = await desk.getMintQuote(ethAmount);
    const poolQuote = await getPoolSellQuote(mintQuote);
    
    // 2. Validate profitability
    const grossProfit = poolQuote - ethAmount;
    const estimatedGas = await estimateGasCosts();
    const netProfit = grossProfit - estimatedGas;
    
    if (netProfit <= 0) {
      console.log('Trade not profitable after gas');
      return;
    }
    
    // 3. Execute atomic transaction
    const tx = await arbitrageContract.executeMintArbitrage(
      ethAmount,
      mintQuote,
      poolQuote * 0.99, // 1% slippage tolerance
      { value: ethAmount }
    );
    
    await tx.wait();
    console.log(`Arbitrage executed: ${netProfit} ETH profit`);
    
  } catch (error) {
    console.error('Arbitrage failed:', error);
  }
}
```

## Smart Contract Integration

### Arbitrage Contract

```solidity
contract ArbitrageBot {
    IDeskController public desk;
    IUniswapV2Pair public pair;
    IERC20 public fusd;
    
    function executeMintArbitrage(
        uint256 ethAmount,
        uint256 expectedFusd,
        uint256 minEthOut
    ) external payable onlyBot {
        // 1. Mint fUSD
        desk.mint{value: ethAmount}();
        
        // 2. Sell to pool
        uint256 fusdBalance = fusd.balanceOf(address(this));
        require(fusdBalance >= expectedFusd * 99 / 100, "Mint slippage");
        
        fusd.transfer(address(pair), fusdBalance);
        
        // 3. Swap
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 amountOut = getAmountOut(fusdBalance, reserve0, reserve1);
        require(amountOut >= minEthOut, "Pool slippage");
        
        pair.swap(0, amountOut, address(this), "");
        
        // 4. Send profits
        payable(msg.sender).transfer(address(this).balance);
    }
}
```

## Configuration

### Environment Variables

```bash
# Network Configuration
RPC_URL=https://rpc.testnet.fluent.xyz
CHAIN_ID=1234

# Contract Addresses
DESK_CONTROLLER=0x...
FUSD_TOKEN=0x...
POOL_ADDRESS=0x...
ARBITRAGE_CONTRACT=0x...

# Bot Configuration
PRIVATE_KEY=0x...
MIN_PROFIT_THRESHOLD=0.002  # 0.2%
MAX_SLIPPAGE=0.01           # 1%
POLL_INTERVAL=5000          # 5 seconds
MAX_GAS_PRICE=100           # 100 gwei

# Risk Management
MAX_POSITION_SIZE=10        # 10 ETH max per trade
DAILY_LOSS_LIMIT=1          # 1 ETH max daily loss
COOLDOWN_PERIOD=60          # 60 seconds between trades
```

### Risk Parameters

```javascript
const riskConfig = {
  // Position sizing
  maxPositionSize: parseEther('10'),
  maxPoolImpact: 0.02, // 2% max pool impact
  
  // Loss limits
  dailyLossLimit: parseEther('1'),
  maxConsecutiveLosses: 3,
  
  // Timing
  minTimeBetweenTrades: 60, // seconds
  maxPendingTime: 300, // 5 minutes max for pending tx
  
  // Gas management
  maxGasPrice: parseUnits('100', 'gwei'),
  gasLimitMultiplier: 1.2, // 20% buffer
};
```

## Monitoring and Logging

### Performance Metrics

```javascript
class ArbitrageMonitor {
  constructor() {
    this.metrics = {
      totalTrades: 0,
      successfulTrades: 0,
      failedTrades: 0,
      totalProfit: BigNumber.from(0),
      totalGasSpent: BigNumber.from(0),
      largestProfit: BigNumber.from(0),
      largestLoss: BigNumber.from(0),
    };
  }
  
  logTrade(result) {
    this.metrics.totalTrades++;
    
    if (result.success) {
      this.metrics.successfulTrades++;
      this.metrics.totalProfit = this.metrics.totalProfit.add(result.profit);
      
      if (result.profit.gt(this.metrics.largestProfit)) {
        this.metrics.largestProfit = result.profit;
      }
    } else {
      this.metrics.failedTrades++;
      
      if (result.loss && result.loss.gt(this.metrics.largestLoss)) {
        this.metrics.largestLoss = result.loss;
      }
    }
    
    this.metrics.totalGasSpent = this.metrics.totalGasSpent.add(result.gasUsed);
    
    // Log to monitoring service
    await prometheus.recordTrade(this.metrics);
  }
}
```

### Alert System

```javascript
const alerts = {
  priceDeviation: {
    threshold: 0.05, // 5% deviation
    action: async (deviation) => {
      await sendAlert(`High price deviation detected: ${deviation}%`);
    }
  },
  
  lowLiquidity: {
    threshold: parseEther('100'), // 100 ETH minimum
    action: async (liquidity) => {
      await sendAlert(`Low pool liquidity: ${liquidity} ETH`);
    }
  },
  
  highGasPrice: {
    threshold: parseUnits('200', 'gwei'),
    action: async (gasPrice) => {
      console.log(`High gas price: ${gasPrice}, pausing bot`);
      await pauseBot();
    }
  },
  
  lossLimit: {
    action: async (totalLoss) => {
      await sendAlert(`Daily loss limit reached: ${totalLoss} ETH`);
      await emergencyShutdown();
    }
  }
};
```

## Advanced Strategies

### 1. Flash Loan Arbitrage

For capital-efficient arbitrage without holding funds:

```solidity
contract FlashArbitrage {
    function executeFlashArbitrage(
        uint256 borrowAmount,
        bool mintFirst
    ) external {
        // Borrow ETH from flash loan provider
        flashLoanProvider.flashLoan(borrowAmount);
    }
    
    function onFlashLoan(uint256 amount) external {
        if (mintFirst) {
            // Mint -> Sell flow
            desk.mint{value: amount}();
            uint256 fusdReceived = fusd.balanceOf(address(this));
            swapFusdForEth(fusdReceived);
        } else {
            // Buy -> Burn flow
            uint256 fusdBought = swapEthForFusd(amount);
            fusd.approve(address(desk), fusdBought);
            desk.burn(fusdBought);
        }
        
        // Repay flash loan + fee
        uint256 totalOwed = amount + flashLoanFee;
        require(address(this).balance >= totalOwed, "Unprofitable");
        flashLoanProvider.repay{value: totalOwed}();
        
        // Transfer profit
        owner.transfer(address(this).balance);
    }
}
```

### 2. MEV Protection

Protect against sandwich attacks:

```javascript
async function executeWithMEVProtection(transaction) {
  try {
    // Use Flashbots or similar
    const flashbotsProvider = new FlashbotsProvider();
    
    const bundle = [
      {
        transaction,
        signer: wallet
      }
    ];
    
    const result = await flashbotsProvider.sendBundle(bundle);
    
    if (result.error) {
      console.error('Flashbots error:', result.error);
      // Fallback to regular transaction
      return executeNormalTransaction(transaction);
    }
    
    return result;
    
  } catch (error) {
    console.error('MEV protection failed:', error);
    return executeNormalTransaction(transaction);
  }
}
```

### 3. Multi-Pool Arbitrage

```javascript
async function findBestArbitrageRoute() {
  const routes = [
    { name: 'Direct', path: [desk, pool1] },
    { name: 'Triangular', path: [desk, pool1, pool2, desk] },
    { name: 'Multi-hop', path: [desk, pool1, pool2, pool3, desk] }
  ];
  
  let bestRoute = null;
  let bestProfit = 0;
  
  for (const route of routes) {
    const profit = await calculateRouteProfit(route);
    
    if (profit > bestProfit) {
      bestProfit = profit;
      bestRoute = route;
    }
  }
  
  return { route: bestRoute, expectedProfit: bestProfit };
}
```

## Deployment and Operations

### Deployment Checklist

1. **Pre-deployment**
   - [ ] Audit arbitrage contract
   - [ ] Test on testnet extensively
   - [ ] Set up monitoring infrastructure
   - [ ] Configure alert thresholds

2. **Deployment**
   - [ ] Deploy arbitrage contract
   - [ ] Fund bot wallet
   - [ ] Set conservative parameters initially
   - [ ] Enable monitoring

3. **Post-deployment**
   - [ ] Monitor first 24 hours closely
   - [ ] Gradually increase position sizes
   - [ ] Optimize gas usage
   - [ ] Document any issues

### Operational Procedures

```markdown
## Daily Operations

1. **Morning Checks**
   - Review overnight performance
   - Check for any alerts
   - Verify pool liquidity levels
   - Update gas price limits

2. **Continuous Monitoring**
   - Watch profit/loss in real-time
   - Monitor gas prices
   - Check for unusual activity
   - Verify oracle health

3. **End of Day**
   - Calculate daily P&L
   - Archive logs
   - Update risk parameters if needed
   - Plan for next day

## Emergency Procedures

1. **Bot Malfunction**
   - Immediately pause bot
   - Check recent transactions
   - Identify root cause
   - Resume with fix or rollback

2. **Market Anomaly**
   - Pause trading
   - Assess situation
   - Adjust parameters
   - Resume gradually

3. **Security Incident**
   - Emergency shutdown
   - Secure remaining funds
   - Investigate breach
   - Implement fixes before restart
```

## Future Enhancements

1. **Machine Learning Integration**
   - Predict optimal trade timing
   - Dynamic threshold adjustment
   - Pattern recognition for market conditions

2. **Cross-Chain Arbitrage**
   - Monitor prices across networks
   - Execute cross-chain swaps
   - Optimize for bridge costs

3. **Advanced Order Types**
   - Limit orders for better execution
   - TWAP orders for large trades
   - Stop-loss mechanisms

## Summary

The arbitrage bot serves as a critical component for:
- **Price Stability**: Maintaining fUSD peg
- **Profitability**: Generating returns for operators
- **Market Efficiency**: Reducing price discrepancies
- **Testing**: Validating system robustness

Proper configuration and monitoring ensure profitable and stable operations while contributing to the overall health of the fUSD ecosystem.

---

**Navigation**: [README](../README.md) | [Controller Architecture](controller-architecture.md) | [Access Control](access-control.md) | [Oracle Integration](oracle-integration.md) | [AMM Pool Integration](amm-pool-integration.md) | [Arbitrage Bot](arbitrage-bot.md)