// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OWLN} from "../src/OWLN.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract OWLNTest is Test {
    OWLN token;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        token = new OWLN();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Oneway Launch");
        assertEq(token.symbol(), "OWLN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_mintsOnceToActualDeployerWithEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        OWLN another = new OWLN();
        assertEq(another.balanceOf(ALICE), SUPPLY);
        assertEq(another.balanceOf(address(this)), 0);
    }

    function testFuzz_transferConservesSupplyWithoutTax(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalTransferFromAndAllowanceExhaustion() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 10 ether);
        assertTrue(token.approve(ALICE, 10 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 7 ether));
        assertEq(token.allowance(address(this), ALICE), 3 ether);
        assertEq(token.balanceOf(BOB), 7 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 3 ether, 4 ether)
        );
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 4 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteApprovalAndRevocation() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        token.approve(ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_invalidTransfersAndApprovalRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_selfAndZeroTransfers() public {
        token.transfer(address(this), SUPPLY);
        token.transfer(ALICE, 0);
        vm.prank(ALICE);
        token.transfer(BOB, 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noAdministrativeOrMintSelectorsForAnyone() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)",
            "pause()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1 ether));
            (bool fromDeployer,) = address(token).call(data);
            vm.prank(ALICE);
            (bool fromStranger,) = address(token).call(data);
            assertFalse(fromDeployer);
            assertFalse(fromStranger);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
