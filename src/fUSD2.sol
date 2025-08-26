// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

contract fUSD2 is ERC20, Ownable, Pausable {
    // Address that can mint/burn tokens (MintBurnWindow contract)
    address public minter;
    
    event MinterSet(address indexed oldMinter, address indexed newMinter);
    
    modifier onlyMinter() {
        require(msg.sender == minter, "fUSD: caller is not the minter");
        _;
    }
    
    constructor() ERC20("fluentUSD", "fUSD") Ownable(msg.sender) {
    }
    
    /**
     * @dev Override decimals to use 6 decimals like USDC
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    /**
     * @dev Set the minter address (only owner can call)
     */
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "fUSD: minter cannot be zero address");
        address oldMinter = minter;
        minter = _minter;
        emit MinterSet(oldMinter, _minter);
    }
    
    /**
     * @dev Mint new tokens (only minter can call)
     */
    function mint(address to, uint256 amount) external onlyMinter whenNotPaused {
        require(to != address(0), "fUSD: cannot mint to zero address");
        _mint(to, amount);
    }
    
    /**
     * @dev Burn tokens from an account (only minter can call)
     */
    function burnFrom(address from, uint256 amount) external onlyMinter whenNotPaused {
        require(from != address(0), "fUSD: cannot burn from zero address");
        _burn(from, amount);
    }
    
    /**
     * @dev Pause all minting/burning operations (only owner can call)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause all minting/burning operations (only owner can call)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}