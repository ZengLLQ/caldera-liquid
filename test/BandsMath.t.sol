// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { BandsMath } from "../src/libraries/BandsMath.sol";

contract BandsMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant P_BASE = 3000 * 1e18; // $3,000 base price
    uint256 constant A = 50; // Amplification

    function setUp() public { }

    function test_BandRatio() public pure {
        // For A = 50, ratio is 49/50 = 0.98 in WAD = 0.98e18
        uint256 ratio = BandsMath.getBandRatio(50);
        assertEq(ratio, 980_000_000_000_000_000);
    }

    function test_BandPriceMonotonicity() public pure {
        // As band index n increases, price must decrease strictly
        uint256 p0 = BandsMath.getBandPrice(P_BASE, A, 0);
        uint256 p1 = BandsMath.getBandPrice(P_BASE, A, 1);
        uint256 p2 = BandsMath.getBandPrice(P_BASE, A, 2);
        uint256 pMinus1 = BandsMath.getBandPrice(P_BASE, A, -1);

        assertEq(p0, P_BASE);
        assertTrue(pMinus1 > p0);
        assertTrue(p0 > p1);
        assertTrue(p1 > p2);
    }

    function test_BandLimits() public pure {
        (uint256 pLow, uint256 pHigh) = BandsMath.getBandLimits(P_BASE, A, 0);
        assertEq(pHigh, P_BASE);
        assertEq(pLow, (P_BASE * 49) / 50);
        assertTrue(pHigh > pLow);
    }

    function test_InvariantConstants() public pure {
        uint256 collateral = 10 * WAD; // 10 ETH
        (uint256 pLow, uint256 pHigh) = BandsMath.getBandLimits(P_BASE, A, 0);

        (uint256 x0, uint256 y0, uint256 K) = BandsMath.computeInvariantConstants(collateral, pLow, pHigh, A);

        assertTrue(x0 > 0);
        assertTrue(y0 > 0);
        assertTrue(K > 0);

        // x0 = collateral * (A - 1) = 10 * 49 = 490 WAD
        assertEq(x0, 10 * 49 * WAD);

        // Check invariant identity: (c + x0) * y0 == K
        assertEq((collateral + x0) * y0, K);
    }

    function test_ComputeMaxDebt() public pure {
        uint256 collateral = 10 * WAD; // 10 ETH
        (uint256 pLow,) = BandsMath.getBandLimits(P_BASE, A, 0);

        uint256 yMax = BandsMath.computeMaxDebt(collateral, pLow);
        assertTrue(yMax > 28_000 * WAD && yMax < 30_000 * WAD);
    }

    function test_SwapQuotesAndConservation() public pure {
        uint256 collateral = 10 * WAD;
        (uint256 pLow, uint256 pHigh) = BandsMath.getBandLimits(P_BASE, A, 0);
        (uint256 x0, uint256 y0, uint256 K) = BandsMath.computeInvariantConstants(collateral, pLow, pHigh, A);

        // Calculate exact point on the curve at 5 ETH collateral
        uint256 curX = 5 * WAD;
        uint256 curY = (K / (curX + x0)) - y0;

        // Quote swapping 1 ETH for debt Y
        (uint256 dyNet, uint256 newX, uint256 newY) =
            BandsMath.quoteSwapXForY(
                1 * WAD,
                curX,
                curY,
                x0,
                y0,
                K,
                20 // 20 bps fee
            );

        assertTrue(dyNet > 0);
        assertEq(newX, curX + 1 * WAD);

        // Quote swapping debt back for collateral X
        (uint256 dxNet,,) = BandsMath.quoteSwapYForX(dyNet, newX, newY, x0, y0, K, 20);

        // Roundtrip loss should be bounded strictly by swap fees (2 * 20 bps = ~0.4%)
        assertTrue(dxNet <= 1 * WAD);
        assertTrue(dxNet > 990 * 1e15); // > 0.99 ETH returned
    }

    function testFuzz_BandPriceStrictlyDecreasing(int16 n) public pure {
        vm.assume(n >= -50 && n <= 50);
        int256 band = int256(n);
        uint256 pCurrent = BandsMath.getBandPrice(P_BASE, A, band);
        uint256 pNext = BandsMath.getBandPrice(P_BASE, A, band + 1);

        assertTrue(pCurrent > pNext);
    }

    function testFuzz_ValuationMonotonicity(uint96 colAmount, uint96 debtAmount, uint96 price) public pure {
        vm.assume(price > 1e18 && price < 100_000e18);
        vm.assume(colAmount > 1e16 && colAmount < 1_000_000e18);
        vm.assume(debtAmount < 1_000_000e18);

        uint256 v1 = BandsMath.valueInDebt(colAmount, debtAmount, price);
        uint256 v2 = BandsMath.valueInDebt(colAmount + 1e18, debtAmount, price);

        assertTrue(v2 > v1);
    }
}
