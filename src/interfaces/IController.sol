// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IController
 * @dev Interface for fUSD controllers that can mint and burn tokens
 */
interface IController {
    /**
     * @dev Emitted when tokens are minted
     */
    event Mint(address indexed user, uint256 ethIn, uint256 fusdOut, uint256 ethPrice);
    
    /**
     * @dev Emitted when tokens are burned
     */
    event Burn(address indexed user, uint256 fusdIn, uint256 ethOut, uint256 ethPrice);
    
    /**
     * @dev Get the current ETH/USD price from the oracle
     */
    function getETHUSD() external view returns (uint256);
    
    /**
     * @dev Get a quote for minting fUSD with ETH
     * @param ethAmount Amount of ETH to mint with
     * @return fusdAmount Amount of fUSD that would be minted
     */
    function getMintQuote(uint256 ethAmount) external view returns (uint256);
    
    /**
     * @dev Get a quote for burning fUSD to receive ETH
     * @param fusdAmount Amount of fUSD to burn
     * @return ethAmount Amount of ETH that would be received
     */
    function getBurnQuote(uint256 fusdAmount) external view returns (uint256);
    
    /**
     * @dev Get enhanced quote for minting fUSD with ETH (includes price and timestamp)
     * @param ethAmount Amount of ETH to mint with
     * @return fusdAmount Amount of fUSD that would be minted
     * @return ethPrice Current ETH price
     * @return timestamp Quote timestamp
     */
    function getMintQuoteDetailed(uint256 ethAmount) external view returns (
        uint256 fusdAmount,
        uint256 ethPrice,
        uint256 timestamp
    );
    
    /**
     * @dev Get enhanced quote for burning fUSD to receive ETH (includes price and timestamp)
     * @param fusdAmount Amount of fUSD to burn
     * @return ethAmount Amount of ETH that would be received
     * @return ethPrice Current ETH price
     * @return timestamp Quote timestamp
     */
    function getBurnQuoteDetailed(uint256 fusdAmount) external view returns (
        uint256 ethAmount,
        uint256 ethPrice,
        uint256 timestamp
    );
}
