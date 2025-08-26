// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IController.sol";
import "../interfaces/IUSD.sol";
import "../MockOracle.sol";

/**
 * @title DeskController
 * @dev Trading desk controller for fUSD minting/burning with ETH
 * Implements rate limiting and oracle-based pricing
 */
contract DeskController is IController, Pausable, Ownable {
    IOracle public immutable oracle;
    IERC20 public immutable fUSD;
    
    // Rate limiting: once per day per account
    mapping(address => uint256) public lastActionTime;
    uint256 public constant ACTION_COOLDOWN = 1 days;
    
    // Minimum amounts (6 decimals)
    uint256 public constant MIN_MINT = 1 * 1e6; // 1 fUSD
    uint256 public constant MIN_ETH = 0.0001 ether; // Dust prevention
    
    // Modifier for oracle health check
    modifier onlyHealthyOracle() {
        require(oracle.isHealthy(), "Oracle unhealthy");
        _;
    }
    
    // Events are defined in IController interface
    
    /**
     * @dev Constructor
     * @param _fUSD Address of the fUSD token contract
     * @param _oracle Address of the price oracle
     */
    constructor(address _fUSD, address _oracle) Ownable(msg.sender) {
        require(_fUSD != address(0), "fUSD: zero address");
        require(_oracle != address(0), "fUSD: zero address");
        
        fUSD = IERC20(_fUSD);
        oracle = IOracle(_oracle);
    }
    
    /**
     * @dev Mint fUSD by sending ETH
     * Rate limited to once per day per account
     */
    function mint() external payable whenNotPaused onlyHealthyOracle {
        require(block.timestamp >= lastActionTime[msg.sender] + ACTION_COOLDOWN, "Cooldown active");
        require(msg.value >= MIN_ETH, "ETH amount too small");
        
        uint256 ethPrice = oracle.getETHUSD(); // Returns price in 6 decimals
        require(ethPrice > 0, "Invalid oracle price");
        
        // ETH has 18 decimals, fUSD has 6 decimals, price has 6 decimals
        // fusdAmount = ethAmount * price / 1e18
        uint256 fusdAmount = (msg.value * ethPrice) / 1e18;
        
        require(fusdAmount >= MIN_MINT, "Mint amount too small");
        
        lastActionTime[msg.sender] = block.timestamp;
        IUSD(address(fUSD)).mint(msg.sender, fusdAmount);
        
        emit Mint(msg.sender, msg.value, fusdAmount, ethPrice);
    }
    
    /**
     * @dev Burn fUSD to receive ETH
     * Rate limited to once per day per account
     * @param fusdAmount Amount of fUSD to burn
     */
    function burn(uint256 fusdAmount) external whenNotPaused onlyHealthyOracle {
        require(block.timestamp >= lastActionTime[msg.sender] + ACTION_COOLDOWN, "Cooldown active");
        require(fusdAmount >= MIN_MINT, "Burn amount too small");
        
        uint256 ethPrice = oracle.getETHUSD();
        require(ethPrice > 0, "Invalid oracle price");
        
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
    
    /**
     * @dev Get quote for minting fUSD with ETH
     * @param ethAmount Amount of ETH to mint with
     * @return fusdAmount Amount of fUSD that would be minted
     */
    function getMintQuote(uint256 ethAmount) external view onlyHealthyOracle returns (uint256) {
        require(ethAmount >= MIN_ETH, "ETH amount too small");
        
        uint256 ethPrice = oracle.getETHUSD();
        require(ethPrice > 0, "Invalid oracle price");
        
        return (ethAmount * ethPrice) / 1e18;
    }
    
    /**
     * @dev Get quote for burning fUSD to burn
     * @param fusdAmount Amount of fUSD to burn
     * @return ethAmount Amount of ETH that would be received
     */
    function getBurnQuote(uint256 fusdAmount) external view onlyHealthyOracle returns (uint256) {
        require(fusdAmount >= MIN_MINT, "Burn amount too small");
        
        uint256 ethPrice = oracle.getETHUSD();
        return (fusdAmount * 1e18) / ethPrice;
    }
    
    /**
     * @dev Get current ETH/USD price from oracle
     * @return Current ETH price in 6 decimals
     */
    function getETHUSD() external view returns (uint256) {
        return oracle.getETHUSD();
    }
    
    /**
     * @dev Check if oracle is healthy
     * @return True if oracle is functioning normally
     */
    function isOracleHealthy() external view returns (bool) {
        return oracle.isHealthy();
    }
    
    /**
     * @dev Pause all operations (only owner can call)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause all operations (only owner can call)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Emergency function to withdraw ETH (only owner can call)
     * @param amount Amount of ETH to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    /**
     * @dev Get contract ETH balance
     * @return Current ETH balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Check if user can perform action (rate limiting)
     * @param user Address to check
     * @return True if user can perform action
     */
    function canPerformAction(address user) external view returns (bool) {
        return block.timestamp >= lastActionTime[user] + ACTION_COOLDOWN;
    }
    
    /**
     * @dev Get time until user can perform next action
     * @param user Address to check
     * @return Seconds until next action is allowed
     */
    function getTimeUntilNextAction(address user) external view returns (uint256) {
        uint256 nextActionTime = lastActionTime[user] + ACTION_COOLDOWN;
        if (block.timestamp >= nextActionTime) {
            return 0;
        }
        return nextActionTime - block.timestamp;
    }
    
    // Allow contract to receive ETH
    receive() external payable {}
}