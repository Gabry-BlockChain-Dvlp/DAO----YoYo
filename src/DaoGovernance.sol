// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IShareToken is IVotes {
    function mintFor(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Token-sale membership and direct/liquid voting, with timelocked execution.
contract DaoGovernance is
    Governor,
    GovernorSettings,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    Ownable
{
    using SafeERC20 for IERC20;

    uint256 private constant SHARE_SCALE = 1e18;

    IShareToken public immutable shareToken;
    IERC20 public immutable paymentToken;
    uint256 public immutable pricePerShare;
    bool public saleOpen = true;

    struct ProposalDetails {
        string title;
        string information;
    }

    mapping(uint256 proposalId => ProposalDetails details) public proposalDetails;

    // Per-proposal tallies use each member's shares at the proposal snapshot.
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address voter => bool) hasVoted;
    }
    mapping(uint256 proposalId => ProposalVote tally) private _proposalVotes;

    event VoteCast(address indexed voter, uint256 indexed proposalId, uint8 support, uint256 weight);

    event SharesPurchased(address indexed member, uint256 shares, uint256 payment);
    event SaleClosed();
    event ProposalRecorded(uint256 indexed proposalId, address indexed proposer, string title, string information);

    error SaleIsClosed();
    error InvalidPurchase();
    error NotAMember();
    error EmptyTitle();
    error InvalidVoteType();
    error AlreadyVoted();

    constructor(
        IShareToken token,
        IERC20 payment,
        uint256 sharePrice,
        TimelockController timelock,
        address admin
    )
        Governor("YoYo DAO")
        GovernorSettings(1, 50_400, 1e18)
        GovernorVotes(IVotes(address(token)))
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(timelock)
        Ownable(admin)
    {
        require(address(token) != address(0) && address(payment) != address(0), "zero token");
        require(address(timelock) != address(0) && sharePrice > 0, "invalid config");
        shareToken = token;
        paymentToken = payment;
        pricePerShare = sharePrice;
    }

    /// @notice Buy voting shares. Price is payment-token smallest units per whole share,
    ///         scaled by 1e18. For example, 2e18 means 2 payment tokens per share.
    function buyShares(uint256 shares) external {
        if (!saleOpen) revert SaleIsClosed();
        if (shares == 0) revert InvalidPurchase();

        uint256 payment = (shares * pricePerShare) / SHARE_SCALE;
        if (payment == 0 || payment * SHARE_SCALE / pricePerShare != shares) {
            revert InvalidPurchase();
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), payment);
        shareToken.mintFor(msg.sender, shares);
        emit SharesPurchased(msg.sender, shares, payment);
    }

    /// @notice Permanently ends primary share sales.
    function closeSale() external onlyOwner {
        if (!saleOpen) revert SaleIsClosed();
        saleOpen = false;
        emit SaleClosed();
    }

    /// @notice Standard Governor proposal entry point; description is used as its title.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256 proposalId) {
        _requireMember();
        proposalId = super.propose(targets, values, calldatas, description);
        proposalDetails[proposalId] = ProposalDetails(description, "");
        emit ProposalRecorded(proposalId, msg.sender, description, "");
    }

    /// @notice Proposal with separate title and additional information.
    function proposeWithDetails(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string calldata title,
        string calldata information
    ) external returns (uint256 proposalId) {
        _requireMember();
        if (bytes(title).length == 0) revert EmptyTitle();
        string memory description = string.concat(title, "\n\n", information);
        proposalId = super.propose(targets, values, calldatas, description);
        proposalDetails[proposalId] = ProposalDetails(title, information);
        emit ProposalRecorded(proposalId, msg.sender, title, information);
    }

    /// @notice Treasury transfers can only run as an approved, timelocked governance action.
    function transferTreasuryToken(IERC20 token, address recipient, uint256 amount)
        external
        onlyGovernance
    {
        require(recipient != address(0), "zero recipient");
        token.safeTransfer(recipient, amount);
    }

    function _requireMember() internal view {
        if (shareToken.balanceOf(msg.sender) == 0) revert NotAMember();
    }

    /// @notice Direct voting weight is the voter's own share balance at proposal creation.
    /// Delegated shares are added by ERC20Votes to the delegate's checkpointed balance.
    function _getVotes(address account, uint256 timepoint, bytes memory params)
        internal view override(Governor, GovernorVotes) returns (uint256)
    {
        return super._getVotes(account, timepoint, params);
    }

    /// @notice Describes the ballot choices and quorum rule to Governor clients.
    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    /// @notice Count one vote per member, weighted by their shares at the proposal snapshot.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 totalWeight, bytes memory)
        internal override returns (uint256)
    {
        // Governor accepts zero-weight ballots unless the counting extension rejects them.
        // Membership is based on owned shares, not delegated voting power.
        if (shareToken.balanceOf(account) == 0) revert NotAMember();

        ProposalVote storage tally = _proposalVotes[proposalId];
        if (tally.hasVoted[account]) revert AlreadyVoted();
        if (support > 2) revert InvalidVoteType();
        tally.hasVoted[account] = true;
        if (support == 0) tally.againstVotes += totalWeight;
        else if (support == 1) tally.forVotes += totalWeight;
        else tally.abstainVotes += totalWeight;
        emit VoteCast(account, proposalId, support, totalWeight);
        return totalWeight;
    }

    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    function proposalVotes(uint256 proposalId) public view returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) {
        ProposalVote storage tally = _proposalVotes[proposalId];
        return (tally.againstVotes, tally.forVotes, tally.abstainVotes);
    }

    function _quorumReached(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage tally = _proposalVotes[proposalId];
        return quorum(proposalSnapshot(proposalId)) <= tally.forVotes + tally.abstainVotes;
    }

    function _voteSucceeded(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage tally = _proposalVotes[proposalId];
        return tally.forVotes > tally.againstVotes;
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
