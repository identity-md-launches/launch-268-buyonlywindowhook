// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {OWLN} from "../src/OWLN.sol";
import {BuyOnlyWindowHook} from "../src/BuyOnlyWindowHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {LaunchParameters as Params} from "./helpers/LaunchParameters.sol";
import {LaunchFactory} from "./helpers/LaunchFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract BuyOnlyWindowHookTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager manager;
    LaunchFactory factory;
    OWLN token;
    BuyOnlyWindowHook hook;
    PoolSwapTest router;
    PoolModifyLiquidityTest liquidityRouter;
    PoolKey key;
    uint256 initializationBlock;
    Vm.Log[] launchLogs;

    event WindowSet(PoolId indexed poolId, uint256 opensAt);

    function setUp() public {
        vm.roll(1000);
        vm.deal(address(this), 10_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new LaunchFactory(manager);
        bytes32 initHash =
            keccak256(abi.encodePacked(type(BuyOnlyWindowHook).creationCode, abi.encode(manager)));
        (bytes32 salt, address predicted) = HookMiner.mine(address(factory), initHash);
        initializationBlock = block.number;
        vm.recordLogs();
        factory.launch(salt, Params.SQRT_PRICE_X96, Params.FEE, Params.TICK_SPACING, _seed(Params.LIQUIDITY));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            launchLogs.push(logs[i]);
        }
        token = factory.token();
        hook = factory.hook();
        assertEq(address(hook), predicted);
        key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            Params.FEE,
            Params.TICK_SPACING,
            IHooks(address(hook))
        );
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        factory.releaseTokens(address(this), 500_000_000 ether);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
    }

    function test_launchRehearsalInitializeSeedAndFirstBuyIntoEthlessPool() public {
        assertEq(hook.opensAt(key.toId()), initializationBlock + 300);
        assertFalse(hook.sellsOpen(key.toId()));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Params.SQRT_PRICE_X96);
        assertGe(price, TickMath.getSqrtPriceAtTick(Params.TICK_UPPER));
        assertEq(address(manager).balance, 0, "seed must not require ETH");
        assertEq(factory.seedDelta().amount0(), 0);
        assertLt(factory.seedDelta().amount1(), 0);
        assertEq(token.balanceOf(address(manager)), uint256(-int256(factory.seedDelta().amount1())));
        (uint128 liquidity,,) = manager.getPositionInfo(
            key.toId(), address(factory), Params.TICK_LOWER, Params.TICK_UPPER, bytes32(0)
        );
        assertEq(liquidity, uint256(Params.LIQUIDITY));

        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        BalanceDelta delta = _swap(key, true, -int256(1 ether));
        assertEq(delta.amount0(), -int256(1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(token.balanceOf(address(this)), tokenBefore + uint128(delta.amount1()));
        assertEq(address(this).balance, ethBefore - 1 ether);
        assertEq(address(manager).balance, 1 ether);
        _assertSettledAndNoHookFunds(key);
    }

    function test_launchEmitsWindowAndMintToFactoryExactlyOnce() public view {
        uint256 windowEvents;
        uint256 mintEvents;
        for (uint256 i; i < launchLogs.length; ++i) {
            Vm.Log storage log = launchLogs[i];
            if (log.emitter == address(hook) && log.topics[0] == keccak256("WindowSet(bytes32,uint256)")) {
                ++windowEvents;
                assertEq(log.topics[1], PoolId.unwrap(key.toId()));
                assertEq(abi.decode(log.data, (uint256)), initializationBlock + 300);
            }
            if (
                log.emitter == address(token)
                    && log.topics[0] == keccak256("Transfer(address,address,uint256)")
                    && log.topics[1] == bytes32(0)
            ) {
                ++mintEvents;
                assertEq(address(uint160(uint256(log.topics[2]))), address(factory));
                assertEq(abi.decode(log.data, (uint256)), 1_000_000_000 ether);
            }
        }
        assertEq(windowEvents, 1);
        assertEq(mintEvents, 1);
    }

    function test_permissionsAreExactly1080AndManagerIsImmutable() public view {
        Hooks.Permissions memory expected;
        expected.afterInitialize = true;
        expected.beforeSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x1080);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.WINDOW_BLOCKS(), 300);
    }

    function test_constructorRejectsWrongPermissionBits() public {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(BuyOnlyWindowHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted = HookMiner.predict(address(this), salt, initHash);
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == 0x1080) {
            salt = bytes32(uint256(1));
            predicted = HookMiner.predict(address(this), salt, initHash);
        }
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x1080);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new BuyOnlyWindowHook{salt: salt}(manager);
    }

    function test_buysBothModesAndLockedSellsBothModesAtLastLockedBlock() public {
        vm.roll(hook.opensAt(key.toId()) - 1);
        BalanceDelta exactIn = _swap(key, true, -int256(1 ether));
        assertEq(exactIn.amount0(), -int256(1 ether));
        assertGt(exactIn.amount1(), 0);
        BalanceDelta exactOut = _swap(key, true, int256(100 ether));
        assertEq(exactOut.amount1(), 100 ether);
        assertLt(exactOut.amount0(), 0);
        _expectSellLocked(router, key, -int256(100 ether), "");
        _expectSellLocked(router, key, int256(0.001 ether), "");
        assertFalse(hook.sellsOpen(key.toId()));
        _assertSettledAndNoHookFunds(key);
    }

    function test_sellsBothModesSucceedAtExactlyOpensAt() public {
        _swap(key, true, -int256(1 ether));
        vm.roll(hook.opensAt(key.toId()));
        assertTrue(hook.sellsOpen(key.toId()));
        BalanceDelta exactIn = _swap(key, false, -int256(100 ether));
        assertEq(exactIn.amount1(), -int256(100 ether));
        assertGt(exactIn.amount0(), 0);
        BalanceDelta exactOut = _swap(key, false, int256(0.001 ether));
        assertEq(exactOut.amount0(), 0.001 ether);
        assertLt(exactOut.amount1(), 0);
        _assertSettledAndNoHookFunds(key);
    }

    function test_revertedSellsDoNotChangeBalancesPriceOrWindow() public {
        _swap(key, true, -int256(1 ether));
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeEth = address(this).balance;
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 opening = hook.opensAt(key.toId());
        _expectSellLocked(router, key, -int256(100 ether), "");
        _expectSellLocked(router, key, int256(0.001 ether), "");
        assertEq(token.balanceOf(address(this)), beforeToken);
        assertEq(address(this).balance, beforeEth);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
        assertEq(hook.opensAt(key.toId()), opening);
        _assertSettledAndNoHookFunds(key);
    }

    function test_dustOneWeiInBothModesAndDirections() public {
        // Core rounding may consume a one-wei exact input entirely as LP fees.
        _swap(key, true, -int256(1));
        assertEq(_swap(key, true, 1).amount1(), 1);
        _expectSellLocked(router, key, -1, "");
        _expectSellLocked(router, key, 1, "");
        _swap(key, true, -int256(1 ether));
        vm.roll(hook.opensAt(key.toId()));
        _swap(key, false, -1);
        assertEq(_swap(key, false, 1).amount0(), 1);
        _assertSettledAndNoHookFunds(key);
    }

    function test_addRemoveAndDonateDuringWindow() public {
        uint256 opening = hook.opensAt(key.toId());
        BalanceDelta added = factory.modify(_seed(Params.LIQUIDITY / 10));
        assertEq(added.amount0(), 0);
        assertLt(added.amount1(), 0);
        // Even before the first buy, the factory can recover its whole one-sided seed.
        BalanceDelta removed = factory.modify(_seed(-Params.LIQUIDITY / 10));
        assertEq(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        _swap(key, true, -int256(1 ether));
        PoolDonateTest donor = new PoolDonateTest(manager);
        token.approve(address(donor), type(uint256).max);
        BalanceDelta donation = donor.donate{value: 0.01 ether}(key, 0.01 ether, 1 ether, "");
        assertEq(donation.amount0(), -int256(0.01 ether));
        assertEq(donation.amount1(), -int256(1 ether));
        BalanceDelta withdrawal = factory.modify(_seed(-Params.LIQUIDITY));
        assertGt(withdrawal.amount0(), 0);
        assertGt(withdrawal.amount1(), 0);
        (uint128 liquidity,,) = manager.getPositionInfo(
            key.toId(), address(factory), Params.TICK_LOWER, Params.TICK_UPPER, bytes32(0)
        );
        assertEq(liquidity, 0);
        assertEq(hook.opensAt(key.toId()), opening);
        assertFalse(hook.sellsOpen(key.toId()));
        _assertSettledAndNoHookFunds(key);
    }

    function test_nonEthPoolHasNoWindowNoEventAndTradesAllFourWays() public {
        MockERC20 other = new MockERC20("Other", "OTH", 1_000_000 ether);
        (Currency c0, Currency c1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory nonEth = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        vm.recordLogs();
        manager.initialize(nonEth, uint160(1 << 96));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook));
        }
        assertEq(hook.opensAt(nonEth.toId()), 0);
        assertTrue(hook.sellsOpen(nonEth.toId()));
        other.approve(address(liquidityRouter), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        liquidityRouter.modifyLiquidity(nonEth, ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), "");
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 mode; mode < 2; ++mode) {
                BalanceDelta delta =
                    _swap(nonEth, direction == 0, mode == 0 ? -int256(0.1 ether) : int256(0.1 ether));
                assertTrue(delta.amount0() != 0 && delta.amount1() != 0);
            }
        }
        assertEq(other.balanceOf(address(hook)), 0);
        _assertSettledAndNoHookFunds(nonEth);
    }

    function test_secondEthPoolHasIndependentWindowAndCannotRearmFirst() public {
        uint256 firstOpening = hook.opensAt(key.toId());
        _swap(key, true, -int256(1 ether));
        vm.roll(firstOpening - 10);
        PoolKey memory second = key;
        second.fee = 500;
        vm.expectEmit(true, false, false, true, address(hook));
        emit WindowSet(second.toId(), block.number + 300);
        manager.initialize(second, Params.SQRT_PRICE_X96);
        liquidityRouter.modifyLiquidity(second, _seed(Params.LIQUIDITY), "");
        _swap(second, true, -int256(1 ether));
        uint256 secondOpening = hook.opensAt(second.toId());
        assertEq(secondOpening, firstOpening + 290);
        vm.roll(firstOpening);
        assertGt(_swap(key, false, -int256(100 ether)).amount0(), 0);
        _expectSellLocked(router, second, -int256(100 ether), "");
        _expectSellLocked(router, second, int256(1), "");
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, Params.SQRT_PRICE_X96);
        assertEq(hook.opensAt(key.toId()), firstOpening);
        vm.roll(secondOpening);
        assertGt(_swap(second, false, -int256(100 ether)).amount0(), 0);
        _assertSettledAndNoHookFunds(second);
    }

    function test_differentRouterAndArbitraryHookDataCannotBypassLock() public {
        _swap(key, true, -int256(1 ether));
        PoolSwapTest alternate = new PoolSwapTest(manager);
        token.approve(address(alternate), type(uint256).max);
        bytes memory fakeIdentity = abi.encode(address(manager), address(hook), address(factory));
        _expectSellLocked(alternate, key, -int256(100 ether), fakeIdentity);
        _expectSellLocked(alternate, key, int256(0.001 ether), fakeIdentity);
        BalanceDelta bought = alternate.swap{value: 1 ether}(
            key, _params(true, -int256(1 ether)), PoolSwapTest.TestSettings(false, false), fakeIdentity
        );
        assertGt(bought.amount1(), 0);
        _assertSettledAndNoHookFunds(key);
    }

    function test_directCallbacksRejectNonManagerEvenWithSpoofedSender() public {
        vm.expectRevert(BuyOnlyWindowHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(manager), key, Params.SQRT_PRICE_X96, 0);
        vm.expectRevert(BuyOnlyWindowHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(manager), key, _params(true, -1), "");
        assertEq(hook.opensAt(key.toId()), initializationBlock + 300);
    }

    function test_returnsSelectorsZeroDeltaAndNoFeeOverride() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), key, _params(true, -1), "anything");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
        vm.roll(hook.opensAt(key.toId()));
        vm.prank(address(manager));
        (selector, delta, fee) = hook.beforeSwap(address(this), key, _params(false, 1), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_uninitializedViewMeansNoHookLock() public view {
        PoolId unknown = PoolId.wrap(bytes32(uint256(123)));
        assertEq(hook.opensAt(unknown), 0);
        assertTrue(hook.sellsOpen(unknown));
    }

    function test_failedTokenSettlementRollsBackSwapAtomically() public {
        _swap(key, true, -int256(1 ether));
        vm.roll(hook.opensAt(key.toId()));
        address unfunded = address(0xBEEF);
        vm.prank(unfunded);
        token.approve(address(router), type(uint256).max);
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 beforeEth = address(manager).balance;
        uint256 beforeToken = token.balanceOf(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, unfunded, 0, 100 ether)
        );
        vm.prank(unfunded);
        router.swap(key, _params(false, -int256(100 ether)), PoolSwapTest.TestSettings(false, false), "");
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(address(manager).balance, beforeEth);
        assertEq(token.balanceOf(address(manager)), beforeToken);
        assertEq(unfunded.balance, 0);
        _assertSettledAndNoHookFunds(key);
    }

    function testFuzz_initializeHasNoPriceOrSpacingGate(int24 rawTick, uint16 rawSpacing) public {
        int24 tick = int24(bound(int256(rawTick), -887271, 887271));
        int24 spacing = int24(int256(bound(uint256(rawSpacing), 1, 32767)));
        PoolKey memory another = key;
        another.fee = 500;
        another.tickSpacing = spacing;
        vm.expectEmit(true, false, false, true, address(hook));
        emit WindowSet(another.toId(), block.number + 300);
        manager.initialize(another, TickMath.getSqrtPriceAtTick(tick));
        assertEq(hook.opensAt(another.toId()), block.number + 300);
        assertEq(address(manager).balance, 0);
    }

    function test_windowDoesNotExtendWithActivityAndNeverRelocks() public {
        uint256 opening = hook.opensAt(key.toId());
        for (uint256 i; i < 3; ++i) {
            vm.roll(initializationBlock + 100 * i);
            _swap(key, true, -int256(0.1 ether));
            _expectSellLocked(router, key, -1, "");
            assertEq(hook.opensAt(key.toId()), opening);
        }
        vm.roll(opening + 10_000_000);
        assertTrue(hook.sellsOpen(key.toId()));
        assertGt(_swap(key, false, -int256(100 ether)).amount0(), 0);
        assertEq(hook.opensAt(key.toId()), opening);
    }

    function testFuzz_swapSizesBothDirectionsAndModes(uint96 rawSize, bool exactOutput) public {
        uint256 size = bound(rawSize, 1e9, 0.1 ether);
        int256 buyAmount = exactOutput ? int256(size) : -int256(size);
        BalanceDelta buy = _swap(key, true, buyAmount);
        if (exactOutput) assertEq(buy.amount1(), int256(size));
        else assertEq(buy.amount0(), -int256(size));
        _expectSellLocked(router, key, exactOutput ? int256(1) : -int256(size), "");
        // Fund ETH reserves for all sell sizes independently of the first buy's mode.
        _swap(key, true, -int256(1 ether));
        vm.roll(hook.opensAt(key.toId()));
        BalanceDelta sell = _swap(key, false, exactOutput ? int256(size) : -int256(size));
        if (exactOutput) assertEq(sell.amount0(), int256(size));
        else assertEq(sell.amount1(), -int256(size));
        _assertSettledAndNoHookFunds(key);
    }

    function testFuzz_sellGateIgnoresAmountSignAndHookData(int256 amount, bytes calldata hookData) public {
        vm.roll(hook.opensAt(key.toId()) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(BuyOnlyWindowHook.SellsLocked.selector, hook.opensAt(key.toId()))
        );
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, _params(false, amount), hookData);
        vm.prank(address(manager));
        (, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), key, _params(true, amount), hookData);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_runtimeHasNoProxyOrDestructionOpcodes() public view {
        _assertRuntimeSafe(address(hook));
        _assertRuntimeSafe(address(token));
    }

    function _assertRuntimeSafe(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function _seed(int256 amount) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(Params.TICK_LOWER, Params.TICK_UPPER, amount, bytes32(0));
    }

    function _params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swap(PoolKey memory pool, bool buy, int256 amount) internal returns (BalanceDelta) {
        uint256 value = pool.currency0.isAddressZero() && buy ? 10 ether : 0;
        return
            router.swap{value: value}(pool, _params(buy, amount), PoolSwapTest.TestSettings(false, false), "");
    }

    function _expectSellLocked(PoolSwapTest swapRouter, PoolKey memory pool, int256 amount, bytes memory data)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyWindowHook.SellsLocked.selector, hook.opensAt(pool.toId())),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(pool, _params(false, amount), PoolSwapTest.TestSettings(false, false), data);
    }

    function _assertSettledAndNoHookFunds(PoolKey memory pool) internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.currencyDelta(address(hook), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), pool.currency1), 0);
        assertEq(manager.currencyDelta(address(router), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(router), pool.currency1), 0);
        assertEq(manager.currencyDelta(address(factory), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(factory), pool.currency1), 0);
        assertEq(manager.balanceOf(address(hook), pool.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), pool.currency1.toId()), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    receive() external payable {}
}
