// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaveToken} from "../src/PaveToken.sol";

/// @notice Stands in for the launch factory: deploys the token so the supply is minted to a
/// contract, then transfers on command. Mirrors how ProjectFactory.launchCustom holds the supply.
contract FactoryStub {
    PaveToken public token;

    function deployToken() external returns (PaveToken) {
        token = new PaveToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PaveTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    PaveToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address spender = makeAddr("spender");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new PaveToken();
    }

    // ------------------------------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "GLOBAL INK");
        assertEq(token.symbol(), "PAVE");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWith18Decimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new PaveToken();
    }

    /// @dev At launch the deployer is a contract (the factory). The mint goes to msg.sender, so
    /// the factory holds the whole supply and can pay it out; the constructor calls nothing.
    function test_mintsToAContractDeployer() public {
        FactoryStub factory = new FactoryStub();
        PaveToken launched = factory.deployToken();
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.totalSupply(), SUPPLY);
        // The factory's flows move exactly what they say.
        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.send(alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - swarm);
    }

    function test_constructorTakesNoArgumentsAndHasNoMint() public {
        // No mint / owner / pause surface at all: these selectors do not exist.
        bytes4[7] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("blacklist(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, uint256(1)));
            assertFalse(ok, "unexpected privileged function");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1_000 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 500 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 500 ether));
        assertEq(token.balanceOf(alice), 500 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, 10 ether, 11 ether));
        vm.prank(alice);
        token.transfer(bob, 11 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(PaveToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(alice, 1);
    }

    // ------------------------------------------------------------------------------------------
    // approve / allowance / transferFrom
    // ------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 42);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 42));
        assertEq(token.allowance(deployer, spender), 42);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 100);
        token.approve(spender, 7);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 7);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(PaveToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 40 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 60 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));

        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, spender), 40 ether);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, deployer, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 5);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, deployer, spender, 5, 6));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 6);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(spender, 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_transferFromRevertsToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1);
        vm.expectRevert(PaveToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1);
    }

    function test_transferFromByNonSpenderCannotMoveHolderFunds() public {
        // Nobody, the deployer included, can pull a holder's balance without an allowance.
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, alice, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(deployer);
        assertTrue(token.increaseAllowance(spender, 10));
        assertEq(token.allowance(deployer, spender), 10);
        assertTrue(token.increaseAllowance(spender, 5));
        assertEq(token.allowance(deployer, spender), 15);
        assertTrue(token.decreaseAllowance(spender, 15));
        assertEq(token.allowance(deployer, spender), 0);
        vm.stopPrank();
    }

    function test_decreaseAllowanceBelowZeroReverts() public {
        vm.prank(deployer);
        token.approve(spender, 3);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.AllowanceBelowZero.selector, deployer, spender, 3, 4));
        vm.prank(deployer);
        token.decreaseAllowance(spender, 4);
    }

    function test_increaseAllowanceOverflowReverts() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(); // checked arithmetic panic
        vm.prank(deployer);
        token.increaseAllowance(spender, 1);
    }

    // ------------------------------------------------------------------------------------------
    // burn
    // ------------------------------------------------------------------------------------------

    function test_burnReducesBalanceAndSupply() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 30 ether);
        vm.prank(alice);
        token.burn(30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.totalSupply(), SUPPLY - 30 ether);
    }

    function test_burnMoreThanHeldReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, 1 ether, 1 ether + 1));
        vm.prank(alice);
        token.burn(1 ether + 1);
    }

    function test_burnOnlyAffectsCaller() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(deployer);
        token.burn(1 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 6 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz: conservation and bounds
    // ------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferBeyondBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(PaveToken.InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(PaveToken.InsufficientAllowance.selector, deployer, spender, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, spender), allowed - amount);
        }
    }

    function testFuzz_burnNeverIncreasesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.burn(amount);
        assertEq(token.totalSupply(), SUPPLY - amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
    }

    // ------------------------------------------------------------------------------------------
    // Bytecode: nothing the launch floor refuses
    // ------------------------------------------------------------------------------------------

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
