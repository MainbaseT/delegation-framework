// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import { Execution, Caveat, Delegation, ModeCode, CallType, ExecType } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

import { ERC20TotalBalanceChangeEnforcer } from "../../src/enforcers/ERC20TotalBalanceChangeEnforcer.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC20TotalBalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20TotalBalanceChangeEnforcer public enforcer;
    ERC20TransferAmountEnforcer public transferAmountEnforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;

    BasicERC20 public token;
    BasicERC20 public tokenB;

    SwapMock public swapMock;

    address delegator;
    address delegate;
    address delegatorIntegration;
    address delegateIntegration;
    address recipient;
    address someUser;
    address dm;

    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        someUser = address(users.dave.deleGator);
        dm = address(delegationManager);
        vm.label(address(enforcer), "ERC20 Balance Change Enforcer");
        vm.label(address(token), "ERC20 Test Token");
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator, 100) });
        mintExecutionCallData = abi.encode(mintExecution);

        // deploy enforcers
        enforcer = new ERC20TotalBalanceChangeEnforcer();
        transferAmountEnforcer = new ERC20TransferAmountEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();

        delegatorIntegration = address(users.alice.deleGator);

        // Deploy test tokens
        tokenB = new BasicERC20(delegate, "TokenB", "TKB", 0);
        token = new BasicERC20(delegator, "TEST", "TEST", 0);

        // Deploy SwapMock and set it as the delegate
        swapMock = new SwapMock(delegationManager);
        swapMock.setTokens(address(token), address(tokenB));
        delegateIntegration = address(swapMock);

        vm.prank(delegate);
        tokenB.mint(delegateIntegration, 100 ether);
    }

    ////////////////////////////// Basic Functionality //////////////////////////////

    // Validates the terms get decoded correctly for an increase scenario
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(enforceDecrease_, false);
        assertEq(token_, address(token));
        assertEq(recipient_, address(recipient));
        assertEq(amount_, 100);
    }

    // Validates that getHashKey function returns the correct hash
    function test_getHashKey() public {
        address caller_ = address(dm);
        address token_ = address(token);
        address recipient_ = address(delegator);

        bytes32 expectedHash_ = keccak256(abi.encode(caller_, token_, recipient_));
        bytes32 actualHash_ = enforcer.getHashKey(caller_, token_, recipient_);

        assertEq(actualHash_, expectedHash_, "getHashKey should return correct hash");
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Terms: [flag=false, token, recipient, amount=100]
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Increase by 100
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase by 1000
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 1000);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a delegation can be reused with different recipients (for increase) without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Terms for two different recipients (flag=false indicates increase expected)
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(token), address(delegator), uint256(100));

        // Increase for recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase for delegator as recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a balance decrease within the allowed range passes.
    // For decreases (flag = true), the enforcer now checks that the final balance is not below the cached balance minus the
    // allowed amount.
    // Example: if the cached balance is 100 and the allowed decrease is 10, the final balance must be at least 90.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Set an initial balance for the recipient.
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), token, recipient, allowed decrease amount = 10.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        // Cache the initial balance via beforeAllHook.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Simulate a decrease by transferring out 5 tokens (final balance becomes 95, which is >= 100 - 10)
        vm.prank(recipient);
        token.transfer(delegator, 5);

        // afterAllHook should pass since 95 >= 90.
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // New Test: Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount)
    function test_notAllow_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), token, recipient, allowed maximum decrease = 10.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Simulate an excessive decrease: transfer out 20 tokens (final balance becomes 80, which is below 100 - 10).
        vm.prank(recipient);
        token.transfer(delegator, 20);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if an increase hasn't been sufficient
    function test_notAllow_insufficientIncrease() public {
        // Terms: flag=false (increase expected), required increase of 100 tokens.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Mint only 10 tokens (insufficient increase)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 10);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if no increase happens when one is expected
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Cache the initial balance.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Do not modify recipient's balance.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if balance changes between beforeAllHook calls for the same recipient/token pair
    function test_notAllow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // First beforeAllHook call - caches the initial balance
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Modify the recipient's balance between beforeAllHook calls
        vm.prank(delegator);
        token.mint(recipient, 50);

        // Second beforeAllHook call - should revert because balance changed
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:balance-changed"));
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the terms are well formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 73 bytes)
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint8(100));
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 73.
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100), uint256(100));
        vm.expectRevert(bytes("ERC20TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address (address(0)) reverts when calling beforeAllHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(recipient), uint256(100));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert();

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(token), address(recipient)));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, uint256 expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 100);

        vm.prank(delegator);
        token.mint(recipient, 100);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 0);
    }

    // Reverts if the execution mode is invalid (not default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    // Reverts if amount is 0
    function test_revertWithZeroAmount() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient.
    // We are running 3 enforcers in the delegation chain: all increasing by 100. Total expected balance change is an
    // increase of at least 300.
    function test_multiple_enforcers_insufficient_increase() public {
        // Terms: [flag=false, token, recipient, amount=100]
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 299);
        vm.prank(dm);
        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the total balance decrease is correct with multiple decrease enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 10. Total expected balance change is a
    // decrease of at most 20.
    function test_multiple_enforcers_decrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: [flag=true, token, recipient, amount=10]
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(recipient);
        token.transfer(delegator, 20);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        // calling afterAllHook for each beforeAllHook
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple decrease enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 10. Total expected balance change is a
    // decrease of at most 20.
    function test_multiple_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: [flag=true, token, recipient, amount=10]
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(recipient);
        token.transfer(delegator, 21);
        vm.prank(dm);
        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the total balance increase is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 100 and one decreasing by 10. Total expected
    // balance change is an increase of at least 90.
    function test_mixed_enforcers_overall_increase() public {
        // Terms: [flag=false, token, recipient, amount=100]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        // Terms: [flag=true, token, recipient, amount=10]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 90);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the total balance decrease is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 10 and one decreasing by 100. Total expected
    // balance change is a decrease of at most 90.
    function test_mixed_enforcers_overall_decrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: [flag=false, token, recipient, amount=10]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(10));
        // Terms: [flag=true, token, recipient, amount=100]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(recipient);
        token.transfer(delegator, 90);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 100 and one decreasing by 10. Total expected
    // balance change is an increase of at least 90.
    function test_mixed_enforcers_insufficientIncrease() public {
        // Terms: [flag=false, token, recipient, amount=100]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        // Terms: [flag=true, token, recipient, amount=10]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 89);
        vm.prank(dm);
        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 10 and one decreasing by 100. Total expected
    // balance change is a decrease of at most 90.
    function test_mixed_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: [flag=false, token, recipient, amount=10]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(10));
        // Terms: [flag=true, token, recipient, amount=100]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(recipient);
        token.transfer(delegator, 91);
        vm.prank(dm);
        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // First beforeAllHook - should emit both TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.TrackedBalance(dm, recipient, address(token), 0);
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient, address(token), false, 100);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second beforeAllHook - should ONLY emit UpdatedExpectedBalance, NOT TrackedBalance
        vm.recordLogs();

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check the logs to ensure only UpdatedExpectedBalance was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(recipient))))); // recipint
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(token))))); // token

        // Perform the balance change
        vm.prank(delegator);
        token.mint(recipient, 200);

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.ValidatedBalance(dm, recipient, address(token), 200);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook - should not emit any events
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        Vm.Log[] memory afterAllLogs = vm.getRecordedLogs();
        assertEq(afterAllLogs.length, 0, "Should not emit any events");
    }

    // Test events for decrease scenario
    function test_events_emitted_correctly_decrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(50));

        // Test TrackedBalance and UpdatedExpectedBalance events for decrease
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.TrackedBalance(dm, recipient, address(token), 100);
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient, address(token), true, 50);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Perform allowed decrease
        vm.prank(recipient);
        token.transfer(delegator, 30);

        // Test ValidatedBalance event for decrease
        vm.expectEmit(true, true, true, true);
        emit ERC20TotalBalanceChangeEnforcer.ValidatedBalance(dm, recipient, address(token), 50);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Integration tests //////////////////////////////

    /// @notice Tests enforcement of minimum balance increase requirement in a token swap scenario
    /// @dev Verifies that ERC20TotalBalanceChangeEnforcer correctly reverts when:
    ///      1. token is sent from delegator to SwapMock
    ///      2. The required minimum increase in TokenB balance is not met
    /// This test ensures the ERC20TotalBalanceChangeEnforcer properly protects against failed or incomplete swaps
    /// But it is very restrictive because it doesn't allow a space for the payment to be made.
    function test_ERC20TotalBalanceChangeEnforcer_failWhenPaymentNotReceived() public {
        vm.prank(delegator);
        token.mint(delegatorIntegration, 100 ether);
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of token
        bytes memory transferTerms_ = abi.encodePacked(address(token), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegatorIntegration), uint256(2 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of token
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the balance of the recipient to increase by 2 ETH worth of TokenB
        caveats_[1] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase");
        swapMock.swap(delegations_, 1 ether);
    }

    /// @notice Tests nested delegations for a token swap with strict parameter validation
    ///
    /// Flow:
    /// 1. Inner delegation: Alice -> SwapMock
    ///    - Allows SwapMock to transfer token from Alice
    ///
    /// 2. Outer delegation: Alice -> SomeUser
    ///    - Enforces exact swap parameters:
    ///      - Exact calldata for swap function
    ///      - Only allows calling SwapMock contract
    ///      - No ETH value allowed
    ///      - Requires receiving TokenB back
    ///
    /// NOTES:
    /// This approach works but it assumes that the function swap can be called by anyone.
    /// The delegation should be needed in a context where the caller is restricted and this wouldn't work.
    function test_ERC20TotalBalanceChangeEnforcer_nestedDelegations() public {
        vm.prank(delegator);
        token.mint(delegatorIntegration, 100 ether);
        // Create first delegation from Alice to SwapMock allowing transfer of 1 ETH worth of token
        bytes memory transferTerms_ = abi.encodePacked(address(token), uint256(1 ether));

        Caveat[] memory innerCaveats_ = new Caveat[](1);
        // Allows to transfer 1 ETH worth of token
        innerCaveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });

        Delegation memory innerDelegation_ = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: innerCaveats_,
            salt: 0,
            signature: hex""
        });

        innerDelegation_ = signDelegation(users.alice, innerDelegation_);

        Delegation[] memory innerDelegations_ = new Delegation[](1);
        innerDelegations_[0] = innerDelegation_;

        // Create second delegation with exact calldata for swap function
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegatorIntegration), uint256(1 ether));
        Caveat[] memory outerCaveats_ = new Caveat[](4);
        outerCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(exactCalldataEnforcer),
            terms: abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        });
        outerCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(swapMock)) });
        outerCaveats_[2] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encodePacked(uint256(0)) });
        outerCaveats_[3] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory outerDelegation_ = Delegation({
            delegate: address(someUser),
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: outerCaveats_,
            salt: 1,
            signature: hex""
        });

        outerDelegation_ = signDelegation(users.alice, outerDelegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = outerDelegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(
            address(swapMock), 0, abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        );

        assertEq(token.balanceOf(address(delegatorIntegration)), 100 ether, "token balance of delegator should be 100 ether");
        assertEq(tokenB.balanceOf(address(delegatorIntegration)), 0 ether, "TokenB balance of delegator should be 0 ether");
        assertEq(token.balanceOf(address(swapMock)), 0 ether, "token balance of swapMock should be 0 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 100 ether, "TokenB balance of swapMock should be 100 ether");

        vm.prank(someUser);
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        assertEq(token.balanceOf(address(delegatorIntegration)), 99 ether, "token balance of delegator should be 99 ether");
        assertEq(tokenB.balanceOf(address(delegatorIntegration)), 1 ether, "TokenB balance of delegator should be 1 ether");
        assertEq(token.balanceOf(address(swapMock)), 1 ether, "token balance of swapMock should be 1 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 99 ether, "TokenB balance of swapMock should be 99 ether");
    }

    /**
     * @notice Tests insufficient balance increase reverts in ERC20TotalBalanceChangeEnforcer
     * @dev This test verifies that the enforcer properly reverts when total balance increase requirements
     *      are not met across batched delegations. Specifically:
     *      1. Two delegations each require a 1 ETH tokenB balance increase (2 ETH total required)
     *      2. Each delegation allows transfer of 1 ETH token (2 ETH total transferred)
     *      3. Swap attempts to return only 1 ETH tokenB total when 2 ETH is required
     *      4. Transaction reverts due to insufficient balance increase
     *      5. Demonstrates enforcer properly validates cumulative balance changes
     */
    function test_ERC20TotalBalanceChangeEnforcer_revertOnInsufficientBalanceIncrease() public {
        vm.prank(delegator);
        token.mint(delegatorIntegration, 100 ether);
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of token
        bytes memory transferTerms_ = abi.encodePacked(address(token), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(bool(false), address(tokenB), address(delegatorIntegration), uint256(1 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of token
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the total balance increase of 2 ETH worth of TokenB across all delegations
        caveats_[1] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation1 = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory delegation2 = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Creating two redemption flows
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation2;

        vm.expectRevert("ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase");
        swapMock.swapDoubleSpend(delegations_, 1 ether, false);
    }

    /**
     * @notice Tests successful batch delegation redemption with balance change verification
     * @dev This test verifies that multiple delegations can be redeemed successfully with proper balance tracking:
     *      1. Creates two delegations each allowing 1 ETH token transfer and requiring 1 ETH tokenB receipt
     *      2. Executes both delegations in a batch
     *      3. Verifies token was deducted (-2 ETH total) and tokenB was received (+2 ETH total)
     *      4. Demonstrates proper balance accounting across batched delegations
     */
    function test_ERC20BalanceChangeTotalEnforcer_successfulBatchRedemption() public {
        vm.prank(delegator);
        token.mint(delegatorIntegration, 100 ether);
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of token
        bytes memory transferTerms_ = abi.encodePacked(address(token), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(bool(false), address(tokenB), address(delegatorIntegration), uint256(1 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of token
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the total balance increase of 2 ETH worth of TokenB across all delegations
        caveats_[1] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation1 = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory delegation2 = Delegation({
            delegate: delegateIntegration,
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Creating two redemption flows
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation2;

        uint256 tokenBalanceBefore = token.balanceOf(address(delegatorIntegration));
        uint256 tokenBBalanceBefore = tokenB.balanceOf(address(delegatorIntegration));

        swapMock.swapDoubleSpend(delegations_, 1 ether, true);

        assertEq(token.balanceOf(address(delegatorIntegration)), tokenBalanceBefore - 2 ether);
        assertEq(tokenB.balanceOf(address(delegatorIntegration)), tokenBBalanceBefore + 2 ether);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}

// Helper contract for integration tests
contract SwapMock is ExecutionHelper {
    IDelegationManager public delegationManager;
    IERC20 public tokenIn;
    IERC20 public tokenOut;

    error NotSelf();
    error UnsupportedCallType(CallType callType);
    error UnsupportedExecType(ExecType execType);

    /**
     * @notice Require the function call to come from the this contract itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(IDelegationManager _delegationManager) {
        delegationManager = _delegationManager;
    }

    function setTokens(address _tokenIn, address _tokenOut) external {
        tokenIn = IERC20(_tokenIn);
        tokenOut = IERC20(_tokenOut);
    }

    // This contract swaps X amount of tokensIn for the amount of tokensOut
    function swap(Delegation[] memory _delegations, uint256 _amountIn) external {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(tokenIn), 0, abi.encodeCall(IERC20.transfer, (address(this), _amountIn)));

        // If the normal ERC20TotalBalanceChangeEnforcer is used, this will revert because even when the exection is
        // succesful and the tokens get transferred to the SwapMock, this contract doesn't have a change to pay Alice with the
        // tokensOut.
        // Immediately after the execution the balance of Alice should increase and that can't happen here since it needs the
        // redemption to finish to then pay the tokensOut.
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Some condition representing the need for the ERC20 tokensIn at this point to continue with the execution
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));
        require(balanceTokenIn_ >= _amountIn, "SwapMock:insufficient-balance-in");

        // This is a big assumption
        address recipient_ = _delegations[0].delegator;
        // Transfer the amount of tokensOut to the recipient after receiving the tokensIn
        tokenOut.transfer(recipient_, _amountIn);
    }

    // Uses more than one delegation to transfer tokens from the delegator to the SwapMock
    function swapDoubleSpend(Delegation[][] memory _delegations, uint256 _amountIn, bool _isFair) external {
        uint256 length_ = _delegations.length;
        bytes[] memory permissionContexts_ = new bytes[](length_ + 1);
        for (uint256 i = 0; i < length_; i++) {
            permissionContexts_[i] = abi.encode(_delegations[i]);
        }
        permissionContexts_[length_] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](length_ + 1);
        for (uint256 i = 0; i < length_ + 1; i++) {
            encodedModes_[i] = ModeLib.encodeSimpleSingle();
        }

        bytes memory executionCalldata_ = ExecutionLib.encodeSingle(
            address(tokenIn), 0, abi.encodeWithSelector(IERC20.transfer.selector, address(this), _amountIn)
        );
        bytes[] memory executionCallDatas_ = new bytes[](length_ + 1);
        for (uint256 i = 0; i < length_; i++) {
            executionCallDatas_[i] = executionCalldata_;
        }

        bytes4 selector_ = _isFair ? this.validateAndTransferFair.selector : this.validateAndTransferUnfair.selector;

        // This is a big assumption
        // The first delegation.delegate is the one that will receive the tokensOut
        executionCallDatas_[length_] = ExecutionLib.encodeSingle(
            address(this), 0, abi.encodeWithSelector(selector_, _delegations[0][0].delegator, length_, _amountIn)
        );

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Validates that enough tokens were received and transfers output tokens to caller
     * @dev Can only be called by this contract itself via onlySelf modifier
     * @param _delegationsLength The number of delegations that were processed
     * @param _amountIn The input amount per delegation
     */
    function validateAndTransferUnfair(address _recipient, uint256 _delegationsLength, uint256 _amountIn) external onlySelf {
        // Some condition representing the need for the ERC20 tokensIn at this point
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));

        // Required the amount in multiple times
        require(balanceTokenIn_ >= _amountIn * _delegationsLength, "SwapMock:insufficient-balance-in");

        // No matter how many delegations are processed, the amount of tokenB is the amountIn only once.
        // To make it fair, we would need to transfer the amountIn for each delegation.
        tokenOut.transfer(_recipient, _amountIn);
    }

    /**
     * @notice Validates that enough tokens were received and transfers output tokens to caller
     * @dev Can only be called by this contract itself via onlySelf modifier
     * @param _delegationsLength The number of delegations that were processed
     * @param _amountIn The input amount per delegation
     */
    function validateAndTransferFair(address _recipient, uint256 _delegationsLength, uint256 _amountIn) external onlySelf {
        // Some condition representing the need for the ERC20 tokensIn at this point
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));

        uint256 fairAmount_ = _amountIn * _delegationsLength;

        // Required the amount in multiple times
        require(balanceTokenIn_ >= fairAmount_, "SwapMock:insufficient-balance-in");

        // This makes it fair, for each token the same amount of tokenB
        tokenOut.transfer(_recipient, fairAmount_);
    }

    /**
     * @notice Executes one calls on behalf of this contract,
     *         authorized by the DelegationManager.
     * @dev Only callable by the DelegationManager. Supports single-call execution,
     *         and handles the revert logic via ExecType.
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @param _mode The encoded execution mode of the transaction (CallType, ExecType, etc.).
     * @param _executionCalldata The encoded call data (single) to be executed.
     * @return returnData_ An array of returned data from each executed call.
     */
    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        returns (bytes[] memory returnData_)
    {
        require(msg.sender == address(delegationManager), "SwapMock:not-delegation-manager");

        (CallType callType_, ExecType execType_,,) = ModeLib.decode(_mode);

        // Only support single call type with default execution
        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) revert UnsupportedCallType(callType_);
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) revert UnsupportedExecType(execType_);

        // Process single execution directly without additional checks
        (address target_, uint256 value_, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCalldata);

        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
        return returnData_;
    }
}
