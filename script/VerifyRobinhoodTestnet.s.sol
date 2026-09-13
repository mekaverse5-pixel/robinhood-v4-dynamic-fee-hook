// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

interface IPositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

interface IStateViewBindings {
    function poolManager() external view returns (address);
}

/// @notice Read-only fingerprint and wiring check for the v4 contracts observed on chain 46630.
/// @dev These addresses are not currently declared by Uniswap's public deployment list, so
///      callers should run this check immediately before simulating or broadcasting a deploy.
contract VerifyRobinhoodTestnet is Script {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 internal constant POSITION_MANAGER_CODEHASH =
        0xf3a0edb689229fa4bf135a728f2ec2eb4a2fbee2e41e3e74ffadb7b4c56e8a6d;
    bytes32 internal constant STATE_VIEW_CODEHASH = 0x7d9c591e0956fd89d98feb4ffcfe8bf1f7a62bd485edd979fa21d104b49878a6;

    function run() external view {
        require(block.chainid == 46630, "wrong chain");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODEHASH, "PoolManager codehash changed");
        require(POSITION_MANAGER.codehash == POSITION_MANAGER_CODEHASH, "PositionManager codehash changed");
        require(STATE_VIEW.codehash == STATE_VIEW_CODEHASH, "StateView codehash changed");
        require(PERMIT2.code.length != 0, "Permit2 missing");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");
        require(
            IPositionManagerBindings(POSITION_MANAGER).poolManager() == POOL_MANAGER, "PositionManager pool mismatch"
        );
        require(IPositionManagerBindings(POSITION_MANAGER).permit2() == PERMIT2, "PositionManager Permit2 mismatch");
        require(IStateViewBindings(STATE_VIEW).poolManager() == POOL_MANAGER, "StateView pool mismatch");
    }
}
