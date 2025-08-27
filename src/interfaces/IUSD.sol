// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IUSD
 * @dev Interface for the fUSD token contract
 */
interface IUSD {
    /**
     * @dev Mint new tokens
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @dev Burn tokens from an account
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) external;
}
