// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseUsdcContract.sol";

// Oracle Contract
contract OracleContract is BaseUsdcContract, IOracle {
    uint256 public constant CANCELLATION_DURATION = 120 days; // If no result beyond this period, mark as: 5 = Cancelled
    uint256 public stakingAmount;                             // Total staked amount, cannot exceed this value when transferring USDC out

    // Type Hashes
    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant TYPEHASH_EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TYPEHASH_VOTE = keccak256("Vote(address prediction,uint256 optionId,uint256 outcome,uint256 staking,uint256 chainId,address oracleContract)");
    bytes32 private constant TYPEHASH_CHALLENGE = keccak256("Challenge(address prediction,uint256 optionId,uint256 outcome,uint256 staking,uint256 chainId,address oracleContract)");
    bytes32 private constant TYPEHASH_ARBITRATE = keccak256("Arbitrate(address prediction,uint256 optionId,uint256 outcome,uint256 chainId,address oracleContract)");
    mapping(address => mapping(uint256 => Prediction)) private predictions; // Voting records: address=prediction contract address, uint256=round, Prediction=voting record

    event Voted(uint256 requestId);                      // Vote event
    event Challenged(uint256 requestId);                 // Challenge event
    event Arbitrated(uint256 requestId);                 // Arbitration event
    event FeeTransferred(uint256 requestId);             // Transfer to fee event
    event Rewarded(uint256 requestId, address[] wallet); // Reward distribution event

    // Prediction
    struct Prediction {
        mapping(uint256 => Option) options; // Voting records: uint256=prediction option, Option=option details
        Option option;                      // Option for multiple-choice single result
        uint256[] optionIds;                // IDs of prediction options
    }

    // Option
    struct Option {
        uint256 firstVoteTime;                // Time of the first vote
        mapping(address => Vote) votes;       // Voting records: address=wallet contract, Ballot=vote
        mapping(uint256 => uint256) counters; // Vote result statistics: uint256=vote outcome, uint256=count
        Challenge challenge;                  // Challenge record
        Arbitration arbitration;              // Arbitration result
    }

    // Vote
    struct Vote {
        uint64 optionId; // Prediction option
        uint32 ranking;  // Vote ranking
        uint8 outcome;   // Vote outcome, 1=yes, 2=no, 3=unclear 50-50 settlement
        bool done;       // false=default, true=reward distributed
    }

    // Challenge
    struct Challenge {
        uint64 optionId; // Prediction option
        address wallet;  // Challenger
        uint8 outcome;   // Challenge outcome, 1=yes, 2=no, 3=unclear 50-50 settlement
        bool done;       // false=default, true=reward distributed
    }

    // Arbitration
    struct Arbitration {
        uint64 optionId; // Prediction option
        uint8 outcome;   // Arbitration outcome, outcome: 1=yes, 2=no, 3=unclear 50-50 settlement, 4=pending arbitration, 5=cancelled
    }

    // Constructor
    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(TYPEHASH_EIP712_DOMAIN, keccak256(bytes("Oracle Contract")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    // Vote
    function vote(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, address wallet, bytes calldata signature) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId > 0 && IPERMISSION.checkAddress(wallet, AddressTypeLib.WALLET), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Check if voting is allowed
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        require(_getOutcome(pre, opt, optionId, setting, true) == 0, "no vote");

        // Record vote
        if (setting.independent) {
            // Independent results allow: 1=yes, 2=no, 3=unclear 50-50 settlement
            require(outcome == 1 || outcome == 2 || outcome == 3, "outcome err");

            // Must be after closing time
            if (opt.firstVoteTime == 0) {
                require(block.timestamp > setting.endingTime, "time err");
                opt.firstVoteTime = block.timestamp;
            }
            require(block.timestamp < (opt.firstVoteTime + setting.votingDuration), "time err");

            // Each person can vote only once per option
            Vote storage vot = opt.votes[wallet];
            require(vot.optionId == 0, "voted");

            // Record vote and count
            vot.optionId = uint64(optionId);
            vot.outcome = uint8(outcome);
            vot.ranking = uint32(opt.counters[outcome]++);
        } else {
            // Must be after closing time
            if (pre.option.firstVoteTime == 0) {
                require(block.timestamp > setting.endingTime, "time err");
                pre.option.firstVoteTime = block.timestamp;
            }
            require(block.timestamp < (pre.option.firstVoteTime + setting.votingDuration), "time err");

            // Each person can vote only once per prediction
            Vote storage vot = pre.option.votes[wallet];
            require(vot.optionId == 0, "voted");

            // Record vote and count
            vot.optionId = uint64(optionId);
            vot.outcome = uint8(outcome);
            if (outcome == 1) {
                vot.ranking = uint32(opt.counters[1]++);

                // Record the count of voting options
                if (opt.counters[1] == 1) {
                    pre.optionIds.push(optionId);
                }
            } else if (outcome == 3) {
                vot.ranking = uint32(pre.option.counters[3]++);
            } else {
                revert("outcome err");
            }
        }

        // Stake USDC to the prediction contract
        if (setting.stakingAmount > 0) {
            IWallet(wallet).transferToOracle(setting.stakingAmount, abi.encode(TYPEHASH_VOTE, prediction, optionId, outcome, setting.stakingAmount, block.chainid, address(this)), signature);
            stakingAmount += setting.stakingAmount;
        }

        // Log success event
        emit Voted(requestId);
    }

    // Challenge
    function challenge(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, address wallet, bytes calldata signature) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId > 0 && IPERMISSION.checkAddress(wallet, AddressTypeLib.WALLET), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Check if challenging is allowed
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        require(_getOutcome(pre, opt, optionId, setting, true) == 0, "no challenge");

        // Record challenge
        if (setting.independent) {
            // Only one challenge allowed
            require(opt.challenge.optionId == 0, "challenged");

            // Check if challenge timing is correct
            require(opt.firstVoteTime > 0 && block.timestamp > (opt.firstVoteTime + setting.votingDuration) && block.timestamp < (opt.firstVoteTime + setting.votingDuration + setting.challengeDuration), "time err");

            // Independent result, must vote for the minority option to represent challenge. If tied, no restriction on minority.
            uint256 yes = opt.counters[1];     // [1]=yes
            uint256 no = opt.counters[2];      // [2]=no
            uint256 unknown = opt.counters[3]; // [3]=unclear 50-50 settlement
            if (yes > no && yes > unknown) {
                require(outcome == 2 || outcome == 3, "minority"); // yes majority, can only vote no or unclear 50-50 settlement
            } else if (no > yes && no > unknown) {
                require(outcome == 1 || outcome == 3, "minority"); // no majority, can only vote yes or unclear 50-50 settlement
            } else if (unknown > yes && unknown > no) {
                require(outcome == 1 || outcome == 2, "minority"); // unclear 50-50 settlement majority, can only vote yes or no
            } else {
                require(outcome == 1 || outcome == 2 || outcome == 3, "outcome err"); // Independent result can challenge: 1=yes, 2=no, 3=unclear 50-50 settlement
            }

            // Record challenge vote
            opt.challenge.optionId = uint64(optionId);
            opt.challenge.outcome = uint8(outcome);
            opt.challenge.wallet = wallet;
        } else {
            // Only one challenge allowed
            require(pre.option.challenge.optionId == 0, "challenged");

            // Check if challenge timing is correct
            require(pre.option.firstVoteTime > 0 && block.timestamp > (pre.option.firstVoteTime + setting.votingDuration) && block.timestamp < (pre.option.firstVoteTime + setting.votingDuration + setting.challengeDuration), "time err");

            // Single result, challenge vote cannot be the highest-voted option. If tied, no restriction.
            (uint256 max1, uint256 max2, ) = _getMax1Max2(pre);
            if (outcome == 1) {
                require(max1 == max2 || opt.counters[1] < max1, "minority");  // yes vote
            } else if (outcome == 3) {
                require(max1 == max2 || pre.option.counters[3] < max1, "minority"); // 3=unclear 50-50 vote
            } else {       
                revert("outcome err"); // Single result only allows challenge: 1=yes, 3=unclear 50-50 settlement
            }

            // Record challenge vote
            pre.option.challenge.optionId = uint64(optionId);
            pre.option.challenge.outcome = uint8(outcome);
            pre.option.challenge.wallet = wallet;
        }

        // Challenger must stake additional USDC to the prediction contract
        if (setting.challengeStaking > 0) {
            IWallet(wallet).transferToOracle(setting.challengeStaking, abi.encode(TYPEHASH_CHALLENGE, prediction, optionId, outcome, setting.challengeStaking, block.chainid, address(this)), signature);
            stakingAmount += setting.challengeStaking;
        }

        // Log success event
        emit Challenged(requestId);
    }

    // Arbitrate
    function arbitrate(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, bytes[] calldata signatures) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId > 0, "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Check if arbitration is allowed
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        require(signatures.length == 2 && _getOutcome(pre, opt, optionId, setting, true) == 4, "arbitrate failed");

        // Check by multisig
        address addr1 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_ARBITRATE, prediction, optionId, outcome, block.chainid, address(this)), signatures[0]);
        address addr2 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, abi.encode(TYPEHASH_ARBITRATE, prediction, optionId, outcome, block.chainid, address(this)), signatures[1]);
        require(addr1 != addr2 && IPERMISSION.checkAddress2(addr1, AddressTypeLib.ARBITRATOR_EOA, addr2, AddressTypeLib.ARBITRATOR_EOA), "arbitrate failed");

        // Record arbitration
        if (setting.independent) {
            require(outcome == 1 || outcome == 2 || outcome == 3 || outcome == 5, "outcome err");
            opt.arbitration = Arbitration(uint64(optionId), uint8(outcome));
        } else {
            require(outcome == 1 || outcome == 3 || outcome == 5, "outcome err");
            pre.option.arbitration = Arbitration(uint64(optionId), uint8(outcome));
        }

        // Log success event
        emit Arbitrated(requestId);
    }

    // Transfer to fee EOA
    function transferToFee(uint256 requestId, uint256 amount) external onlyExecutorEOA {
        uint256 balance = IUSDC.balanceOf(address(this));
        require(balance >= (amount + stakingAmount), "param err");
        transferUsdc(IPERMISSION.feeEOA(), amount);
        emit FeeTransferred(requestId);
    }

    // Distribute rewards
    function reward(uint256 requestId, address prediction, uint256 optionId, address[] calldata wallets) external {
        // Critical parameter checks
        require(optionId > 0 && IPERMISSION.checkAddress(prediction, AddressTypeLib.PREDICTION), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get voting outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        uint256 outcome = _getOutcome(pre, opt, optionId, setting, true);

        // 1,2,3 represent yes,no,unclear 50-50 settlement, rewards can be distributed
        uint256 totalRewards;
        if (outcome == 1 || outcome == 2 || outcome == 3) {
            totalRewards = setting.totalRewards;
        } else if (outcome == 5) {
            // 5 represents cancelled, no rewards, only return staked amount
        } else {
            revert("outcome err");
        }

        // Challenge rewards
        Option storage optOption;
        uint256 returnStaking;
        uint256 voteRewards;
        if (setting.independent) {
            optOption = opt;
            (returnStaking, voteRewards) = _rewardChallenge(optOption, opt, false, outcome, totalRewards, setting);
        } else {
            optOption = pre.option;
            (returnStaking, voteRewards) = _rewardChallenge(optOption, opt, outcome == 3, outcome, totalRewards, setting);
        }

        // Voting rewards
        for (uint256 i = 0; i < wallets.length; ++i) {
            returnStaking += _rewardVote(optOption, wallets[i], optionId, outcome, voteRewards, setting);
        }

        // Update staked amount
        stakingAmount -= returnStaking;

        // Log success event
        emit Rewarded(isExecutorEOA(msg.sender) ? requestId : 0, wallets);
    }

    // Get voting result
    function getVote(address prediction, uint256 optionId) external view returns (uint256) {
        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get voting outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        return _getOutcome(pre, opt, optionId, setting, false);
    }

    // Get outcome
    function getOutcome(address prediction, uint256 optionId) external view returns (uint256) {
        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        return _getOutcome(pre, opt, optionId, setting, true);
    }

    // Challenge rewards
    function _rewardChallenge(Option storage optOption, Option storage opt, bool isOutcome3, uint256 outcome, uint256 totalRewards, PredictionSetting memory setting) private returns (uint256, uint256) {
        uint256 returnStaking;
        uint256 challengeRewards;

        // Check if there is a challenge
        if (optOption.challenge.optionId > 0) {
            // Check if challenge is correct (isOutcome3=true means for multiple-choice single result arbitrated as unclear 50-50, optionId doesn't matter, only outcome needs to be correct)
            if ((optOption.challenge.optionId == optOption.arbitration.optionId || isOutcome3) && optOption.challenge.outcome == optOption.arbitration.outcome) {
                // Challenge reward
                challengeRewards = totalRewards * setting.challengePercent / 100;

                // Check if reward already distributed
                if (!optOption.challenge.done) {
                    optOption.challenge.done = true;
                    returnStaking = setting.challengeStaking;

                    // Distribute reward
                    transferUsdc(optOption.challenge.wallet, setting.challengeStaking + challengeRewards);
                }
            } else {
                if (!optOption.challenge.done) {
                    optOption.challenge.done = true;
                    returnStaking = setting.challengeStaking;

                    // If cancelled, regardless of challenge correctness, return staked amount
                    if (outcome == 5) {
                        transferUsdc(optOption.challenge.wallet, setting.challengeStaking);
                    }
                }
            }
        }

        // Voting rewards (if participant limit reached, only top ranking participants; if not reached, all correct voters split equally)
        uint256 voteRewards;
        if (setting.rewardRanking > 0) {
            uint256 voteCounter = isOutcome3 ? optOption.counters[outcome] : opt.counters[outcome];
            if (voteCounter > 0) {
                voteRewards = voteCounter > setting.rewardRanking ? (totalRewards - challengeRewards) / setting.rewardRanking : (totalRewards - challengeRewards) / voteCounter; // Total rewards minus the challenger's share
            }
        }

        // Return staked amount and voting rewards
        return (returnStaking, voteRewards);
    }

    // Voting rewards
    function _rewardVote(Option storage optOption, address wallet, uint256 optionId, uint256 outcome, uint256 voteRewards, PredictionSetting memory setting) private returns (uint256) {
        uint256 returnStaking;

        // Check if there is a vote
        Vote storage vot = optOption.votes[wallet];
        if (vot.optionId == optionId) {
            // Check if vote is correct
            if (vot.outcome == outcome) {
                // Check if reward already distributed
                if (!vot.done) {
                    vot.done = true;
                    returnStaking = setting.stakingAmount;

                    // Only top rewardRanking participants get rewards
                    transferUsdc(wallet, vot.ranking < setting.rewardRanking ? setting.stakingAmount + voteRewards : setting.stakingAmount);
                }
            } else {
                if (!vot.done) {
                    vot.done = true;
                    returnStaking = setting.stakingAmount;

                    // If cancelled, regardless of vote correctness, return staked amount
                    if (outcome == 5) {
                        transferUsdc(wallet, setting.stakingAmount);
                    }
                }
            }
        }

        // Return staked amount
        return returnStaking;
    }

    // Get outcome (0=voting/challenging, 1=yes, 2=no, 3=unclear 50-50 settlement, 4=pending arbitration, 5=arbitrated as cancelled)
    function _getOutcome(Prediction storage pre, Option storage opt, uint256 optionId, PredictionSetting memory setting, bool isFinal) private view returns (uint256) {
        // If arbitration exists, return arbitration result directly
        Option storage optOption = setting.independent ? opt : pre.option;
        if (optOption.arbitration.optionId == optionId) {
            return optOption.arbitration.outcome;
        } else if (optOption.arbitration.optionId > 0) {
            return optOption.arbitration.outcome < 3 ? 3 - optOption.arbitration.outcome : optOption.arbitration.outcome; // For multiple-choice single result, invert the outcome
        }

        // If no one voted and more than 120 days have passed after prediction end, mark as cancelled
        if (optOption.firstVoteTime == 0) {
            if (block.timestamp > (CANCELLATION_DURATION + setting.endingTime)) {
                return 5; // Cancelled
            }
            return 0; // In progress
        }

        // If there is a challenge and no arbitration for more than 120 days, mark as cancelled
        if (optOption.challenge.optionId > 0) {
            return _cancelOrArbitrate(optOption.firstVoteTime, setting);
        }

        // isFinal=true means challenge period ended, can get result. Otherwise, it's the result based on current voting, note this is not final.
        if (isFinal && block.timestamp < (optOption.firstVoteTime + setting.votingDuration + setting.challengeDuration)) {
            return 0; // In progress
        }

        // Independent result, direct comparison
        uint256 yes = opt.counters[1];         // [1]=yes
        if (setting.independent) {
            uint256 no = opt.counters[2];      // [2]=no
            uint256 unknown = opt.counters[3]; // [3]=unclear 50-50 settlement
            if (yes > no && yes > unknown) {
                return 1;
            }
            if (no > yes && no > unknown) {
                return 2;
            }
            if (unknown > yes && unknown > no) {
                return 3;
            }
            return _cancelOrArbitrate(optOption.firstVoteTime, setting);
        } else {
            // Single result (by comparing top two maximum values)
            (uint256 max1, uint256 max2, bool isUnknown) = _getMax1Max2(pre);
            if (max1 == max2) {
                return _cancelOrArbitrate(optOption.firstVoteTime, setting);
            }
            if (isUnknown) {
                return 3; // Unclear vote is the highest
            }
            if (yes == max1) {
                return 1; // Highest vote count
            }
            return 2; // Not the highest
        }
    }

    // Find the top two maximum values in an array. If maximum values are equal, order doesn't matter.
    function _getMax1Max2(Prediction storage pre) private view returns (uint256, uint256, bool) {
        // Unclear vote count
        uint256 unknown = pre.option.counters[3]; // 3 represents unclear

        // Top two vote counts
        uint256 max1;
        uint256 max2;
        uint256 len = pre.optionIds.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 current = pre.options[pre.optionIds[i]].counters[1];
            if (current > max1) {
                // current becomes new max, old max becomes second max
                max2 = max1;
                max1 = current;
            } else if (current > max2) {
                // current is second max (greater than current second max but not exceeding max)
                max2 = current;
            }
        }

        // Return top 2
        if (unknown > max1) {
            return (unknown, max1, true); // true means unclear vote count is highest
        }
        if (unknown > max2) {
            return (max1, unknown, false);
        }
        return (max1, max2, false);
    }

    // Return cancelled or pending arbitration
    function _cancelOrArbitrate(uint256 firstVoteTime, PredictionSetting memory setting) private view returns (uint256) {
        // Tie, no arbitration for more than 120 days, mark as cancelled
        if (block.timestamp > (CANCELLATION_DURATION + firstVoteTime + setting.votingDuration + setting.challengeDuration)) {
            return 5; // Cancelled
        }
        return 4; // Pending arbitration
    }
}
