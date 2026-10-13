// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaveToken} from "../src/PaveToken.sol";

/// @notice Drives PaveToken with bounded inputs from a fixed set of actors (the deployer and five
/// holders) in random order. Every handler either succeeds and checks its own postconditions, or
/// deliberately aims at a failure path and checks the exact revert and that nothing moved. Ghost
/// variables record what the token should hold; the invariants below compare them with the token.
contract PaveTokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    PaveToken public immutable token;
    address[] public actors;

    // --------------------------------------------------------------------------------------------
    // Ghost state
    // --------------------------------------------------------------------------------------------

    /// @dev Everything any actor has burned, summed.
    uint256 public ghostBurned;
    /// @dev Everything moved by successful transfer / transferFrom calls, summed.
    uint256 public ghostTransferVolume;
    /// @dev Expected allowance for every (owner, spender) pair among actors.
    mapping(address owner => mapping(address spender => uint256)) public shadowAllowance;
    /// @dev How many times each handler ran its intended path (coverage check, not a property).
    mapping(bytes32 => uint256) public calls;

    constructor(PaveToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        for (uint256 i = 1; i <= 5; ++i) {
            actors.push(makeAddr(string.concat("holder", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // --------------------------------------------------------------------------------------------
    // transfer
    // --------------------------------------------------------------------------------------------

    /// @notice A transfer the holder can afford (any amount up to the full balance, zero included).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transferExpectingSuccess(from, to, amount);
        calls["transfer"]++;
    }

    /// @notice Liveness: a holder can always move its whole balance in one call.
    function transferFull(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        _transferExpectingSuccess(from, _actor(toSeed), token.balanceOf(from));
        calls["transferFull"]++;
    }

    /// @notice Failure path: more than the holder has must revert with the exact error and move nothing.
    function transferInsufficient(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, held + 1, type(uint256).max);
        uint256 supplyBefore = token.totalSupply();
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.transfer, (to, amount)));
        assertFalse(ok, "transfer beyond balance succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, from, held, amount));
        assertEq(token.balanceOf(from), held, "failed transfer changed sender balance");
        assertEq(token.balanceOf(to), toBefore, "failed transfer changed recipient balance");
        assertEq(token.totalSupply(), supplyBefore, "failed transfer changed supply");
        calls["transferInsufficient"]++;
    }

    /// @notice Failure path: the zero address is never a valid recipient, whatever the amount.
    function transferToZero(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to zero address succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.ZeroAddress.selector));
        assertEq(token.balanceOf(from), held, "failed transfer changed sender balance");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
        calls["transferToZero"]++;
    }

    function _transferExpectingSuccess(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        assertEq(token.totalSupply(), supplyBefore, "transfer changed supply");
        ghostTransferVolume += amount;
    }

    // --------------------------------------------------------------------------------------------
    // approve / increaseAllowance / decreaseAllowance
    // --------------------------------------------------------------------------------------------

    /// @notice Sets an absolute allowance; the full uint256 range is allowed, so the unlimited
    /// sentinel is reached too.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not set the exact allowance");
        shadowAllowance[owner][spender] = amount;
        calls["approve"]++;
    }

    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) public {
        approve(ownerSeed, spenderSeed, type(uint256).max);
        calls["approveUnlimited"]++;
    }

    /// @notice Failure path: approving the zero address reverts and leaves other allowances alone.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.approve, (address(0), amount)));
        assertFalse(ok, "approve of zero spender succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.ZeroAddress.selector));
        assertEq(token.allowance(owner, address(0)), 0, "zero spender has an allowance");
        calls["approveZeroSpender"]++;
    }

    /// @notice Raises an allowance; past the uint256 ceiling the call must revert with a checked
    /// arithmetic panic and change nothing.
    function increaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 added) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);

        if (added > type(uint256).max - current) {
            vm.prank(owner);
            (bool ok, bytes memory ret) =
                address(token).call(abi.encodeCall(PaveToken.increaseAllowance, (spender, added)));
            assertFalse(ok, "increaseAllowance overflowed without reverting");
            assertEq(ret, abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)), "not an overflow panic");
            assertEq(token.allowance(owner, spender), current, "failed increase changed allowance");
            calls["increaseAllowanceOverflow"]++;
            return;
        }

        vm.prank(owner);
        assertTrue(token.increaseAllowance(spender, added), "increaseAllowance returned false");
        assertEq(token.allowance(owner, spender), current + added, "increase not exact");
        shadowAllowance[owner][spender] = current + added;
        calls["increaseAllowance"]++;
    }

    /// @notice Lowers an allowance; below zero the call must revert with the exact error.
    function decreaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 subtracted) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);

        if (subtracted > current) {
            vm.prank(owner);
            (bool ok, bytes memory ret) =
                address(token).call(abi.encodeCall(PaveToken.decreaseAllowance, (spender, subtracted)));
            assertFalse(ok, "decreaseAllowance went below zero without reverting");
            assertEq(
                ret, abi.encodeWithSelector(PaveToken.AllowanceBelowZero.selector, owner, spender, current, subtracted)
            );
            assertEq(token.allowance(owner, spender), current, "failed decrease changed allowance");
            calls["decreaseAllowanceBelowZero"]++;
            return;
        }

        vm.prank(owner);
        assertTrue(token.decreaseAllowance(spender, subtracted), "decreaseAllowance returned false");
        assertEq(token.allowance(owner, spender), current - subtracted, "decrease not exact");
        shadowAllowance[owner][spender] = current - subtracted;
        calls["decreaseAllowance"]++;
    }

    // --------------------------------------------------------------------------------------------
    // transferFrom
    // --------------------------------------------------------------------------------------------

    /// @notice A delegated transfer within both the allowance and the owner's balance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);
        _transferFromExpectingSuccess(spender, owner, to, amount);
        calls["transferFrom"]++;
    }

    /// @notice Liveness: a spender can always take exactly what it is allowed and the owner holds.
    function transferFromFull(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        _transferFromExpectingSuccess(spender, owner, _actor(toSeed), allowed < held ? allowed : held);
        calls["transferFromFull"]++;
    }

    /// @notice Failure path: a finite allowance is a hard ceiling, whatever the owner holds.
    function transferFromBeyondAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        public
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // unlimited: nothing is beyond it
        amount = bound(amount, allowed + 1, type(uint256).max);
        uint256 held = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.transferFrom, (owner, to, amount)));
        assertFalse(ok, "transferFrom beyond allowance succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, owner, spender, allowed, amount));
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed allowance");
        assertEq(token.balanceOf(owner), held, "failed transferFrom changed owner balance");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed recipient balance");
        calls["transferFromBeyondAllowance"]++;
    }

    /// @notice Failure path: an allowance (even unlimited) never lets a spender exceed the balance.
    function transferFromBeyondBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed <= held) return; // cannot aim past the balance while staying inside the allowance
        amount = bound(amount, held + 1, allowed);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.transferFrom, (owner, to, amount)));
        assertFalse(ok, "transferFrom beyond balance succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, owner, held, amount));
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed allowance");
        assertEq(token.balanceOf(owner), held, "failed transferFrom changed owner balance");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed recipient balance");
        calls["transferFromBeyondBalance"]++;
    }

    function _transferFromExpectingSuccess(address spender, address owner, address to, uint256 amount) internal {
        uint256 allowed = token.allowance(owner, spender);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        if (spender != owner && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "spender balance changed");
        }
        assertEq(token.totalSupply(), supplyBefore, "transferFrom changed supply");

        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), allowed, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented exactly");
            shadowAllowance[owner][spender] = allowed - amount;
        }
        ghostTransferVolume += amount;
    }

    // --------------------------------------------------------------------------------------------
    // burn
    // --------------------------------------------------------------------------------------------

    /// @notice Burns up to the whole balance of the caller.
    function burn(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _burnExpectingSuccess(from, amount);
        calls["burn"]++;
    }

    /// @notice Liveness: a holder can burn everything it has in one call.
    function burnFull(uint256 fromSeed) public {
        address from = _actor(fromSeed);
        _burnExpectingSuccess(from, token.balanceOf(from));
        calls["burnFull"]++;
    }

    /// @notice Failure path: burning more than held reverts exactly and leaves the supply alone.
    function burnTooMuch(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, held + 1, type(uint256).max);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PaveToken.burn, (amount)));
        assertFalse(ok, "burn beyond balance succeeded");
        assertEq(ret, abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, from, held, amount));
        assertEq(token.balanceOf(from), held, "failed burn changed balance");
        assertEq(token.totalSupply(), supplyBefore, "failed burn changed supply");
        calls["burnTooMuch"]++;
    }

    function _burnExpectingSuccess(address from, uint256 amount) internal {
        uint256 held = token.balanceOf(from);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        token.burn(amount);
        assertEq(token.balanceOf(from), held - amount, "burn did not debit exactly");
        assertEq(token.totalSupply(), supplyBefore - amount, "burn did not lower supply exactly");
        ghostBurned += amount;
    }

    // --------------------------------------------------------------------------------------------
    // Calls the token has no function for
    // --------------------------------------------------------------------------------------------

    /// @notice Failure path: any selector with ether attached is refused, so nothing can be parked
    /// in the token and no payable entry point exists.
    function callWithEther(uint256 fromSeed, bytes4 selector, uint256 value) public {
        address from = _actor(fromSeed);
        value = bound(value, 1, 1 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}(abi.encodeWithSelector(selector, from, uint256(1)));
        assertFalse(ok, "a payable path exists");
        assertEq(address(token).balance, 0, "the token holds ether");
        calls["callWithEther"]++;
    }

    // --------------------------------------------------------------------------------------------
    // Views used by the invariants
    // --------------------------------------------------------------------------------------------

    function sumOfActorBalances() external view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
    }
}

