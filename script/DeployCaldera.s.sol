// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CalderaController } from "../src/CalderaController.sol";
import { CalderaPool } from "../src/CalderaPool.sol";
import { CalderaUSD } from "../src/CalderaUSD.sol";
import { CalderaOracle } from "../src/CalderaOracle.sol";
import { CalderaRouter } from "../src/CalderaRouter.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";

/// @title DeployCalderaScript
/// @notice Automated deployment and wiring script for CalderaLiquid
contract DeployCalderaScript is Script {
    uint256 constant P_BASE = 3000 * 1e18; // $3000 base WETH price
    uint256 constant A = 50; // Amplification factor

    function run() external {
        vm.startBroadcast();

        // 1. Deploy Mock WETH collateral
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log("Mock WETH deployed at:", address(weth));

        // 2. Deploy Oracle
        CalderaOracle oracle = new CalderaOracle(P_BASE);
        console.log("CalderaOracle deployed at:", address(oracle));

        // 3. Deploy Controller
        CalderaController controller = new CalderaController(address(weth), address(oracle));
        console.log("CalderaController deployed at:", address(controller));

        // 4. Deploy synthetic calUSD debt token
        CalderaUSD calUsd = new CalderaUSD(address(controller));
        controller.setDebtToken(address(calUsd));
        console.log("CalderaUSD deployed at:", address(calUsd));

        // 5. Deploy LLAMMA Pool
        CalderaPool pool = new CalderaPool(address(weth), address(calUsd), address(controller), P_BASE, A);
        controller.setPool(address(pool));
        console.log("CalderaPool deployed at:", address(pool));

        // 6. Deploy Router
        CalderaRouter router = new CalderaRouter(address(controller), address(pool), address(weth), address(calUsd));
        console.log("CalderaRouter deployed at:", address(router));

        vm.stopBroadcast();
    }
}
