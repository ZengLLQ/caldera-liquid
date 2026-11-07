// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICalderaPool
/// @notice Interface for the Lending-Liquidating AMM (LLAMMA) multi-band continuous pool
interface ICalderaPool {
    struct BandInfo {
        uint256 collateral; // X token balance in band
        uint256 debt; // Y token balance in band
        uint256 totalShares;
        uint256 pLow;
        uint256 pHigh;
    }

    event BandDeposit(address indexed user, int256 indexed bandIndex, uint256 collateralAmount, uint256 sharesIssued);
    event BandWithdraw(address indexed user, int256 indexed bandIndex, uint256 collateralOut, uint256 debtOut);
    event SwapExecuted(
        address indexed sender,
        address indexed recipient,
        bool isCollateralToDebt,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feePaid
    );

    function collateralToken() external view returns (address);
    function debtToken() external view returns (address);
    function pBase() external view returns (uint256);
    function A() external view returns (uint256);
    function activeBand() external view returns (int256);
    function minActiveBand() external view returns (int256);
    function maxActiveBand() external view returns (int256);

    function depositIntoBands(
        address user,
        uint256 totalCollateral,
        int256 n1,
        int256 n2
    )
        external
        returns (uint256[] memory sharesPerBand);

    function withdrawFromBands(
        address user,
        int256 n1,
        int256 n2,
        uint256 fractionWad
    )
        external
        returns (uint256 totalCollateralOut, uint256 totalDebtOut);

    function swapCollateralForDebt(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        returns (uint256 amountOut);

    function swapDebtForCollateral(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        returns (uint256 amountOut);

    function getBand(int256 bandIndex) external view returns (BandInfo memory);
    function getUserBandBalance(address user, int256 bandIndex) external view returns (uint256 collateral, uint256 debt);
    function getUserTotalValue(
        address user,
        int256 n1,
        int256 n2,
        uint256 oraclePrice
    )
        external
        view
        returns (uint256 totalValueWad);
}
