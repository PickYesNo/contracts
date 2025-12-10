// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseUsdcContract.sol";

// Marketing Contract
contract MarketingContract is BaseUsdcContract, IMarketing {
    mapping(address => uint256) public nonces; // Signature nonce, for replay protection

    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant TYPEHASH_EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TYPEHASH_TRANSFER_FROM = keccak256("TransferFrom(uint256 amount,address wallet,bytes32 code,uint256 nonce,uint256 chainId,address marketingContract)");
    mapping(address => AmountDeadline) private walletPermits; // Authorization allowance: address=wallet address, uint256=allowance
    mapping(bytes32 => AmountDeadline) private codePermits;   // Authorization allowance: bytes32=hash(marketing code), uint256=allowance

    event WalletPermitted(uint256 requestId);   // Event for authorizing wallet transfer allowance
    event CodePermitted(uint256 requestId);     // Event for authorizing marketing code transfer allowance
    event WalletTransferred(uint256 requestId); // Event for transfer to wallet
    event CodeTransferred(uint256 requestId);   // Event for transfer to wallet
    event FeeTransferred(uint256 requestId);    // Event for transfer to fee address

    // Authorization allowance and deadline
    struct AmountDeadline {
        uint64 amount;
        uint64 deadline;
    }

    // Transfer amount and address
    struct AmountWallet {
        uint64 amount;
        address wallet;
    }

    // Only the wallet contract can call
    modifier onlyWallet() {
        require(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.WALLET), "unauthorized");
        _;
    }

    // Only the operator EOA can call
    modifier onlyOperationEOA() {
        require(msg.sender == IPERMISSION.operationEOA(), "unauthorized");
        _;
    }

    // Constructor
    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(TYPEHASH_EIP712_DOMAIN, keccak256(bytes("Marketing Contract")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    // Transfer to wallet address
    function transferFrom(uint256 amount, address wallet, bytes32 code, bytes calldata signature) external onlyWallet {
        // Prioritize using signature
        if (signature.length > 0) {
            address addr = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_TRANSFER_FROM, amount, wallet, code, nonces[wallet]++, block.chainid, address(this)), signature);
            require(addr == IPERMISSION.operationEOA(), "addr err");
        } else if (code != bytes32(0) && codePermits[code].amount >= amount && codePermits[code].deadline > block.timestamp) {
            // Use marketing code allowance
            codePermits[code].amount -= uint64(amount);
        } else if (walletPermits[wallet].amount >= amount && walletPermits[wallet].deadline > block.timestamp) {
            // Use wallet allowance
            walletPermits[wallet].amount -= uint64(amount);
        } else {
            revert("transferFrom failed");
        }
        
        // Transfer
        transferUsdc(wallet, amount);
    }

    // Authorize wallet transfer allowance
    function permitWallet(uint256 requestId, uint256 amount, uint256 deadline, address[] calldata wallets) external onlyOperationEOA {
        // Set allowance
        for (uint256 i = 0; i < wallets.length; ++i) {
            walletPermits[wallets[i]] = AmountDeadline(uint64(amount), uint64(deadline));
        }

        // Log success
        emit WalletPermitted(requestId);
    }

    // Authorize marketing code transfer allowance
    function permitCode(uint256 requestId, uint256 amount, uint256 deadline, bytes32 code) external onlyOperationEOA {
        // Set allowance
        codePermits[code] = AmountDeadline(uint64(amount), uint64(deadline));

        // Log success
        emit CodePermitted(requestId);
    }

    // Transfer to wallet address
    function transferToByWallet(uint256 requestId, AmountWallet[] calldata amountWallets) external onlyExecutorEOA {
        // Loop transfers
        for (uint256 i = 0; i < amountWallets.length; ++i) {
            address wallet = amountWallets[i].wallet;
            uint64 amount = amountWallets[i].amount;
            require(walletPermits[wallet].amount >= amount && walletPermits[wallet].deadline > block.timestamp, "transfer failed");
            walletPermits[wallet].amount -= amount;
            transferUsdc(wallet, amount);
        }

        // Log success
        emit WalletTransferred(requestId);
    }

    // Transfer to wallet address
    function transferToByCode(uint256 requestId, AmountWallet[] calldata amountWallets, bytes32 code) external onlyExecutorEOA {
        // Check validity period
        require(codePermits[code].deadline > block.timestamp, "deadline err");
        
        // Loop transfers
        for (uint256 i = 0; i < amountWallets.length; ++i) {
            uint64 amount = amountWallets[i].amount;          
            require(codePermits[code].amount >= amount, "amount err");
            codePermits[code].amount -= amount;
            transferUsdc(amountWallets[i].wallet, amount);
        }

        // Log success
        emit CodeTransferred(requestId);
    }

    // Transfer to fee EOA
    function transferToFee(uint256 requestId, uint256 amount) external onlyExecutorEOA {
        transferUsdc(IPERMISSION.feeEOA(), amount);
        emit FeeTransferred(requestId);
    }

    // Get authorization allowance
    function getWalletPermit(address wallet) external view returns (AmountDeadline memory) {
        return walletPermits[wallet];
    }
    
    // Get total authorization allowance
    function getWalletPermitTotal(address[] calldata wallets) external view returns (uint64) {
        uint64 total;
        for (uint256 i = 0; i < wallets.length; ++i) {
            total += walletPermits[wallets[i]].amount;
        }
        return total;
    }

    // Get authorization allowance
    function getCodePermit(bytes32 code) external view returns (AmountDeadline memory) {
        return codePermits[code];
    }

    // Get total authorization allowance
    function getCodePermitTotal(bytes32[] calldata codes) external view returns (uint64) {
        uint64 total;
        for (uint256 i = 0; i < codes.length; ++i) {
            total += codePermits[codes[i]].amount;
        }
        return total;
    }
}
