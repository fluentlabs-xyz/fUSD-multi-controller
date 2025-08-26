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