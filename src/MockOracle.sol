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