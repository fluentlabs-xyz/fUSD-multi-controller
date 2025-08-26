// PSEUDOCODE
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