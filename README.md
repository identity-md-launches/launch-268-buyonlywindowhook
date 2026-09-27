# Oneway Launch (OWLN)

This contribution implements the fixed-supply OWLN ERC-20 and `BuyOnlyWindowHook` for the approved Sepolia native-ETH launch. The Foundry suite deploys a real Uniswap v4 `PoolManager` and mines a genuine CREATE2 hook address; it does not replace hook bytecode or bypass constructor validation.

**Public safety disclosure:** blocking sells is the mechanism honeypots use. Here it is a disclosed, fixed 300-block (about an hour on Sepolia) test of launch-time gating, visible on-chain before anyone buys. Block times vary: the on-chain block number, not a clock estimate, determines when sells open. Liquidity can be removed at any time, including during the sell lock. This hook does not guarantee liquidity, a sale price, or the ability to sell through some other pool.

## Contracts

- `src/OWLN.sol`: OpenZeppelin ERC-20, name **Oneway Launch**, symbol **OWLN**, 18 decimals, exactly **1,000,000,000 OWLN** (`10^27` base units). Its zero-argument constructor mints everything to `msg.sender`, which is the deploying factory. Transfers have no tax. No external mint, burn, owner, admin, permit, pause, or upgrade interface is added.
- `src/BuyOnlyWindowHook.sol`: one constructor argument, `IPoolManager manager`. It calls `Hooks.validateHookPermissions` with exactly `afterInitialize` and `beforeSwap` enabled. All twelve remaining permissions, including every return-delta permission, are false. Required address mask: `uint160(hook) & 0x3fff == 0x1080` (decimal flags **4224**).

`afterInitialize` accepts valid PoolManager initialization without a token, price, fee, sender, or tick-spacing gate. When currency0 is native ETH (`address(0)`), it stores `opensAt[poolId] = block.number + 300` and emits `WindowSet(poolId, opensAt)`. There are no external calls from the hook. Arithmetic assumes real chain block numbers, which are nowhere near the uint256 limit.

`beforeSwap` rejects `zeroForOne == false` on native-ETH pools while `block.number < opensAt[poolId]`, using `SellsLocked(opensAt)`. That direction spends currency1 to receive ETH for **both** exact input (negative `amountSpecified`) and exact output (positive `amountSpecified`). Buys pass immediately; sells pass starting at **exactly** `opensAt`. Every allowed callback returns its selector, zero swap delta and zero fee override. The pool's ordinary 0.3% LP fee still applies; the hook charges nothing.

All implemented callbacks require `msg.sender == poolManager`. The `sender` argument and `hookData` are ignored; no identity is authenticated, credited or privileged. No router allowlist is necessary for this direction-based rule. There are no liquidity or donate callbacks, and no owner, setter, sweep, pause or upgrade path.

Every native-ETH pool attached to this hook gets its own window, including a second pool with a different fee, spacing or paired token. The hook intentionally does not bind itself to one OWLN address. Pools whose currency0 is not native ETH have no window, no hook event and no gating. Wrapping ETH into WETH makes an ERC-20 pool outside this rule. OWLN transfers and trading elsewhere remain unrestricted.

The trusted immutable PoolManager permits a given PoolId to initialize only once. Consequently there is no reachable way to re-arm, shorten or extend that pool's window. Activity and liquidity changes leave it unchanged. A halted chain delays opening in wall-clock time, because the window counts blocks.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun EVM, optimizer 200 runs and `bytecode_hash = "none"`. FFI and filesystem cheatcode access are disabled. The compiler and Foundry are build prerequisites; all Solidity dependencies needed by this project are ordinary files under `lib/`, with upstream commits and archive hashes recorded in [docs/dependencies.json](docs/dependencies.json). No `forge install`, submodules, RPC, API keys, environment configuration or network access is required to run the tests once the pinned compiler is installed.

The suite checks token minting, supply conservation, approvals, transfer failures and absent administrative selectors. Hook tests cover exact input/output in both directions, one-wei dust, fuzzed amounts and initialization parameters, the final locked block and opening block, unauthorized callbacks, malicious hook data, another router, non-ETH pools, a second native-ETH pool, initialization replay, liquidity removal, donation, failed settlement rollback, zero hook balances/claims/deltas, permission validation, and forbidden runtime opcodes. Tests have independent setup and do not read or modify environment variables.

## Factory launch rehearsal and parameter handoff

`test/helpers/LaunchFactory.sol` is a **test fixture**, not a production factory. Within its `launch` call it deploys the zero-argument token, verifies the factory owns all supply, deploys the hook by CREATE2, calls `initialize`, enters `unlock`, adds a factory-owned position, and settles the one-sided token debt. The test verifies zero ETH was needed, then executes the first buy through the upstream `PoolSwapTest` router. The helper's unrestricted methods exist solely for testing and must not be deployed as a custody service.

