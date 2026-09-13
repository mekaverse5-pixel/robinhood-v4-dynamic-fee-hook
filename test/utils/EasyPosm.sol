// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

library EasyPosm {
    using CurrencyLibrary for Currency;

    function mint(
        IPositionManager posm,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 tokenId) {
        bytes[] memory params = new bytes[](4);
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, recipient);
        params[3] = abi.encode(poolKey.currency1, recipient);
        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    function decrease(
        IPositionManager posm,
        uint256 tokenId,
        uint256 liquidity,
        Currency currency0,
        Currency currency1,
        address recipient,
        uint256 deadline
    ) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, 0, 0, bytes(""));
        params[1] = abi.encode(currency0, currency1, recipient);
        posm.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params), deadline
        );
    }
}
