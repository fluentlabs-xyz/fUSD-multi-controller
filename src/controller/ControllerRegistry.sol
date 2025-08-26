// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title ControllerRegistry
 * @dev Registry to manage multiple controllers and admin addresses
 * Provides centralized management of fUSD minting/burning controllers
 */
contract ControllerRegistry is AccessControl {
    // Support multiple admins
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // Track active controllers with metadata
    struct ControllerInfo {
        bool active;
        string name;
        uint256 dailyLimit;
        uint256 totalMinted;
        uint256 lastResetTime;
        uint256 dailyMinted;
    }
    
    mapping(address => ControllerInfo) public controllers;
    address[] public controllerList;
    
    // Global safety limits
    uint256 public globalDailyLimit = 10_000_000 * 1e6; // 10M fUSD
    uint256 public globalTotalMinted = 0;
    
    // Events
    event ControllerAdded(address indexed controller, string name, uint256 dailyLimit);
    event ControllerRemoved(address indexed controller);
    event ControllerUpdated(address indexed controller, string name, uint256 dailyLimit);
    event GlobalLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event DailyLimitReset(address indexed controller, uint256 oldAmount, uint256 newAmount);
    
    /**
     * @dev Constructor
     * @param initialAdmin Initial admin address
     */
    constructor(address initialAdmin) {
        require(initialAdmin != address(0), "Registry: zero address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
    }
    
    /**
     * @dev Add a new controller
     * @param controller Address of the controller contract
     * @param name Human-readable name for the controller
     * @param limit Daily minting limit in fUSD (6 decimals)
     */
    function addController(
        address controller, 
        string memory name, 
        uint256 limit
    ) external onlyRole(ADMIN_ROLE) {
        require(controller != address(0), "Registry: zero address");
        require(bytes(name).length > 0, "Registry: empty name");
        require(limit > 0, "Registry: zero limit");
        require(!controllers[controller].active, "Registry: controller exists");
        
        controllers[controller] = ControllerInfo({
            active: true,
            name: name,
            dailyLimit: limit,
            totalMinted: 0,
            lastResetTime: block.timestamp,
            dailyMinted: 0
        });
        
        controllerList.push(controller);
        
        emit ControllerAdded(controller, name, limit);
    }
    
    /**
     * @dev Remove a controller
     * @param controller Address of the controller to remove
     */
    function removeController(address controller) external onlyRole(ADMIN_ROLE) {
        require(controllers[controller].active, "Registry: controller not found");
        
        // Remove from active controllers
        controllers[controller].active = false;
        
        // Remove from controller list
        for (uint i = 0; i < controllerList.length; i++) {
            if (controllerList[i] == controller) {
                controllerList[i] = controllerList[controllerList.length - 1];
                controllerList.pop();
                break;
            }
        }
        
        emit ControllerRemoved(controller);
    }
    
    /**
     * @dev Update controller information
     * @param controller Address of the controller to update
     * @param name New name for the controller
     * @param limit New daily limit
     */
    function updateController(
        address controller,
        string memory name,
        uint256 limit
    ) external onlyRole(ADMIN_ROLE) {
        require(controllers[controller].active, "Registry: controller not found");
        require(bytes(name).length > 0, "Registry: empty name");
        require(limit > 0, "Registry: zero limit");
        
        string memory oldName = controllers[controller].name;
        uint256 oldLimit = controllers[controller].dailyLimit;
        
        controllers[controller].name = name;
        controllers[controller].dailyLimit = limit;
        
        emit ControllerUpdated(controller, name, limit);
    }
    
    /**
     * @dev Update global daily limit
     * @param newLimit New global daily limit
     */
    function setGlobalDailyLimit(uint256 newLimit) external onlyRole(ADMIN_ROLE) {
        require(newLimit > 0, "Registry: zero limit");
        
        uint256 oldLimit = globalDailyLimit;
        globalDailyLimit = newLimit;
        
        emit GlobalLimitUpdated(oldLimit, newLimit);
    }
    
    /**
     * @dev Record minting activity from a controller
     * @param controller Address of the controller
     * @param amount Amount minted
     */
    function recordMint(address controller, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(controllers[controller].active, "Registry: controller not found");
        
        // Reset daily counter if 24 hours have passed
        if (block.timestamp >= controllers[controller].lastResetTime + 1 days) {
            controllers[controller].dailyMinted = 0;
            controllers[controller].lastResetTime = block.timestamp;
        }
        
        // Check daily limit
        require(
            controllers[controller].dailyMinted + amount <= controllers[controller].dailyLimit,
            "Registry: daily limit exceeded"
        );
        
        // Check global daily limit
        require(
            getGlobalDailyMinted() + amount <= globalDailyLimit,
            "Registry: global daily limit exceeded"
        );
        
        // Update counters
        controllers[controller].dailyMinted += amount;
        controllers[controller].totalMinted += amount;
        globalTotalMinted += amount;
    }
    
    /**
     * @dev Get global daily minted amount
     * @return Total amount minted today across all controllers
     */
    function getGlobalDailyMinted() public view returns (uint256) {
        uint256 total = 0;
        uint256 currentTime = block.timestamp;
        
        for (uint i = 0; i < controllerList.length; i++) {
            address controller = controllerList[i];
            if (controllers[controller].active) {
                // Only count if within last 24 hours
                if (currentTime < controllers[controller].lastResetTime + 1 days) {
                    total += controllers[controller].dailyMinted;
                }
            }
        }
        
        return total;
    }
    
    /**
     * @dev Get all active controllers
     * @return Array of active controller addresses
     */
    function getActiveControllers() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active controllers
        for (uint i = 0; i < controllerList.length; i++) {
            if (controllers[controllerList[i]].active) {
                activeCount++;
            }
        }
        
        // Create array with active controllers
        address[] memory activeControllers = new address[](activeCount);
        uint256 index = 0;
        
        for (uint i = 0; i < controllerList.length; i++) {
            if (controllers[controllerList[i]].active) {
                activeControllers[index] = controllerList[i];
                index++;
            }
        }
        
        return activeControllers;
    }
    
    /**
     * @dev Get controller count
     * @return Total number of controllers (active + inactive)
     */
    function getControllerCount() external view returns (uint256) {
        return controllerList.length;
    }
    
    /**
     * @dev Check if controller is active
     * @param controller Address to check
     * @return True if controller is active
     */
    function isControllerActive(address controller) external view returns (bool) {
        return controllers[controller].active;
    }
    
    /**
     * @dev Get remaining daily limit for a controller
     * @param controller Address of the controller
     * @return Remaining amount that can be minted today
     */
    function getRemainingDailyLimit(address controller) external view returns (uint256) {
        if (!controllers[controller].active) {
            return 0;
        }
        
        // Reset daily counter if 24 hours have passed
        if (block.timestamp >= controllers[controller].lastResetTime + 1 days) {
            return controllers[controller].dailyLimit;
        }
        
        return controllers[controller].dailyLimit - controllers[controller].dailyMinted;
    }
    
    /**
     * @dev Get remaining global daily limit
     * @return Remaining global amount that can be minted today
     */
    function getRemainingGlobalDailyLimit() external view returns (uint256) {
        uint256 dailyMinted = getGlobalDailyMinted();
        return dailyMinted >= globalDailyLimit ? 0 : globalDailyLimit - dailyMinted;
    }
}