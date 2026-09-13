// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DynamicFeeRebalanceHook} from "../src/DynamicFeeRebalanceHook.sol";

/// @notice Mines the permission bits and deploys the immutable hook through CREATE2.
/// @dev POOL_MANAGER must point to the target chain's actual v4 PoolManager. Run the
///      read-only VerifyRobinhoodTestnet script before using the observed 46630 deployment.
contract DeployDynamicFeeRebalanceHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant REVIEWED_CREATION_CODE_SIZE = 24_300;
    uint256 internal constant REVIEWED_RUNTIME_SIZE = 23_412;

    function run() external returns (DynamicFeeRebalanceHook hook) {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        require(address(manager).code.length != 0, "POOL_MANAGER has no code");
        require(
            type(DynamicFeeRebalanceHook).creationCode.length == REVIEWED_CREATION_CODE_SIZE,
            "unreviewed hook creation code size"
        );

        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory constructorArgs = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(DynamicFeeRebalanceHook).creationCode, constructorArgs);
        console2.log("expected hook", expected);
        console2.logBytes32(salt);

        vm.broadcast();
        hook = new DynamicFeeRebalanceHook{salt: salt}(manager);
        require(address(hook) == expected, "hook address mismatch");
        require(address(hook).code.length == REVIEWED_RUNTIME_SIZE, "deployed runtime size mismatch");
    }
}
