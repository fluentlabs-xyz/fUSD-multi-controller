// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IController} from "../interfaces/IController.sol";
import {IUSD} from "../interfaces/IUSD.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title DeskController
 * @dev Trading desk controller for fUSD minting/burning with ETH
 * Implements rate limiting, oracle-based pricing, and enhanced security features
 * Uses AccessControl for multi-admin operations across different time zones
 */
contract DeskController is IController, Pausable, AccessControl, ReentrancyGuard {
    IOracle public immutable ORACLE;
    IERC20 public immutable FUSD;

    // Role definitions for multi-admin access
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Rate limiting: configurable cooldown per account
    mapping(address => uint256) public lastActionTime;
    uint256 public actionCooldown = 1 days;

    // Minimum amounts (configurable)
    uint256 public minMint = 1 * 1e6; // 1 fUSD
    uint256 public minEth = 0.0001 ether; // Dust prevention

    // Price validation parameters
    uint256 public maxPriceMove = 5e16; // 5% maximum price movement
    uint256 public lastPrice;
    uint256 public lastPriceUpdate;
    uint256 public priceUpdateCount;

    // Circuit breaker flags
    bool public mintingPaused = false;
    bool public burningPaused = false;

    // Events
    event ConfigUpdated(uint256 cooldown, uint256 minMint, uint256 minEth);
    event PriceValidationFailed(uint256 oldPrice, uint256 newPrice, uint256 maxMove);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event MaxPriceMoveUpdated(uint256 oldMove, uint256 newMove);
    event MintingPaused(address indexed admin);
    event MintingResumed(address indexed admin);
    event BurningPaused(address indexed admin);
    event BurningResumed(address indexed admin);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event EmergencyAction(address indexed admin, string action, uint256 amount);

    // Modifier for oracle health check
    modifier onlyHealthyOracle() {
        require(ORACLE.isHealthy(), "Oracle unhealthy");
        _;
    }

    // Modifier for admin operations
    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "DeskController: admin role required");
        _;
    }

    // Modifier for emergency operations
    modifier onlyEmergency() {
        require(hasRole(EMERGENCY_ROLE, msg.sender), "DeskController: emergency role required");
        _;
    }

    // Modifier for minting operations
    modifier whenMintingEnabled() {
        require(!mintingPaused, "Minting paused");
        _;
    }

    // Modifier for burning operations
    modifier whenBurningEnabled() {
        require(!burningPaused, "Burning paused");
        _;
    }

    /**
     * @dev Constructor
     * @param fusd Address of the fUSD token contract
     * @param oracle Address of the price oracle
     */
    constructor(address fusd, address oracle) {
        require(fusd != address(0), "fUSD: zero address");
        require(oracle != address(0), "Oracle: zero address");

        FUSD = IERC20(fusd);
        ORACLE = IOracle(oracle);

        // Initialize access control - deployer gets all roles initially
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        // Initialize price tracking
        lastPrice = ORACLE.getEthUsd();
        lastPriceUpdate = block.timestamp;
    }

    /**
     * @dev Internal function to validate price movements
     * @param newPrice New price to validate
     */
    function _validatePrice(uint256 newPrice) internal view {
        if (lastPrice > 0) {
            uint256 priceDiff = _abs(newPrice, lastPrice);
            uint256 maxAllowedMove = (lastPrice * maxPriceMove) / 1e18;
            require(priceDiff <= maxAllowedMove, "Price move too large");
        }
    }

    /**
     * @dev Internal function to update price tracking
     * @param newPrice New price to set
     */
    function _updatePrice(uint256 newPrice) internal {
        if (newPrice != lastPrice) {
            uint256 oldPrice = lastPrice;
            lastPrice = newPrice;
            lastPriceUpdate = block.timestamp;
            priceUpdateCount++;
            emit PriceUpdated(oldPrice, newPrice);
        }
    }

    /**
     * @dev Calculate absolute difference between two numbers
     */
    function _abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /**
     * @dev Mint fUSD by sending ETH
     * Rate limited to configurable cooldown per account
     */
    function mint() external payable whenNotPaused whenMintingEnabled onlyHealthyOracle nonReentrant {
        require(msg.value > 0, "Must send ETH");
        require(block.timestamp >= lastActionTime[msg.sender] + actionCooldown, "Cooldown active");
        require(msg.value >= minEth, "ETH amount too small");

        uint256 ethPrice = ORACLE.getEthUsd(); // Returns price in 6 decimals
        require(ethPrice > 0, "Invalid oracle price");

        // Validate price hasn't moved too much
        _validatePrice(ethPrice);

        // ETH has 18 decimals, fUSD has 6 decimals, price has 6 decimals
        // fusdAmount = ethAmount * price / 1e18
        uint256 fusdAmount = (msg.value * ethPrice) / 1e18;

        require(fusdAmount >= minMint, "Mint amount too small");

        lastActionTime[msg.sender] = block.timestamp;
        _updatePrice(ethPrice);
        IUSD(address(FUSD)).mint(msg.sender, fusdAmount);

        emit Mint(msg.sender, msg.value, fusdAmount, ethPrice);
    }

    /**
     * @dev Burn fUSD to receive ETH
     * Rate limited to configurable cooldown per account
     * @param fusdAmount Amount of fUSD to burn
     */
    function burn(uint256 fusdAmount) external whenNotPaused whenBurningEnabled onlyHealthyOracle nonReentrant {
        require(fusdAmount > 0, "Amount must be greater than 0");
        require(block.timestamp >= lastActionTime[msg.sender] + actionCooldown, "Cooldown active");
        require(fusdAmount >= minMint, "Burn amount too small");

        uint256 ethPrice = ORACLE.getEthUsd();
        require(ethPrice > 0, "Invalid oracle price");

        // Validate price hasn't moved too much
        _validatePrice(ethPrice);

        // ethAmount = fusdAmount * 1e18 / price
        uint256 ethAmount = (fusdAmount * 1e18) / ethPrice;

        require(ethAmount > 0, "Amount too small");
        require(ethAmount <= address(this).balance, "Insufficient ETH reserves");

        lastActionTime[msg.sender] = block.timestamp;
        _updatePrice(ethPrice);
        require(FUSD.transferFrom(msg.sender, address(this), fusdAmount), "FUSD transfer failed");
        IUSD(address(FUSD)).burnFrom(address(this), fusdAmount);

        (bool success,) = msg.sender.call{value: ethAmount}("");
        require(success, "ETH transfer failed");

        emit Burn(msg.sender, fusdAmount, ethAmount, ethPrice);
    }

    /**
     * @dev Get quote for minting fUSD with ETH
     * @param ethAmount Amount of ETH to mint with
     * @return fusdAmount Amount of fUSD that would be minted
     */
    function getMintQuote(uint256 ethAmount) external view onlyHealthyOracle returns (uint256) {
        require(ethAmount >= minEth, "ETH amount too small");

        uint256 ethPrice = ORACLE.getEthUsd();
        require(ethPrice > 0, "Invalid oracle price");

        return (ethAmount * ethPrice) / 1e18;
    }

    /**
     * @dev Get enhanced quote for minting fUSD with ETH (includes price and timestamp)
     * @param ethAmount Amount of ETH to mint with
     * @return _fusdAmount Amount of fUSD that would be minted
     * @return _ethPrice Current ETH price
     * @return _timestamp Quote timestamp
     */
    function getMintQuoteDetailed(uint256 ethAmount)
        external
        view
        onlyHealthyOracle
        returns (uint256 _fusdAmount, uint256 _ethPrice, uint256 _timestamp)
    {
        require(ethAmount >= minEth, "ETH amount too small");

        uint256 ethPrice = ORACLE.getEthUsd();
        require(ethPrice > 0, "Invalid oracle price");

        _fusdAmount = (ethAmount * ethPrice) / 1e18;
        _ethPrice = ethPrice;
        _timestamp = block.timestamp;
    }

    /**
     * @dev Get quote for burning fUSD to receive ETH
     * @param fusdAmount Amount of fUSD to burn
     * @return ethAmount Amount of ETH that would be received
     */
    function getBurnQuote(uint256 fusdAmount) external view onlyHealthyOracle returns (uint256) {
        require(fusdAmount >= minMint, "Burn amount too small");

        uint256 ethPrice = ORACLE.getEthUsd();
        require(ethPrice > 0, "Invalid oracle price");

        return (fusdAmount * 1e18) / ethPrice;
    }

    /**
     * @dev Get enhanced quote for burning fUSD to receive ETH (includes price and timestamp)
     * @param fusdAmount Amount of fUSD to burn
     * @return _ethAmount Amount of ETH that would be received
     * @return _ethPrice Current ETH price
     * @return _timestamp Quote timestamp
     */
    function getBurnQuoteDetailed(uint256 fusdAmount)
        external
        view
        onlyHealthyOracle
        returns (uint256 _ethAmount, uint256 _ethPrice, uint256 _timestamp)
    {
        require(fusdAmount >= minMint, "Burn amount too small");

        uint256 ethPrice = ORACLE.getEthUsd();
        require(ethPrice > 0, "Invalid oracle price");

        _ethAmount = (fusdAmount * 1e18) / ethPrice;
        _ethPrice = ethPrice;
        _timestamp = block.timestamp;
    }

    /**
     * @dev Get current ETH/USD price from oracle
     * @return Current ETH price in 6 decimals
     */
    function getEthUsd() external view returns (uint256) {
        return ORACLE.getEthUsd();
    }

    /**
     * @dev Check if oracle is healthy
     * @return True if oracle is functioning normally
     */
    function isOracleHealthy() external view returns (bool) {
        return ORACLE.isHealthy();
    }

    /**
     * @dev Get reserve ratio (ETH balance / fUSD total supply)
     * @return Reserve ratio with 18 decimals
     */
    function getReserveRatio() external view returns (uint256) {
        uint256 totalSupply = FUSD.totalSupply();
        if (totalSupply == 0) return 0;
        return (address(this).balance * 1e18) / totalSupply;
    }

    /**
     * @dev Check if contract has sufficient reserves for a burn operation
     * @param fusdAmount Amount of fUSD to check reserves for
     * @return True if sufficient reserves exist
     */
    function hasSufficientReserves(uint256 fusdAmount) external view returns (bool) {
        uint256 ethPrice = ORACLE.getEthUsd();
        if (ethPrice == 0) return false;
        uint256 requiredEth = (fusdAmount * 1e18) / ethPrice;
        return address(this).balance >= requiredEth;
    }

    /**
     * @dev Get price tracking information
     * @return _lastPrice Last recorded price
     * @return _lastUpdate Timestamp of last price update
     * @return _updateCount Total number of price updates
     */
    function getPriceInfo() external view returns (uint256 _lastPrice, uint256 _lastUpdate, uint256 _updateCount) {
        return (lastPrice, lastPriceUpdate, priceUpdateCount);
    }

    /**
     * @dev Pause all operations (only admin can call)
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @dev Unpause all operations (only admin can call)
     */
    function unpause() external onlyAdmin {
        _unpause();
    }

    /**
     * @dev Pause minting operations only
     */
    function pauseMinting() external onlyAdmin {
        mintingPaused = true;
        emit MintingPaused(msg.sender);
    }

    /**
     * @dev Resume minting operations
     */
    function resumeMinting() external onlyAdmin {
        mintingPaused = false;
        emit MintingResumed(msg.sender);
    }

    /**
     * @dev Pause burning operations only
     */
    function pauseBurning() external onlyAdmin {
        burningPaused = true;
        emit BurningPaused(msg.sender);
    }

    /**
     * @dev Resume burning operations
     */
    function resumeBurning() external onlyAdmin {
        burningPaused = false;
        emit BurningResumed(msg.sender);
    }

    /**
     * @dev Update configuration parameters
     * @param _cooldown New cooldown period
     * @param _minMint New minimum mint amount
     * @param _minEth New minimum ETH amount
     */
    function setConfig(uint256 _cooldown, uint256 _minMint, uint256 _minEth) external onlyAdmin {
        require(_cooldown > 0, "Cooldown must be positive");
        require(_minMint > 0, "Min mint must be positive");
        require(_minEth > 0, "Min ETH must be positive");

        actionCooldown = _cooldown;
        minMint = _minMint;
        minEth = _minEth;

        emit ConfigUpdated(_cooldown, _minMint, _minEth);
    }

    /**
     * @dev Set maximum allowed price movement
     * @param _maxMove Maximum price movement as fraction of 1e18 (e.g., 5e16 = 5%)
     */
    function setMaxPriceMove(uint256 _maxMove) external onlyAdmin {
        require(_maxMove <= 1e18, "Move too large"); // Max 100%
        uint256 oldMove = maxPriceMove;
        maxPriceMove = _maxMove;
        emit MaxPriceMoveUpdated(oldMove, _maxMove);
    }

    /**
     * @dev Emergency function to withdraw ETH (only emergency role can call)
     * @param amount Amount of ETH to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyEmergency {
        require(amount <= address(this).balance, "Insufficient balance");

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit EmergencyAction(msg.sender, "ETH_WITHDRAW", amount);
    }

    /**
     * @dev Emergency function to withdraw fUSD (only emergency role can call)
     * @param amount Amount of fUSD to withdraw
     */
    function emergencyWithdrawFusd(uint256 amount) external onlyEmergency {
        uint256 balance = FUSD.balanceOf(address(this));
        require(amount <= balance, "Insufficient fUSD balance");

        require(FUSD.transfer(msg.sender, amount), "FUSD transfer failed");

        emit EmergencyAction(msg.sender, "FUSD_WITHDRAW", amount);
    }

    /**
     * @dev Get contract ETH balance
     * @return Current ETH balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get contract fUSD balance
     * @return Current fUSD balance
     */
    function getFusdBalance() external view returns (uint256) {
        return FUSD.balanceOf(address(this));
    }

    /**
     * @dev Check if user can perform action (rate limiting)
     * @param user Address to check
     * @return True if user can perform action
     */
    function canPerformAction(address user) external view returns (bool) {
        return block.timestamp >= lastActionTime[user] + actionCooldown;
    }

    /**
     * @dev Get time until user can perform next action
     * @param user Address to check
     * @return Seconds until next action is allowed
     */
    function getTimeUntilNextAction(address user) external view returns (uint256) {
        uint256 nextActionTime = lastActionTime[user] + actionCooldown;
        if (block.timestamp >= nextActionTime) {
            return 0;
        }
        return nextActionTime - block.timestamp;
    }

    /**
     * @dev Get current configuration
     * @return _cooldown Current action cooldown
     * @return _minMint Current minimum mint amount
     * @return _minEth Current minimum ETH amount
     * @return _maxPriceMove Current maximum price movement
     */
    function getConfig()
        external
        view
        returns (uint256 _cooldown, uint256 _minMint, uint256 _minEth, uint256 _maxPriceMove)
    {
        return (actionCooldown, minMint, minEth, maxPriceMove);
    }

    // Allow contract to receive ETH
    receive() external payable {}

    /**
     * @dev Grant admin role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant admin role to
     */
    function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "DeskController: zero address");
        _grantRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Revoke admin role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke admin role from
     */
    function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "DeskController: zero address");
        _revokeRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Grant emergency role to an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to grant emergency role to
     */
    function grantEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "DeskController: zero address");
        _grantRole(EMERGENCY_ROLE, account);
    }

    /**
     * @dev Revoke emergency role from an address (only DEFAULT_ADMIN_ROLE can call)
     * @param account Address to revoke emergency role from
     */
    function revokeEmergencyRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "DeskController: zero address");
        _revokeRole(EMERGENCY_ROLE, account);
    }

    /**
     * @dev Check if an address has admin role
     * @param account Address to check
     * @return True if address has admin role
     */
    function hasAdminRole(address account) external view returns (bool) {
        return hasRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Check if an address has emergency role
     * @param account Address to check
     * @return True if address has emergency role
     */
    function hasEmergencyRole(address account) external view returns (bool) {
        return hasRole(EMERGENCY_ROLE, account);
    }
}
