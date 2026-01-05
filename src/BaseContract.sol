// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./Common.sol";

// Base contract
abstract contract BaseContract {
    address public constant PERMISSION = 0x0000000000000000000000000000000000000000; // Built-in permission contract address

    IPermission internal constant IPERMISSION = IPermission(PERMISSION);  // Permission contract interface

    // Only the Executor EOA can call
    modifier onlyExecutorEOA() {
        require(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA), "unauthorized");
        _;
    }
}