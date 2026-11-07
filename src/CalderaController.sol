// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ICalderaController } from "./interfaces/ICalderaController.sol";
import { ICalderaPool } from "./interfaces/ICalderaPool.sol";
import { ICalderaUSD } from "./interfaces/ICalderaUSD.sol";
import { ICalderaOracle } from "./interfaces/ICalderaOracle.sol";

interface IERC20Standard {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CalderaController
/// @notice Isolated CDP lending controller orchestrating continuous LLAMMA soft-liquidations
contract CalderaController is ICalderaController {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;

    // Risk Parameters
    uint256 public constant MAX_LTV_BPS = 8500; // 85% maximum initial LTV
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 9200; // 92% liquidation health cutoff
    uint256 public constant LIQUIDATOR_BONUS_BPS = 200; // 2% bonus incentive for safety liquidator
    uint256 public constant MIN_DEBT = 100 * 1e18; // 100 calUSD minimum debt
    uint256 public constant DEBT_CEILING = 10_000_000 * 1e18; // 10M calUSD debt ceiling

    // Interest Rate Model: Kinked Jump Rate
    uint256 public constant BASE_RATE_APR_WAD = 2 * 1e16; // 2% base APR
    uint256 public constant OPTIMAL_UTILIZATION_BPS = 8000; // 80% optimal utilization
    uint256 public constant SLOPE1_RATE_APR_WAD = 4 * 1e16; // 4% slope 1 APR
    uint256 public constant SLOPE2_RATE_APR_WAD = 30 * 1e16; // 30% jump slope 2 APR

    address public immutable collateralToken;
    address public debtToken;
    address public pool;
    address public immutable oracle;

    mapping(address => Position) public positions;
    uint256 public totalDebt;
    uint256 public interestIndex;
    uint256 public lastAccrualTimestamp;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error PositionAlreadyExists();
    error PositionDoesNotExist();
    error InvalidBandRange();
    error BandPriceAboveCurrent();
    error DebtCeilingExceeded();
    error DebtBelowMinimum();
    error ExceedsMaxLtv();
    error PositionHealthy();
    error TransferFailed();

    modifier onlyPool() {
        if (msg.sender != pool) revert Unauthorized();
        _;
    }

    constructor(address _collateralToken, address _oracle) {
        if (_collateralToken == address(0) || _oracle == address(0)) {
            revert ZeroAddress();
        }
        collateralToken = _collateralToken;
        oracle = _oracle;
        interestIndex = WAD;
        lastAccrualTimestamp = block.timestamp;
    }

    /// @notice Sets the connected synthetic debt token address (one-time setup)
    function setDebtToken(address _debtToken) external {
        if (debtToken != address(0)) revert Unauthorized();
        if (_debtToken == address(0)) revert ZeroAddress();
        debtToken = _debtToken;
    }

    /// @notice Sets the connected LLAMMA pool address (one-time setup)
    function setPool(address _pool) external {
        if (pool != address(0)) revert Unauthorized();
        if (_pool == address(0)) revert ZeroAddress();
        pool = _pool;
    }

    /// @notice Creates an isolated CDP loan by depositing collateral into LLAMMA bands [n1, n2]
    function createLoan(uint256 collateralAmount, uint256 debtAmount, int256 n1, int256 n2) external override {
        if (positions[msg.sender].exists) revert PositionAlreadyExists();
        if (collateralAmount == 0 || debtAmount == 0) revert ZeroAmount();
        if (debtAmount < MIN_DEBT) revert DebtBelowMinimum();
        if (n1 > n2 || (n2 - n1 + 1) < 4 || (n2 - n1 + 1) > 50) revert InvalidBandRange();

        accrueInterest();

        if (totalDebt + debtAmount > DEBT_CEILING) revert DebtCeilingExceeded();

        uint256 oraclePrice = ICalderaOracle(oracle).getPrice();
        uint256 collateralValueWad = (collateralAmount * oraclePrice) / WAD;
        uint256 maxBorrow = (collateralValueWad * MAX_LTV_BPS) / BPS;
        if (debtAmount > maxBorrow) revert ExceedsMaxLtv();

        positions[msg.sender] = Position({
            debt: debtAmount,
            bandRangeStart: n1,
            bandRangeEnd: n2,
            initialCollateral: collateralAmount,
            lastInterestIndex: interestIndex,
            exists: true
        });

        totalDebt += debtAmount;

        // Pull collateral from user
        bool okIn = IERC20Standard(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        if (!okIn) revert TransferFailed();

        // Approve pool and deposit collateral into bands
        IERC20Standard(collateralToken).approve(pool, collateralAmount);
        ICalderaPool(pool).depositIntoBands(msg.sender, collateralAmount, n1, n2);

        // Mint synthetic debt token calUSD to user
        ICalderaUSD(debtToken).mint(msg.sender, debtAmount);

        emit LoanCreated(msg.sender, collateralAmount, debtAmount, n1, n2);
    }

    /// @notice Repays loan and withdraws remaining collateral and debt tokens from LLAMMA
    function repayAndClose() external override {
        Position storage pos = positions[msg.sender];
        if (!pos.exists) revert PositionDoesNotExist();

        accrueInterest();

        uint256 currentDebt = _getCurrentDebt(pos);

        // Burn debt tokens from user
        ICalderaUSD(debtToken).burn(msg.sender, currentDebt);
        totalDebt = totalDebt > pos.debt ? totalDebt - pos.debt : 0;

        // Withdraw 100% (1e18) of user's band allocations from pool
        (uint256 collateralOut, uint256 debtOut) =
            ICalderaPool(pool).withdrawFromBands(msg.sender, pos.bandRangeStart, pos.bandRangeEnd, WAD);

        delete positions[msg.sender];

        // Send recovered assets to user
        if (collateralOut > 0) {
            bool okCol = IERC20Standard(collateralToken).transfer(msg.sender, collateralOut);
            if (!okCol) revert TransferFailed();
        }
        if (debtOut > 0) {
            bool okDbt = IERC20Standard(debtToken).transfer(msg.sender, debtOut);
            if (!okDbt) revert TransferFailed();
        }

        emit LoanRepaid(msg.sender, currentDebt, collateralOut, debtOut);
    }

    /// @notice Hard liquidation triggered only when LLAMMA soft liquidation is overwhelmed and H < 1.0
    function hardLiquidate(address user) external override {
        Position storage pos = positions[user];
        if (!pos.exists) revert PositionDoesNotExist();

        accrueInterest();

        uint256 hf = getHealthFactor(user);
        if (hf >= WAD) revert PositionHealthy();

        uint256 currentDebt = _getCurrentDebt(pos);

        // Liquidator repays user's debt
        ICalderaUSD(debtToken).burn(msg.sender, currentDebt);
        totalDebt = totalDebt > pos.debt ? totalDebt - pos.debt : 0;

        // Withdraw all assets from user's bands
        (uint256 collateralOut, uint256 debtOut) =
            ICalderaPool(pool).withdrawFromBands(user, pos.bandRangeStart, pos.bandRangeEnd, WAD);

        delete positions[user];

        // Award all recovered assets to liquidator
        if (collateralOut > 0) {
            bool okCol = IERC20Standard(collateralToken).transfer(msg.sender, collateralOut);
            if (!okCol) revert TransferFailed();
        }
        if (debtOut > 0) {
            bool okDbt = IERC20Standard(debtToken).transfer(msg.sender, debtOut);
            if (!okDbt) revert TransferFailed();
        }

        emit HardLiquidated(user, msg.sender, currentDebt, collateralOut, debtOut);
    }

    /// @notice Returns position health factor: H = (Portfolio Value * 10000) / (Debt * LiquidationThreshold)
    function getHealthFactor(address user) public view override returns (uint256 healthFactorWad) {
        Position storage pos = positions[user];
        if (!pos.exists) return 0;

        uint256 currentDebt = _getCurrentDebt(pos);
        if (currentDebt == 0) return type(uint256).max;

        uint256 oraclePrice = ICalderaOracle(oracle).getPrice();
        uint256 portfolioValueWad =
            ICalderaPool(pool).getUserTotalValue(user, pos.bandRangeStart, pos.bandRangeEnd, oraclePrice);

        // Required threshold value = (Debt * LIQUIDATION_THRESHOLD_BPS) / BPS
        uint256 thresholdValue = (currentDebt * LIQUIDATION_THRESHOLD_BPS) / BPS;
        if (thresholdValue == 0) return type(uint256).max;

        healthFactorWad = (portfolioValueWad * WAD) / thresholdValue;
    }

    function getPosition(address user) external view override returns (Position memory) {
        return positions[user];
    }

    /// @notice Evaluates current kinked borrow rate APR in WAD
    function currentBorrowRate() public view override returns (uint256 rateAprWad) {
        if (DEBT_CEILING == 0) return BASE_RATE_APR_WAD;
        uint256 utilizationBps = (totalDebt * BPS) / DEBT_CEILING;

        if (utilizationBps <= OPTIMAL_UTILIZATION_BPS) {
            // rate = base + (utilization / optimal) * slope1
            uint256 added = (utilizationBps * SLOPE1_RATE_APR_WAD) / OPTIMAL_UTILIZATION_BPS;
            return BASE_RATE_APR_WAD + added;
        } else {
            // rate = base + slope1 + ((utilization - optimal) / (1 - optimal)) * slope2
            uint256 excess = utilizationBps - OPTIMAL_UTILIZATION_BPS;
            uint256 remaining = BPS - OPTIMAL_UTILIZATION_BPS;
            uint256 jump = (excess * SLOPE2_RATE_APR_WAD) / remaining;
            return BASE_RATE_APR_WAD + SLOPE1_RATE_APR_WAD + jump;
        }
    }

    /// @notice Accrues continuous interest into interestIndex
    function accrueInterest() public override returns (uint256 currentIndex) {
        uint256 timeElapsed = block.timestamp - lastAccrualTimestamp;
        if (timeElapsed == 0) return interestIndex;

        uint256 rateApr = currentBorrowRate();
        // deltaIndex = (interestIndex * rateApr * timeElapsed) / (SECONDS_PER_YEAR * WAD)
        uint256 deltaIndex = (interestIndex * rateApr * timeElapsed) / (SECONDS_PER_YEAR * WAD);
        interestIndex += deltaIndex;
        lastAccrualTimestamp = block.timestamp;

        emit InterestAccrued(interestIndex, rateApr, block.timestamp);
        return interestIndex;
    }

    function _getCurrentDebt(Position storage pos) internal view returns (uint256) {
        if (pos.lastInterestIndex == 0) return pos.debt;
        return (pos.debt * interestIndex) / pos.lastInterestIndex;
    }
}
