// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { CalderaOracle } from "../src/CalderaOracle.sol";

contract CalderaOracleTest is Test {
    CalderaOracle oracle;
    uint256 constant INITIAL_PRICE = 3000 * 1e18; // $3000

    function setUp() public {
        oracle = new CalderaOracle(INITIAL_PRICE);
    }

    function test_InitialPrice() public view {
        assertEq(oracle.getPrice(), INITIAL_PRICE);
        assertEq(oracle.getSpotPrice(), INITIAL_PRICE);
        assertEq(oracle.lastUpdate(), block.timestamp);
    }

    function test_EmaPriceUpdateWithinBounds() public {
        // Update spot price to $3030 (1% increase, within 2.5% max deviation)
        uint256 newSpot = 3030 * 1e18;
        oracle.updatePrice(newSpot);

        // Expected EMA = (2500 * 3030 + 7500 * 3000) / 10000 = (7,575,000 + 22,500,000) / 10000 = 3007.5
        uint256 expectedEma = (2500 * newSpot + 7500 * INITIAL_PRICE) / 10_000;
        assertEq(oracle.getPrice(), expectedEma);
        assertEq(oracle.getSpotPrice(), newSpot);
    }

    function test_CircuitBreakerOnMassiveSpike() public {
        // Attempt 20% spike to $3600 (exceeds 2.5% MAX_DEVIATION_BPS)
        uint256 massiveSpike = 3600 * 1e18;
        oracle.updatePrice(massiveSpike);

        // Bounded spot should be capped at 3000 + 2.5% = 3075
        uint256 maxShift = (INITIAL_PRICE * 250) / 10_000;
        uint256 boundedSpot = INITIAL_PRICE + maxShift;
        uint256 expectedEma = (2500 * boundedSpot + 7500 * INITIAL_PRICE) / 10_000;

        assertEq(oracle.getPrice(), expectedEma);
        assertEq(oracle.getSpotPrice(), massiveSpike);
        assertTrue(oracle.getPrice() < 3050 * 1e18);
    }

    function test_UnauthorizedUpdateReverts() public {
        vm.prank(address(0xbad));
        vm.expectRevert(CalderaOracle.Unauthorized.selector);
        oracle.updatePrice(3100 * 1e18);
    }
}
