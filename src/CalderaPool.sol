// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ICalderaPool } from "./interfaces/ICalderaPool.sol";
import { BandsMath } from "./libraries/BandsMath.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CalderaPool
/// @notice Continuous Lending-Liquidating AMM (LLAMMA) multi-band pool with EIP-1153 transient reentrancy guard
contract CalderaPool is ICalderaPool {
    using BandsMath for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_FEE_BPS = 20; // 0.20% swap fee

    // EIP-1153 Cancun Transient Storage slot for reentrancy locking
    bytes32 private constant REENTRANCY_SLOT = 0x5d00000000000000000000000000000000000000000000000000000000000000;

    address public immutable override collateralToken;
    address public immutable override debtToken;
    address public immutable controller;
    uint256 public immutable override pBase;
    uint256 public immutable override A;

    struct BandState {
        uint256 collateral; // X token balance
        uint256 debt; // Y token balance
        uint256 totalShares;
        uint256 x0;
        uint256 y0;
        uint256 K; // Invariant: (x + x0)*(y + y0) = K
        uint256 pLow;
        uint256 pHigh;
        bool initialized;
    }

    mapping(int256 => BandState) public bands;
    mapping(int256 => mapping(address => uint256)) public userShares;

    int256 public override activeBand;
    int256 public override minActiveBand;
    int256 public override maxActiveBand;
    bool private boundsInitialized;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidBands();
    error SlippageExceeded();
    error Reentrancy();
    error TransferFailed();

    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        assembly {
            if tload(REENTRANCY_SLOT) {
                // Reentrancy detected
                mstore(0x00, 0xab143cce) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    constructor(address _collateralToken, address _debtToken, address _controller, uint256 _pBase, uint256 _A) {
        if (_collateralToken == address(0) || _debtToken == address(0) || _controller == address(0)) {
            revert ZeroAddress();
        }
        collateralToken = _collateralToken;
        debtToken = _debtToken;
        controller = _controller;
        pBase = _pBase;
        A = _A;
    }

    /// @notice Deposits collateral into a continuous range of bands [n1, n2]
    /// @dev Called strictly by the lending controller during loan creation
    function depositIntoBands(
        address user,
        uint256 totalCollateral,
        int256 n1,
        int256 n2
    )
        external
        override
        onlyController
        nonReentrant
        returns (uint256[] memory sharesPerBand)
    {
        if (n1 > n2) revert InvalidBands();
        if (totalCollateral == 0) revert ZeroAmount();

        uint256 numBands = uint256(n2 - n1 + 1);
        sharesPerBand = new uint256[](numBands);
        uint256 collateralPerBand = totalCollateral / numBands;
        uint256 remainder = totalCollateral % numBands;

        if (!boundsInitialized) {
            minActiveBand = n1;
            maxActiveBand = n2;
            activeBand = n1;
            boundsInitialized = true;
        } else {
            if (n1 < minActiveBand) minActiveBand = n1;
            if (n2 > maxActiveBand) maxActiveBand = n2;
        }

        for (uint256 i = 0; i < numBands; ++i) {
            int256 bandIdx = n1 + int256(i);
            uint256 amount = collateralPerBand + (i == 0 ? remainder : 0);

            BandState storage b = bands[bandIdx];
            if (!b.initialized) {
                (b.pLow, b.pHigh) = BandsMath.getBandLimits(pBase, A, bandIdx);
                b.initialized = true;
            }

            uint256 shares;
            if (b.totalShares == 0) {
                shares = amount;
                b.collateral = amount;
                b.debt = 0;
                (b.x0, b.y0, b.K) = BandsMath.computeInvariantConstants(amount, b.pLow, b.pHigh, A);
            } else {
                shares = (amount * b.totalShares) / b.collateral;
                b.collateral += amount;
                (b.x0, b.y0, b.K) = BandsMath.computeInvariantConstants(b.collateral, b.pLow, b.pHigh, A);
            }

            b.totalShares += shares;
            userShares[bandIdx][user] += shares;
            sharesPerBand[i] = shares;

            emit BandDeposit(user, bandIdx, amount, shares);
        }

        // Transfer collateral from controller into pool
        bool ok = IERC20Minimal(collateralToken).transferFrom(msg.sender, address(this), totalCollateral);
        if (!ok) revert TransferFailed();
    }

    /// @notice Withdraws pro-rata user collateral and debt tokens from bands [n1, n2]
    function withdrawFromBands(
        address user,
        int256 n1,
        int256 n2,
        uint256 fractionWad
    )
        external
        override
        onlyController
        nonReentrant
        returns (uint256 totalCollateralOut, uint256 totalDebtOut)
    {
        if (n1 > n2) revert InvalidBands();
        if (fractionWad == 0 || fractionWad > WAD) revert ZeroAmount();

        uint256 numBands = uint256(n2 - n1 + 1);
        for (uint256 i = 0; i < numBands; ++i) {
            int256 bandIdx = n1 + int256(i);
            BandState storage b = bands[bandIdx];
            uint256 uShares = userShares[bandIdx][user];
            if (uShares == 0) continue;

            uint256 burnShares = (uShares * fractionWad) / WAD;
            if (burnShares == 0) continue;

            uint256 colShare = (b.collateral * burnShares) / b.totalShares;
            uint256 debtShare = (b.debt * burnShares) / b.totalShares;

            userShares[bandIdx][user] = uShares - burnShares;
            b.totalShares -= burnShares;
            b.collateral -= colShare;
            b.debt -= debtShare;

            totalCollateralOut += colShare;
            totalDebtOut += debtShare;

            // Recalculate invariant if shares remain
            if (b.totalShares > 0) {
                (b.x0, b.y0, b.K) = BandsMath.computeInvariantConstants(b.collateral, b.pLow, b.pHigh, A);
            } else {
                b.K = 0;
            }

            emit BandWithdraw(user, bandIdx, colShare, debtShare);
        }

        if (totalCollateralOut > 0) {
            bool ok = IERC20Minimal(collateralToken).transfer(msg.sender, totalCollateralOut);
            if (!ok) revert TransferFailed();
        }
        if (totalDebtOut > 0) {
            bool ok = IERC20Minimal(debtToken).transfer(msg.sender, totalDebtOut);
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Swaps collateral X for debt Y across active bands (driving band collateral up)
    function swapCollateralForDebt(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 remainingIn = amountIn;
        int256 currBand = activeBand;

        while (remainingIn > 0 && currBand >= minActiveBand) {
            BandState storage b = bands[currBand];
            if (b.initialized && b.K > 0 && b.debt > 0) {
                (uint256 dyNet, uint256 newX, uint256 newY) =
                    BandsMath.quoteSwapXForY(remainingIn, b.collateral, b.debt, b.x0, b.y0, b.K, BASE_FEE_BPS);

                if (dyNet > 0) {
                    b.collateral = newX;
                    b.debt = newY;
                    amountOut += dyNet;
                    remainingIn = 0; // Filled within band
                    break;
                }
            }
            currBand--;
        }

        if (amountOut < minAmountOut) revert SlippageExceeded();
        activeBand = currBand < minActiveBand ? minActiveBand : currBand;

        // Pull collateral from sender and send debt tokens to recipient
        bool okIn = IERC20Minimal(collateralToken).transferFrom(msg.sender, address(this), amountIn);
        if (!okIn) revert TransferFailed();

        bool okOut = IERC20Minimal(debtToken).transfer(recipient, amountOut);
        if (!okOut) revert TransferFailed();

        emit SwapExecuted(msg.sender, recipient, true, amountIn, amountOut, (amountOut * BASE_FEE_BPS) / BPS);
    }

    /// @notice Swaps debt Y for collateral X across active bands (executing continuous soft liquidation)
    function swapDebtForCollateral(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 remainingIn = amountIn;
        int256 currBand = activeBand;

        while (remainingIn > 0 && currBand <= maxActiveBand) {
            BandState storage b = bands[currBand];
            if (b.initialized && b.K > 0 && b.collateral > 0) {
                (uint256 dxNet, uint256 newX, uint256 newY) =
                    BandsMath.quoteSwapYForX(remainingIn, b.collateral, b.debt, b.x0, b.y0, b.K, BASE_FEE_BPS);

                if (dxNet > 0) {
                    b.collateral = newX;
                    b.debt = newY;
                    amountOut += dxNet;
                    remainingIn = 0;
                    break;
                }
            }
            currBand++;
        }

        if (amountOut < minAmountOut) revert SlippageExceeded();
        activeBand = currBand > maxActiveBand ? maxActiveBand : currBand;

        // Pull debt token from sender and send collateral to recipient
        bool okIn = IERC20Minimal(debtToken).transferFrom(msg.sender, address(this), amountIn);
        if (!okIn) revert TransferFailed();

        bool okOut = IERC20Minimal(collateralToken).transfer(recipient, amountOut);
        if (!okOut) revert TransferFailed();

        emit SwapExecuted(msg.sender, recipient, false, amountIn, amountOut, (amountOut * BASE_FEE_BPS) / BPS);
    }

    function getBand(int256 bandIndex) external view override returns (BandInfo memory info) {
        BandState storage b = bands[bandIndex];
        info.collateral = b.collateral;
        info.debt = b.debt;
        info.totalShares = b.totalShares;
        info.pLow = b.pLow;
        info.pHigh = b.pHigh;
    }

    function getUserBandBalance(
        address user,
        int256 bandIndex
    )
        external
        view
        override
        returns (uint256 collateral, uint256 debt)
    {
        BandState storage b = bands[bandIndex];
        uint256 uShares = userShares[bandIndex][user];
        if (uShares == 0 || b.totalShares == 0) return (0, 0);

        collateral = (b.collateral * uShares) / b.totalShares;
        debt = (b.debt * uShares) / b.totalShares;
    }

    function getUserTotalValue(
        address user,
        int256 n1,
        int256 n2,
        uint256 oraclePrice
    )
        external
        view
        override
        returns (uint256 totalValueWad)
    {
        if (n1 > n2) return 0;
        uint256 numBands = uint256(n2 - n1 + 1);

        for (uint256 i = 0; i < numBands; ++i) {
            int256 bandIdx = n1 + int256(i);
            BandState storage b = bands[bandIdx];
            uint256 uShares = userShares[bandIdx][user];
            if (uShares == 0 || b.totalShares == 0) continue;

            uint256 col = (b.collateral * uShares) / b.totalShares;
            uint256 dbt = (b.debt * uShares) / b.totalShares;

            totalValueWad += BandsMath.valueInDebt(col, dbt, oraclePrice);
        }
    }
}
