// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DaoGovernance, IShareToken} from "../src/DaoGovernance.sol";
import {YoYo} from "../src/GovToken.sol";
import {TimeController} from "../src/TimeController.sol";
import {Box} from "../src/Box.sol";

contract MockPaymentToken is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MyGovernorTest is Test {
    uint256 private constant SHARE = 1 ether;
    uint256 private constant SHARE_PRICE = 2e6; // 2 payment tokens per share
    uint256 private constant MIN_DELAY = 1 hours;

    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private outsider = makeAddr("outsider");
    address private recipient = makeAddr("recipient");

    YoYo private shareToken;
    MockPaymentToken private paymentToken;
    TimeController private timelock;
    DaoGovernance private dao;
    Box private box;

    function setUp() public {
        vm.startPrank(admin);
        shareToken = new YoYo();
        paymentToken = new MockPaymentToken();
        address[] memory noProposers = new address[](0);
        address[] memory noExecutors = new address[](0);
        timelock = new TimeController(MIN_DELAY, noProposers, noExecutors);
        dao = new DaoGovernance(
            IShareToken(address(shareToken)),
            IERC20(address(paymentToken)),
            SHARE_PRICE,
            timelock,
            admin
        );

        shareToken.transferOwnership(address(dao));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(dao));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        box = new Box();
        box.transferOwnership(address(timelock));
    }

    function testBuySharesAtFixedPriceCreatesVotingMember() public {
        _buyShares(alice, 3 * SHARE);

        assertEq(shareToken.balanceOf(alice), 3 * SHARE);
        assertEq(paymentToken.balanceOf(address(dao)), 6e6);
        assertEq(shareToken.delegates(alice), alice);
        assertTrue(dao.saleOpen());
    }

    function testBuySharesRejectsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(DaoGovernance.InvalidPurchase.selector);
        dao.buyShares(0);
    }

    function testAdminCanCloseSalePermanently() public {
        vm.prank(admin);
        dao.closeSale();
        assertFalse(dao.saleOpen());

        vm.prank(alice);
        vm.expectRevert(DaoGovernance.SaleIsClosed.selector);
        dao.buyShares(SHARE);

        vm.prank(admin);
        vm.expectRevert(DaoGovernance.SaleIsClosed.selector);
        dao.closeSale();
    }

    function testOnlyAdminCanCloseSale() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.closeSale();
    }

    function testMemberCanCreateProposalAndProposalIsRecorded() public {
        _buyShares(alice, 10 * SHARE);
        string memory title = "Community budget";
        string memory information = "Fund community projects";
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxAction(1);

        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 proposalId = dao.proposeWithDetails(targets, values, calldatas, title, information);

        (string memory recordedTitle, string memory recordedInformation) = dao.proposalDetails(proposalId);
        assertEq(recordedTitle, title);
        assertEq(recordedInformation, information);
        assertEq(dao.proposalProposer(proposalId), alice);
    }

    function testOnlyMembersCanPropose() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(outsider);
        vm.expectRevert(DaoGovernance.NotAMember.selector);
        dao.proposeWithDetails(targets, values, calldatas, "No shares", "");
    }

    function testWeightedVotesAreSnapshotShareBalancesAndTalliesAreRecorded() public {
        _buyShares(alice, 60 * SHARE);
        _buyShares(bob, 40 * SHARE);
        uint256 proposalId = _proposeSimple("Weighted decision");
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 1); // For
        vm.prank(bob);
        dao.castVote(proposalId, 0); // Against

        assertTrue(dao.hasVoted(proposalId, alice));
        assertTrue(dao.hasVoted(proposalId, bob));
        assertFalse(dao.hasVoted(proposalId, outsider));

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = dao.proposalVotes(proposalId);
        assertEq(forVotes, 60 * SHARE);
        assertEq(againstVotes, 40 * SHARE);
        assertEq(abstainVotes, 0);
    }

    function testDuplicateVoteIsRejected() public {
        _buyShares(alice, 100 * SHARE);
        uint256 proposalId = _proposeSimple("Single vote");
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 1);
        vm.prank(alice);
        vm.expectRevert(DaoGovernance.AlreadyVoted.selector);
        dao.castVote(proposalId, 0);
    }

    function testNonMemberCannotVote() public {
        _buyShares(alice, 100 * SHARE);
        uint256 proposalId = _proposeSimple("Members only vote");
        _activate(proposalId);

        vm.prank(outsider);
        vm.expectRevert(DaoGovernance.NotAMember.selector);
        dao.castVote(proposalId, 1);
    }

    function testMajorityDecisionIsQueuedAndExecutedByTimelock() public {
        _buyShares(alice, 60 * SHARE);
        _buyShares(bob, 40 * SHARE);
        uint256 newValue = 888;
        string memory description = "Store 888 in Box";
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxAction(newValue);
        uint256 proposalId = _propose(alice, targets, values, calldatas, description);
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 1);
        vm.prank(bob);
        dao.castVote(proposalId, 0);
        _finishVoting(proposalId);

        assertEq(uint256(uint8(dao.state(proposalId))), 4);
        bytes32 descriptionHash = keccak256(bytes(description));
        dao.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint256(uint8(dao.state(proposalId))), 5);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        dao.execute(targets, values, calldatas, descriptionHash);

        assertEq(box.getNumber(), newValue);
        assertEq(uint256(uint8(dao.state(proposalId))), 7);
    }

    function testProposalWithoutForMajorityIsDefeatedAndVotesRemainRecorded() public {
        _buyShares(alice, 60 * SHARE);
        _buyShares(bob, 40 * SHARE);
        uint256 proposalId = _proposeSimple("Rejected decision");
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 0);
        vm.prank(bob);
        dao.castVote(proposalId, 1);
        _finishVoting(proposalId);

        assertEq(uint256(uint8(dao.state(proposalId))), 3);
        (uint256 againstVotes, uint256 forVotes,) = dao.proposalVotes(proposalId);
        assertEq(againstVotes, 60 * SHARE);
        assertEq(forVotes, 40 * SHARE);
        assertTrue(dao.hasVoted(proposalId, alice));
        assertTrue(dao.hasVoted(proposalId, bob));
    }

    function testProposalThatMissesQuorumIsDefeated() public {
        _buyShares(alice, 100 * SHARE);
        uint256 proposalId = _proposeSimple("Quorum test");
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 0);
        _finishVoting(proposalId);

        assertEq(uint256(uint8(dao.state(proposalId))), 3);
    }

    function testApprovedProposalCanTransferTreasuryERC20() public {
        _buyShares(alice, 100 * SHARE);
        uint256 amount = 1_250_000;
        paymentToken.mint(address(dao), 5e6);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(dao);
        calldatas[0] = abi.encodeCall(dao.transferTreasuryToken, (paymentToken, recipient, amount));
        string memory description = "Treasury payout";
        uint256 proposalId = _propose(alice, targets, values, calldatas, description);
        _activate(proposalId);

        vm.prank(alice);
        dao.castVote(proposalId, 1);
        _finishVoting(proposalId);
        bytes32 descriptionHash = keccak256(bytes(description));
        dao.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        dao.execute(targets, values, calldatas, descriptionHash);

        assertEq(paymentToken.balanceOf(recipient), amount);
        assertEq(uint256(uint8(dao.state(proposalId))), 7);
    }

    function _buyShares(address member, uint256 amount) private {
        uint256 payment = amount * SHARE_PRICE / SHARE;
        paymentToken.mint(member, payment);
        vm.startPrank(member);
        paymentToken.approve(address(dao), payment);
        dao.buyShares(amount);
        vm.stopPrank();
    }

    function _proposeSimple(string memory description) private returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxAction(1);
        return _propose(alice, targets, values, calldatas, description);
    }

    function _propose(
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        // Governor checks the proposer's votes at clock() - 1; move past the
        // purchase block so ERC20Votes has a queryable historical checkpoint.
        vm.roll(block.number + 1);
        vm.prank(proposer);
        proposalId = dao.propose(targets, values, calldatas, description);
    }

    function _activate(uint256 proposalId) private {
        vm.roll(dao.proposalSnapshot(proposalId) + 1);
    }

    function _finishVoting(uint256 proposalId) private {
        vm.roll(dao.proposalDeadline(proposalId) + 1);
    }

    function _boxAction(uint256 value)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(box);
        calldatas[0] = abi.encodeCall(box.store, (value));
    }

}
