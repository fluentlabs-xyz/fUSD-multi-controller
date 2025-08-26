// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOracle
 * @dev Interface for price oracles
 */
interface IOracle {
    function getEthUsd() external view returns (uint256);
    function isHealthy() external view returns (bool);
}
