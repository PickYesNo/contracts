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
    bytes32 private constant TYPEHASH_BIND_WALLET = keccak256("BindWallet(address wallet,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_REDEEM = keccak256("Redeem(address wallet,uint256 amount,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_PRESIGN = keccak256("PreSign(uint64 amount,uint256 nonce,uint256 chainId,address walletContract)");
    bytes32 private constant TYPEHASH_UPGRADE_WALLET = keccak256("UpgradeWallet(address implementation,address predictionFactory,address oracle,bool value,uint256 nonce,uint256 chainId,address walletContract)");

    // Uses ERC-1967 storage slot address, based on a "hybrid mode" upgrade approach. Important points:
    // 1. The new logic must inherit BaseUsdcContract, which inherits from BaseContract. This means variables in all base classes within the inheritance chain cannot be added, removed, or changed in order.
    // 2. The new logic must copy all variables from the old logic and cannot change the order of any old logic variables.
    // 3. The new logic must not modify the values of any old logic variables but can read them.
    // 4. New logic variables must be appended at the end.
    // 5. Retrieval logic: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event WalletBound(uint256 requestId, address wallet, bool byUser);                // Wallet bound event
    event Entrusted(uint256 requestId, address wallet, uint256 amount, bool byUser);  // Entrust event
    event Redeemed(uint256 requestId, address wallet, uint256 amount, bool byUser);   // Reddeem event
    event PreSigned(uint256 requestId, uint64 amount, bool byUser);                   // Pre-sign event
    event Presented(uint256 requestId);                                               // Bonus presentation event
    event TokenRescued(uint256 requestId, address from, address to, uint256 balance); // Token rescue event
    event WalletRecycled(uint256 requestId, uint256 balance, bool success);           // Wallet recycled event
    event Upgraded(address indexed implementation);                                   // Contract upgraded event
    event WalletUpgraded(uint256 requestId);                                          // Wallet contract upgraded event

    // Only the bound wallet or an executor EOA can call
    modifier onlyBoundWalletOrExecutorEOA() {
        require(msg.sender == boundWallet || IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA), "unauthorized");
        _;
    }

    // Initialization
    constructor() {
        predictionFactories.push(0x1CB187729ea2395f6a7e717D2c7026C9B9345950); // Built-in prediction factory contract
        oracles[0xF8a69A4478e870f0fB6b34482E0Dc96AEa43F676] = true;           // Built-in oracle contract
        oracles[0x0940c93f2B4D6f48dBf628dFF0A43B3413BD8460] = true;           // Built-in chainlink oracle contract

        // EIP712 Domain Separator
        DOMAIN_SEPARATOR = keccak256(abi.encode(EIP712Lib.EIP712_DOMAIN, keccak256(bytes("Wallet Contract")), keccak256(bytes("1")), block.chainid, address(this)));
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

        // Log success event
        emit WalletBound(requestId, wallet, byUser);
    }

    // Entrust USDC to contract. Besides platform calls, the bound wallet can also call to redeem by itself.
    function entrust(uint256 requestId, address from, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external onlyBoundWalletOrExecutorEOA {
        // Permit
        IUSDC.permit(from, address(this), amount, deadline, v, r, s);

        // Transfer to Wallet Contract
        require(IUSDC.transferFrom(from, address(this), amount), "entrust failed"); 

        // Record last used time
        lastTime = uint64(block.timestamp);

        // Log success event
        emit Entrusted(requestId, from, amount, msg.sender == boundWallet);
    }

    // Redeem USDC to a specified address. Besides platform calls, the bound wallet can also call to redeem by itself.
    function redeem(uint256 requestId, address wallet, uint256 amount, bytes calldata signature) external onlyBoundWalletOrExecutorEOA {
        // Redemption amount does not include the bonus
        require(wallet != address(0) && IUSDC.balanceOf(address(this)) >= (amount + bonus), "param err");

        // Whether called by the user
        bool byUser = msg.sender == boundWallet;

        // If wallet is bound, and the caller is not the bound wallet, and the redemption address is not the bound wallet, signature is required
        if (boundWallet != address(0) && boundWallet != wallet && !byUser) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_REDEEM, wallet, amount, nonce++, block.chainid, address(this)), signature), "signature err");
        }

        // Redeem to the user-specified wallet
        transferUsdc(wallet, amount);

        // Log success event
        emit Redeemed(requestId, wallet, amount, byUser);
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

        // Log success event
        emit PreSigned(requestId, amount, byUser);
    }

    // Award bonus / Unlock bonus / Reclaim bonus
    function present(uint256 requestId, uint64 amount, address from, bytes32 code, bytes calldata signature, uint64 unlocked, uint64 reclaimed) external onlyExecutorEOA {
        // Award bonus
        if (amount != 0) {
            require(IPERMISSION.checkAddress(from, AddressTypeLib.MARKETING), "from err");
            IMarketing(from).transferFrom(amount, address(this), code, signature);
            bonus += amount;
        }

        // Unlock bonus
        if (unlocked != 0) {
            require(bonus >= unlocked, "unlocked err");
            bonus -= unlocked;
        }

        // Reclaim bonus
        if (reclaimed != 0) {
            require(bonus >= reclaimed, "reclaimed err");
            bonus -= reclaimed;
            transferUsdc(IPERMISSION.feeEOA(), reclaimed);
        }

        // Log success event
        emit Presented(requestId);
    }

    // Rescue ERC-20 tokens
    function rescueToken(uint256 requestId, address from, address to) external onlyExecutorEOA {
        // Ensure safety via whitelist, and USDC is not supported for rescue because USDC must be redeemed via redeem
        require(from != USDC && to != address(0) && IPERMISSION.checkAddress(from, AddressTypeLib.ERC20), "param err");

        // Rescue transfer
        IERC20 token = IERC20(from);
        uint256 balance = token.balanceOf(address(this));
        require(balance != 0, "balance err");

        // No need to worry about whether the transfer was successful
        token.transfer(to, balance);

        // Log success event
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
            if (balance != 0) {
                // Wallet balance greater than 0, but must have no transaction record for at least 1 year to be recycled, and balance transferred to: fee EOA
                if (lastTime != 0) {
                    if (block.timestamp > (365 days + lastTime)) {
                        transferUsdc(IPERMISSION.feeEOA(), balance);
                        success = true;
                    }
                } else {
                    lastTime = uint64(block.timestamp);
                }
            } else {
                // Wallet balance equals 0, but no transaction record for over half a year, can be recycled
                if (block.timestamp > (180 days + lastTime)) {
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

        // Log success event
        emit WalletRecycled(requestId, balance, success);
    }

    // Upgrade contract
    function upgradeWallet(uint256 requestId, address newImplementation, address newPredictionFactory, address newOracle, bool value, bytes calldata signature) external onlyExecutorEOA {
        // Only bound wallets need signature verification
        if (boundWallet != address(0) && (newImplementation != address(0) || value)) {
            require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_UPGRADE_WALLET, newImplementation, newPredictionFactory, newOracle, value, nonce++, block.chainid, address(this)), signature), "signature err");
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
            uint256 index;
            uint256 len = predictionFactories.length;
            for (uint256 i; i < len;) {
                if (predictionFactories[i] == newPredictionFactory) {
                    index = i + 1;
                    break;
                }

                // for
                unchecked { ++i; }
            }
            if (value) {                
                require(index == 0 && IPERMISSION.checkAddress(newPredictionFactory, AddressTypeLib.PREDICTION_FACTORY), "factory err");
                predictionFactories.push(newPredictionFactory);
            } else {
                require(index != 0, "factory err");
                predictionFactories[index - 1] = predictionFactories[len - 1];
                predictionFactories.pop();
            }
        }
        if (newOracle != address(0)) {
            if (value) {
                require(IPERMISSION.checkAddress(newOracle, AddressTypeLib.ORACLE), "oracle err");
            } else {
                require(oracles[newOracle], "oracle err");
            }
            oracles[newOracle] = value;
        }

        // Log success event
        emit WalletUpgraded(requestId);
    }

    // Verify buy signature and transfer USDC to prediction contract
    function transferToBuyPrediction(address oracle, uint256 amount, bytes calldata encodedData, bytes calldata signature) external {
        require(oracles[oracle] && _checkPrediction(msg.sender), "unauthorized");
        _checkSign(amount, encodedData, signature);
        transferUsdc(msg.sender, amount);
    }

    // Verify sell signature
    function transferToSellPrediction(uint256 amount, bytes calldata encodedData, bytes calldata signature) external {
        require(_checkPrediction(msg.sender), "unauthorized");
        _checkSign(amount, encodedData, signature);
    }

    // Verify signature and transfer USDC to oracle contract
    function transferToOracle(uint256 amount, bytes calldata encodedData, bytes calldata signature) external {
        require(oracles[msg.sender], "unauthorized");
        _checkSign(amount, encodedData, signature);
        transferUsdc(msg.sender, amount);
    }

    // Check if the prediction is correct
    function _checkPrediction(address prediction) private view returns (bool) {
        uint256 len = predictionFactories.length;
        while (len != 0) {
            unchecked { --len; }
            if (IFactory(predictionFactories[len]).check(prediction)) {
                return true;
            }
        }
        return false;
    }

    // Check signature and update pre-signed amount
    function _checkSign(uint256 amount, bytes memory encodedData, bytes memory signature) private {
        if (boundWallet != address(0)) {
            if (signature.length != 0 || preSignAmount < amount) {
                require(boundWallet == EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, encodedData, signature), "signature err"); // If a signature is passed in or the operation amount exceeds the pre-signed amount, signature validity must be checked.
            } else {
                preSignAmount -= uint64(amount); // Deduct pre-signed amount (overflow considered)
            }
        }

        // Record last used time
        lastTime = uint64(block.timestamp);
    }
}