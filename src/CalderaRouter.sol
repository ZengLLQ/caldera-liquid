// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ICalderaController } from "./interfaces/ICalderaController.sol";
import { ICalderaPool } from "./interfaces/ICalderaPool.sol";
import { ICalderaUSD } from "./interfaces/ICalderaUSD.sol";

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external;
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

/// @title CalderaRouter
/// @notice Aggregation router providing atomic permit-loans and multi-band arbitrage routing
contract CalderaRouter {
    address public immutable controller;
    address public immutable pool;
    address public immutable collateralToken;
    address public immutable debtToken;

    error DeadlineExpired();
    error ZeroAddress();

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    constructor(address _controller, address _pool, address _collateralToken, address _debtToken) {
        if (
            _controller == address(0) || _pool == address(0) || _collateralToken == address(0)
                || _debtToken == address(0)
        ) {
            revert ZeroAddress();
        }
        controller = _controller;
        pool = _pool;
        collateralToken = _collateralToken;
        debtToken = _debtToken;
    }

    /// @notice Creates loan using EIP-2612 Permit for one-transaction atomic execution
    function createLoanWithPermit(
        uint256 collateralAmount,
        uint256 debtAmount,
        int256 n1,
        int256 n2,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        checkDeadline(deadline)
    {
        // Execute permit to allow Router to transfer collateral
        IERC20Permit(collateralToken).permit(msg.sender, address(this), collateralAmount, deadline, v, r, s);

        // Pull collateral into router, approve controller, and create loan
        IERC20Permit(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        IERC20Permit(collateralToken).approve(controller, collateralAmount);

        // Note: For router to create loan on behalf of user, or user direct call
        // Here we transfer collateral to user and call or let user approve directly
        IERC20Permit(collateralToken).approve(controller, collateralAmount);
        ICalderaController(controller).createLoan(collateralAmount, debtAmount, n1, n2);
    }

    /// @notice Arbitrage router swap: collateral -> debt token
    function swapCollateralForDebt(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    )
        external
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        IERC20Permit(collateralToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20Permit(collateralToken).approve(pool, amountIn);
        amountOut = ICalderaPool(pool).swapCollateralForDebt(amountIn, minAmountOut, recipient);
    }

    /// @notice Arbitrage router swap: debt token -> collateral (soft liquidation)
    function swapDebtForCollateral(
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    )
        external
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        IERC20Permit(debtToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20Permit(debtToken).approve(pool, amountIn);
        amountOut = ICalderaPool(pool).swapDebtForCollateral(amountIn, minAmountOut, recipient);
    }
}
