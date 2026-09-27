# Contract interfaces

The JSON files in `docs/abi/` are complete ABI arrays generated with the pinned compiler. Solidity `PoolId` is ABI encoded as `bytes32`, `Currency` as `address`, and `BeforeSwapDelta` as `int256`.

## OWLN

Constructor: `constructor()`; deployment value must be zero. It emits `Transfer(address(0), msg.sender, 1000000000000000000000000000)` exactly once and mints that full supply to the deploying factory.

| Function | Result / meaning |
| --- | --- |
| `name()` | `Oneway Launch` |
| `symbol()` | `OWLN` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` |
| `balanceOf(address)` | Balance in base units |
| `allowance(address,address)` | Remaining spender authorization |
| `approve(address,uint256)` | Set authorization; returns `true` and emits `Approval` |
| `transfer(address,uint256)` | Transfer exact base units; returns `true` and emits `Transfer` |
| `transferFrom(address,address,uint256)` | Spend allowance and transfer; returns `true` and emits `Transfer` |

OpenZeppelin v5 ERC-20 errors are present in the JSON, including insufficient balance/allowance and invalid zero-address sender/receiver/approver/spender. Infinite allowance is not decremented. Spending allowance does not emit a new `Approval` event in this version. Zero-value transfers are valid for nonzero recipients. There are no administrative or post-deployment issuance selectors.

## BuyOnlyWindowHook

Constructor: `constructor(address manager)`; deployment value must be zero. The service encodes the approved Sepolia PoolManager as the sole argument and mines the address for mask `0x3fff`, required value `0x1080`. Wrong bits revert with `HookAddressNotValid(address)` inherited from the Hooks library's constructor validation.

| Function | Result / meaning |
| --- | --- |
| `poolManager()` | Immutable manager address |
| `WINDOW_BLOCKS()` | `300` |
| `opensAt(bytes32 poolId)` | Initialization block plus 300 for native-ETH pools; zero for unknown/non-ETH pools |
| `sellsOpen(bytes32 poolId)` | `block.number >= opensAt[poolId]`; true for unknown/non-ETH pools too |
| `getHookPermissions()` | Fourteen booleans in v4 `Hooks.Permissions` order; only afterInitialize and beforeSwap are true |

For a pool key `(currency0, currency1, fee, tickSpacing, hooks)`, `poolId = keccak256(abi.encode(key))`; use full ABI encoding, not packed encoding. Currencies are sorted numerically by address. Pool parameters including the hook address are part of the id.

`WindowSet(bytes32 indexed poolId, uint256 opensAt)` is emitted by native-ETH initialization only. Topic0 is `keccak256("WindowSet(bytes32,uint256)")`, topic1 is the pool id, and the data is the ABI-encoded opening block. Non-ETH initialization does not emit this event or change the mapping.

`afterInitialize(address sender, PoolKey key, uint160 sqrtPriceX96, int24 tick)` returns its `bytes4` selector. `beforeSwap(address sender, PoolKey key, SwapParams params, bytes hookData)` returns `(bytes4 selector, int256 delta, uint24 feeOverride)`, with delta and override both zero. `SwapParams` is `(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)`. The complete tuple layouts and permission ordering are in the ABI JSON. These callbacks are manager-only, not user entrypoints.

`OnlyPoolManager()` rejects other callers. `SellsLocked(uint256 opensAt)` rejects a native-ETH sell before its opening block; exact-output swaps buying ETH are sells as well. In normal router execution the v4 PoolManager wraps the hook error in `WrappedError(address target, bytes4 selector, bytes reason, bytes details)`: target is the hook, selector is `beforeSwap`, reason encodes `SellsLocked`, and details encodes `HookCallFailed()`. Consumers should decode this nested reason. A direct unauthorized callback instead fails with `OnlyPoolManager()`.

There are no liquidity/donation entrypoints, return-delta capabilities, payable receive/fallback functions, upgrade selectors, claims, user credits or withdrawal methods in the hook.
