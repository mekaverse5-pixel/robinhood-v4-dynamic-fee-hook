// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {DynamicFeeRebalanceHook} from "../src/DynamicFeeRebalanceHook.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";

/// @notice Creates an isolated ERC-20 pair, initializes the deployed Hook pool,
///         and mints one real testnet position through the canonical PositionManager.
contract SmokeTestDeployedHook is Script {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() external returns (address token0, address token1, PoolId createdPoolId, uint256 positionTokenId) {
        require(block.chainid == 46630, "wrong chain");
        address deployer = vm.envAddress("DEPLOYER");
        DynamicFeeRebalanceHook hook = DynamicFeeRebalanceHook(vm.envAddress("HOOK_ADDRESS"));
        require(address(hook).code.length != 0, "hook missing");
        require(address(hook.poolManager()) == address(POOL_MANAGER), "wrong PoolManager");

        vm.startBroadcast();

        (token0, token1) = _deployAndApproveTokens(deployer);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        DynamicFeeRebalanceHook.PoolConfig memory config = DynamicFeeRebalanceHook.PoolConfig({
            minFeePips: 500,
            maxFeePips: 10_000,
            baseFeePips: 3_000,
            volatilityCoeff: 25,
            maxFeeStepPips: 2_000,
            autoFeeEnabled: true,
            rebalanceUpEnabled: false,
            rebalanceWidthTicks: 1_200,
            rebalanceTriggerBps: 100,
            feeRecipient: deployer,
            revenueCutBps: 500,
            poolOwner: deployer
        });
        hook.setPendingConfig(key, config);

        uint160 sqrtPriceX96 = uint160(1 << 96);
        POOL_MANAGER.initialize(key, sqrtPriceX96);
        createdPoolId = key.toId();

        positionTokenId = _mintPosition(key, sqrtPriceX96, deployer);

        vm.stopBroadcast();
    }

    function _deployAndApproveTokens(address deployer) internal returns (address token0, address token1) {
        MockERC20 tokenA = new MockERC20("V4 Hook Test Token A", "V4A", 18);
        MockERC20 tokenB = new MockERC20("V4 Hook Test Token B", "V4B", 18);
        MockERC20 first = tokenA < tokenB ? tokenA : tokenB;
        MockERC20 second = tokenA < tokenB ? tokenB : tokenA;
        token0 = address(first);
        token1 = address(second);
        first.mint(deployer, 1_000_000 ether);
        second.mint(deployer, 1_000_000 ether);
        first.approve(address(PERMIT2), type(uint256).max);
        second.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token0, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token1, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
    }

    function _mintPosition(PoolKey memory key, uint160 sqrtPriceX96, address deployer)
        internal
        returns (uint256 positionTokenId)
    {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 100 ether;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        return POSITION_MANAGER.mint(
            key, tickLower, tickUpper, liquidity, amount0 + 1, amount1 + 1, deployer, block.timestamp + 1 hours
        );
    }
}