/// @notice Invariants over random handler call sequences. Every token ever minted sits with one of
/// the actors or has been burned, so the ghost ledger must agree with the token after every call.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PaveTokenInvariantTest is Test {
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;

    PaveToken token;
    PaveTokenHandler handler;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new PaveToken();
        handler = new PaveTokenHandler(token, deployer);
        targetContract(address(handler));
    }

    /// @dev Conservation: what the token says exists equals what the actors hold.
    function invariant_supplyEqualsSumOfBalances() public view {
        assertEq(handler.sumOfActorBalances(), token.totalSupply(), "balances do not sum to totalSupply");
    }

    /// @dev Fixed supply: the only way supply changes is a burn, and the ghost ledger knows every burn.
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY - handler.ghostBurned(), "supply drifted from the burn ledger");
        assertLe(token.totalSupply(), INITIAL_SUPPLY, "supply grew");
        assertEq(token.INITIAL_SUPPLY(), INITIAL_SUPPLY, "INITIAL_SUPPLY changed");
    }

    /// @dev The zero address is a sink for burns, never a holder.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }

    /// @dev No single holder can hold more than exists.
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.actors(i)), token.totalSupply(), "a balance exceeds supply");
        }
    }

    /// @dev Allowances change only through approve / increase / decrease / a finite transferFrom,
    /// and only by the amount those calls say.
    function invariant_allowancesMatchShadowLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.shadowAllowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(handler.actors(i), address(0)), 0, "zero spender has an allowance");
        }
    }

    /// @dev Metadata is constant: no call sequence can change what the token calls itself.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "GLOBAL INK");
        assertEq(token.symbol(), "PAVE");
        assertEq(token.decimals(), 18);
    }

    /// @dev The token never accumulates ether and never gains code paths: its runtime is unchanged.
    function invariant_tokenHoldsNoEtherAndCodeIsStable() public view {
        assertEq(address(token).balance, 0, "token holds ether");
        assertEq(keccak256(address(token).code), keccak256(type(PaveToken).runtimeCode), "runtime code changed");
    }
}
