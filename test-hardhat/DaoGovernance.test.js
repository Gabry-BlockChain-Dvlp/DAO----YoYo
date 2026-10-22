const { expect } = require("chai");
const { ethers } = require("hardhat");

const SHARE = ethers.parseEther("1");
const SHARE_PRICE = ethers.parseUnits("2", 6);
const MIN_DELAY = 60;

describe("DaoGovernance", function () {
  let admin, alice, bob, outsider, recipient, payment, shares, timelock, dao;

  async function buy(account, amount) {
    const cost = amount * SHARE_PRICE / SHARE;
    await payment.mint(account.address, cost);
    await payment.connect(account).approve(await dao.getAddress(), cost);
    await dao.connect(account).buyShares(amount);
  }

  async function propose(targets, values, calldatas, title, information = "") {
    const tx = await dao.connect(alice).proposeWithDetails(targets, values, calldatas, title, information);
    const receipt = await tx.wait();
    const event = receipt.logs.map((log) => {
      try { return dao.interface.parseLog(log); } catch { return null; }
    }).find((log) => log?.name === "ProposalRecorded");
    return event.args.proposalId;
  }

  async function mineTo(blockNumber) {
    const current = BigInt(await ethers.provider.getBlockNumber());
    if (current < blockNumber) await ethers.provider.send("hardhat_mine", [ethers.toQuantity(blockNumber - current)]);
  }

  async function moveToActive(proposalId) {
    await mineTo((await dao.proposalSnapshot(proposalId)) + 1n);
    expect(await dao.state(proposalId)).to.equal(1n);
  }

  async function finishVoting(proposalId) {
    await mineTo((await dao.proposalDeadline(proposalId)) + 1n);
  }

  beforeEach(async function () {
    [admin, alice, bob, outsider, recipient] = await ethers.getSigners();
    payment = await (await ethers.getContractFactory("MockERC20")).deploy("Payment", "PAY", 6);
    shares = await (await ethers.getContractFactory("YoYo")).deploy();
    timelock = await (await ethers.getContractFactory("TimeController")).deploy(MIN_DELAY, [], []);
    dao = await (await ethers.getContractFactory("DaoGovernance")).deploy(
      await shares.getAddress(), await payment.getAddress(), SHARE_PRICE, await timelock.getAddress(), admin.address,
    );
    await shares.transferOwnership(await dao.getAddress());
    await timelock.grantRole(await timelock.PROPOSER_ROLE(), await dao.getAddress());
    await timelock.grantRole(await timelock.EXECUTOR_ROLE(), ethers.ZeroAddress);
    await timelock.renounceRole(await timelock.DEFAULT_ADMIN_ROLE(), admin.address);
  });

  it("sells shares at the fixed price and creates voting members", async function () {
    await buy(alice, 3n * SHARE);
    expect(await shares.balanceOf(alice.address)).to.equal(3n * SHARE);
    expect(await payment.balanceOf(await dao.getAddress())).to.equal(6_000_000n);
    expect(await shares.delegates(alice.address)).to.equal(alice.address);
    expect(await dao.saleOpen()).to.equal(true);
  });

  it("lets the administrator close the sale permanently", async function () {
    await dao.closeSale();
    expect(await dao.saleOpen()).to.equal(false);
    await expect(dao.connect(alice).buyShares(SHARE)).to.be.revertedWithCustomError(dao, "SaleIsClosed");
    await expect(dao.closeSale()).to.be.revertedWithCustomError(dao, "SaleIsClosed");
  });

  it("records proposal details and rejects proposers without shares", async function () {
    await buy(alice, 10n * SHARE);
    const id = await propose([], [], [], "Budget", "Fund community work");
    const details = await dao.proposalDetails(id);
    expect(details.title).to.equal("Budget");
    expect(details.information).to.equal("Fund community work");
    expect(await dao.proposalProposer(id)).to.equal(alice.address);
    await expect(dao.connect(outsider).proposeWithDetails([], [], [], "No shares", ""))
      .to.be.revertedWithCustomError(dao, "NotAMember");
  });

  it("weights votes by snapshot share balance and records each member's vote", async function () {
    await buy(alice, 60n * SHARE);
    await buy(bob, 40n * SHARE);
    const id = await propose([], [], [], "Weighted vote");
    await moveToActive(id);
    await dao.connect(alice).castVote(id, 1);
    await dao.connect(bob).castVote(id, 0);
    expect(await dao.hasVoted(id, alice.address)).to.equal(true);
    expect(await dao.hasVoted(id, bob.address)).to.equal(true);
    expect(await dao.hasVoted(id, outsider.address)).to.equal(false);
    const votes = await dao.proposalVotes(id);
    expect(votes.againstVotes).to.equal(40n * SHARE);
    expect(votes.forVotes).to.equal(60n * SHARE);
    expect(votes.abstainVotes).to.equal(0n);
  });

  it("rejects nonmember votes and duplicate votes", async function () {
    await buy(alice, 100n * SHARE);
    const id = await propose([], [], [], "Member vote");
    await moveToActive(id);
    await expect(dao.connect(outsider).castVote(id, 1)).to.be.revertedWithCustomError(dao, "GovernorInvalidVote");
    await dao.connect(alice).castVote(id, 1);
    await expect(dao.connect(alice).castVote(id, 0)).to.be.revertedWithCustomError(dao, "AlreadyVoted");
  });

  it("approves a majority decision and records successful timelock execution", async function () {
    await buy(alice, 60n * SHARE);
    await buy(bob, 40n * SHARE);
    const description = "Set treasury marker";
    const marker = await (await ethers.getContractFactory("GovernanceMarker")).deploy();
    const targets = [await marker.getAddress()];
    const values = [0];
    const calldatas = [marker.interface.encodeFunctionData("setValue", [42])];
    const id = await propose(targets, values, calldatas, description);
    await moveToActive(id);
    await dao.connect(alice).castVote(id, 1);
    await dao.connect(bob).castVote(id, 0);
    await finishVoting(id);
    expect(await dao.state(id)).to.equal(4n);
    const hash = ethers.keccak256(ethers.toUtf8Bytes(description));
    await dao.queue(targets, values, calldatas, hash);
    expect(await dao.state(id)).to.equal(5n);
    await ethers.provider.send("evm_increaseTime", [MIN_DELAY + 1]);
    await ethers.provider.send("evm_mine", []);
    await dao.execute(targets, values, calldatas, hash);
    expect(await marker.value()).to.equal(42n);
    expect(await dao.state(id)).to.equal(7n);
  });

  it("defeats proposals without a majority and keeps vote tallies", async function () {
    await buy(alice, 100n * SHARE);
    const id = await propose([], [], [], "Rejected decision");
    await moveToActive(id);
    await dao.connect(alice).castVote(id, 0);
    await finishVoting(id);
    expect(await dao.state(id)).to.equal(3n);
    expect(await dao.hasVoted(id, alice.address)).to.equal(true);
    const votes = await dao.proposalVotes(id);
    expect(votes.againstVotes).to.equal(100n * SHARE);
    expect(votes.forVotes).to.equal(0n);
  });

  it("executes treasury ERC-20 transfers only through approved governance", async function () {
    await buy(alice, 100n * SHARE);
    await payment.mint(await dao.getAddress(), 5_000_000n);
    const amount = 1_250_000n;
    const targets = [await dao.getAddress()];
    const values = [0];
    const calldatas = [dao.interface.encodeFunctionData("transferTreasuryToken", [await payment.getAddress(), recipient.address, amount])];
    const id = await propose(targets, values, calldatas, "Treasury payout");
    await moveToActive(id);
    await dao.connect(alice).castVote(id, 1);
    await finishVoting(id);
    const hash = ethers.keccak256(ethers.toUtf8Bytes("Treasury payout"));
    await dao.queue(targets, values, calldatas, hash);
    await ethers.provider.send("evm_increaseTime", [MIN_DELAY + 1]);
    await ethers.provider.send("evm_mine", []);
    await dao.execute(targets, values, calldatas, hash);
    expect(await payment.balanceOf(recipient.address)).to.equal(amount);
  });
});