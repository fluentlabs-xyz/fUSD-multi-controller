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
