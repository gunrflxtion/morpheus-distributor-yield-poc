// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IAavePoolMini {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveData(address asset)
        external
        view
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            address,
            address,
            address,
            address,
            uint8
        );
}

interface IERC20Mini {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract AaveIsolation is Test {
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant L1SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    function testViewReserveData() public view {
        uint256 income = IAavePoolMini(POOL).getReserveNormalizedIncome(WBTC);
        console.log("normalized income", income);
    }

    function testSupplyDirect() public {
        address tester = makeAddr("tester");
        deal(WBTC, tester, 100000);
        vm.startPrank(tester);
        IERC20Mini(WBTC).approve(POOL, type(uint256).max);
        try IAavePoolMini(POOL).supply(WBTC, 1000, tester, 0) {
            console.log("supply ok, aWBTC balance", IERC20Mini(AWBTC).balanceOf(tester));
        } catch Error(string memory reason) {
            console.log("supply reverted:", reason);
        } catch (bytes memory) {
            console.log("supply reverted without reason");
        }
        vm.stopPrank();
    }

    function testWithdrawAsDistributor() public {
        vm.prank(DISTRIBUTOR);
        try IAavePoolMini(POOL).withdraw(WBTC, 10, L1SENDER) returns (uint256 amount) {
            console.log("withdraw ok, amount", amount);
        } catch Error(string memory reason) {
            console.log("withdraw reverted:", reason);
        } catch (bytes memory) {
            console.log("withdraw reverted without reason");
        }
    }
}
