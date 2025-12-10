// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseUsdcContract.sol";

// Prediction Contract
contract PredictionContract is BaseUsdcContract, IPrediction {
    bytes32 public immutable PREDICTION_HASH; // Hash calculated from title + rules, used for users to verify if contract content has been tampered with
    address public immutable ORACLE;          // Oracle contract address
    uint256 public fees;                      // Total accumulated fees

    bytes32 private constant TYPEHASH_BROKER = keccak256("Broker(uint256 optionId,uint256 mode,uint256 buysell,uint256 expectedPrice,uint256 expectedShares,uint256 fee,bytes32 uuid,uint256 chainId,address predictionContract)");
    PredictionSetting private setting;                                                     // Default contract parameters
    mapping(uint256 => PredictionSetting) private settings;                                // Contract parameters: uint256=prediction option, IPrediction.Setting=contract parameters
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) private positions; // Position records: uint256=prediction option, uint256=Order.buysell, address=wallet contract, uint256=position quantity
    mapping(bytes32 => uint256) private signatures;                                        // Signature records: bytes32=hash of signature data, uint256=traded volume

    event Brokered(uint256 requestId);                  // Order Matched Event
    event SettingsSet(uint256 requestId);               // Contract Parameters Set Event
    event FeeTransferred(uint256 requestId);            // Fee Transferred Event
    event Settled(uint256 requestId, address[] wallet); // Settlement Completed Event

    // Order Structure
    struct Order {
        uint256 mode;           // 1=Market Order, 2=Limit Order
        uint256 buysell;        // 1=buy yes, 2=buy no, 3=sell yes, 4=sell no
        uint256 expectedPrice;  // For mode=1: Expected total order amount for market order. For mode=2: Desired buy/sell price for limit order.
        uint256 expectedShares; // For mode=1: Maximum desired shares for market order. For mode=2: Desired number of shares for limit order.
        uint256 matchedPrice;   // Actual executed buy/sell price
        uint256 matchedShares;  // Actual executed number of shares
        uint256 fee;            // Fee
        address wallet;         // Wallet contract
        bytes32 uuid;           // Used for signing, similar to nonce
        bytes signature;        // Signature data
    }

    // Constructor
    constructor(bytes32 newPredictionHash, address newOracle, PredictionSetting[] memory newSettings) {
        require(newPredictionHash != bytes32(0) && newOracle != address(0) && newSettings.length > 0, "param err");
        PREDICTION_HASH = newPredictionHash;
        ORACLE = newOracle;
        setting = newSettings[0];
        for (uint256 i = 0; i < newSettings.length; ++i) {
            settings[newSettings[i].optionId] = newSettings[i];
        }
    }

    // Match Orders
    function broker(uint256 requestId, uint256 optionId, Order calldata taker, Order[] calldata makers) external onlyExecutorEOA {
        // Important parameter checks
        require(optionId > 0 && block.timestamp < (settings[optionId].endingTime == 0 ? setting.endingTime : settings[optionId].endingTime), "param err");

        // Process Taker order
        uint256 fee = _processOrder(optionId, taker);

        // Loop through Maker orders
        uint256 makerMatchedShares;
        for (uint256 i = 0; i < makers.length; ++i) {
            Order memory maker = makers[i];

            // Process Maker order
            fee += _processOrder(optionId, maker);

            // Check matching rules
            _checkMatch(taker, maker);

            // Accumulate total matched shares from makers
            makerMatchedShares += maker.matchedShares;
        }

        // Taker's matched shares must equal total maker shares
        require(taker.matchedShares == makerMatchedShares, "matchedShares err");

        // Update fees
        fees += fee;

        // Log success event
        emit Brokered(requestId);
    }

    // Set Contract Parameters
    function setSetting(uint256 requestId, PredictionSetting[] calldata newSettings) external onlyExecutorEOA {
        for (uint256 i = 0; i < newSettings.length; ++i) {
            // Save option's setting
            PredictionSetting storage ps = settings[newSettings[i].optionId];
            if (ps.optionId == 0) {
                ps.optionId = newSettings[i].optionId;
                ps.roundNo = newSettings[i].roundNo;
            } else {
                // If oracle already has a result, do not allow updating settings
                require(IOracle(ORACLE).getOutcome(address(this), newSettings[i].optionId) == 0, "outcome err");
            }

            // Update option's ending time
            ps.endingTime = newSettings[i].endingTime;

            // Update option's voting/challenge duration (voting duration min 1 sec, challenge duration min 10 minutes)
            if (newSettings[i].votingDuration > 0) {
                ps.votingDuration = newSettings[i].votingDuration;
            }
            if (newSettings[i].challengeDuration > 600) {
                ps.challengeDuration = newSettings[i].challengeDuration;
            }
        }
        emit SettingsSet(requestId);
    }

    // Transfer to Fee EOA
    function transferToFee(uint256 requestId, uint256 amount) external onlyExecutorEOA {
        require(fees >= amount, "param err");
        transferUsdc(IPERMISSION.feeEOA(), amount);
        fees -= amount;
        emit FeeTransferred(requestId);
    }

    // Settlement (outcome: 1=yes, 2=no, 3=draw, 4=pending arbitration, 5=canceled). Users can call this themselves, not restricted by platform.
    function settle(uint256 requestId, uint256 optionId, address[] calldata wallets) external {
        // Get result via oracle
        uint256 outcome = IOracle(ORACLE).getOutcome(address(this), optionId);

        // Loop through settlement
        for (uint256 i = 0; i < wallets.length; ++i) {
            _settle(optionId, outcome, wallets[i]);
        }

        // Log success event
        emit Settled(isExecutorEOA(msg.sender) ? requestId : 0, wallets);
    }

    // Get Contract Parameters
    function getSetting(uint256 optionId) external view returns (PredictionSetting memory) {
        PredictionSetting storage ps = settings[optionId];
        if (ps.optionId == 0) {
            return settings[setting.optionId];
        }
        return PredictionSetting(
            ps.optionId,
            ps.roundNo,
            ps.endingTime,
            ps.votingDuration == 0 ? setting.votingDuration : ps.votingDuration,
            ps.challengeDuration == 0 ? setting.challengeDuration : ps.challengeDuration,
            setting.stakingAmount,
            setting.challengeStaking,
            setting.totalRewards,
            setting.rewardRanking,
            setting.challengePercent,
            setting.independent
        );
    }

    // Process Order
    function _processOrder(uint256 optionId, Order memory order) private returns (uint256) {
        // Important parameter checks (matchedPrice: >= 0.1 cent, < 100 cents. matchedShares: >= 0.1 share)
        require(order.matchedPrice > 999 && order.matchedPrice < 1000000 && order.matchedShares > 99999 && IPERMISSION.checkAddress(order.wallet, AddressTypeLib.WALLET), "param err");

        // Check signature
        bytes memory encodedData;
        if (order.signature.length > 0) {
            _checkSign(order);
            encodedData = abi.encode(TYPEHASH_BROKER, optionId, order.mode, order.buysell, order.expectedPrice, order.expectedShares, order.fee, order.uuid, block.chainid, address(this));
        }

        // Total amount
        uint256 amount = order.matchedPrice * order.matchedShares / 1000000; // To support fractional shares, matchedShares is multiplied by 10**6 off-chain, then divided here

        // Calculate fee
        uint256 fee = amount * order.fee / 10000; // Fee unit: basis point (1/10000)

        // Update shares
        if (order.buysell == 1 || order.buysell == 2) {
            // Verify signature and transfer
            IWallet(order.wallet).transferToBuyPrediction(ORACLE, amount + fee, encodedData, order.signature);

            // Buy shares
            positions[optionId][order.buysell][order.wallet] += order.matchedShares;
        } else if (order.buysell == 3 || order.buysell == 4) {
            // Verify signature
            IWallet(order.wallet).transferToSellPrediction(amount + fee, encodedData, order.signature);

            // Sell shares (first check if shares to sell are sufficient)
            require(positions[optionId][order.buysell - 2][order.wallet] >= order.matchedShares, "shares err");
            positions[optionId][order.buysell - 2][order.wallet] -= order.matchedShares;

            // Transfer sold shares (minus fee) to wallet contract
            transferUsdc(order.wallet, amount - fee);
        } else {
            revert("buysell err");
        }

        // Return fee
        return fee;
    }

    // Check if signature's price is correct and if signature's quota is used up
    function _checkSign(Order memory order) private {
        // Use signature as key to get traded volume
        bytes32 key = keccak256(order.signature);
        uint256 sum = signatures[key];

        // Market Order: Actual executed total order amount must be <= expected executed total order amount
        if (order.mode == 1) {
            sum += order.matchedPrice * order.matchedShares / 1000000; // To support fractional shares, matchedShares is multiplied by 10**6 off-chain, then divided here
            require(sum <= order.expectedPrice, "prices err");
        } else if (order.mode == 2) {
            // Limit Order: Actual executed shares must be <= expected executed shares
            sum += order.matchedShares;
            require(sum <= order.expectedShares, "shares err");

            // Check price slippage
            if (order.buysell < 3) {
                require(order.matchedPrice <= order.expectedPrice, "price err"); // If buying, executed price allowed to be <= expected price
            } else {
                require(order.matchedPrice >= order.expectedPrice, "price err"); // If selling, executed price allowed to be >= expected price
            }
        } else {
            revert("mode err");
        }

        // Update traded volume
        signatures[key] = sum;
    }

    // Check Matching Rules
    function _checkMatch(Order memory taker, Order memory maker) private pure {
        if (taker.buysell < 3) {
            // Taker is buying:
            // When maker is buying: Directions opposite, executed prices must sum to 1 USDC.
            // When maker is selling: Directions same, executed prices must be equal.
            if (maker.buysell < 3) {
                require(taker.buysell == (3 - maker.buysell) && (taker.matchedPrice + maker.matchedPrice) == 1000000, "match err");
            } else {
                require(taker.buysell == (maker.buysell - 2) && taker.matchedPrice == maker.matchedPrice, "match err");
            }
        } else {
            // Taker is selling:
            // When maker is buying: Directions same, executed prices must be equal.
            // When maker is selling: Directions opposite, executed prices must sum to 1 USDC. Note: This means shares net to zero.
            if (maker.buysell < 3) {
                require(taker.buysell == (maker.buysell + 2) && taker.matchedPrice == maker.matchedPrice, "match err");
            } else {
                require(taker.buysell == (7 - maker.buysell) && (taker.matchedPrice + maker.matchedPrice) == 1000000, "match err");
            }
        }
    }

    // Settlement
    function _settle(uint256 optionId, uint256 outcome, address wallet) private {
        // Position shares
        uint256 shares;

        // For outcome yes/no, calculate based on purchased shares
        if (outcome == 1 || outcome == 2) {
            // Only winning buys are counted
            shares = positions[optionId][outcome][wallet];
            if (shares > 0) {
                positions[optionId][outcome][wallet] = 0;
                transferUsdc(wallet, shares); // Shares are passed as 10**6 off-chain, same decimals as 1 USDC
            }
        } else if (outcome == 3 || outcome == 5) {
            // Draw or canceled, both calculated at 50%
            shares = positions[optionId][1][wallet];
            if (shares > 0) {
                positions[optionId][1][wallet] = 0;
                transferUsdc(wallet, shares / 2);
            }
            shares = positions[optionId][2][wallet];
            if (shares > 0) {
                positions[optionId][2][wallet] = 0;
                transferUsdc(wallet, shares / 2);
            }
        } else {
            revert("outcome err");
        }
    }
}
