// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";


contract TimeController is TimelockController {
// minDelay is the minimum time that must pass before a queued operation can be executed. This is a security feature to prevent immediate execution of potentially malicious operations.
// Proposers are the addresses that are allowed to propose operations to be executed after the delay.  
// Executors are the addresses that are allowed to execute the operations after the delay has passed. The admin is the address that can manage the proposers and executors, and can also cancel operations.
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController (minDelay, proposers, executors, msg.sender) {}
}