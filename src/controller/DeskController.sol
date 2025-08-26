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