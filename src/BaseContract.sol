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
    address public constant PERMISSION = 0x67B45f943945087BA607767A9496d830D9b550aF; // Built-in permission contract address

    IPermission internal constant IPERMISSION = IPermission(PERMISSION);  // Permission contract interface
    uint24 internal cacheTime = 30 days;                                  // Cache for 30 days
    mapping(address => mapping(uint256 => uint256)) internal permissions; // Permission cache: address=address, uint256=address type, uint256=cache timestamp

    event PermissionCleared(uint256 requestId); // Cache cleared event

    // Only the Executor EOA can call
    modifier onlyExecutorEOA() {
        require(isExecutorEOA(msg.sender), "unauthorized");
        _;
    }

    // Clear permission cache
    function clearPermission(uint256 requestId, uint24 newCacheTime, address[] calldata addresses, uint256 addrType) external onlyExecutorEOA {
        cacheTime = newCacheTime;
        for (uint256 i = 0; i < addresses.length; ++i) {
            delete permissions[addresses[i]][addrType];
        }
        emit PermissionCleared(requestId);
    }

    // Check if it is an Executor EOA
    function isExecutorEOA(address addr) internal returns (bool) {
        if (block.timestamp < (cacheTime + permissions[addr][AddressTypeLib.EXECUTOR_EOA])) {
            return true;
        }
        if (IPERMISSION.checkAddress(addr, AddressTypeLib.EXECUTOR_EOA)) {
            permissions[addr][AddressTypeLib.EXECUTOR_EOA] = block.timestamp;
            return true;
        }
        return false;
    }
}
