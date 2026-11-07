// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ICalderaOracle } from "./interfaces/ICalderaOracle.sol";

/// @title CalderaOracle
/// @notice Resilient price oracle with Exponential Moving Average (EMA) and 250 bps circuit breakers
contract CalderaOracle is ICalderaOracle {
    uint256 public constant BPS = 10_000;
    uint256 public constant ALPHA_BPS = 2500; // 25% weight to newest spot price
    uint256 public constant MAX_DEVIATION_BPS = 250; // 2.5% max single-update shift

    address public immutable owner;
    uint256 public override getSpotPrice;
    uint256 public override getPrice; // EMA price
    uint256 public override lastUpdate;

    error Unauthorized();
    error InvalidPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint256 initialPrice) {
        if (initialPrice == 0) revert InvalidPrice();
        owner = msg.sender;
        getSpotPrice = initialPrice;
        getPrice = initialPrice;
        lastUpdate = block.timestamp;

        emit PriceUpdated(initialPrice, initialPrice, block.timestamp);
    }

    /// @notice Updates oracle price with EMA smoothing and deviation bound
    /// @param newSpotPrice New reported spot price (in 18-decimal WAD)
    function updatePrice(uint256 newSpotPrice) external override onlyOwner {
        if (newSpotPrice == 0) revert InvalidPrice();

        uint256 previousEma = getPrice;
        uint256 boundedSpot = newSpotPrice;

        // Circuit breaker: limit spot price swing to MAX_DEVIATION_BPS relative to current EMA
        uint256 maxShift = (previousEma * MAX_DEVIATION_BPS) / BPS;
        if (newSpotPrice > previousEma + maxShift) {
            boundedSpot = previousEma + maxShift;
            emit CircuitBreakerTriggered(newSpotPrice, previousEma, MAX_DEVIATION_BPS);
        } else if (previousEma > maxShift && newSpotPrice < previousEma - maxShift) {
            boundedSpot = previousEma - maxShift;
            emit CircuitBreakerTriggered(newSpotPrice, previousEma, MAX_DEVIATION_BPS);
        }

        // EMA computation: EMA_new = (ALPHA * spot + (10000 - ALPHA) * EMA_prev) / 10000
        uint256 newEma = (ALPHA_BPS * boundedSpot + (BPS - ALPHA_BPS) * previousEma) / BPS;

        getSpotPrice = newSpotPrice;
        getPrice = newEma;
        lastUpdate = block.timestamp;

        emit PriceUpdated(newSpotPrice, newEma, block.timestamp);
    }
}
