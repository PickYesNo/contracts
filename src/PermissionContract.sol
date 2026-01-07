// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./Common.sol";

// Permission Contract
contract PermissionContract is IPermission {
    address public feeEOA = 0x0000000000000000000000000000000000000000;       // Built-in fee EOA
    address public managerEOA = 0x0000000000000000000000000000000000000000;   // Built-in manager EOA
    address public operationEOA = 0x0000000000000000000000000000000000000000; // Built-in operation EOA
    uint256 public nonce;                                                     // Signature nonce for replay protection

    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant TYPEHASH_SET_FEE_EOA = keccak256("SetFeeEOA(address feeEOA,uint256 chainId,address permissionContract)");
    bytes32 private constant TYPEHASH_SET_MANAGER_EOA = keccak256("SetManagerEOA(address managerEOA,uint256 chainId,address permissionContract)");
    bytes32 private constant TYPEHASH_SET_OPERATION_EOA = keccak256("SetOperationEOA(address operationEOA,uint256 chainId,address permissionContract)");
    bytes32 private constant TYPEHASH_MULTISIG_FEE_EOA = keccak256("MultisigFeeEOA(address feeEOA,uint256 nonce,uint256 chainId,address permissionContract)");
    bytes32 private constant TYPEHASH_MULTISIG_MANAGER_EOA = keccak256("MultisigManagerEOA(address managerEOA,uint256 nonce,uint256 chainId,address permissionContract)");
    bytes32 private constant TYPEHASH_MULTISIG_OPERATION_EOA = keccak256("MultisigOperationEOA(address operationEOA,uint256 nonce,uint256 chainId,address permissionContract)");

    mapping(address => mapping(uint256 => uint256)) private addressMapping; // All addresses
    Address[] private addressArray;                                         // All addresses

    event FeeEOASet(uint256 requestId);                    // Fee EOA set event
    event ManagerEOASet(uint256 requestId);                // Manager EOA set event
    event OperationEOASet(uint256 requestId);              // Operation EOA set event
    event AddressSet(uint256 requestId, uint256 addrType); // Address set event

    // address
    struct Address {
        address addr;    // address value
        uint32 addrType; // address type
        bool value;      // false=disabled, true=enabled
    }

    // Initialization
    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(EIP712Lib.EIP712_DOMAIN, keccak256(bytes("Permission Contract")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    // Set fee EOA
    function setFeeEOA(uint256 requestId, address newFeeEOA, bytes calldata signature, bytes[] calldata signatures) external {
        // Only the fee EOA can call or multisig call
        if (msg.sender != feeEOA) {
            require(_checkMultisig(signatures, TYPEHASH_MULTISIG_FEE_EOA, newFeeEOA, nonce++, managerEOA, operationEOA), "unauthorized");
        }

        // Set address
        address addr = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_SET_FEE_EOA, newFeeEOA, block.chainid, address(this)), signature);
        require(addr != address(0) && addr == newFeeEOA, "addr err");
        feeEOA = newFeeEOA;

        // Log success
        emit FeeEOASet(requestId);
    }

    // Set manager EOA
    function setManagerEOA(uint256 requestId, address newManagerEOA, bytes calldata signature, bytes[] calldata signatures) external {
        // Only the manager EOA can call or multisig call
        if (msg.sender != managerEOA) {
            require(_checkMultisig(signatures, TYPEHASH_MULTISIG_MANAGER_EOA, newManagerEOA, nonce++, feeEOA, operationEOA), "unauthorized");
        }

        // Set address
        address addr = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_SET_MANAGER_EOA, newManagerEOA, block.chainid, address(this)), signature);
        require(addr != address(0) && addr == newManagerEOA, "addr err");
        managerEOA = newManagerEOA;

        // Log success
        emit ManagerEOASet(requestId);
    }

    // Set operation EOA
    function setOperationEOA(uint256 requestId, address newOperationEOA, bytes calldata signature, bytes[] calldata signatures) external {
        // Only the operation EOA can call or multisig call
        if (msg.sender != operationEOA) {
            require(_checkMultisig(signatures, TYPEHASH_MULTISIG_OPERATION_EOA, newOperationEOA, nonce++, feeEOA, managerEOA), "unauthorized");
        }

        // Set address
        address addr = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_SET_OPERATION_EOA, newOperationEOA, block.chainid, address(this)), signature);
        require(addr != address(0) && addr == newOperationEOA, "addr err");
        operationEOA = newOperationEOA;

        // Log success
        emit OperationEOASet(requestId);
    }

    // Set address
    function setAddress(uint256 requestId, address newAddress, uint256 addrType, bool value) external {
        // Only factory contract or manager EOA can call
        require(addressMapping[msg.sender][AddressTypeLib.PREDICTION_FACTORY] == 1 || addressMapping[msg.sender][AddressTypeLib.WALLET_FACTORY] == 1 || msg.sender == managerEOA, "unauthorized");

        // set address
        require(newAddress != address(0), "param err");
        if (addressMapping[newAddress][addrType] == 0) {
            addressArray.push(Address(newAddress, uint32(addrType), value));
        }
        addressMapping[newAddress][addrType] = value ? 1 : 2;

        // Log success
        emit AddressSet(requestId, addrType);
    }

    // Set address
    function setAddresses(uint256 requestId, address[] calldata newAddresses, uint256 addrType, bool value) external {
        // Only factory contract or manager EOA can call
        require(addressMapping[msg.sender][AddressTypeLib.PREDICTION_FACTORY] == 1 || addressMapping[msg.sender][AddressTypeLib.WALLET_FACTORY] == 1 || msg.sender == managerEOA, "unauthorized");

        // set address
        uint256 len = newAddresses.length;
        for (uint256 i; i < len;) {
            require(newAddresses[i] != address(0), "param err");
            if (addressMapping[newAddresses[i]][addrType] == 0) {
                addressArray.push(Address(newAddresses[i], uint32(addrType), value));
            }
            addressMapping[newAddresses[i]][addrType] = value ? 1 : 2;

            // for
            unchecked { ++i; }
        }

        // Log success
        emit AddressSet(requestId, addrType);
    }

    // Get contracts from the array starting from `start` with `length` length
    function getAddresses(uint256 start, uint256 length) external view returns (uint256, Address[] memory) {
        // If start is out of bounds, return an empty array
        uint256 totalLength = addressArray.length;
        if (start >= totalLength || length == 0) {
            return (totalLength, new Address[](0));
        }

        // Calculate valid length: ensure returned data doesn't exceed total array length
        uint256 validLength = (start + length > totalLength) ? totalLength - start : length;

        // Create a new array to store the subarray
        Address[] memory subArray = new Address[](validLength);

        // Copy partial data from original array to the new array
        for (uint256 i; i < validLength;) {
            Address storage temp = addressArray[start + i];
            subArray[i].addr = temp.addr;
            subArray[i].addrType = temp.addrType;
            subArray[i].value = addressMapping[temp.addr][temp.addrType] == 1;

            // for
            unchecked { ++i; }
        }

        // Return the new array
        return (totalLength, subArray);
    }

    // Check if address is valid
    function checkAddress(address addr, uint256 addrType) external view returns (bool) {
        return addressMapping[addr][addrType] == 1;
    }
    
    // Check if both addresses is valid
    function checkAddress2(address addr1, uint256 addrType1, address addr2, uint256 addrType2) external view returns (bool) {
        return addressMapping[addr1][addrType1] == 1 && addressMapping[addr2][addrType2] == 1;
    }
    
    // Check if both addresses is valid
    function checkAddress3(address addr1, uint256 addrType1, address addr2, uint256 addrType2, address addr3, uint256 addrType3) external view returns (bool) {
        return addressMapping[addr1][addrType1] == 1 && addressMapping[addr2][addrType2] == 1 && addressMapping[addr3][addrType3] == 1;
    }

    // Verify multisig to recover EOA
    function _checkMultisig(bytes[] memory signatures, bytes32 typeHash, address newEOA, uint256 currentNonce, address signatureEOA1, address signatureEOA2) private view returns (bool) {
        if (signatures.length != 2) {
            return false;
        }
        bytes memory hash = abi.encode(typeHash, newEOA, currentNonce, block.chainid, address(this));
        address addr1 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, hash, signatures[0]);
        address addr2 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, hash, signatures[1]);
        return addr1 != address(0) && addr2 != address(0) && addr1 != addr2 && addr1 == signatureEOA1 && addr2 == signatureEOA2;
    }
}