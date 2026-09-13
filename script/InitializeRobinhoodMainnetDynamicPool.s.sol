// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
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

/// @notice Initializes the bounded production smoke-test pool and mints its first position.
/// @dev All addresses and token budgets are pinned to prevent accidental expansion of scope.
contract InitializeRobinhoodMainnetDynamicPool is Script {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    DynamicFeeRebalanceHook internal constant HOOK =
        DynamicFeeRebalanceHook(0xC538C832BF24e2bC53EB19dECEFa0BCFD59Dd0C4);

    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 internal constant MAX_WETH = 0.00015 ether;
    uint256 internal constant MAX_USDG = 350_000;
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 3_979_225_974_902_204_775_885_201;
    int24 internal constant TICK_LOWER = -198_600;
    int24 internal constant TICK_UPPER = -197_400;

    function run() external returns (PoolId createdPoolId, uint128 liquidity) {
        require(block.chainid == 4663, "mainnet only");
        address owner = vm.envAddress("DEPLOYER");
        require(owner == 0xf7E7da333d6949adBDBb39Fd2C744CA116C8DDa3, "unexpected owner");
        require(address(HOOK).code.length == 23_412, "hook bytecode mismatch");
        require(address(HOOK.poolManager()) == address(POOL_MANAGER), "wrong PoolManager");
        require(WETH < USDG, "unexpected currency order");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(HOOK))
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
            feeRecipient: owner,
            revenueCutBps: 500,
            poolOwner: owner
        });

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            MAX_WETH,
            MAX_USDG
        );
        require(liquidity != 0, "zero liquidity");
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            liquidity
        );
        require(amount0 <= MAX_WETH && amount1 <= MAX_USDG, "budget exceeded");

        vm.startBroadcast();
        IERC20Minimal(WETH).approve(address(PERMIT2), MAX_WETH);
        IERC20Minimal(USDG).approve(address(PERMIT2), MAX_USDG);
        PERMIT2.approve(WETH, address(POSITION_MANAGER), uint160(MAX_WETH), uint48(block.timestamp + 30 days));
        PERMIT2.approve(USDG, address(POSITION_MANAGER), uint160(MAX_USDG), uint48(block.timestamp + 30 days));
        HOOK.initializePool(key, INITIAL_SQRT_PRICE_X96, config);
        createdPoolId = key.toId();
        // Do not report EasyPosm's pre-transaction nextTokenId prediction as the
        // minted ID: other mainnet mints can land between these broadcast calls.
        // Resolve the authoritative ID from PositionManager's Transfer event.
        POSITION_MANAGER.mint(
            key, TICK_LOWER, TICK_UPPER, liquidity, amount0 + 1, amount1 + 1, owner, block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        console2.logBytes32(PoolId.unwrap(createdPoolId));
        console2.log("Liquidity:", liquidity);
        console2.log("WETH budget used:", amount0 + 1);
        console2.log("USDG budget used:", amount1 + 1);
    }
}
