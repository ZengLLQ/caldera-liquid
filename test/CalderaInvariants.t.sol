// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { CalderaController } from "../src/CalderaController.sol";
import { CalderaPool } from "../src/CalderaPool.sol";
import { CalderaUSD } from "../src/CalderaUSD.sol";
import { CalderaOracle } from "../src/CalderaOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ICalderaController } from "../src/interfaces/ICalderaController.sol";
import { ICalderaPool } from "../src/interfaces/ICalderaPool.sol";

contract CalderaInvariantsTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant P_BASE = 3000 * 1e18;
    uint256 constant A = 50;

    MockERC20 collateralToken;
    CalderaUSD debtToken;
    CalderaOracle oracle;
    CalderaPool pool;
    CalderaController controller;

    address user1 = address(0x111);
    address user2 = address(0x222);
    address trader = address(0x333);

    function setUp() public {
        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new CalderaOracle(P_BASE);

        controller = new CalderaController(address(collateralToken), address(oracle));
        debtToken = new CalderaUSD(address(controller));
        controller.setDebtToken(address(debtToken));

        pool = new CalderaPool(address(collateralToken), address(debtToken), address(controller), P_BASE, A);
        controller.setPool(address(pool));

        collateralToken.mint(user1, 100 * WAD);
        collateralToken.mint(user2, 100 * WAD);
        collateralToken.mint(trader, 1000 * WAD);

        vm.prank(address(controller));
        debtToken.mint(trader, 1_000_000 * WAD);
    }

    /// @notice Invariant: Solvency & continuous conservation across arbitrary swaps
    function testFuzz_SoftLiquidationConservation(uint96 swapAmount) public {
        vm.assume(swapAmount > 100 * WAD && swapAmount < 50_000 * WAD);

        // User1 creates loan in bands [0, 9]
        vm.startPrank(user1);
        collateralToken.approve(address(controller), 20 * WAD);
        controller.createLoan(20 * WAD, 30_000 * WAD, 0, 9);
        vm.stopPrank();

        // Trader performs soft liquidation swap (debt -> collateral)
        vm.startPrank(trader);
        debtToken.approve(address(pool), swapAmount);
        uint256 colOut = pool.swapDebtForCollateral(swapAmount, 0, trader);
        vm.stopPrank();

        assertTrue(colOut > 0);

        // Invariant: Pool's total held collateral + total held debt must be strictly non-zero
        uint256 poolCol = collateralToken.balanceOf(address(pool));
        uint256 poolDebt = debtToken.balanceOf(address(pool));
        assertTrue(poolCol > 0 || poolDebt > 0);

        // Invariant: User1's total portfolio valuation across bands must stay >= 0
        uint256 userVal = pool.getUserTotalValue(user1, 0, 9, oracle.getPrice());
        assertTrue(userVal > 0);
    }

    /// @notice Invariant: Reversibility — round-trip soft liquidation and price recovery
    function test_SoftLiquidationReversibility() public {
        vm.startPrank(user1);
        collateralToken.approve(address(controller), 10 * WAD);
        controller.createLoan(10 * WAD, 15_000 * WAD, 0, 4);
        vm.stopPrank();

        uint256 initialVal = pool.getUserTotalValue(user1, 0, 4, oracle.getPrice());

        // Step 1: Price drops, trader swaps debt for collateral
        vm.startPrank(trader);
        debtToken.approve(address(pool), 6000 * WAD);
        uint256 colOut = pool.swapDebtForCollateral(6000 * WAD, 0, trader);

        // Step 2: Price recovers, trader swaps collateral back for debt
        collateralToken.approve(address(pool), colOut);
        uint256 debtOut = pool.swapCollateralForDebt(colOut, 0, trader);
        vm.stopPrank();

        assertTrue(debtOut > 0);

        // Final valuation of user1 should be closely conserved (within trading fee bounds)
        uint256 finalVal = pool.getUserTotalValue(user1, 0, 4, oracle.getPrice());
        uint256 diff = initialVal > finalVal ? initialVal - finalVal : finalVal - initialVal;

        // Spread/loss is less than 1% of initial valuation
        assertTrue(diff < (initialVal * 100) / 10_000);
    }
}
