// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

abstract contract Deployers {
    IPermit2 internal permit2;
    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    IUniswapV4Router04 internal swapRouter;

    function _etch(address, bytes memory) internal virtual;

    function deployArtifacts() internal {
        address permit2Address = AddressConstants.getPermit2Address();
        if (permit2Address.code.length == 0) _etch(permit2Address, Permit2Deployer.deploy().code);
        permit2 = IPermit2(permit2Address);
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(0x4444)));
        positionManager = IPositionManager(
            V4PositionManagerDeployer.deploy(address(poolManager), address(permit2), 300_000, address(0), address(0))
        );
        swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
    }

    function deployToken() internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(address(this), 10_000_000 ether);
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function deployCurrencyPair() internal returns (Currency currency0, Currency currency1) {
        MockERC20 token0 = deployToken();
        MockERC20 token1 = deployToken();
        if (token0 > token1) (token0, token1) = (token1, token0);
        return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
    }
}
