// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BandsMath
/// @notice Core mathematical library for the Lending-Liquidating AMM (LLAMMA) continuous bands
library BandsMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;

    error BandIndexOutOfBounds();
    error ZeroAmplification();
    error InsufficientBandLiquidity();
    error InvalidBandLimits();
    error Overflow();

    /// @notice Computes (A-1)/A ratio in WAD
    function getBandRatio(uint256 A) internal pure returns (uint256) {
        if (A <= 1) revert ZeroAmplification();
        return ((A - 1) * WAD) / A;
    }

    /// @notice Computes p(n) = pBase * ((A-1)/A)^n in WAD
    /// @param pBase Base price at index 0 (in WAD, e.g. 3000e18)
    /// @param A Amplification factor (e.g. 50)
    /// @param n Band index (positive means lower price, negative means higher price)
    function getBandPrice(uint256 pBase, uint256 A, int256 n) internal pure returns (uint256) {
        if (n < -500 || n > 500) revert BandIndexOutOfBounds();
        if (n == 0) return pBase;

        uint256 ratio = getBandRatio(A);
        if (n > 0) {
            uint256 p = pBase;
            uint256 count = uint256(n);
            for (uint256 i = 0; i < count; ++i) {
                p = (p * ratio) / WAD;
            }
            return p;
        } else {
            uint256 p = pBase;
            uint256 count = uint256(-n);
            for (uint256 i = 0; i < count; ++i) {
                p = (p * WAD) / ratio;
            }
            return p;
        }
    }

    /// @notice Returns [pLow, pHigh] for band n
    /// @dev pHigh = p(n), pLow = p(n+1)
    function getBandLimits(uint256 pBase, uint256 A, int256 n) internal pure returns (uint256 pLow, uint256 pHigh) {
        pHigh = getBandPrice(pBase, A, n);
        pLow = (pHigh * getBandRatio(A)) / WAD;
        if (pLow >= pHigh || pLow == 0) revert InvalidBandLimits();
    }

    /// @notice Computes constant-product invariant constants for a band initialized with collateral c
    /// @param c Initial collateral deposited into band (in WAD)
    /// @param pLow Lower band price (in WAD)
    /// @param pHigh Upper band price (in WAD)
    /// @param A Amplification factor
    /// @return x0 X-offset in collateral (in WAD)
    /// @return y0 Y-offset in debt token (in WAD)
    /// @return K Transformed constant-product invariant (x + x0)*(y + y0) = K
    function computeInvariantConstants(
        uint256 c,
        uint256 pLow,
        uint256 pHigh,
        uint256 A
    )
        internal
        pure
        returns (uint256 x0, uint256 y0, uint256 K)
    {
        pHigh; // Silence unused variable warning
        if (c == 0) return (0, 0, 0);
        x0 = c * (A - 1);

        // y0 = (c * pLow * (A - 1)) / WAD
        // Dimensional: ETH * (USD / ETH) = USD
        y0 = (c * pLow) / WAD;
        y0 = y0 * (A - 1);

        // K = (c + x0) * y0 = (c * A) * y0
        K = (c * A) * y0;
    }

    /// @notice Computes max debt yMax attainable when 100% of collateral c is converted at pLow
    function computeMaxDebt(uint256 c, uint256 pLow) internal pure returns (uint256) {
        return (c * pLow) / WAD;
    }

    /// @notice Calculates quote for swapping collateral X for debt Y within a single band
    function quoteSwapXForY(
        uint256 dx,
        uint256 currentX,
        uint256 currentY,
        uint256 x0,
        uint256 y0,
        uint256 K,
        uint256 feeBps
    )
        internal
        pure
        returns (uint256 dyNet, uint256 newX, uint256 newY)
    {
        if (K == 0) revert InsufficientBandLiquidity();
        newX = currentX + dx;
        uint256 denominator = newX + x0;
        if (denominator == 0) revert InsufficientBandLiquidity();

        uint256 newYPlusY0 = K / denominator;
        if (newYPlusY0 < y0) {
            newY = 0;
        } else {
            newY = newYPlusY0 - y0;
        }

        if (newY >= currentY) {
            return (0, currentX, currentY);
        }

        uint256 dyGross = currentY - newY;
        dyNet = (dyGross * (BPS - feeBps)) / BPS;
    }

    /// @notice Calculates quote for swapping debt Y for collateral X within a single band
    function quoteSwapYForX(
        uint256 dy,
        uint256 currentX,
        uint256 currentY,
        uint256 x0,
        uint256 y0,
        uint256 K,
        uint256 feeBps
    )
        internal
        pure
        returns (uint256 dxNet, uint256 newX, uint256 newY)
    {
        if (K == 0) revert InsufficientBandLiquidity();
        newY = currentY + dy;
        uint256 denominator = newY + y0;
        if (denominator == 0) revert InsufficientBandLiquidity();

        uint256 newXPlusX0 = K / denominator;
        if (newXPlusX0 < x0) {
            newX = 0;
        } else {
            newX = newXPlusX0 - x0;
        }

        if (newX >= currentX) {
            return (0, currentX, currentY);
        }

        uint256 dxGross = currentX - newX;
        dxNet = (dxGross * (BPS - feeBps)) / BPS;
    }

    /// @notice Computes total valuation of (xAmount collateral + yAmount debt) at oraclePrice
    /// @return totalValueWad Total portfolio value in USD (WAD)
    function valueInDebt(
        uint256 xAmount,
        uint256 yAmount,
        uint256 oraclePrice
    )
        internal
        pure
        returns (uint256 totalValueWad)
    {
        uint256 xValue = (xAmount * oraclePrice) / WAD;
        totalValueWad = xValue + yAmount;
    }
}
