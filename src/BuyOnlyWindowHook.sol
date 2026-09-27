// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Disclosed, fixed 300-block sell lock for each native-ETH pool initialized with this hook.
/// @dev No custody, custom accounting, identity checks, administrative powers, or liquidity hooks.
contract BuyOnlyWindowHook {
    error OnlyPoolManager();
    error SellsLocked(uint256 opensAt);

    event WindowSet(PoolId indexed poolId, uint256 opensAt);

    uint256 public constant WINDOW_BLOCKS = 300;
    IPoolManager public immutable poolManager;
    mapping(PoolId poolId => uint256 blockNumber) public opensAt;

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev The immutable PoolManager allows each pool to initialize only once. No price, sender,
    /// token, fee, or tick-spacing gate can interfere with the factory's valid initialization.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (key.currency0.isAddressZero()) {
            PoolId id = key.toId();
            uint256 openingBlock = block.number + WINDOW_BLOCKS;
            opensAt[id] = openingBlock;
            emit WindowSet(id, openingBlock);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @dev Direction identifies the input currency for both exact-input and exact-output swaps.
    /// With native ETH sorted first, oneForZero always sells the paired token for ETH.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (key.currency0.isAddressZero() && !params.zeroForOne) {
            uint256 openingBlock = opensAt[key.toId()];
            if (block.number < openingBlock) revert SellsLocked(openingBlock);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice True if this hook does not currently lock sells for the id.
    /// @dev Also true for unknown and non-ETH pools (opensAt == 0); does not assert pool existence.
    function sellsOpen(PoolId poolId) external view returns (bool) {
        return block.number >= opensAt[poolId];
    }
}
