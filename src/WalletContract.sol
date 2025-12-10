// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseUsdcContract.sol";

// Wallet Contract
contract WalletContract is BaseUsdcContract, IWallet {
    uint256 public nonce;                    // Signature nonce for replay protection
    address public boundWallet;              // Bound wallet, default 0 indicates not bound
    uint64 public boundTime;                 // Time when the wallet was bound, default 0 indicates not bound
    uint64 public preSignAmount;             // Pre-signed amount
    uint64 public bonus;                     // Bonus given by platform marketing, etc., can be used for trading, but direct redemption is restricted by marketing rules
    uint64 public lastTime;                  // Last transaction time
    address[] public predictionFactories;    // Built-in prediction factory contracts
    mapping(address => bool) public oracles; // Built-in oracle contracts

    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant TYPEHASH_EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TYPEHASH_BIND_WALLET = keccak256("BindWallet(address wallet,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_REDEEM = keccak256("Redeem(address wallet,uint256 amount,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_PRESIGN = keccak256("PreSign(uint64 amount,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_UPGRADE_WALLET = keccak256("UpgradeWallet(address implementation,address predictionFactory,address oracle,uint256 chainId,address walletContract)");

    // Uses ERC-1967 storage slot address, based on a "hybrid mode" upgrade approach. Important points:
    // 1. The new logic must inherit BaseUsdcContract, which inherits from BaseContract. This means variables in all base classes within the inheritance chain cannot be added, removed, or changed in order.
    // 2. The new logic must copy all variables from the old logic and cannot change the order of any old logic variables.
    // 3. The new logic must not modify the values of any old logic variables but can read them.
    // 4. New logic variables must be appended at the end.
    // 5. Retrieval logic: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event WalletBound(uint256 requestId, address walletContract, address wallet, bool byUser);              // Wallet bound event
    event Redeemed(uint256 requestId, address walletContract, address wallet, uint256 amount, bool byUser); // Redemption event
    event PreSigned(uint256 requestId, uint64 amount, bool byUser);                                         // Pre-sign event
    event Presented(uint256 requestId);                                                                     // Bonus presentation event
    event TokenRescued(uint256 requestId, address from, address to, uint256 balance);                       // Token rescue event
    event WalletRecycled(uint256 requestId, uint256 balance, bool success);                                 // Wallet recycling event
    event Upgraded(address indexed implementation);                                                         // Contract upgrade event
    event WalletUpgraded(uint256 requestId);                                                                // Wallet contract upgrade event

    // Only the bound wallet or an executor EOA can call
    modifier onlyBoundWalletOrExecutorEOA() {
        require(msg.sender == boundWallet || isExecutorEOA(msg.sender), "unauthorized");
        _;
    }

    // Only prediction contracts can call
    modifier onlyPrediction() {
        require(_checkPrediction(msg.sender), "unauthorized");
        _;
    }

    // Only oracle contracts can call
    modifier onlyOracle() {
        require(_checkOracle(msg.sender), "unauthorized");
        _;
    }

    // Initialization
    constructor() {
        predictionFactories.push(0x2FAFd4c5E8FeeF8816AeB954846d2EacCc68f30c); // Built-in prediction factory contract
        oracles[0xB4259DE0CE584da6e76ee75c1B6D3eab6f663137] = true;           // Built-in oracle contract

        // EIP712 Domain Separator
        DOMAIN_SEPARATOR = keccak256(abi.encode(TYPEHASH_EIP712_DOMAIN, keccak256(bytes("Wallet Contract")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    // Non-payable fallback function, key protection
    fallback() external payable {
        require(msg.value == 0, "fallback err");
        assembly {
            let impl := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // Non-payable receive function, another layer of protection
    receive() external payable {
        revert("receive err");
    }

    // Bind a wallet, used for withdrawals and signing
    function bindWallet(uint256 requestId, address wallet, bytes calldata signature) external onlyBoundWalletOrExecutorEOA {
        // Whether called by the user
        bool byUser = msg.sender == boundWallet;

        // If wallet is bound, and the caller is not the bound wallet, signature is required
        if (boundWallet != address(0) && !byUser) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_BIND_WALLET, wallet, nonce++, block.chainid, address(this)), signature), "signature err");
        }

        // Bind the wallet
        boundWallet = wallet;

        // Only save the first binding time to prevent continuously calling bindWallet to refresh boundTime and evade recycle
        if (boundTime == 0) {
            boundTime = uint64(block.timestamp);
        }

        // Log success
        emit WalletBound(requestId, address(this), wallet, byUser);
    }

    // Redeem USDC to a specified address. Besides platform calls, the bound wallet can also call to redeem by itself.
    function redeem(uint256 requestId, address wallet, uint256 amount, bytes calldata signature) external onlyBoundWalletOrExecutorEOA {
        // Redemption amount does not include the bonus
        uint256 balance = IUSDC.balanceOf(address(this));
        require(wallet != address(0) && balance >= (amount + bonus), "param err");

        // Whether called by the user
        bool byUser = msg.sender == boundWallet;

        // If wallet is bound, and the caller is not the bound wallet, and the redemption address is not the bound wallet, signature is required
        if (boundWallet != address(0) && boundWallet != wallet && !byUser) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_REDEEM, wallet, amount, nonce++, block.chainid, address(this)), signature), "signature err");
        }

        // Redeem to the user-specified wallet
        transferUsdc(wallet, amount);

        // Log success
        emit Redeemed(requestId, address(this), wallet, amount, byUser);
    }

    // Pre-sign
    function preSign(uint256 requestId, uint64 amount, bytes calldata signature) external onlyBoundWalletOrExecutorEOA {
        // Only bound wallets need pre-signing
        require(boundWallet != address(0), "unbound wallet");

        // Whether called by the user
        bool byUser = msg.sender == boundWallet;

        // If wallet is bound, and the caller is not the bound wallet, signature is required
        if (!byUser) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_PRESIGN, amount, nonce++, block.chainid, address(this)), signature), "signature err");
        }

        // Set the pre-signed amount
        preSignAmount = amount;

        // Log success
        emit PreSigned(requestId, amount, byUser);
    }

    // Award bonus / Unlock bonus / Reclaim bonus
    function present(uint256 requestId, uint64 amount, address from, bytes32 code, bytes calldata signature, uint64 unlocked, uint64 reclaimed) external onlyExecutorEOA {
        // Award bonus
        if (amount > 0) {
            require(IPERMISSION.checkAddress(from, AddressTypeLib.MARKETING), "from err");
            IMarketing(from).transferFrom(amount, address(this), code, signature);
            bonus += amount;
        }

        // Unlock bonus
        if (unlocked > 0) {
            require(bonus >= unlocked, "unlocked err");
            bonus -= unlocked;
        }

        // Reclaim bonus
        if (reclaimed > 0) {
            require(bonus >= reclaimed, "reclaimed err");
            bonus -= reclaimed;
            transferUsdc(IPERMISSION.feeEOA(), reclaimed);
        }

        // Log success
        emit Presented(requestId);
    }

    // Rescue ERC-20 tokens
    function rescueToken(uint256 requestId, address from, address to) external onlyExecutorEOA {
        // Ensure safety via whitelist, and USDC is not supported for rescue because USDC must be redeemed via redeem
        require(IPERMISSION.checkAddress(from, AddressTypeLib.ERC20) && from != USDC && to != address(0), "param err");

        // Rescue transfer
        IERC20 token = IERC20(from);
        uint256 balance = token.balanceOf(address(this));
        token.transfer(to, balance);

        // Log success
        emit TokenRescued(requestId, from, to, balance);
    }

    // Recycle wallet
    function recycleWallet(uint256 requestId) external onlyExecutorEOA {
        // Balance
        uint256 balance = IUSDC.balanceOf(address(this));

        // Record whether recycling was successful, for off-chain judgment
        bool success;

        // If a wallet is bound, it cannot be recycled within 3 days of binding to prevent users from binding, then depositing, but being recycled before having a chance to trade.
        if (block.timestamp > (3 days + boundTime)) {
            if (balance == 0) {
                // Wallet balance equals 0, but no transaction record for over half a year, can be recycled
                if (block.timestamp > (180 days + lastTime)) {
                    success = true;
                }
            } else {
                // Wallet balance greater than 0, but must have no transaction record for at least 1 year to be recycled, and balance transferred to: fee EOA
                if (lastTime == 0) {
                    lastTime = uint64(block.timestamp);
                }
                if (block.timestamp > (365 days + lastTime)) {
                    transferUsdc(IPERMISSION.feeEOA(), balance);
                    success = true;
                }
            }

            // Successfully recycled, remove binding
            if (success) {
                boundWallet = address(0);
                boundTime = 0;
                preSignAmount = 0;
                bonus = 0;
                lastTime = 0;
            }
        }

        // Log success
        emit WalletRecycled(requestId, balance, success);
    }

    // Upgrade contract
    function upgradeWallet(uint256 requestId, address newImplementation, address newPredictionFactory, address newOracle, bytes calldata signature) external onlyExecutorEOA {
        // Only bound wallets need signature verification
        if (boundWallet != address(0)) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_UPGRADE_WALLET, newImplementation, newPredictionFactory, newOracle, block.chainid, address(this)), signature), "signature err");
        }

        // Update implementation address
        if (newImplementation != address(0)) {
            require(IPERMISSION.checkAddress(newImplementation, AddressTypeLib.IMPLEMENTATION), "impl err");
            assembly {
                sstore(IMPLEMENTATION_SLOT, newImplementation)
            }
            emit Upgraded(newImplementation);
        }

        // Update contracts, while preserving contract history so that old predictions/oracles can continue to be used
        if (newPredictionFactory != address(0)) {
            require(IPERMISSION.checkAddress(newPredictionFactory, AddressTypeLib.PREDICTION_FACTORY), "prediction err");
            predictionFactories.push(newPredictionFactory);
        }
        if (newOracle != address(0)) {
            require(IPERMISSION.checkAddress(newOracle, AddressTypeLib.ORACLE), "oracle err");
            oracles[newOracle] = true;
        }

        // Log success
        emit WalletUpgraded(requestId);
    }

    // Verify buy signature and transfer USDC to prediction contract
    function transferToBuyPrediction(address oracle, uint256 amount, bytes memory encodedData, bytes memory signature) external onlyPrediction {
        require(_checkOracle(oracle), "oracle err");
        _checkSign(amount, encodedData, signature);
        transferUsdc(msg.sender, amount);
    }

    // Verify sell signature
    function transferToSellPrediction(uint256 amount, bytes memory encodedData, bytes memory signature) external onlyPrediction {
        _checkSign(amount, encodedData, signature);
    }

    // Verify signature and transfer USDC to oracle contract
    function transferToOracle(uint256 amount, bytes memory encodedData, bytes memory signature) external onlyOracle {
        _checkSign(amount, encodedData, signature);
        transferUsdc(msg.sender, amount);
    }

    // Verify if prediction contract is legitimate (user approved, platform also approved)
    function _checkPrediction(address addr) private returns (bool) {
        if (block.timestamp < (cacheTime + permissions[addr][AddressTypeLib.PREDICTION])) {
            return true;
        }
        uint256 len = predictionFactories.length;
        while (len != 0) {
            if (IFactory(predictionFactories[--len]).check(addr) && IPERMISSION.checkAddress(addr, AddressTypeLib.PREDICTION)) {
                permissions[addr][AddressTypeLib.PREDICTION] = block.timestamp;
                return true;
            }
        }
        return false;
    }

    // Verify if oracle contract is legitimate (user approved, platform also approved)
    function _checkOracle(address addr) private returns (bool) {
        if (block.timestamp < (cacheTime + permissions[addr][AddressTypeLib.ORACLE])) {
            return true;
        }
        if (oracles[addr] && IPERMISSION.checkAddress(addr, AddressTypeLib.ORACLE)) {
            permissions[addr][AddressTypeLib.ORACLE] = block.timestamp;
            return true;
        }
        return false;
    }

    // Check signature and update pre-signed amount
    function _checkSign(uint256 amount, bytes memory encodedData, bytes memory signature) private {
        if (boundWallet != address(0)) {
            if (signature.length > 0 || preSignAmount < amount) {
                require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, encodedData, signature), "signature err"); // If a signature is passed in or the operation amount exceeds the pre-signed amount, signature validity must be checked.
            } else {
                preSignAmount -= uint64(amount); // Deduct pre-signed amount (overflow considered)
            }
        }

        // Record last used time
        lastTime = uint64(block.timestamp);
    }
}
