// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {DynamicFeeRebalanceHook} from "../src/DynamicFeeRebalanceHook.sol";
import {IReferencePriceOracle} from "../src/interfaces/IReferencePriceOracle.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract MockReferencePriceOracle is IReferencePriceOracle {
    uint256 public priceX18;
    uint256 public updatedAt;
    bool public marketOpen;

    function set(uint256 price, uint256 timestamp, bool isOpen) external {
        priceX18 = price;
        updatedAt = timestamp;
        marketOpen = isOpen;
    }

    function latestPriceX18() external view returns (uint256, uint256, bool) {
        return (priceX18, updatedAt, marketOpen);
    }
}

contract DynamicFeeRebalanceHookTest is BaseTest {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeRebalanceHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;
    Currency internal currency0;
    Currency internal currency1;
    uint256 internal tokenId;

    address internal constant ATTACKER = address(0xBEEF);

    MockReferencePriceOracle internal oracle;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address hookAddress = address(flags ^ uint160(0x4444 << 144));
        deployCodeTo(
            "contracts/src/DynamicFeeRebalanceHook.sol:DynamicFeeRebalanceHook", abi.encode(poolManager), hookAddress
        );
        hook = DynamicFeeRebalanceHook(hookAddress);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        oracle = new MockReferencePriceOracle();
    }

    function _config(bool autoFee, bool rebalance)
        internal
        view
        returns (DynamicFeeRebalanceHook.PoolConfig memory config)
    {
        config = DynamicFeeRebalanceHook.PoolConfig({
            minFeePips: 500,
            maxFeePips: 10_000,
            baseFeePips: 3_000,
            volatilityCoeff: 25,
            maxFeeStepPips: 2_000,
            autoFeeEnabled: autoFee,
            rebalanceUpEnabled: rebalance,
            rebalanceWidthTicks: 1_200,
            rebalanceTriggerBps: 100,
            feeRecipient: address(this),
            revenueCutBps: 500,
            poolOwner: address(this)
        });
    }

    function _initialize(bool autoFee, bool rebalance, bool addLiquidity) internal {
        hook.setPendingConfig(key, _config(autoFee, rebalance));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        if (addLiquidity) _addLiquidity();
    }

    function _oracleConfig(uint16 maxDeviationBps)
        internal
        view
        returns (DynamicFeeRebalanceHook.OracleConfig memory config)
    {
        config = DynamicFeeRebalanceHook.OracleConfig({
            oracle: address(oracle),
            maxAge: 1 hours,
            maxDeviationBps: maxDeviationBps,
            currency0Decimals: 18,
            currency1Decimals: 18,
            priceInverted: false
        });
    }

    function _addLiquidity() internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = 100e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        tokenId = positionManager.mint(
            key, tickLower, tickUpper, liquidity, amount0 + 1, amount1 + 1, address(this), block.timestamp
        );
    }

    function _addNarrowLiquidity() internal {
        uint128 liquidity = 10e18;
        int24 tickLower = -60;
        int24 tickUpper = 60;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        tokenId = positionManager.mint(
            key, tickLower, tickUpper, liquidity, amount0 + 1, amount1 + 1, address(this), block.timestamp
        );
    }

    function _swapExactInput(uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: bytes("untrusted-and-ignored"),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _swapExactInputOneForZero(uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: bytes("untrusted-and-ignored"),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testPendingConfigRejectsInvalidBounds() public {
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, false);
        config.maxFeePips = 999_999;
        vm.expectRevert(DynamicFeeRebalanceHook.InvalidConfig.selector);
        hook.setPendingConfig(key, config);

        config = _config(false, false);
        config.minFeePips = 4_000;
        config.maxFeePips = 3_000;
        vm.expectRevert(DynamicFeeRebalanceHook.InvalidConfig.selector);
        hook.setPendingConfig(key, config);
    }

    function testOracleGuardAcceptsMatchingInitialPriceAndReportsHealthy() public {
        vm.warp(10_000);
        oracle.set(1e18, block.timestamp, true);
        hook.setPendingConfigWithOracle(key, _config(false, true), _oracleConfig(100));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        (
            bool enabled,
            bool valid,
            uint256 referencePrice,
            uint256 poolPrice,
            uint256 updatedAt,
            bool open,
            uint256 deviation
        ) = hook.oracleStatus(key);
        assertTrue(enabled);
        assertTrue(valid);
        assertEq(referencePrice, 1e18);
        assertEq(poolPrice, 1e18);
        assertEq(updatedAt, block.timestamp);
        assertTrue(open);
        assertEq(deviation, 0);
    }

    function testOracleGuardRejectsManipulatedInitialPrice() public {
        vm.warp(10_000);
        oracle.set(2e18, block.timestamp, true);
        hook.setPendingConfigWithOracle(key, _config(false, false), _oracleConfig(100));
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function testOracleGuardRejectsStaleAndClosedInitialPrice() public {
        vm.warp(10_000);
        oracle.set(1e18, block.timestamp - 1 hours - 1, true);
        hook.setPendingConfigWithOracle(key, _config(false, false), _oracleConfig(100));
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        oracle.set(1e18, block.timestamp, false);
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function testStaleOracleNeverBlocksSwapsOrLiquidityExit() public {
        vm.warp(10_000);
        oracle.set(1e18, block.timestamp, true);
        hook.setPendingConfigWithOracle(key, _config(true, true), _oracleConfig(100));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _addLiquidity();

        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);
        _swapExactInput(1 ether);

        positionManager.decrease(tokenId, 1e18, currency0, currency1, address(this), block.timestamp);
    }

    function testOracleDeviationBlocksOnlyRebalanceSuggestion() public {
        vm.warp(10_000);
        oracle.set(1e18, block.timestamp, true);
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, true);
        config.rebalanceWidthTicks = 120;
        config.rebalanceTriggerBps = 100;
        hook.setPendingConfigWithOracle(key, config, _oracleConfig(1));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _addLiquidity();

        vm.roll(block.number + 1);
        _swapExactInputOneForZero(1 ether);
        vm.expectRevert(DynamicFeeRebalanceHook.OraclePriceDeviation.selector);
        hook.requestRebalanceUp(key);

        // The failed explicit suggestion does not poison normal pool operation.
        vm.roll(block.number + 1);
        _swapExactInput(0.1 ether);
    }

    function testPoolMayChooseNarrowerImmutableFeeBounds() public {
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, false);
        config.minFeePips = 1_000;
        config.baseFeePips = 2_000;
        config.maxFeePips = 4_000;
        hook.setPendingConfig(key, config);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        (uint24 minimum, uint24 maximum, uint24 base,,,,,,,,,) = hook.poolConfigs(poolId);
        assertEq(minimum, 1_000);
        assertEq(maximum, 4_000);
        assertEq(base, 2_000);

        config.maxFeePips = 5_000;
        vm.expectRevert(DynamicFeeRebalanceHook.InvalidConfig.selector);
        hook.setPoolConfig(key, config);
    }

    function testPendingConfigCannotBeConsumedByAnotherInitializer() public {
        hook.setPendingConfig(key, _config(false, false));
        vm.prank(ATTACKER);
        // PoolManager wraps hook callback errors; any successful consumption here is a security failure.
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        assertTrue(hook.isPoolConfigured(poolId));
    }

    function testAtomicInitializeConsumesConfigInOneTransaction() public {
        int24 tick = hook.initializePool(key, Constants.SQRT_PRICE_1_1, _config(false, false));

        assertEq(tick, 0);
        assertTrue(hook.isPoolConfigured(poolId));
        (,, address initializer,) = hook.pendingConfigs(poolId);
        assertEq(initializer, address(0));
        (,,,,,,,,, address recipient,, address owner) = hook.poolConfigs(poolId);
        assertEq(recipient, address(this));
        assertEq(owner, address(this));
    }

    function testAtomicInitializeSupersedesHostilePendingConfig() public {
        DynamicFeeRebalanceHook.PoolConfig memory attackerConfig = _config(false, false);
        attackerConfig.poolOwner = ATTACKER;
        attackerConfig.feeRecipient = ATTACKER;
        vm.prank(ATTACKER);
        hook.setPendingConfig(key, attackerConfig);

        hook.initializePool(key, Constants.SQRT_PRICE_1_1, _config(false, false));

        (,,,,,,,,, address recipient,, address owner) = hook.poolConfigs(poolId);
        assertEq(recipient, address(this));
        assertEq(owner, address(this));
    }

    function testAtomicInitializeRequiresCallerToBePoolOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(DynamicFeeRebalanceHook.NotPoolOwner.selector);
        hook.initializePool(key, Constants.SQRT_PRICE_1_1, _config(false, false));
    }

    function testAtomicInitializeRollbackOnOracleFailure() public {
        vm.warp(10_000);
        oracle.set(2e18, block.timestamp, true);

        vm.expectRevert();
        hook.initializePoolWithOracle(key, Constants.SQRT_PRICE_1_1, _config(false, false), _oracleConfig(100));

        assertFalse(hook.isPoolConfigured(poolId));
        (,, address initializer,) = hook.pendingConfigs(poolId);
        assertEq(initializer, address(0));
    }

    function testAtomicInitializeWithOracleAcceptsMatchingPrice() public {
        vm.warp(10_000);
        oracle.set(1e18, block.timestamp, true);

        hook.initializePoolWithOracle(key, Constants.SQRT_PRICE_1_1, _config(false, false), _oracleConfig(100));

        (bool enabled, bool valid,,,,,) = hook.oracleStatus(key);
        assertTrue(enabled);
        assertTrue(valid);
    }

    function testExpiredPendingConfigCannotInitializeAndMayBeReplaced() public {
        hook.setPendingConfig(key, _config(false, false));
        vm.roll(block.number + hook.PENDING_TTL_BLOCKS() + 1);
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        DynamicFeeRebalanceHook.PoolConfig memory attackerConfig = _config(false, false);
        attackerConfig.poolOwner = ATTACKER;
        attackerConfig.feeRecipient = ATTACKER;
        vm.startPrank(ATTACKER);
        hook.setPendingConfig(key, attackerConfig);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();
        (,,,,,,,,, address recipient,, address owner) = hook.poolConfigs(poolId);
        assertEq(recipient, ATTACKER);
        assertEq(owner, ATTACKER);
    }

    function testAfterInitializeStoresConfigAndSetsNonZeroDynamicFee() public {
        _initialize(false, false, false);
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 3_000);
        (,, uint24 baseFeePips,,,,,,,,,) = hook.poolConfigs(poolId);
        assertEq(baseFeePips, 3_000);
    }

    function testBeforeSwapAlwaysReturnsBaseFeeWhenAutoFeeDisabled() public {
        _initialize(false, false, false);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(address(poolManager));
        (, BeforeSwapDelta ignored, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(BeforeSwapDelta.unwrap(ignored), 0);
        assertEq(feeWithFlag, 3_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testAutoFeeUsesEmaAndLimitsSingleSwapStep() public {
        _initialize(true, false, true);
        vm.roll(block.number + 1);
        _swapExactInput(20 ether);

        (uint24 emaBefore, uint24 previousFee,,,,,) = hook.feeStates(poolId);
        assertGt(emaBefore, 0);
        _swapExactInput(1 ether);
        (, uint24 nextFee,,,,,) = hook.feeStates(poolId);
        assertGe(nextFee, previousFee);
        assertLe(nextFee - previousFee, 2_000);
        assertLe(nextFee, 10_000);
    }

    function testMaximumBusinessFeeIsAppliedWithOverrideFlag() public {
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, false);
        config.maxFeePips = 100_000;
        config.baseFeePips = 100_000;
        hook.setPendingConfig(key, config);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(address(poolManager));
        (,, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(feeWithFlag, 100_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testZeroLiquiditySwapProducesNoDeltaOrRevenue() public {
        _initialize(false, false, false);
        BalanceDelta delta = _swapExactInput(1 ether);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(hook.claimable(poolId, currency0.toId()), 0);
        assertEq(hook.claimable(poolId, currency1.toId()), 0);
    }

    function testPartialExactInputUsesRealizedDelta() public {
        _initialize(false, false, false);
        _addNarrowLiquidity();
        BalanceDelta delta = _swapExactInput(1_000 ether);
        uint256 actuallyConsumed = uint256(-int256(delta.amount0()));
        assertLt(actuallyConsumed, 1_000 ether);
        assertGt(hook.claimable(poolId, currency1.toId()), 0);
    }

    function testAfterSwapRevenueShareExactInputAndClaim() public {
        _initialize(false, false, true);
        BalanceDelta delta = _swapExactInput(10 ether);
        uint256 accrued = hook.claimable(poolId, currency1.toId());
        uint256 rawAmountOut = uint256(uint128(delta.amount1())) + accrued;
        uint256 expected = rawAmountOut * (3_000 * 500) / ((1_000_000 - 3_000) * 10_000);
        assertApproxEqAbs(accrued, expected, 2);
        assertGt(accrued, 0);

        uint256 recipientBefore = currency1.balanceOf(address(this));
        hook.claim(key);
        assertEq(currency1.balanceOf(address(this)), recipientBefore + accrued);
        assertEq(hook.claimable(poolId, currency1.toId()), 0);
    }

    function testAfterSwapRevenueShareExactOutput() public {
        _initialize(false, false, true);
        BalanceDelta delta = swapRouter.swapTokensForExactTokens({
            amountOut: 1 ether,
            amountInMax: 2 ether,
            zeroForOne: true,
            poolKey: key,
            hookData: bytes("ignored"),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 accrued = hook.claimable(poolId, currency0.toId());
        uint256 grossInput = uint256(-int256(delta.amount0())) - accrued;
        uint256 expected = grossInput * (3_000 * 500) / (1_000_000 * 10_000);
        assertApproxEqAbs(accrued, expected, 2);
    }

    function testOnlyOwnerCanUpdateConfig() public {
        _initialize(false, false, false);
        DynamicFeeRebalanceHook.PoolConfig memory next = _config(true, true);
        vm.prank(ATTACKER);
        vm.expectRevert(DynamicFeeRebalanceHook.NotPoolOwner.selector);
        hook.setPoolConfig(key, next);

        hook.setPoolConfig(key, next);
        (,,,,, bool autoFeeBefore,,,,,,) = hook.poolConfigs(poolId);
        assertFalse(autoFeeBefore);
        vm.expectRevert(DynamicFeeRebalanceHook.ConfigUpdateNotReady.selector);
        hook.executePoolConfig(key);

        vm.warp(block.timestamp + hook.CONFIG_UPDATE_DELAY());
        vm.prank(ATTACKER);
        hook.executePoolConfig(key);
        (,,,,, bool autoFeeEnabled, bool rebalanceEnabled,,,,,) = hook.poolConfigs(poolId);
        assertTrue(autoFeeEnabled);
        assertTrue(rebalanceEnabled);
    }

    function testQueuedConfigCanBeCancelledAndExpires() public {
        _initialize(false, false, false);
        DynamicFeeRebalanceHook.PoolConfig memory next = _config(true, false);
        hook.setPoolConfig(key, next);
        hook.cancelPoolConfigUpdate(key);
        vm.expectRevert(DynamicFeeRebalanceHook.ConfigUpdateMissing.selector);
        hook.executePoolConfig(key);

        hook.setPoolConfig(key, next);
        vm.warp(block.timestamp + hook.CONFIG_UPDATE_DELAY() + hook.CONFIG_UPDATE_GRACE_PERIOD() + 1);
        vm.expectRevert(DynamicFeeRebalanceHook.ConfigUpdateExpired.selector);
        hook.executePoolConfig(key);
    }

    function testPoolOwnershipTransferIsTwoStepAndInvalidatesQueuedConfig() public {
        _initialize(false, false, false);
        DynamicFeeRebalanceHook.PoolConfig memory next = _config(true, false);
        hook.setPoolConfig(key, next);

        hook.proposePoolOwner(key, ATTACKER);
        vm.prank(address(0xCAFE));
        vm.expectRevert(DynamicFeeRebalanceHook.NotPendingPoolOwner.selector);
        hook.acceptPoolOwnership(key);
        vm.prank(ATTACKER);
        hook.acceptPoolOwnership(key);

        (,,,,,,,,,,, address owner) = hook.poolConfigs(poolId);
        assertEq(owner, ATTACKER);
        vm.expectRevert(DynamicFeeRebalanceHook.ConfigUpdateMissing.selector);
        hook.executePoolConfig(key);
        vm.expectRevert(DynamicFeeRebalanceHook.NotPoolOwner.selector);
        hook.setPoolConfig(key, next);
    }

    function testOnlyOneVolatilityObservationPerBlock() public {
        _initialize(true, false, true);
        vm.roll(block.number + 1);
        _swapExactInput(1 ether);
        (uint24 firstEma,,,,,, uint64 observationBlock) = hook.feeStates(poolId);
        _swapExactInput(1 ether);
        (uint24 secondEma,,,,,, uint64 secondObservationBlock) = hook.feeStates(poolId);
        assertEq(secondEma, firstEma);
        assertEq(secondObservationBlock, observationBlock);
    }

    function testUpwardMoveAcrossObservationBlocksTriggersRebalanceSignal() public {
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, true);
        config.rebalanceWidthTicks = 120;
        config.rebalanceTriggerBps = 100;
        hook.setPendingConfig(key, config);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _addLiquidity();

        vm.roll(block.number + 1);
        _swapExactInputOneForZero(1 ether);

        (,, int24 lastTick, int24 referenceTick,, bool shouldRebalance,) = hook.feeStates(poolId);
        assertGt(lastTick, referenceTick);
        assertTrue(shouldRebalance);

        (int24 currentTick, int24 newTickLower, int24 newTickUpper) = hook.requestRebalanceUp(key);
        assertEq(newTickLower % key.tickSpacing, 0);
        assertEq(newTickUpper % key.tickSpacing, 0);
        assertLt(newTickLower, currentTick);
        assertGt(newTickUpper, currentTick);
        (,,, int24 nextReferenceTick,, bool signalAfterRequest,) = hook.feeStates(poolId);
        assertEq(nextReferenceTick, currentTick);
        assertFalse(signalAfterRequest);
    }

    function testDownwardMoveDoesNotTriggerUpwardRebalanceSignal() public {
        DynamicFeeRebalanceHook.PoolConfig memory config = _config(false, true);
        config.rebalanceWidthTicks = 120;
        config.rebalanceTriggerBps = 100;
        hook.setPendingConfig(key, config);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _addLiquidity();

        vm.roll(block.number + 1);
        _swapExactInput(1 ether);

        (,,,,, bool shouldRebalance,) = hook.feeStates(poolId);
        assertFalse(shouldRebalance);
        vm.expectRevert(DynamicFeeRebalanceHook.RebalanceNotReady.selector);
        hook.requestRebalanceUp(key);
    }

    function testUnlockCallbackRejectsUntrustedCaller() public {
        vm.expectRevert();
        hook.unlockCallback(bytes(""));
    }

    function testPoolStateIsIsolatedByPoolId() public {
        _initialize(false, false, false);
        (Currency other0, Currency other1) = deployCurrencyPair();
        PoolKey memory otherKey = PoolKey(other0, other1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId otherPoolId = otherKey.toId();
        DynamicFeeRebalanceHook.PoolConfig memory otherConfig = _config(true, false);
        otherConfig.baseFeePips = 9_000;
        hook.setPendingConfig(otherKey, otherConfig);
        poolManager.initialize(otherKey, Constants.SQRT_PRICE_1_1);

        (,, uint24 firstBase,,,,,,,,,) = hook.poolConfigs(poolId);
        (,, uint24 secondBase,,,,,,,,,) = hook.poolConfigs(otherPoolId);
        assertEq(firstBase, 3_000);
        assertEq(secondBase, 9_000);
        assertNotEq(PoolId.unwrap(poolId), PoolId.unwrap(otherPoolId));
    }

    function testRebalanceDisabledReverts() public {
        _initialize(false, false, false);
        vm.expectRevert(DynamicFeeRebalanceHook.RebalanceDisabled.selector);
        hook.requestRebalanceUp(key);
    }

    function testPermissionBitsMatchAndRemovalCannotBeBlocked() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);

        uint160 expected = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & uint160((1 << 14) - 1), expected);

        _initialize(false, false, true);
        positionManager.decrease(tokenId, 1 ether, currency0, currency1, address(this), block.timestamp);
    }
}
