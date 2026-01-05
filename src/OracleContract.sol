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
    bytes32 private constant TYPEHASH_VOTE = keccak256("Vote(address prediction,uint256 optionId,uint256 outcome,uint256 staking,uint256 chainId,address oracleContract)");
    bytes32 private constant TYPEHASH_CHALLENGE = keccak256("Challenge(address prediction,uint256 optionId,uint256 outcome,uint256 staking,uint256 chainId,address oracleContract)");
    bytes32 private constant TYPEHASH_ARBITRATE = keccak256("Arbitrate(address prediction,uint256 optionId,uint256 outcome,uint256 chainId,address oracleContract)");
    mapping(address => mapping(uint256 => Prediction)) private predictions; // Voting records: address=prediction contract address, uint256=round no, Prediction=voting record

    event Voted(uint256 requestId, uint256 optionId);      // Vote event
    event Challenged(uint256 requestId, uint256 optionId); // Challenge event
    event Arbitrated(uint256 requestId);                   // Arbitration event
    event FeeTransferred(uint256 requestId);               // Transfer to fee event
    event Rewarded(uint256 requestId, address[] wallet);   // Reward distribution event

    // Prediction
    struct Prediction {
        mapping(uint256 => Option) options; // Voting records: uint256=option id, Option=option details
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
        DOMAIN_SEPARATOR = keccak256(abi.encode(EIP712Lib.EIP712_DOMAIN, keccak256(bytes("Oracle Contract")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    // Vote
    function vote(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, address wallet, bytes calldata signature) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId != 0 && IPERMISSION.checkAddress(wallet, AddressTypeLib.WALLET), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Record vote
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        if (setting.independent) {
            // Valid outcome
            require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.NO || outcome == OutcomeTypeLib.UNCLEAR, "outcome err");

            // Must be after closing time
            if (opt.firstVoteTime == 0) {
                require(block.timestamp > setting.endTime && block.timestamp < (CANCELLATION_DURATION + setting.endTime), "time err");
                opt.firstVoteTime = block.timestamp;
            }
            require(block.timestamp < (opt.firstVoteTime + setting.votingDuration), "time err");

            // Each person can vote only once per option
            Vote storage vot = opt.votes[wallet];
            require(vot.optionId == 0, "voted");

            // Valid maximum votes
            uint256 cnt = opt.counters[outcome]++;
            require(cnt < setting.maxVotes, "max err");

            // Record vote and count
            vot.optionId = uint64(optionId);
            vot.ranking = uint32(cnt);
            vot.outcome = uint8(outcome);
        } else {
            // Must be after closing time
            Option storage opt0 = pre.options[OutcomeTypeLib.ZERO];
            if (opt0.firstVoteTime == 0) {
                require(block.timestamp > setting.endTime && block.timestamp < (CANCELLATION_DURATION + setting.endTime), "time err");
                opt0.firstVoteTime = block.timestamp;
            }
            require(block.timestamp < (opt0.firstVoteTime + setting.votingDuration), "time err");

            // Each person can vote only once per prediction
            Vote storage vot = opt0.votes[wallet];
            require(vot.optionId == 0, "voted");

            // Valid outcome & calculate ranking
            uint256 cnt;
            if (outcome == OutcomeTypeLib.YES) {
                cnt = opt.counters[OutcomeTypeLib.YES]++;
                if (cnt == 0) {
                    pre.optionIds.push(optionId); // Record the count of voting options
                }
            } else if (outcome == OutcomeTypeLib.UNCLEAR) {
                cnt = opt0.counters[OutcomeTypeLib.UNCLEAR]++;
            } else {
                revert("outcome err");
            }

            // Valid maximum votes
            require(cnt < setting.maxVotes, "max err");

            // Record vote and count
            vot.optionId = uint64(optionId);
            vot.ranking = uint32(cnt);
            vot.outcome = uint8(outcome);
        }

        // Stake USDC to the prediction contract
        if (setting.stakingAmount != 0) {
            IWallet(wallet).transferToOracle(setting.stakingAmount, abi.encode(TYPEHASH_VOTE, prediction, optionId, outcome, setting.stakingAmount, block.chainid, address(this)), signature);
            stakingAmount += setting.stakingAmount;
        }

        // Log success event
        emit Voted(requestId, optionId);
    }

    // Challenge
    function challenge(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, address wallet, bytes calldata signature) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId != 0 && IPERMISSION.checkAddress(wallet, AddressTypeLib.WALLET), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Record challenge
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        if (setting.independent) {
            // Only one challenge allowed
            require(opt.challenge.optionId == 0, "challenged");

            // Check if challenge timing is correct
            require(opt.firstVoteTime != 0 && block.timestamp > (opt.firstVoteTime + setting.votingDuration) && block.timestamp < (opt.firstVoteTime + setting.votingDuration + setting.challengeDuration), "time err");

            // Independent result, must vote for the minority option to represent challenge. If tie, no restriction on minority.
            uint256 yes = opt.counters[OutcomeTypeLib.YES];
            uint256 no = opt.counters[OutcomeTypeLib.NO];
            uint256 unclear = opt.counters[OutcomeTypeLib.UNCLEAR];
            if (yes > no && yes > unclear) {
                require(outcome == OutcomeTypeLib.NO || outcome == OutcomeTypeLib.UNCLEAR, "minority"); // Yes majority, can only vote no or unclear 50-50 settlement
            } else if (no > yes && no > unclear) {
                require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.UNCLEAR, "minority"); // No majority, can only vote yes or unclear 50-50 settlement
            } else if (unclear > yes && unclear > no) {
                require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.NO, "minority"); // Unclear majority, can only vote yes or no
            } else {
                require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.NO || outcome == OutcomeTypeLib.UNCLEAR, "outcome err"); // Tie， no restriction
            }

            // Record challenge vote
            opt.challenge.optionId = uint64(optionId);
            opt.challenge.wallet = wallet;
            opt.challenge.outcome = uint8(outcome);
        } else {
            // Only one challenge allowed
            Option storage opt0 = pre.options[OutcomeTypeLib.ZERO];
            require(opt0.challenge.optionId == 0, "challenged");

            // Check if challenge timing is correct
            require(opt0.firstVoteTime != 0 && block.timestamp > (opt0.firstVoteTime + setting.votingDuration) && block.timestamp < (opt0.firstVoteTime + setting.votingDuration + setting.challengeDuration), "time err");

            // Single result, challenge vote cannot be the highest-voted option. If tie, no restriction.
            (uint256 max1, uint256 max2, ) = _getMax1Max2(pre);
            if (outcome == OutcomeTypeLib.YES) {
                require(max1 == max2 || opt.counters[OutcomeTypeLib.YES] < max1, "minority");  // Yes vote
            } else if (outcome == OutcomeTypeLib.UNCLEAR) {
                require(max1 == max2 || opt0.counters[OutcomeTypeLib.UNCLEAR] < max1, "minority"); // Unclear vote
            } else {       
                revert("outcome err"); // Single result only allows challenge: yes and unclear
            }

            // Record challenge vote
            opt0.challenge.optionId = uint64(optionId);
            opt0.challenge.wallet = wallet;
            opt0.challenge.outcome = uint8(outcome);
        }

        // Challenger must stake additional USDC to the prediction contract
        if (setting.challengeStaking != 0) {
            IWallet(wallet).transferToOracle(setting.challengeStaking, abi.encode(TYPEHASH_CHALLENGE, prediction, optionId, outcome, setting.challengeStaking, block.chainid, address(this)), signature);
            stakingAmount += setting.challengeStaking;
        }

        // Log success event
        emit Challenged(requestId, optionId);
    }

    // Arbitrate
    function arbitrate(uint256 requestId, address prediction, uint256 optionId, uint256 outcome, bytes[] calldata signatures) external onlyExecutorEOA {
        // Critical parameter checks
        require(optionId != 0 && signatures.length == 2, "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Check if arbitration is allowed
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        require((setting.independent ? _getOutcomeIndependent(opt, setting, true) : _getOutcomeNonIndependent(pre, opt, optionId, setting, true)) == OutcomeTypeLib.PENDING, "arbitrate failed");

        // Check by multisig
        bytes memory hash = abi.encode(TYPEHASH_ARBITRATE, prediction, optionId, outcome, block.chainid, address(this));
        address addr1 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, hash, signatures[0]);
        address addr2 = EIP712Lib.recoverEIP712(DOMAIN_SEPARATOR, hash, signatures[1]);
        require(addr1 != address(0) && addr2 != address(0) && addr1 != addr2 && IPERMISSION.checkAddress2(addr1, AddressTypeLib.ARBITRATOR_EOA, addr2, AddressTypeLib.ARBITRATOR_EOA), "arbitrate failed");

        // Record arbitration
        if (setting.independent) {
            require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.NO || outcome == OutcomeTypeLib.UNCLEAR || outcome == OutcomeTypeLib.CANCELLED, "outcome err");
            opt.arbitration = Arbitration(uint64(optionId), uint8(outcome));
        } else {
            require(outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.UNCLEAR || outcome == OutcomeTypeLib.CANCELLED, "outcome err");
            pre.options[OutcomeTypeLib.ZERO].arbitration = Arbitration(uint64(optionId), uint8(outcome));
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
        require(optionId != 0 && IPERMISSION.checkAddress(prediction, AddressTypeLib.PREDICTION), "param err");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get voting outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        uint256 outcome = setting.independent ? _getOutcomeIndependent(opt, setting, true) : _getOutcomeNonIndependent(pre, opt, optionId, setting, true);

        // Only yes,no,unclear 50-50 settlement, rewards can be distributed
        uint256 totalRewards;
        if (outcome == OutcomeTypeLib.YES || outcome == OutcomeTypeLib.NO || outcome == OutcomeTypeLib.UNCLEAR) {
            totalRewards = setting.totalRewards;
        } else if (outcome == OutcomeTypeLib.CANCELLED) {
            // Cancelled, no rewards, only return staked amount
        } else {
            revert("outcome err");
        }

        // Challenge rewards
        uint256 returnStaking;
        uint256 voteRewards;
        if (setting.independent) {
            (returnStaking, voteRewards) = _rewardChallenge(opt, opt, false, outcome, totalRewards, setting);
        } else {
            Option storage opt0 = pre.options[OutcomeTypeLib.ZERO];
            (returnStaking, voteRewards) = _rewardChallenge(opt0, opt, outcome == OutcomeTypeLib.UNCLEAR, outcome, totalRewards, setting);
            opt = opt0; // Important assignment
        }

        // Voting rewards
        uint256 len = wallets.length;
        for (uint256 i; i < len;) {
            returnStaking += _rewardVote(opt, wallets[i], optionId, outcome, voteRewards, setting);

            // for
            unchecked { ++i; }
        }

        // Update staked amount
        stakingAmount -= returnStaking;

        // Log success event
        emit Rewarded(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA) ? requestId : 0, wallets);
    }

    // Get voting result
    function getVote(address prediction, uint256 optionId) external view returns (uint256) {
        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get voting outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        return setting.independent ? _getOutcomeIndependent(opt, setting, false) : _getOutcomeNonIndependent(pre, opt, optionId, setting, false);
    }

    // Get outcome
    function getOutcome(address prediction, uint256 optionId) external view returns (uint256) {
        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(optionId);

        // Get outcome
        Prediction storage pre = predictions[prediction][setting.roundNo];
        Option storage opt = pre.options[optionId];
        return setting.independent ? _getOutcomeIndependent(opt, setting, true) : _getOutcomeNonIndependent(pre, opt, optionId, setting, true);
    }

    // Challenge rewards
    function _rewardChallenge(Option storage optOr0, Option storage opt, bool isUnclear, uint256 outcome, uint256 totalRewards, PredictionSetting memory setting) private returns (uint256, uint256) {
        uint256 returnStaking;
        uint256 voteRewards;

        // Check if there is a challenge
        uint256 challengeRewards;
        if (optOr0.challenge.optionId != 0) {
            // Check if challenge is correct (isUnclear=true means for multiple-choice single result arbitrated as unclear 50-50, optionId doesn't matter, only outcome needs to be correct)
            if ((optOr0.challenge.optionId == optOr0.arbitration.optionId || isUnclear) && optOr0.challenge.outcome == optOr0.arbitration.outcome) {
                // Challenge reward
                challengeRewards = totalRewards * setting.challengePercent / 100;

                // Check if reward already distributed
                if (!optOr0.challenge.done) {
                    optOr0.challenge.done = true;
                    returnStaking = setting.challengeStaking;

                    // Distribute reward
                    transferUsdc(optOr0.challenge.wallet, setting.challengeStaking + challengeRewards);
                }
            } else {
                if (!optOr0.challenge.done) {
                    optOr0.challenge.done = true;
                    returnStaking = setting.challengeStaking;

                    // If cancelled, regardless of challenge correctness, return staked amount
                    if (outcome == OutcomeTypeLib.CANCELLED) {
                        transferUsdc(optOr0.challenge.wallet, setting.challengeStaking);
                    }
                }
            }
        }

        // Voting rewards (if participant limit reached, only top ranking participants; if not reached, all correct voters split equally)
        if (setting.rewardRanking != 0) {
            uint256 cnt = isUnclear ? optOr0.counters[outcome] : opt.counters[outcome];
            if (cnt != 0) {
                voteRewards = cnt > setting.rewardRanking ? (totalRewards - challengeRewards) / setting.rewardRanking : (totalRewards - challengeRewards) / cnt; // Total rewards minus the challenger's share
            }
        }

        // Return staked amount and voting rewards
        return (returnStaking, voteRewards);
    }

    // Voting rewards
    function _rewardVote(Option storage optOr0, address wallet, uint256 optionId, uint256 outcome, uint256 voteRewards, PredictionSetting memory setting) private returns (uint256) {
        uint256 returnStaking;

        // Check if there is a vote
        Vote storage vot = optOr0.votes[wallet];
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
                    if (outcome == OutcomeTypeLib.CANCELLED) {
                        transferUsdc(wallet, setting.stakingAmount);
                    }
                }
            }
        }

        // Return staked amount
        return returnStaking;
    }

    // Get independent outcome
    function _getOutcomeIndependent(Option storage opt, PredictionSetting memory setting, bool isFinal) private view returns (uint256) {        
        // If arbitration exists, return arbitration result directly
        if (opt.arbitration.optionId != 0) {
            return opt.arbitration.outcome;
        }

        // If no one voted and more than 120 days have passed after prediction end, mark as cancelled
        if (opt.firstVoteTime == 0) {
            if (block.timestamp > (CANCELLATION_DURATION + setting.endTime)) {
                return OutcomeTypeLib.CANCELLED;
            }
            return OutcomeTypeLib.ZERO; // In progress
        }

        // If there is a challenge and no arbitration for more than 120 days, mark as cancelled
        if (opt.challenge.optionId != 0) {
            return _cancelOrArbitrate(opt.firstVoteTime, setting);
        }

        // isFinal=true means challenge period ended, can get result. Otherwise, it's the result based on current voting, note this is not final.
        if (isFinal && block.timestamp < (opt.firstVoteTime + setting.votingDuration + setting.challengeDuration)) {
            return OutcomeTypeLib.ZERO; // In progress
        }

        // Independent result, direct comparison
        uint256 yes = opt.counters[OutcomeTypeLib.YES];
        uint256 no = opt.counters[OutcomeTypeLib.NO];
        uint256 unclear = opt.counters[OutcomeTypeLib.UNCLEAR];
        if (yes > no && yes > unclear) {
            return OutcomeTypeLib.YES;
        }
        if (no > yes && no > unclear) {
            return OutcomeTypeLib.NO;
        }
        if (unclear > yes && unclear > no) {
            return OutcomeTypeLib.UNCLEAR;
        }
        return _cancelOrArbitrate(opt.firstVoteTime, setting);
    }

    // Get non-independent outcome
    function _getOutcomeNonIndependent(Prediction storage pre, Option storage opt, uint256 optionId, PredictionSetting memory setting, bool isFinal) private view returns (uint256) {
        // If arbitration exists, return arbitration result directly
        Option storage opt0 = pre.options[OutcomeTypeLib.ZERO];
        if (opt0.arbitration.optionId != 0) {
            if (opt0.arbitration.optionId == optionId) {
                return opt0.arbitration.outcome;
            } else {
                return opt0.arbitration.outcome < OutcomeTypeLib.UNCLEAR ? OutcomeTypeLib.UNCLEAR - opt0.arbitration.outcome : opt0.arbitration.outcome; // For multiple-choice single result, invert the outcome
            }
        }

        // If no one voted and more than 120 days have passed after prediction end, mark as cancelled
        if (opt0.firstVoteTime == 0) {
            if (block.timestamp > (CANCELLATION_DURATION + setting.endTime)) {
                return OutcomeTypeLib.CANCELLED;
            }
            return OutcomeTypeLib.ZERO; // In progress
        }

        // If there is a challenge and no arbitration for more than 120 days, mark as cancelled
        if (opt0.challenge.optionId != 0) {
            return _cancelOrArbitrate(opt0.firstVoteTime, setting);
        }

        // isFinal=true means challenge period ended, can get result. Otherwise, it's the result based on current voting, note this is not final.
        if (isFinal && block.timestamp < (opt0.firstVoteTime + setting.votingDuration + setting.challengeDuration)) {
            return OutcomeTypeLib.ZERO; // In progress
        }

        // Single result (by comparing top two maximum values)
        (uint256 max1, uint256 max2, bool isUnclear) = _getMax1Max2(pre);
        if (max1 == max2) {
            return _cancelOrArbitrate(opt0.firstVoteTime, setting);
        }
        if (isUnclear) {
            return OutcomeTypeLib.UNCLEAR; // Unclear vote is the highest
        }
        if (max1 == opt.counters[OutcomeTypeLib.YES]) {
            return OutcomeTypeLib.YES; // Highest vote count
        }
        return OutcomeTypeLib.NO; // Not the highest
    }

    // Find the top two maximum values in an array. If maximum values are equal, order doesn't matter.
    function _getMax1Max2(Prediction storage pre) private view returns (uint256, uint256, bool) {
        // Unclear vote count
        uint256 unclear = pre.options[OutcomeTypeLib.ZERO].counters[OutcomeTypeLib.UNCLEAR];

        // Top two vote counts
        uint256 max1;
        uint256 max2;
        uint256 len = pre.optionIds.length;
        for (uint256 i; i < len;) {
            uint256 current = pre.options[pre.optionIds[i]].counters[OutcomeTypeLib.YES];
            if (current > max1) {
                // current becomes new max, old max becomes second max
                max2 = max1;
                max1 = current;
            } else if (current > max2) {
                // current is second max (greater than current second max but not exceeding max)
                max2 = current;
            }

            // for
            unchecked { ++i; }
        }

        // Return top 2
        if (unclear > max1) {
            return (unclear, max1, true); // true means unclear vote count is highest
        }
        if (unclear > max2) {
            return (max1, unclear, false);
        }
        return (max1, max2, false);
    }

    // Return cancelled or pending arbitration
    function _cancelOrArbitrate(uint256 firstVoteTime, PredictionSetting memory setting) private view returns (uint256) {
        // Tie, no arbitration for more than 120 days, mark as cancelled
        if (block.timestamp > (CANCELLATION_DURATION + firstVoteTime + setting.votingDuration + setting.challengeDuration)) {
            return OutcomeTypeLib.CANCELLED;
        }
        return OutcomeTypeLib.PENDING;
    }
}