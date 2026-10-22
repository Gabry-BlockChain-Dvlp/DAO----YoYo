// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Non-transfer-restricted governance shares with checkpointed, delegatable votes.
/// The DAO governance contract must be made owner after deployment to mint shares from sales.
contract YoYo is ERC20, ERC20Permit, ERC20Votes, Ownable {
    error DelegateMustBeMember();

    constructor() ERC20("YoYo", "Yo") ERC20Permit("YoYo") Ownable(msg.sender) {}

    function mintFor(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
        // A new holder starts with direct voting power. Existing delegations are preserved.
        if (delegates(account) == address(0)) {
            _delegate(account, account);
        }
    }

    /// @notice Liquid delegation is restricted to existing DAO share holders.
    function delegate(address delegatee) public override {
        if (delegatee != address(0) && balanceOf(delegatee) == 0) {
            revert DelegateMustBeMember();
        }
        super.delegate(delegatee);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner_)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner_);
    }
}
