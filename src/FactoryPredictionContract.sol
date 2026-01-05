// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseContract.sol";
import "./PredictionContract.sol";

// Prediction Factory Contract
contract FactoryPredictionContract is BaseContract, IFactory {
    mapping(address => bool) private contracts; // All prediction contracts
        
    event PredictionCreated(uint256 requestId, address newContract, bytes32 predictionHash, address oracle); // Contract creation success event

    // Create a prediction contract
    function create(uint256 requestId, bytes32 newPredictionHash, address newOracle, PredictionSetting[] calldata newSettings) external onlyExecutorEOA {
        // Check if the oracle is valid
        require(IPERMISSION.checkAddress(newOracle, AddressTypeLib.ORACLE), "oracle err");

        // Deploy the contract
        PredictionContract newContract = new PredictionContract(newPredictionHash, newOracle, newSettings);

        // Store the new contract address
        address addr = address(newContract);
        contracts[addr] = true;

        // Save to the permission contract
        IPERMISSION.setAddress(0, addr, AddressTypeLib.PREDICTION, true);

        // Log success
        emit PredictionCreated(requestId, addr, newPredictionHash, newOracle);
    }

    // Verify a prediction contract
    function check(address addr) external view returns (bool) {
        return contracts[addr];
    }    
}