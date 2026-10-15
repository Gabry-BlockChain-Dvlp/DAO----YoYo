// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {MyGovernor} from "../src/MyGovernor.sol";
import {YoYo} from "../src/GovToken.sol";
import {TimeController} from "../src/TimeController.sol";
import {Box} from "../src/Box.sol";

contract MyGovernorTest is Test {
    MyGovernor governor;
    YoYo govToken;
    TimeController timelock;
    Box box;

    uint256 public constant INITIAL_SUPPLY = 1000 ether;
    address public USER = makeAddr("user");
    uint256 public constant MIN_DELAY = 3600; // 1 hour
    uint256 public constant VOTING_DELAY = 1; // 1 block
    uint256 public constant VOTING_PERIOD = 50400; // 1 week

    address[] proposers;
    address[] executors;

    function setUp() public {
        YoYo token = new YoYo();
        govToken = token;
        deal(address(token), USER, INITIAL_SUPPLY);

        vm.startPrank(USER);
        token.delegate(USER);
        timelock = new TimeController(MIN_DELAY, proposers, executors);
        governor = new MyGovernor(govToken, timelock);

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0));
        timelock.revokeRole(adminRole, address(this));

        vm.stopPrank();

        box = new Box();
        box.transferOwnership(address(timelock));
    }

    function testCanUpdateBoxWhitoutGovernance() public {
        vm.expectRevert();
        box.store(1);
    }

    function testGovernanceUpdateBox() public {
        uint256 valueToStore = 888;
        string memory description = "Proposal #1: Store 888 in Box";
        bytes memory encodedFunctionCall = abi.encodeWithSignature("store(uint256)", valueToStore);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(box);
        values[0] = 0;
        calldatas[0] = encodedFunctionCall;

        uint256 proposalId = governor.propose(targets, values, calldatas, description);
       //.View the state of the proposal before voting
        console.log("Proposal State: ", uint256(governor.state(proposalId)));

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.roll(block.number + VOTING_DELAY +1);
        console.log("Proposal State: ", uint256(governor.state(proposalId)));

        string memory reason = "I like this proposal";
        uint8 voteWay = 1;

        vm.prank(USER);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.roll(block.number + VOTING_PERIOD + 1);
        
        governor.castVoteWithReason(proposalId, voteWay, reason);

        // Queue the proposal for execution
        bytes32 descriptionHash = keccak256(abi.encodePacked(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        // Execute the proposal
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.roll(block.number + MIN_DELAY + 1);

        governor.execute(targets, values, calldatas, descriptionHash);

        console.log("Box value: " , box.getNumber());
        assert(box.getNumber() == valueToStore);
    }
}