// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { CalderaPool } from "../src/CalderaPool.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ICalderaPool } from "../src/interfaces/ICalderaPool.sol";

contract CalderaPoolTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant P_BASE = 3000 * 1e18;
    uint256 constant A = 50;

    MockERC20 collateralToken;
    MockERC20 debtToken;
    CalderaPool pool;

    address controller = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        debtToken = new MockERC20("Caldera USD", "calUSD", 18);

        pool = new CalderaPool(address(collateralToken), address(debtToken), controller, P_BASE, A);

        collateralToken.mint(controller, 1000 * WAD);
        debtToken.mint(controller, 1_000_000 * WAD);

        collateralToken.mint(alice, 100 * WAD);
        debtToken.mint(bob, 100_000 * WAD);
    }

    function test_InitialState() public view {
        assertEq(pool.collateralToken(), address(collateralToken));
        assertEq(pool.debtToken(), address(debtToken));
        assertEq(pool.pBase(), P_BASE);
        assertEq(pool.A(), A);
    }

    function test_DepositIntoBands() public {
        vm.startPrank(controller);
        collateralToken.approve(address(pool), 10 * WAD);
        uint256[] memory shares = pool.depositIntoBands(alice, 10 * WAD, 0, 4);
        vm.stopPrank();

        assertEq(shares.length, 5); // bands 0, 1, 2, 3, 4
        assertEq(pool.minActiveBand(), 0);
        assertEq(pool.maxActiveBand(), 4);

        // Check band 0
        ICalderaPool.BandInfo memory b0 = pool.getBand(0);
        assertEq(b0.collateral, 2 * WAD);
        assertEq(b0.debt, 0);
        assertEq(b0.pHigh, P_BASE);
        assertEq(b0.pLow, (P_BASE * 49) / 50);

        (uint256 userCol, uint256 userDebt) = pool.getUserBandBalance(alice, 0);
        assertEq(userCol, 2 * WAD);
        assertEq(userDebt, 0);
    }

    function test_UserTotalValuation() public {
        vm.startPrank(controller);
        collateralToken.approve(address(pool), 10 * WAD);
        pool.depositIntoBands(alice, 10 * WAD, 0, 4);
        vm.stopPrank();

        // 10 WETH at $3000 = $30,000 WAD
        uint256 totalVal = pool.getUserTotalValue(alice, 0, 4, 3000 * WAD);
        assertEq(totalVal, 30_000 * WAD);
    }

    function test_SoftLiquidationSwap() public {
        // Alice deposits 10 WETH into bands [0, 4]
        vm.startPrank(controller);
        collateralToken.approve(address(pool), 10 * WAD);
        pool.depositIntoBands(alice, 10 * WAD, 0, 4);
        vm.stopPrank();

        // Bob swaps debt token calUSD for collateral (soft liquidation as price moves into bands)
        vm.startPrank(bob);
        debtToken.approve(address(pool), 5000 * WAD);
        uint256 colOut = pool.swapDebtForCollateral(5000 * WAD, 1 * WAD, bob);
        vm.stopPrank();

        assertTrue(colOut > 1 * WAD && colOut < 2 * WAD);
        assertEq(debtToken.balanceOf(address(pool)), 5000 * WAD);

        // Check that Alice's balance in band 0 now contains both collateral AND debt tokens!
        (uint256 aliceCol, uint256 aliceDebt) = pool.getUserBandBalance(alice, 0);
        assertTrue(aliceCol < 2 * WAD); // Collateral partially converted
        assertTrue(aliceDebt > 0); // Now holds stable debt tokens protecting solvency
    }

    function test_WithdrawalFromBands() public {
        vm.startPrank(controller);
        collateralToken.approve(address(pool), 10 * WAD);
        pool.depositIntoBands(alice, 10 * WAD, 0, 4);

        // Withdraw 100% of Alice's position
        (uint256 colOut, uint256 debtOut) = pool.withdrawFromBands(alice, 0, 4, WAD);
        vm.stopPrank();

        assertEq(colOut, 10 * WAD);
        assertEq(debtOut, 0);
        assertEq(collateralToken.balanceOf(controller), 1000 * WAD);
    }

    function test_UnauthorizedDepositReverts() public {
        vm.prank(alice);
        vm.expectRevert(CalderaPool.Unauthorized.selector);
        pool.depositIntoBands(alice, 10 * WAD, 0, 4);
    }
}
