// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

// ERC20 with 6 decimals (USDC-style)
// Minimal token that delegates minting/burning to authorized controllers
contract fUSD is ERC20, AccessControl {
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    
    constructor() ERC20("Fluent USD", "fUSD") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTROLLER_ROLE, msg.sender);
    }
    
    // Controllers can mint/burn
    function mint(address to, uint256 amount) external onlyRole(CONTROLLER_ROLE) {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyRole(CONTROLLER_ROLE) {
        _burn(from, amount);
    }
    
    // Override decimals to return 6 instead of 18
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}