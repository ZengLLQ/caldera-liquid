// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICalderaOracle
/// @notice Interface for the EMA-smoothed resilient price oracle
interface ICalderaOracle {
    event PriceUpdated(uint256 spotPrice, uint256 emaPrice, uint256 timestamp);
    event CircuitBreakerTriggered(uint256 spotPrice, uint256 emaPrice, uint256 deviationBps);

    function getPrice() external view returns (uint256);
    function getSpotPrice() external view returns (uint256);
    function updatePrice(uint256 newSpotPrice) external;
    function lastUpdate() external view returns (uint256);
}
