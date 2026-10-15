// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Box is Ownable{

    constructor() Ownable(msg.sender) {}

    uint256 private s_number;

    event NumberChanged(uint256 newNumber);
    function store(uint256 newNumber) public onlyOwner {
        s_number = newNumber;
        emit NumberChanged(newNumber);
}
function getNumber () public view returns (uint256) {
        return s_number;
    }
}