# YoYo DAO

A Foundry project implementing direct and liquid democracy with ERC-20 governance shares.

## Governance models

- **Direct democracy:** every share holder can vote on proposals, with voting weight equal to their share balance at the proposal snapshot.
- **Liquid democracy:** a member may call `delegate(memberAddress)` on the YoYo share token to transfer their voting power to another member. They can change or revoke that delegation at any time. OpenZeppelin ERC20Votes checkpoints voting power so delegation changes do not rewrite past votes.
- Voting supports **For**, **Against**, and **Abstain**. A proposal succeeds when For votes exceed Against votes and the required quorum is reached. The default quorum is 4% of the share supply.
- Approved operations are queued through the timelock before execution.

## Contracts

- `GovToken.sol`: ERC20Votes shares. New purchasers start with direct self-delegation; existing delegates are preserved on later purchases.
- `DaoGovernance.sol`: fixed-price primary sale, membership-gated proposals, vote records, metadata, and timelocked treasury actions.
- `TimeController.sol`: OpenZeppelin timelock.
- `MyGovernor.sol`: the original Governor example retained for comparison.

## Deployment outline

1. Deploy the `YoYo` share token.
2. Deploy the payment ERC-20 (or select an existing ERC-20).
3. Deploy `TimeController` with empty proposer and executor lists; the deployer is its temporary admin.
4. Deploy `DaoGovernance` with the share token, payment token, price, timelock, and administrator address.
5. Transfer ownership of `YoYo` to `DaoGovernance`. This authorizes the governance contract to mint shares for completed purchases.
6. As timelock admin, grant `DaoGovernance` the proposer role and make execution available (for example, grant executor role to `address(0)`). Then renounce the timelock admin role to finish setup.

The share price is specified in payment-token smallest units per whole share, scaled by `1e18`. For example, `2e6` is a price of two USDC (6 decimals) per one share. Buyers call `approve` on the payment token and then `buyShares`. The administrator ends the initialization sale with `closeSale()`; closure is permanent.

A member may submit a simple proposal through `propose`, or use `proposeWithDetails` to store a title and extra information. To send ERC-20 tokens from the DAO treasury, create a proposal targeting `DaoGovernance.transferTreasuryToken(token, recipient, amount)`. The timelock performs the transfer only after the proposal passes, is queued, and its delay elapses.

The direct and liquid voting paths both use ERC20Votes delegation. A newly minted holder is self-delegated automatically; to use liquid democracy, the holder explicitly delegates their shares to another address. Votes are weighted by the delegated share balance at the proposal snapshot. Transfers of shares are allowed, so holdings and voting power can change between proposals.

## Build

```sh
forge build
forge test
```

## Hardhat tests

Install the JavaScript dependencies and run the governance integration suite:

```sh
npm install
npm run test:hardhat
```

The Hardhat suite exercises share purchases and membership, proposal metadata, weighted snapshots, vote records and restrictions, majority/quorum outcomes, timelock execution, and treasury token transfers. Foundry remains available for the existing Solidity tests.
