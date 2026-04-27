// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract PointsHook is BaseHook, ERC1155 {
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        if (hookData.length == 0) return;
        address user = abi.decode(hookData, (address));
        if (user == address(0)) return;
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        _mint(user, poolIdUint, points, "");
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        _assignPoints(key.toId(), hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }
}