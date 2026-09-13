// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IReferencePriceOracle} from "./interfaces/IReferencePriceOracle.sol";

/// @title DynamicFeeRebalanceHook
/// @notice A non-upgradeable, multi-pool Uniswap v4 hook with bounded volatility fees,
///         a revenue share calculated from the LP-fee estimate, and non-custodial
///         upward-rebalance signals.
/// @dev The hook never owns PositionManager NFTs. Revenue is held as PoolManager
///      ERC-6909 claims and redeemed only from the separate claim path.
contract DynamicFeeRebalanceHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant MIN_FEE_PIPS = 500;
    // Production guardrails: the hook can never charge more than 10% LP fee and
    // can never move the fee by more than 20 bps per observed block.
    uint24 public constant MAX_FEE_PIPS = 100_000;
    uint24 public constant MAX_VOLATILITY_COEFF = 10_000;
    uint24 public constant MAX_FEE_STEP_PIPS = 2_000;
    uint24 public constant MAX_REBALANCE_WIDTH_TICKS = 500_000;
    uint24 public constant MAX_REBALANCE_TRIGGER_BPS = 10_000;
    uint16 public constant MAX_REVENUE_CUT_BPS = 1_000;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint24 public constant FEE_DENOMINATOR = 1_000_000;
    uint64 public constant PENDING_TTL_BLOCKS = 20;
    uint64 public constant CONFIG_UPDATE_DELAY = 1 days;
    uint64 public constant CONFIG_UPDATE_GRACE_PERIOD = 7 days;
    uint32 public constant MAX_ORACLE_AGE = 7 days;
    uint16 public constant MAX_ORACLE_DEVIATION_BPS = 5_000;
    uint256 private constant MAX_INT128 = uint256(uint128(type(int128).max));

    struct PoolConfig {
        uint24 minFeePips;
        uint24 maxFeePips;
        uint24 baseFeePips;
        uint24 volatilityCoeff;
        uint24 maxFeeStepPips;
        bool autoFeeEnabled;
        bool rebalanceUpEnabled;
        uint24 rebalanceWidthTicks;
        uint24 rebalanceTriggerBps;
        address feeRecipient;
        uint16 revenueCutBps;
        address poolOwner;
    }

    struct PendingConfig {
        PoolConfig config;
        OracleConfig oracleConfig;
        address initializer;
        uint64 validUntilBlock;
    }

    /// @notice Immutable per-pool oracle guard. The oracle is deliberately not
    ///         consulted in swap or liquidity callbacks, so a failed feed can
    ///         never freeze trading or LP withdrawals.
    struct OracleConfig {
        address oracle;
        uint32 maxAge;
        uint16 maxDeviationBps;
        uint8 currency0Decimals;
        uint8 currency1Decimals;
        bool priceInverted;
    }

    struct FeeState {
        uint24 emaTickMovement;
        uint24 lastEffectiveFeePips;
        int24 lastTick;
        int24 rebalanceReferenceTick;
        bool hasObservation;
        bool shouldRebalanceUp;
        uint64 lastObservationBlock;
    }

    struct QueuedPoolConfig {
        PoolConfig config;
        address proposer;
        uint64 executeAfter;
        uint64 expiresAt;
    }

    struct ClaimData {
        Currency currency0;
        Currency currency1;
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    error InvalidHook();
    error InvalidDynamicFeePool();
    error InvalidCurrencyOrder();
    error InvalidConfig();
    error InvalidTickSpacing();
    error NotPoolOwner();
    error PoolAlreadyConfigured();
    error PendingConfigExists();
    error PendingConfigMissing();
    error PendingConfigExpired();
    error WrongInitializer();
    error RebalanceDisabled();
    error RebalanceNotReady();
    error NothingToClaim();
    error ClaimAlreadyInProgress();
    error InvalidUnlockCallback();
    error ConfigUpdateMissing();
    error ConfigUpdateNotReady();
    error ConfigUpdateExpired();
    error InvalidPoolOwnerTransfer();
    error NotPendingPoolOwner();
    error InvalidOracleConfig();
    error OracleUnavailable();
    error OraclePriceStale();
    error OracleMarketClosed();
    error OraclePriceDeviation();

    event PendingConfigSet(PoolId indexed poolId, address indexed initializer, uint64 validUntilBlock);
    event PendingConfigCancelled(PoolId indexed poolId, address indexed initializer);
    event PoolConfigured(PoolId indexed poolId, address indexed poolOwner, address indexed feeRecipient);
    event ConfigUpdateQueued(PoolId indexed poolId, address indexed poolOwner, uint64 executeAfter, uint64 expiresAt);
    event ConfigUpdateCancelled(PoolId indexed poolId, address indexed poolOwner);
    event ConfigUpdated(PoolId indexed poolId, address indexed executor);
    event PoolOwnerTransferStarted(PoolId indexed poolId, address indexed currentOwner, address indexed pendingOwner);
    event PoolOwnerTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
    event DynamicFeeApplied(PoolId indexed poolId, uint24 feePips, uint24 emaTickMovement);
    event FeeSkimmed(
        PoolId indexed poolId, address indexed recipient, Currency indexed currency, uint256 amount, uint16 cutBps
    );
    event RevenueClaimed(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);
    event RebalanceUpSuggested(PoolId indexed poolId, int24 currentTick, int24 newTickLower, int24 newTickUpper);
    event OracleGuardConfigured(
        PoolId indexed poolId, address indexed oracle, uint32 maxAge, uint16 maxDeviationBps, bool priceInverted
    );

    mapping(PoolId poolId => PoolConfig config) public poolConfigs;
    mapping(PoolId poolId => PendingConfig pending) public pendingConfigs;
    mapping(PoolId poolId => FeeState state) public feeStates;
    mapping(PoolId poolId => mapping(uint256 currencyId => uint256 amount)) public claimable;
    mapping(PoolId poolId => bool configured) public isPoolConfigured;
    mapping(PoolId poolId => QueuedPoolConfig queued) public queuedPoolConfigs;
    mapping(PoolId poolId => address pendingOwner) public pendingPoolOwners;
    mapping(PoolId poolId => OracleConfig config) public oracleConfigs;

    bool private claimInProgress;

    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Stages configuration for a pool initialization by the same caller.
    /// @dev Binding the initializer closes the public-mempool configuration theft described
    ///      by a naive two-transaction setPendingConfig/initialize flow.
    function setPendingConfig(PoolKey calldata key, PoolConfig calldata config) external {
        OracleConfig memory disabledOracle;
        _setPendingConfig(key, config, disabledOracle);
    }

    /// @notice Stages pool configuration with an immutable external reference-price guard.
    /// @dev The guard validates initialization and explicit rebalance suggestions only.
    function setPendingConfigWithOracle(
        PoolKey calldata key,
        PoolConfig calldata config,
        OracleConfig calldata oracleConfig
    ) external {
        _setPendingConfig(key, config, oracleConfig);
    }

    /// @notice Atomically binds configuration and initializes a pool.
    /// @dev This is the production entry point. It removes the public-mempool gap between
    ///      `setPendingConfig` and `PoolManager.initialize`, and supersedes any stale or
    ///      adversarial pending configuration immediately before consuming it.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, PoolConfig calldata config)
        external
        returns (int24 tick)
    {
        OracleConfig memory disabledOracle;
        return _initializePool(key, sqrtPriceX96, config, disabledOracle);
    }

    /// @notice Atomically binds an immutable oracle guard and initializes a pool.
    function initializePoolWithOracle(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        PoolConfig calldata config,
        OracleConfig calldata oracleConfig
    ) external returns (int24 tick) {
        return _initializePool(key, sqrtPriceX96, config, oracleConfig);
    }

    function _initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        PoolConfig calldata config,
        OracleConfig memory oracleConfig
    ) internal returns (int24 tick) {
        PoolId poolId = _validateInitializationConfig(key, config, oracleConfig);

        // Uniswap v4 deliberately skips hook callbacks when the hook itself initiates
        // the PoolManager action. Persist the validated configuration directly after
        // initialization; any later failure still rolls the whole transaction back.
        tick = poolManager.initialize(key, sqrtPriceX96);
        _storeInitializedPool(poolId, key, sqrtPriceX96, tick, config, oracleConfig);
    }

    function _setPendingConfig(PoolKey calldata key, PoolConfig calldata config, OracleConfig memory oracleConfig)
        internal
    {
        PoolId poolId = _validateInitializationConfig(key, config, oracleConfig);

        PendingConfig storage current = pendingConfigs[poolId];
        if (
            current.initializer != address(0) && current.initializer != msg.sender
                && block.number <= current.validUntilBlock
        ) revert PendingConfigExists();

        uint64 validUntil = uint64(block.number) + PENDING_TTL_BLOCKS;
        pendingConfigs[poolId] = PendingConfig(config, oracleConfig, msg.sender, validUntil);
        emit PendingConfigSet(poolId, msg.sender, validUntil);
    }

    function _validateInitializationConfig(
        PoolKey calldata key,
        PoolConfig calldata config,
        OracleConfig memory oracleConfig
    ) internal view returns (PoolId poolId) {
        poolId = _validatePoolKey(key);
        if (isPoolConfigured[poolId]) revert PoolAlreadyConfigured();
        if (config.poolOwner != msg.sender) revert NotPoolOwner();
        _validateConfig(key.tickSpacing, config);
        _validateOracleConfig(oracleConfig);
    }

    function cancelPendingConfig(PoolKey calldata key) external {
        PoolId poolId = _validatePoolKey(key);
        PendingConfig storage pending = pendingConfigs[poolId];
        if (pending.initializer != msg.sender) revert WrongInitializer();
        delete pendingConfigs[poolId];
        emit PendingConfigCancelled(poolId, msg.sender);
    }

    /// @notice Queues a configuration update. The existing function name is retained for
    ///         client compatibility, but updates no longer take effect immediately.
    function setPoolConfig(PoolKey calldata key, PoolConfig calldata next) external {
        PoolId poolId = _requireConfiguredPool(key);
        PoolConfig storage current = poolConfigs[poolId];
        if (msg.sender != current.poolOwner) revert NotPoolOwner();
        if (
            next.minFeePips != current.minFeePips || next.maxFeePips != current.maxFeePips
                || next.poolOwner != current.poolOwner
        ) {
            revert InvalidConfig();
        }
        _validateConfig(key.tickSpacing, next);

        uint64 executeAfter = uint64(block.timestamp) + CONFIG_UPDATE_DELAY;
        uint64 expiresAt = executeAfter + CONFIG_UPDATE_GRACE_PERIOD;
        queuedPoolConfigs[poolId] = QueuedPoolConfig(next, msg.sender, executeAfter, expiresAt);
        emit ConfigUpdateQueued(poolId, msg.sender, executeAfter, expiresAt);
    }

    function cancelPoolConfigUpdate(PoolKey calldata key) external {
        PoolId poolId = _requireConfiguredPool(key);
        if (msg.sender != poolConfigs[poolId].poolOwner) revert NotPoolOwner();
        if (queuedPoolConfigs[poolId].proposer == address(0)) revert ConfigUpdateMissing();
        delete queuedPoolConfigs[poolId];
        emit ConfigUpdateCancelled(poolId, msg.sender);
    }

    function executePoolConfig(PoolKey calldata key) external {
        PoolId poolId = _requireConfiguredPool(key);
        PoolConfig storage current = poolConfigs[poolId];
        QueuedPoolConfig storage queued = queuedPoolConfigs[poolId];
        if (queued.proposer == address(0) || queued.proposer != current.poolOwner) revert ConfigUpdateMissing();
        if (block.timestamp < queued.executeAfter) revert ConfigUpdateNotReady();
        if (block.timestamp > queued.expiresAt) revert ConfigUpdateExpired();

        PoolConfig memory next = queued.config;
        if (next.poolOwner != current.poolOwner) revert InvalidConfig();
        delete queuedPoolConfigs[poolId];
        poolConfigs[poolId] = next;

        FeeState storage state = feeStates[poolId];
        state.lastEffectiveFeePips = _clampFee(next.baseFeePips, next.minFeePips, next.maxFeePips);
        poolManager.updateDynamicLPFee(key, state.lastEffectiveFeePips);

        emit ConfigUpdated(poolId, msg.sender);
    }

    function proposePoolOwner(PoolKey calldata key, address nextOwner) external {
        PoolId poolId = _requireConfiguredPool(key);
        address currentOwner = poolConfigs[poolId].poolOwner;
        if (msg.sender != currentOwner) revert NotPoolOwner();
        if (nextOwner == address(0) || nextOwner == currentOwner) revert InvalidPoolOwnerTransfer();
        pendingPoolOwners[poolId] = nextOwner;
        emit PoolOwnerTransferStarted(poolId, currentOwner, nextOwner);
    }

    function acceptPoolOwnership(PoolKey calldata key) external {
        PoolId poolId = _requireConfiguredPool(key);
        address nextOwner = pendingPoolOwners[poolId];
        if (msg.sender != nextOwner) revert NotPendingPoolOwner();
        address previousOwner = poolConfigs[poolId].poolOwner;
        delete pendingPoolOwners[poolId];
        delete queuedPoolConfigs[poolId];
        poolConfigs[poolId].poolOwner = nextOwner;
        emit PoolOwnerTransferred(poolId, previousOwner, nextOwner);
    }

    function cancelPoolOwnerTransfer(PoolKey calldata key) external {
        PoolId poolId = _requireConfiguredPool(key);
        if (msg.sender != poolConfigs[poolId].poolOwner) revert NotPoolOwner();
        if (pendingPoolOwners[poolId] == address(0)) revert InvalidPoolOwnerTransfer();
        delete pendingPoolOwners[poolId];
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = _validatePoolKey(key);
        if (isPoolConfigured[poolId]) revert PoolAlreadyConfigured();

        PendingConfig storage pending = pendingConfigs[poolId];
        if (pending.initializer == address(0)) revert PendingConfigMissing();
        if (block.number > pending.validUntilBlock) revert PendingConfigExpired();
        if (sender != pending.initializer) revert WrongInitializer();

        PoolConfig memory config = pending.config;
        OracleConfig memory oracleConfig = pending.oracleConfig;
        _validateConfig(key.tickSpacing, config);
        _storeInitializedPool(poolId, key, sqrtPriceX96, tick, config, oracleConfig);
        return BaseHook.afterInitialize.selector;
    }

    function _storeInitializedPool(
        PoolId poolId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        PoolConfig memory config,
        OracleConfig memory oracleConfig
    ) internal {
        _assertOraclePrice(oracleConfig, sqrtPriceX96);
        poolConfigs[poolId] = config;
        oracleConfigs[poolId] = oracleConfig;
        isPoolConfigured[poolId] = true;
        delete pendingConfigs[poolId];

        feeStates[poolId] = FeeState({
            emaTickMovement: 0,
            lastEffectiveFeePips: config.baseFeePips,
            lastTick: tick,
            rebalanceReferenceTick: tick,
            hasObservation: true,
            shouldRebalanceUp: false,
            lastObservationBlock: uint64(block.number)
        });

        // Dynamic pools start with zero LP fee. This call is required before the first swap.
        poolManager.updateDynamicLPFee(key, config.baseFeePips);
        emit PoolConfigured(poolId, config.poolOwner, config.feeRecipient);
        if (oracleConfig.oracle != address(0)) {
            emit OracleGuardConfigured(
                poolId,
                oracleConfig.oracle,
                oracleConfig.maxAge,
                oracleConfig.maxDeviationBps,
                oracleConfig.priceInverted
            );
        }
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = _requireConfiguredPool(key);
        PoolConfig storage config = poolConfigs[poolId];
        FeeState storage state = feeStates[poolId];

        uint24 nextFee = config.baseFeePips;
        if (config.autoFeeEnabled) {
            uint256 candidate = uint256(config.baseFeePips) + uint256(state.emaTickMovement) * config.volatilityCoeff;
            if (candidate > config.maxFeePips) candidate = config.maxFeePips;
            nextFee = uint24(candidate);

            uint24 previous = state.lastEffectiveFeePips;
            uint24 maxStep = config.maxFeeStepPips;
            if (nextFee > previous && nextFee - previous > maxStep) nextFee = previous + maxStep;
            if (previous > nextFee && previous - nextFee > maxStep) nextFee = previous - maxStep;
        }

        nextFee = _clampFee(nextFee, config.minFeePips, config.maxFeePips);
        state.lastEffectiveFeePips = nextFee;
        emit DynamicFeeApplied(poolId, nextFee, state.emaTickMovement);

        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, nextFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = _requireConfiguredPool(key);
        PoolConfig storage config = poolConfigs[poolId];
        FeeState storage state = feeStates[poolId];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 previousObservedTick = state.lastTick;

        // At most one volatility observation per block. This prevents a single bundled
        // transaction from compounding the EMA through repeated swaps across this hook.
        if (state.hasObservation && block.number > state.lastObservationBlock) {
            uint256 movement = _absoluteTickDelta(currentTick, state.lastTick);
            if (movement > uint256(uint24(type(uint24).max))) movement = uint256(uint24(type(uint24).max));
            state.emaTickMovement = uint24((uint256(state.emaTickMovement) * 7 + movement) / 8);
            state.lastTick = currentTick;
            state.lastObservationBlock = uint64(block.number);
        } else {
            state.hasObservation = true;
        }

        // Compare with the observation captured before mutating `lastTick`. Updating the
        // observation first made every cross-block comparison equal and suppressed valid
        // upward-rebalance signals.
        if (config.rebalanceUpEnabled && currentTick > previousObservedTick) {
            uint256 advance = _absoluteTickDelta(currentTick, state.rebalanceReferenceTick);
            // One Uniswap tick is approximately one basis point of price movement. Treat the
            // configured bps as a conservative whole-tick proximity window; the UI performs the
            // exact position-specific preview before the user signs any rebalance transaction.
            uint256 threshold = config.rebalanceWidthTicks > config.rebalanceTriggerBps
                ? config.rebalanceWidthTicks - config.rebalanceTriggerBps
                : 0;
            if (advance >= threshold) state.shouldRebalanceUp = true;
        }
        uint256 cut = _calculateRevenueCut(params, delta, state.lastEffectiveFeePips, config.revenueCutBps);
        if (cut == 0) return (BaseHook.afterSwap.selector, 0);
        if (cut > MAX_INT128) cut = MAX_INT128;

        Currency feeCurrency = _unspecifiedCurrency(key, params);
        poolManager.mint(address(this), feeCurrency.toId(), cut);
        claimable[poolId][feeCurrency.toId()] += cut;
        emit FeeSkimmed(poolId, config.feeRecipient, feeCurrency, cut, config.revenueCutBps);
        return (BaseHook.afterSwap.selector, int128(int256(cut)));
    }

    /// @notice Emits a non-custodial upward-rebalance suggestion. The caller remains responsible
    ///         for decreasing and minting their PositionManager NFT with slippage limits.
    function requestRebalanceUp(PoolKey calldata key)
        external
        returns (int24 currentTick, int24 newTickLower, int24 newTickUpper)
    {
        PoolId poolId = _requireConfiguredPool(key);
        PoolConfig storage config = poolConfigs[poolId];
        FeeState storage state = feeStates[poolId];
        if (msg.sender != config.poolOwner) revert NotPoolOwner();
        if (!config.rebalanceUpEnabled) revert RebalanceDisabled();
        if (!state.shouldRebalanceUp) revert RebalanceNotReady();

        (uint160 sqrtPriceX96, int24 observedTick,,) = poolManager.getSlot0(poolId);
        currentTick = observedTick;
        _assertOraclePrice(oracleConfigs[poolId], sqrtPriceX96);
        int24 minUsable = TickMath.minUsableTick(key.tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(key.tickSpacing);
        int256 proposedLower = int256(currentTick) - int256(uint256(config.rebalanceWidthTicks));
        if (proposedLower < minUsable) proposedLower = minUsable;
        newTickLower = _floorToSpacing(int24(proposedLower), key.tickSpacing);
        int256 proposedUpper = int256(newTickLower) + int256(uint256(config.rebalanceWidthTicks)) * 2;
        if (proposedUpper > maxUsable) {
            newTickUpper = maxUsable;
            newTickLower = maxUsable - int24(int256(uint256(config.rebalanceWidthTicks)) * 2);
            newTickLower = _floorToSpacing(newTickLower, key.tickSpacing);
        } else {
            newTickUpper = int24(proposedUpper);
        }

        state.shouldRebalanceUp = false;
        state.rebalanceReferenceTick = currentTick;
        emit RebalanceUpSuggested(poolId, currentTick, newTickLower, newTickUpper);
    }

    /// @notice Redeems both pool-currency ERC-6909 revenue claims to the configured recipient.
    /// @dev A failing or rejecting token can only revert this explicit claim call, never a swap.
    function claim(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = _requireConfiguredPool(key);
        if (claimInProgress) revert ClaimAlreadyInProgress();

        PoolConfig storage config = poolConfigs[poolId];
        address recipient = config.feeRecipient;
        amount0 = claimable[poolId][key.currency0.toId()];
        amount1 = claimable[poolId][key.currency1.toId()];
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim();

        claimable[poolId][key.currency0.toId()] = 0;
        claimable[poolId][key.currency1.toId()] = 0;
        claimInProgress = true;
        bytes memory callbackResult = poolManager.unlock(
            abi.encode(
                ClaimData({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    recipient: recipient,
                    amount0: amount0,
                    amount1: amount1
                })
            )
        );
        if (callbackResult.length != 0) revert InvalidUnlockCallback();
        claimInProgress = false;
        emit RevenueClaimed(poolId, recipient, amount0, amount1);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!claimInProgress) revert InvalidUnlockCallback();
        ClaimData memory claimData = abi.decode(data, (ClaimData));

        if (claimData.amount0 != 0) {
            poolManager.burn(address(this), claimData.currency0.toId(), claimData.amount0);
            poolManager.take(claimData.currency0, claimData.recipient, claimData.amount0);
        }
        if (claimData.amount1 != 0) {
            poolManager.burn(address(this), claimData.currency1.toId(), claimData.amount1);
            poolManager.take(claimData.currency1, claimData.recipient, claimData.amount1);
        }
        return bytes("");
    }

    /// @notice Returns live oracle health without reverting, for user interfaces and keepers.
    function oracleStatus(PoolKey calldata key)
        external
        view
        returns (
            bool enabled,
            bool valid,
            uint256 referencePriceX18,
            uint256 poolPriceX18,
            uint256 updatedAt,
            bool marketOpen,
            uint256 deviationBps
        )
    {
        PoolId poolId = _requireConfiguredPool(key);
        OracleConfig memory config = oracleConfigs[poolId];
        enabled = config.oracle != address(0);
        if (!enabled) return (false, true, 0, 0, 0, true, 0);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        poolPriceX18 = _poolPriceX18(sqrtPriceX96, config.currency0Decimals, config.currency1Decimals);
        try IReferencePriceOracle(config.oracle).latestPriceX18() returns (
            uint256 reportedPrice, uint256 reportedAt, bool reportedMarketOpen
        ) {
            referencePriceX18 =
                config.priceInverted && reportedPrice != 0 ? FullMath.mulDiv(1e18, 1e18, reportedPrice) : reportedPrice;
            updatedAt = reportedAt;
            marketOpen = reportedMarketOpen;
            if (referencePriceX18 != 0) {
                deviationBps = FullMath.mulDiv(
                    poolPriceX18 > referencePriceX18
                        ? poolPriceX18 - referencePriceX18
                        : referencePriceX18 - poolPriceX18,
                    BPS_DENOMINATOR,
                    referencePriceX18
                );
            }
            valid = referencePriceX18 != 0 && updatedAt != 0 && updatedAt <= block.timestamp
                && block.timestamp - updatedAt <= config.maxAge && marketOpen && deviationBps <= config.maxDeviationBps;
        } catch {
            valid = false;
        }
    }

    function _validatePoolKey(PoolKey calldata key) internal view returns (PoolId poolId) {
        if (address(key.hooks) != address(this)) revert InvalidHook();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert InvalidDynamicFeePool();
        if (!(key.currency0 < key.currency1)) revert InvalidCurrencyOrder();
        if (key.tickSpacing <= 0 || key.tickSpacing > TickMath.MAX_TICK_SPACING) revert InvalidTickSpacing();
        poolId = key.toId();
    }

    function _requireConfiguredPool(PoolKey calldata key) internal view returns (PoolId poolId) {
        poolId = _validatePoolKey(key);
        if (!isPoolConfigured[poolId]) revert PendingConfigMissing();
    }

    function _validateConfig(int24 tickSpacing, PoolConfig memory config) internal pure {
        // Each pool may choose a narrower immutable fee band, while the hook-level
        // floor and ceiling remain hard safety limits shared by every pool.
        if (
            config.minFeePips < MIN_FEE_PIPS || config.maxFeePips > MAX_FEE_PIPS
                || config.minFeePips > config.maxFeePips
        ) revert InvalidConfig();
        if (config.baseFeePips < config.minFeePips || config.baseFeePips > config.maxFeePips) revert InvalidConfig();
        if (config.volatilityCoeff > MAX_VOLATILITY_COEFF) revert InvalidConfig();
        if (config.maxFeeStepPips > MAX_FEE_STEP_PIPS) revert InvalidConfig();
        if (config.autoFeeEnabled && config.maxFeeStepPips == 0) revert InvalidConfig();
        if (config.feeRecipient == address(0) || config.poolOwner == address(0)) revert InvalidConfig();
        if (config.revenueCutBps > MAX_REVENUE_CUT_BPS) revert InvalidConfig();
        if (
            config.rebalanceWidthTicks == 0 || config.rebalanceWidthTicks > MAX_REBALANCE_WIDTH_TICKS
                || config.rebalanceWidthTicks % uint24(tickSpacing) != 0
        ) revert InvalidConfig();
        if (config.rebalanceTriggerBps == 0 || config.rebalanceTriggerBps > MAX_REBALANCE_TRIGGER_BPS) {
            revert InvalidConfig();
        }
    }

    function _validateOracleConfig(OracleConfig memory config) internal view {
        if (config.oracle == address(0)) {
            if (
                config.maxAge != 0 || config.maxDeviationBps != 0 || config.currency0Decimals != 0
                    || config.currency1Decimals != 0 || config.priceInverted
            ) revert InvalidOracleConfig();
            return;
        }
        if (
            config.oracle.code.length == 0 || config.maxAge == 0 || config.maxAge > MAX_ORACLE_AGE
                || config.maxDeviationBps == 0 || config.maxDeviationBps > MAX_ORACLE_DEVIATION_BPS
                || config.currency0Decimals > 18 || config.currency1Decimals > 18
        ) revert InvalidOracleConfig();
    }

    function _assertOraclePrice(OracleConfig memory config, uint160 sqrtPriceX96) internal view {
        if (config.oracle == address(0)) return;
        uint256 reportedPrice;
        uint256 updatedAt;
        bool marketOpen;
        try IReferencePriceOracle(config.oracle).latestPriceX18() returns (
            uint256 price, uint256 timestamp, bool isOpen
        ) {
            reportedPrice = price;
            updatedAt = timestamp;
            marketOpen = isOpen;
        } catch {
            revert OracleUnavailable();
        }
        if (reportedPrice == 0 || updatedAt == 0 || updatedAt > block.timestamp) revert OracleUnavailable();
        if (block.timestamp - updatedAt > config.maxAge) revert OraclePriceStale();
        if (!marketOpen) revert OracleMarketClosed();
        if (config.priceInverted) reportedPrice = FullMath.mulDiv(1e18, 1e18, reportedPrice);

        uint256 poolPrice = _poolPriceX18(sqrtPriceX96, config.currency0Decimals, config.currency1Decimals);
        uint256 deviation = FullMath.mulDiv(
            poolPrice > reportedPrice ? poolPrice - reportedPrice : reportedPrice - poolPrice,
            BPS_DENOMINATOR,
            reportedPrice
        );
        if (deviation > config.maxDeviationBps) revert OraclePriceDeviation();
    }

    function _poolPriceX18(uint160 sqrtPriceX96, uint8 currency0Decimals, uint8 currency1Decimals)
        internal
        pure
        returns (uint256)
    {
        uint256 ratioX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        return FullMath.mulDiv(
            ratioX96, 1e18 * (10 ** uint256(currency0Decimals)), (1 << 96) * (10 ** uint256(currency1Decimals))
        );
    }

    function _calculateRevenueCut(
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 lpFeePips,
        uint16 revenueCutBps
    ) internal pure returns (uint256) {
        if (revenueCutBps == 0 || lpFeePips == 0) return 0;
        bool exactInput = params.amountSpecified < 0;
        if (exactInput) {
            // afterSwap can only charge the unspecified output currency for exact-input swaps.
            // Convert the input-denominated LP fee into output units using the realized output.
            int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (outputDelta <= 0 || lpFeePips >= FEE_DENOMINATOR) return 0;
            return FullMath.mulDiv(
                uint256(uint128(outputDelta)),
                uint256(lpFeePips) * revenueCutBps,
                uint256(FEE_DENOMINATOR - lpFeePips) * BPS_DENOMINATOR
            );
        } else {
            // For exact-output swaps the unspecified currency is input; the actual gross input
            // delta includes the LP fee, so fee = grossInput * feePips / 1e6.
            int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
            if (inputDelta >= 0) return 0;
            uint256 grossInput = uint256(-int256(inputDelta));
            return
                FullMath.mulDiv(
                    grossInput, uint256(lpFeePips) * revenueCutBps, uint256(FEE_DENOMINATOR) * BPS_DENOMINATOR
                );
        }
    }

    function _unspecifiedCurrency(PoolKey calldata key, SwapParams calldata params) internal pure returns (Currency) {
        bool exactInput = params.amountSpecified < 0;
        return (exactInput == params.zeroForOne) ? key.currency1 : key.currency0;
    }

    function _clampFee(uint24 fee, uint24 minimum, uint24 maximum) internal pure returns (uint24) {
        if (fee < minimum) return minimum;
        if (fee > maximum) return maximum;
        return fee;
    }

    function _absoluteTickDelta(int24 a, int24 b) internal pure returns (uint256) {
        int256 difference = int256(a) - int256(b);
        return uint256(difference < 0 ? -difference : difference);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}
