// ERC20 with 6 decimals (USDC-style)
// Minimal token that delegates minting/burning to authorized controllers
contract fUSD is ERC20, AccessControl {
    uint8 public constant decimals = 6;
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    
    // Controllers can mint/burn
    function mint(address to, uint256 amount) external onlyRole(CONTROLLER_ROLE);
    function burn(address from, uint256 amount) external onlyRole(CONTROLLER_ROLE);
}