// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PaveToken} from "../src/PaveToken.sol";

/// @notice Adversarial edge cases the main suite does not pin: the full supply, one wei, the
/// uint256 ceiling, the same call twice, callers who are not who the code assumed, and the
/// surface the contract does not have (ether, unknown selectors, a second instance).
/// forge-config: default.fuzz.runs = 1000
contract PaveTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    PaveToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address spender = makeAddr("spender");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new PaveToken();
    }

    // ------------------------------------------------------------------------------------------
    // Supply boundaries
    // ------------------------------------------------------------------------------------------

    function test_transferWholeSupplyInOneCall() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOneWeiThenTheRest() public {
        vm.startPrank(deployer);
        token.transfer(alice, 1);
        token.transfer(alice, SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_emptiedDeployerCannotSendOneWei() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transfer(bob, 1);
    }

    function test_burnWholeSupplyLeavesNothingToMove() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, address(0), SUPPLY);
        vm.prank(deployer);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(deployer), 0);
        // The supply is gone for good: nothing can bring it back and nothing can be moved.
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transfer(alice, 1);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "the constant does not track burns");
    }

    function test_burnZeroIsANoOpThatStillEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnFromEmptyAccountRevertsOnOneWei() public {
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.burn(1);
    }

    function test_burnMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.burn(type(uint256).max);
    }

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
    }

    /// @dev Burns lower the supply and transfers never raise it, so the supply is monotone
    /// non-increasing across any interleaving.
    function testFuzz_supplyNeverGrowsAcrossBurnsAndTransfers(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.burn(c);
        vm.stopPrank();
        vm.prank(alice);
        token.burn(b);
        assertEq(token.totalSupply(), SUPPLY - b - c);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), token.totalSupply());
    }

    // ------------------------------------------------------------------------------------------
    // Round trips and repeated calls
    // ------------------------------------------------------------------------------------------

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_chainedTransfersConserveSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, c);
        assertEq(token.balanceOf(deployer), SUPPLY - a);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(carol), c);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), SUPPLY
        );
    }

    function testFuzz_selfTransferIsIdentity(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferBeyondBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(alice, amount);
    }

    function test_sameApproveTwiceDoesNotAccumulate() public {
        vm.startPrank(deployer);
        token.approve(spender, 10);
        token.approve(spender, 10);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 10);
    }

    function testFuzz_approveIsIdempotent(uint256 amount) public {
        vm.startPrank(deployer);
        token.approve(spender, amount);
        token.approve(spender, amount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), amount);
    }

    function test_sameTransferTwiceSpendsTwice() public {
        vm.startPrank(deployer);
        token.transfer(alice, 7);
        token.transfer(alice, 7);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 14);
        assertEq(token.balanceOf(deployer), SUPPLY - 14);
    }

    function test_spendingFullAllowanceTwiceFailsTheSecondTime() public {
        vm.prank(deployer);
        token.approve(spender, 5);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 5);
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, deployer, spender, 0, 5));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 5);
        assertEq(token.balanceOf(bob), 5);
    }

    // ------------------------------------------------------------------------------------------
    // Allowance edges
    // ------------------------------------------------------------------------------------------

    function test_allowanceOfMaxMinusOneIsFiniteAndDecrements() public {
        uint256 almost = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(spender, almost);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), almost - 1, "max-1 was treated as unlimited");
    }

    function test_unlimitedAllowanceStillBoundedByBalance() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, SUPPLY + 1);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_unlimitedAllowanceCanMoveWholeSupply() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_unlimitedAllowanceEmitsNoApprovalOnSpend() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "unlimited spend emitted more than the Transfer");
        assertEq(logs[0].topics[0], Transfer.selector);
    }

    function testFuzz_finiteAllowanceSpendEmitsApprovalWithRemainder(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 1, SUPPLY);
        amount = bound(amount, 1, allowed);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, allowed - amount);
        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);
    }

    function testFuzz_increaseAllowanceOverflowBoundary(uint256 current, uint256 added) public {
        current = bound(current, 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(spender, current);
        vm.prank(deployer);
        if (added > type(uint256).max - current) {
            vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)));
            token.increaseAllowance(spender, added);
        } else {
            assertTrue(token.increaseAllowance(spender, added));
            assertEq(token.allowance(deployer, spender), current + added);
        }
    }

    function testFuzz_decreaseAllowanceExactBoundary(uint256 current, uint256 subtracted) public {
        vm.prank(deployer);
        token.approve(spender, current);
        vm.prank(deployer);
        if (subtracted > current) {
            vm.expectRevert(
                abi.encodeWithSelector(PaveToken.AllowanceBelowZero.selector, deployer, spender, current, subtracted)
            );
            token.decreaseAllowance(spender, subtracted);
        } else {
            assertTrue(token.decreaseAllowance(spender, subtracted));
            assertEq(token.allowance(deployer, spender), current - subtracted);
        }
    }

    function test_increaseAllowanceToExactlyMaxSucceeds() public {
        vm.startPrank(deployer);
        token.approve(spender, 1);
        assertTrue(token.increaseAllowance(spender, type(uint256).max - 1));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_decreaseAllowanceFromZeroByZeroSucceeds() public {
        vm.prank(deployer);
        assertTrue(token.decreaseAllowance(spender, 0));
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_increaseAllowanceRevertsForZeroSpender() public {
        vm.expectRevert(PaveToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.increaseAllowance(address(0), 1);
    }

    function test_decreaseAllowanceRevertsForZeroSpender() public {
        // There is never an allowance for the zero spender, so the below-zero check fires first.
        vm.expectRevert(abi.encodeWithSelector(PaveToken.AllowanceBelowZero.selector, deployer, address(0), 0, 1));
        vm.prank(deployer);
        token.decreaseAllowance(address(0), 1);
        // Even a zero decrease cannot create an entry for the zero spender.
        vm.expectRevert(PaveToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.decreaseAllowance(address(0), 0);
    }

    function test_allowanceIsPerSpenderAndPerOwner() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(spender, deployer), 0);
        // The spender's own allowance does not let it spend from a different owner.
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, alice, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function test_approveDoesNotMoveTokens() public {
        vm.prank(deployer);
        token.approve(spender, SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    // ------------------------------------------------------------------------------------------
    // transferFrom with unexpected callers
    // ------------------------------------------------------------------------------------------

    function test_ownerCanTransferFromItselfOnlyWithSelfAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        // No self-allowance: transferFrom(self) is refused like any other spender.
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, alice, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        // With one, it works and is decremented like any other spender's.
        vm.startPrank(alice);
        token.approve(alice, 4);
        assertTrue(token.transferFrom(alice, bob, 3));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 1);
        assertEq(token.balanceOf(bob), 3);
        assertEq(token.balanceOf(alice), 7);
    }

    function test_transferFromToOwnerKeepsBalanceButSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 6));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 4);
    }

    function test_transferFromToSpenderCreditsSpender() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.prank(spender);
        token.transferFrom(deployer, spender, 10);
        assertEq(token.balanceOf(spender), 10);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_zeroAmountTransferFromWithoutAllowanceSucceedsAndMovesNothing() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 0);
    }

    /// @dev A stranger can name the zero address as `from` with a zero amount; the call goes through
    /// but it must not create tokens or change any balance.
    function test_zeroAmountTransferFromZeroAddressCreatesNothing() public {
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0)), 0);
        // And nothing more than zero can ever leave the zero address.
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, address(0), spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 1);
    }

    function test_burnDoesNotTouchAllowancesButStarvesThem() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(spender, 10);
        token.burn(10);
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), 10, "burn changed an allowance");
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function test_holderCannotBeBurnedByAnyoneElse() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        // Neither an unlimited spender nor the deployer has a path to burn alice's tokens.
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1));
        assertFalse(ok);
        vm.prank(spender);
        token.burn(0); // the spender's own burn touches only the spender
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // Surface the contract does not have
    // ------------------------------------------------------------------------------------------

    function test_rejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    function test_rejectsEtherOnAnyFunction() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(PaveToken.transfer, (alice, 1)));
        assertFalse(ok, "transfer is payable");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_rejectsEmptyCalldataAndUnknownSelector() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata accepted");
        (ok,) = address(token)
            .call(abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertFalse(ok, "unknown selector accepted");
    }

    function testFuzz_unknownSelectorsNeverChangeState(bytes4 selector, uint256 arg) public {
        // Skip the selectors that exist; every other one must be a hard revert.
        bytes4[6] memory known = [
            PaveToken.transfer.selector,
            PaveToken.approve.selector,
            PaveToken.transferFrom.selector,
            PaveToken.increaseAllowance.selector,
            PaveToken.decreaseAllowance.selector,
            PaveToken.burn.selector
        ];
        for (uint256 i; i < known.length; ++i) {
            if (known[i] == selector) selector = bytes4(keccak256(abi.encodePacked(selector, arg)));
        }
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, alice, arg));
        // Views answer; nothing else does, and either way no balance moved.
        if (
            selector != token.name.selector && selector != token.symbol.selector && selector != token.decimals.selector
                && selector != token.totalSupply.selector && selector != token.balanceOf.selector
                && selector != token.allowance.selector && selector != token.INITIAL_SUPPLY.selector
        ) {
            assertFalse(ok, "an undeclared selector succeeded");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_twoInstancesAreIndependent() public {
        vm.prank(alice);
        PaveToken other = new PaveToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        other.burn(SUPPLY);
        assertEq(other.totalSupply(), 0);
        assertEq(token.totalSupply(), SUPPLY, "burning one instance touched another");
    }

    function test_deployerIsWhoeverCreatesIt() public {
        vm.prank(bob);
        PaveToken fromBob = new PaveToken();
        assertEq(fromBob.balanceOf(bob), SUPPLY);
        assertEq(fromBob.balanceOf(address(this)), 0);
    }

    function test_runtimeCodeIsSmallAndStable() public view {
        bytes memory runtime = address(token).code;
        assertEq(keccak256(runtime), keccak256(type(PaveToken).runtimeCode));
        assertLe(runtime.length, 24_576);
    }
}
