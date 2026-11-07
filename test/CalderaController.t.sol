// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { CalderaController } from "../src/CalderaController.sol";
import { CalderaPool } from "../src/CalderaPool.sol";
import { CalderaUSD } from "../src/CalderaUSD.sol";
import { CalderaOracle } from "../src/CalderaOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ICalderaController } from "../src/interfaces/ICalderaController.sol";

contract CalderaControllerTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant P_BASE = 3000 * 1e18; // $3000
    uint256 constant A = 50;

    MockERC20 collateralToken;
    CalderaUSD debtToken;
    CalderaOracle oracle;
    CalderaPool pool;
    CalderaController controller;

    address alice = address(0xA11CE);
    address liquidator = address(0xDEAD);

    function setUp() public {
        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new CalderaOracle(P_BASE);

        controller = new CalderaController(address(collateralToken), address(oracle));
        debtToken = new CalderaUSD(address(controller));
        controller.setDebtToken(address(debtToken));

        pool = new CalderaPool(address(collateralToken), address(debtToken), address(controller), P_BASE, A);
        controller.setPool(address(pool));

        collateralToken.mint(alice, 100 * WAD);
        collateralToken.mint(liquidator, 100 * WAD);
    }

    function test_InitialControllerState() public view {
        assertEq(controller.collateralToken(), address(collateralToken));
        assertEq(controller.debtToken(), address(debtToken));
        assertEq(controller.oracle(), address(oracle));
        assertEq(controller.pool(), address(pool));
        assertEq(controller.interestIndex(), WAD);
        assertEq(controller.currentBorrowRate(), 2 * 1e16); // 2% base APR
    }

    function test_CreateLoan() public {
        // Alice deposits 10 WETH ($30,000) and borrows 15,000 calUSD (50% LTV, well below 85% max)
        vm.startPrank(alice);
        collateralToken.approve(address(controller), 10 * WAD);
        controller.createLoan(10 * WAD, 15_000 * WAD, 0, 4);
        vm.stopPrank();

        ICalderaController.Position memory pos = controller.getPosition(alice);
        assertTrue(pos.exists);
        assertEq(pos.debt, 15_000 * WAD);
        assertEq(pos.initialCollateral, 10 * WAD);
        assertEq(pos.bandRangeStart, 0);
        assertEq(pos.bandRangeEnd, 4);

        assertEq(debtToken.balanceOf(alice), 15_000 * WAD);
        assertEq(controller.totalDebt(), 15_000 * WAD);

        // Check health factor: Portfolio value = $30,000. Debt threshold = 15000 * 0.92 = 13800.
        // HF = 30000 / 13800 = ~2.17 WAD (> 1.0 WAD)
        uint256 hf = controller.getHealthFactor(alice);
        assertTrue(hf > 2 * WAD);
    }

    function test_BorrowRateUtilizationKinks() public {
        // Create a massive loan to increase utilization
        address bigBorrower = address(0x999);
        collateralToken.mint(bigBorrower, 5000 * WAD);

        vm.startPrank(bigBorrower);
        collateralToken.approve(address(controller), 5000 * WAD);
        // Borrow 8M calUSD (80% of 10M debt ceiling -> optimal utilization)
        controller.createLoan(5000 * WAD, 8_000_000 * WAD, 0, 9);
        vm.stopPrank();

        // At 80% utilization: rate = 2% + 4% = 6% APR = 0.06e18
        uint256 rateAtKink = controller.currentBorrowRate();
        assertEq(rateAtKink, 6 * 1e16);

        // Now borrow another 1M calUSD to reach 90% utilization (above kink)
        address secondBorrower = address(0x888);
        collateralToken.mint(secondBorrower, 1000 * WAD);
        vm.startPrank(secondBorrower);
        collateralToken.approve(address(controller), 1000 * WAD);
        controller.createLoan(1000 * WAD, 1_000_000 * WAD, 0, 9);
        vm.stopPrank();

        // At 90% utilization (halfway between 80% and 100%): rate = 6% + 15% = 21% APR
        uint256 rateAboveKink = controller.currentBorrowRate();
        assertEq(rateAboveKink, 21 * 1e16);
    }

    function test_InterestAccrualOverTime() public {
        vm.startPrank(alice);
        collateralToken.approve(address(controller), 10 * WAD);
        controller.createLoan(10 * WAD, 10_000 * WAD, 0, 4);
        vm.stopPrank();

        // Warp time by 1 year (31,536,000 seconds)
        vm.warp(block.timestamp + 31_536_000);

        uint256 newIndex = controller.accrueInterest();
        // Base rate ~2%, so new index should be ~1.02e18
        assertTrue(newIndex > 1019 * 1e15 && newIndex < 1025 * 1e15);
    }

    function test_RepayAndCloseLoan() public {
        vm.startPrank(alice);
        collateralToken.approve(address(controller), 10 * WAD);
        controller.createLoan(10 * WAD, 10_000 * WAD, 0, 4);

        // Approve calUSD debt repayment
        debtToken.approve(address(controller), type(uint256).max);
        controller.repayAndClose();
        vm.stopPrank();

        ICalderaController.Position memory pos = controller.getPosition(alice);
        assertFalse(pos.exists);
        assertEq(collateralToken.balanceOf(alice), 100 * WAD); // 100% collateral returned
        assertEq(debtToken.balanceOf(alice), 0);
        assertEq(controller.totalDebt(), 0);
    }

    function test_HardLiquidationWhenUnderwater() public {
        // Alice opens 10 WETH loan for 24,000 calUSD (near max 85% LTV at $3000)
        vm.startPrank(alice);
        collateralToken.approve(address(controller), 10 * WAD);
        controller.createLoan(10 * WAD, 24_000 * WAD, 0, 4);
        vm.stopPrank();

        // Crash oracle price below $2000 (below band limits, and underwater relative to debt)
        for (uint256 i = 0; i < 70; ++i) {
            oracle.updatePrice((oracle.getPrice() * 975) / 1000);
        }

        // Alice is now underwater and H < 1.0 WAD
        uint256 hf = controller.getHealthFactor(alice);
        assertTrue(hf < WAD);

        // Liquidator repays Alice's debt and liquidates position
        vm.prank(address(controller));
        debtToken.mint(liquidator, 30_000 * WAD);
        vm.startPrank(liquidator);
        debtToken.approve(address(controller), type(uint256).max);
        controller.hardLiquidate(alice);
        vm.stopPrank();

        ICalderaController.Position memory pos = controller.getPosition(alice);
        assertFalse(pos.exists);
        assertTrue(collateralToken.balanceOf(liquidator) > 100 * WAD); // Liquidator received collateral
    }
}
