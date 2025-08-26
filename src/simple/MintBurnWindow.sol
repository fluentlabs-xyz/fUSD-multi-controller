// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "./fUSD2.sol";

// interface IOracle {
//   function latest() external view returns (uint256 price, uint256 updatedAt); // price in USD with 8 or 18 decimals
// }

contract MintBurnWindow is ReentrancyGuard, Ownable, Pausable {
    // Core contracts
    fUSD2 public fusd;
    // IOracle public oracle; // When oracle is available

    // Price configuration
    uint256 public fixedEthPrice = 3000 * 10**6; // $3000 per ETH (6 decimals like fUSD)
    uint256 public lastPrice;      // scaled
    uint256 public maxAge = 5 minutes;
    uint256 public maxPctMove = 5e16; // 5%

    // Events
    event fUSDMinted(address indexed user, uint256 ethAmount, uint256 fUSDAmount, uint256 ethPrice);
    event fUSDBurned(address indexed user, uint256 fUSDAmount, uint256 ethAmount, uint256 ethPrice);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ConfigUpdated(uint256 maxAge, uint256 maxPctMove);

    // Modifiers
    modifier whenWindowOpen() {
        require(!paused(), "Window is paused");
        _;
    }

    constructor(address _fusd) Ownable(msg.sender) {
        require(_fusd != address(0), "Invalid fUSD address");
        fusd = fUSD2(_fusd);
        lastPrice = fixedEthPrice;
    }

    /**
     * @dev Get current ETH price (fixed for now, can be replaced with oracle)
     */
    function quote() public view returns (uint256 price) {
        // For now return fixed price
        // When oracle is available, uncomment below:
        // (uint256 p, uint256 t) = oracle.latest();
        // require(block.timestamp - t <= maxAge, "stale");
        // require(abs(p - lastPrice) <= maxPctMove * lastPrice / 1e18, "jump");
        // return p;
        return fixedEthPrice;
    }

    /**
     * @dev Mint fUSD with ETH
     */
    function mintWithETH() external payable nonReentrant whenWindowOpen {
        require(msg.value > 0, "Must send ETH");
        
        uint256 ethPrice = quote();
        uint256 fUSDAmount = ethToUsd(msg.value, ethPrice);
        
        require(fUSDAmount > 0, "Amount too small");
        
        // Mint fUSD to user
        fusd.mint(msg.sender, fUSDAmount);
        
        // Update last price
        lastPrice = ethPrice;
        
        emit fUSDMinted(msg.sender, msg.value, fUSDAmount, ethPrice);
    }

    /**
     * @dev Burn fUSD for ETH
     */
    function redeemForETH(uint256 fUSDAmount) external nonReentrant whenWindowOpen {
        require(fUSDAmount > 0, "Amount must be greater than 0");
        
        uint256 ethPrice = quote();
        uint256 ethAmount = usdToEth(fUSDAmount, ethPrice);
        
        require(ethAmount > 0, "Amount too small");
        require(address(this).balance >= ethAmount, "Insufficient ETH balance");
        
        // Burn fUSD from user
        fusd.burnFrom(msg.sender, fUSDAmount);
        
        // Send ETH to user
        _sendETH(payable(msg.sender), ethAmount);
        
        // Update last price
        lastPrice = ethPrice;
        
        emit fUSDBurned(msg.sender, fUSDAmount, ethAmount, ethPrice);
    }

    /**
     * @dev Convert ETH amount to USD amount using price
     */
    function ethToUsd(uint256 ethAmount, uint256 ethPrice) public pure returns (uint256) {
        // ethAmount is in wei (18 decimals)
        // ethPrice is in USD with 6 decimals
        // Return fUSD amount with 6 decimals
        return (ethAmount * ethPrice) / 10**18;
    }

    /**
     * @dev Convert USD amount to ETH amount using price
     */
    function usdToEth(uint256 usdAmount, uint256 ethPrice) public pure returns (uint256) {
        // usdAmount is in fUSD (6 decimals)
        // ethPrice is in USD with 6 decimals
        // Return ETH amount in wei (18 decimals)
        return (usdAmount * 10**18) / ethPrice;
    }

    /**
     * @dev Send ETH to recipient
     */
    function _sendETH(address payable recipient, uint256 amount) internal {
        require(recipient != address(0), "Cannot send to zero address");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @dev Calculate absolute difference between two numbers
     */
    function abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // Admin functions

    /**
     * @dev Set the fUSD contract address
     */
    function setFUSD(address _fusd) external onlyOwner {
        require(_fusd != address(0), "Invalid fUSD address");
        fusd = fUSD2(_fusd);
    }

    /**
     * @dev Update fixed ETH price (for testing, remove when oracle is used)
     */
    function setFixedEthPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Price must be greater than 0");
        uint256 oldPrice = fixedEthPrice;
        fixedEthPrice = _price;
        lastPrice = _price;
        emit PriceUpdated(oldPrice, _price);
    }

    /**
     * @dev Set oracle address (when available)
     */
    // function setOracle(address _oracle) external onlyOwner {
    //     oracle = IOracle(_oracle);
    // }

    /**
     * @dev Update configuration parameters
     */
    function setConfig(uint256 _maxAge, uint256 _maxPctMove) external onlyOwner {
        maxAge = _maxAge;
        maxPctMove = _maxPctMove;
        emit ConfigUpdated(_maxAge, _maxPctMove);
    }

    /**
     * @dev Emergency pause minting only
     */
    function pauseMinting() external onlyOwner {
        _pause();
    }

    /**
     * @dev Resume minting
     */
    function unpauseMinting() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdraw ETH (only owner)
     */
    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        _sendETH(payable(owner()), balance);
    }

    /**
     * @dev Emergency withdraw fUSD (only owner)
     */
    function emergencyWithdrawFUSD() external onlyOwner {
        uint256 balance = fusd.balanceOf(address(this));
        require(balance > 0, "No fUSD to withdraw");
        fusd.transfer(owner(), balance);
    }

    /**
     * @dev Receive ETH
     */
    receive() external payable {
        // Allow contract to receive ETH
    }

    /**
     * @dev Get contract ETH balance
     */
    function getEthBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get contract fUSD balance
     */
    function getFUSDBalance() external view returns (uint256) {
        return fusd.balanceOf(address(this));
    }
}