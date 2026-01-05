// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseContract.sol";
import "./WalletContract.sol";

// Wallet Factory Contract
contract FactoryWalletContract is BaseContract, IFactory {
    mapping(address => bool) private contracts; // All wallet contracts

    event WalletCreated(uint256 requestId, address[] newContracts); // Contract creation success event

    // Create contract
    function create(uint256 requestId, uint256 num) external onlyExecutorEOA {
        address[] memory addrs = new address[](num);
        for (uint256 i; i < num;) {
            // Deploy contract
            WalletContract newContract = new WalletContract();

            // Store new contract address
            address addr = address(newContract);
            contracts[addr] = true;

            // Save to temporary array
            addrs[i] = addr;

            // for
            unchecked { ++i; }
        }

        // Save to permission contract
        IPERMISSION.setAddresses(0, addrs, AddressTypeLib.WALLET, true);

        // Log success
        emit WalletCreated(requestId, addrs);
    }

    // Verify wallet contract
    function check(address addr) external view returns (bool) {
        return contracts[addr];
    }
}