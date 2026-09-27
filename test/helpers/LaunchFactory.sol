// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OWLN} from "../../src/OWLN.sol";
import {BuyOnlyWindowHook} from "../../src/BuyOnlyWindowHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Test-only factory rehearsal, not a deployment or custody contract.
/// Same caller deploys the token/hook, initializes, owns the seed position and settles its debt.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    OWLN public token;
    BuyOnlyWindowHook public hook;
    PoolKey public key;
    BalanceDelta public seedDelta;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 salt, uint160 price, uint24 fee, int24 spacing, ModifyLiquidityParams memory seed)
        external
    {
        require(address(token) == address(0), "already launched");
        token = new OWLN();
        require(token.balanceOf(address(this)) == 1_000_000_000 ether, "factory supply mismatch");
        hook = new BuyOnlyWindowHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), fee, spacing, IHooks(address(hook))
        );
        manager.initialize(key, price);
        seedDelta = modify(seed);
    }

    function modify(ModifyLiquidityParams memory params) public payable returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(params)), (BalanceDelta));
    }

    function releaseTokens(address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (BalanceDelta delta,) = manager.modifyLiquidity(key, abi.decode(data, (ModifyLiquidityParams)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                require(token.transfer(address(manager), owed));
                require(manager.settle() == owed, "settlement mismatch");
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }

    receive() external payable {}
}