The supplied workflow refers to “the manifest price” but supplies neither a numeric price nor a factory implementation, seed amount or LP ticks. **No final `launch.json` was provided or authored by this assignment.** [LaunchParameters.sol](test/helpers/LaunchParameters.sol) records the reproducible rehearsal assumptions:

| Parameter | Rehearsal value |
| --- | --- |
| currency0 / currency1 | Native ETH / newly deployed OWLN |
| fee / tickSpacing | `3000` / `60` (required by workflow) |
| initial OWLN per ETH | `1,000,000` (both assets use 18 decimals) |
| initial sqrtPriceX96 | `79228162514264337593543950336000` (`1000 * 2^96`) |
| seed tickLower / tickUpper | `-887220` / `138120` |
| seed liquidity | `100000000000000000000000` (`100_000 ether` liquidity units) |
| window | `300` blocks, a source constant |

The chosen price is above the upper seed tick, so the position owes only currency1. A first buy moves price downward into the range. The seed uses roughly 100 million OWLN, leaving the remainder at the factory until the test distributes some to its trader. Liquidity units are not token units.

The manifest contributor and deployment service must reconcile the final price, token allocation, position owner, seed ticks and liquidity amount with this fixture, update the fixture if they differ, and rerun the rehearsal against the actual factory. This local rehearsal demonstrates the specified call sequence and settlement behavior; it is not a byte-for-byte reproduction of an unavailable factory or a live Sepolia fork result.

## Deployment and operations

Target chain is **Sepolia, chain ID 11155111**. Encode exactly one hook constructor argument: **`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`**, the Sepolia PoolManager specified by the approved workflow. Do not substitute a mainnet manager, owner or token argument. The constructor accepts a manager parameter to support deployment and real-manager local tests; choosing the correct chain and manager is the deployment service's responsibility.

Mine the CREATE2 salt using the actual factory's address and `keccak256(creationCode || abi.encode(manager))`. Check all 14 low bits against `0x1080`. The test miner illustrates this calculation. A changed compiler configuration, source, constructor value or deploying address invalidates previously mined salts. No production salt or hook address is asserted here.

The separate manifest assignment owns `launch.json`. Publication, signed artifact linkage, attestation, admission, deployment transactions, final pool parameters and independent adversarial review belong to their workflow services/contributors. They must review the exact source/ABI/constructor artifacts and verify the target deployment before submitting a funded transaction. This implementation has local test coverage; it has not received the separate independent review or a live-factory fork rehearsal.

After deployment, operators and the later frontend stage should verify the permission bits, `poolManager()`, canonical PoolId, `WindowSet` event and `opensAt` value against the initialization block. The frontend must carry the public safety disclosure above, show the block countdown and treat minutes as an estimate. Read `sellsOpen` together with pool existence/state; `true` alone does not prove a pool exists or has sellable liquidity. Use the workflow's Sepolia StateView and PoolSwapTest router only after services verify their manager linkage and deployed code. No keeper, cron job or administrative opening transaction is needed.

Hook callbacks neither transfer assets nor call `sync`, `settle`, `take`, `mint` or `burn`. The factory/router pays negative deltas and receives positive deltas: for ERC-20 debt it performs **sync → transfer → settle**; for native ETH it sends value to `settle`; for credits it calls `take`. PoolManager rejects an unlock with unsettled deltas. The hook receives no funds or ERC-6909 claims during normal operation. Anyone can nevertheless send ERC-20 tokens to any address or force ETH there; this hook deliberately has no rescue function, so unsolicited funds are unrecoverable.

## ABI exports

Machine-readable ABI arrays are delivered at [docs/abi/OWLN.json](docs/abi/OWLN.json) and [docs/abi/BuyOnlyWindowHook.json](docs/abi/BuyOnlyWindowHook.json). See [docs/ABI.md](docs/ABI.md) for argument encoding, events, view semantics and errors. Regenerate after source changes:

```sh
forge inspect src/OWLN.sol:OWLN abi --json > docs/abi/OWLN.json
forge inspect src/BuyOnlyWindowHook.sol:BuyOnlyWindowHook abi --json > docs/abi/BuyOnlyWindowHook.json
```

Upstream implementation references: [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) and [OpenZeppelin ERC20 v5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/acd4ff74de833399287ed6b31b4debf6b2b35527/contracts/token/ERC20/ERC20.sol). Vendored files retain their upstream licenses; project-authored source is MIT licensed.
