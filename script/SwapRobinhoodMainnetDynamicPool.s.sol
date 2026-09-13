// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";

import {DynamicFeeRebalanceHook} from "../src/DynamicFeeRebalanceHook.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The Robinhood mainnet Universal Router uses the newer v4-periphery
/// ExactInputSingleParams layout. Keep the ABI local so this smoke test stays
/// compatible with the project's older pinned v4-periphery dependency.
struct MainnetExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// @notice Executes one bounded exact-input swap through the exact production smoke-test PoolKey.
contract SwapRobinhoodMainnetDynamicPool is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    IUniversalRouter internal constant UNIVERSAL_ROUTER = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    DynamicFeeRebalanceHook internal constant HOOK =
        DynamicFeeRebalanceHook(0xC538C832BF24e2bC53EB19dECEFa0BCFD59Dd0C4);

    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint128 internal constant WETH_INPUT = 0.000005 ether;
    uint128 internal constant USDG_INPUT = 10_000;

    function run() external returns (uint256 quotedAmountOut, uint24 feeBefore) {
        require(block.chainid == 4663, "mainnet only");
        address owner = vm.envAddress("DEPLOYER");
        require(owner == 0xf7E7da333d6949adBDBb39Fd2C744CA116C8DDa3, "unexpected owner");
        bool zeroForOne = vm.envBool("ZERO_FOR_ONE");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(HOOK))
        });
        require(HOOK.isPoolConfigured(key.toId()), "pool not configured");

        uint128 amountIn = zeroForOne ? WETH_INPUT : USDG_INPUT;
        address tokenIn = zeroForOne ? WETH : USDG;
        (, feeBefore,,,,) = _feeState(key);
        (quotedAmountOut,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: bytes("")
            })
        );
        require(quotedAmountOut != 0, "zero quote");

        MainnetExactInputSingleParams memory params = MainnetExactInputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: uint128(quotedAmountOut * 95 / 100),
            minHopPriceX36: 0,
            hookData: bytes("")
        });
        Plan memory plan = Planner.init().add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(
            zeroForOne ? key.currency0 : key.currency1,
            zeroForOne ? key.currency1 : key.currency0,
            ActionConstants.MSG_SENDER
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        vm.startBroadcast();
        IERC20Minimal(tokenIn).approve(address(PERMIT2), amountIn);
        PERMIT2.approve(tokenIn, address(UNIVERSAL_ROUTER), amountIn, uint48(block.timestamp + 1 days));
        UNIVERSAL_ROUTER.execute(hex"10", inputs, block.timestamp + 20 minutes);
        vm.stopBroadcast();

        console2.log("Direction zeroForOne:", zeroForOne);
        console2.log("Input:", amountIn);
        console2.log("Quoted output:", quotedAmountOut);
        console2.log("Fee before E6:", feeBefore);
    }

    function _feeState(PoolKey memory key)
        private
        view
        returns (uint24 ema, uint24 fee, int24 tick, int24 referenceTick, bool observed, bool signal)
    {
        (ema, fee, tick, referenceTick, observed, signal,) = HOOK.feeStates(key.toId());
    }
}
