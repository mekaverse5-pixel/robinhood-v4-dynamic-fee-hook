// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "./Deployers.sol";

abstract contract BaseTest is Test, Deployers {
    function deployArtifactsAndLabel() internal {
        deployArtifacts();
        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }
}
