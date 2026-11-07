// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICalderaController
/// @notice Interface for the Isolated CDP Lending Controller with soft liquidation
interface ICalderaController {
    struct Position {
        uint256 debt;
        int256 bandRangeStart; // n1
        int256 bandRangeEnd; // n2
        uint256 initialCollateral;
        uint256 lastInterestIndex;
        bool exists;
    }

    event LoanCreated(address indexed user, uint256 collateralDeposited, uint256 debtMinted, int256 n1, int256 n2);
    event LoanRepaid(address indexed user, uint256 debtRepaid, uint256 collateralReturned, uint256 debtTokenReturned);
    event HardLiquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtCovered,
        uint256 collateralAwarded,
        uint256 debtTokenAwarded
    );
    event InterestAccrued(uint256 newIndex, uint256 borrowRateApr, uint256 timestamp);

    function createLoan(uint256 collateralAmount, uint256 debtAmount, int256 n1, int256 n2) external;

    function repayAndClose() external;

    function hardLiquidate(address user) external;

    function getHealthFactor(address user) external view returns (uint256 healthFactorWad);
    function getPosition(address user) external view returns (Position memory);
    function currentBorrowRate() external view returns (uint256 rateAprWad);
    function accrueInterest() external returns (uint256 currentIndex);
}
