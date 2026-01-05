// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

struct PredictionSetting {
    // slot 0
    uint64 optionId;          // Option id
    uint64 roundNo;           // Round number
    uint32 startTime;         // Start time
    uint32 endTime;           // End time
    uint32 interval;          // Interval of each round
    uint16 aggregator;        // Aggregator for chainlink using  
    uint16 maxVotes;          // Maximum number of votes for single outcome

    // slot 1
    uint64 stakingAmount;     // Voting stake amount, unit: 1 USDC, i.e., 10**6
    uint64 challengeStaking;  // Challenge stake amount, unit: 1 USDC, i.e., 10**6
    uint32 votingDuration;    // Voting duration (in seconds)
    uint32 challengeDuration; // Challenge duration (in seconds)
    uint32 totalRewards;      // Total reward amount, unit: 1 USDC, i.e., 10**6
    uint8 rewardRanking;      // Ranking required to receive rewards
    uint8 challengePercent;   // Percentage of reward taken by challengers: 0~100%
    bool independent;         // Whether results are independent, false = single result, true = independent result
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;    
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface AggregatorV3Interface {
    function getRoundData(uint80 _roundId) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IPermission {
    function feeEOA() external view returns (address);
    function managerEOA() external view returns (address);
    function operationEOA() external view returns (address);
    function setAddress(uint256 requestId, address newAddress, uint256 addrType, bool value) external;
    function setAddresses(uint256 requestId, address[] calldata newAddresses, uint256 addrType, bool value) external;
    function checkAddress(address addr, uint256 addrType) external view returns (bool);
    function checkAddress2(address addr1, uint256 addrType1, address addr2, uint256 addrType2) external view returns (bool);
    function checkAddress3(address addr1, uint256 addrType1, address addr2, uint256 addrType2, address addr3, uint256 addrType3) external view returns (bool);
}

interface IFactory {  
    function check(address addr) external view returns (bool);
}

interface IPrediction {
    function getSetting(uint256 optionId) external view returns (PredictionSetting memory);
}

interface IOracle {
    function getOutcome(address prediction, uint256 optionId) external view returns (uint256);
}

interface IWallet {
    function transferToBuyPrediction(address oracle, uint256 amount, bytes calldata encodedData, bytes calldata signature) external;
    function transferToSellPrediction(uint256 amount, bytes calldata encodedData, bytes calldata signature) external;
    function transferToOracle(uint256 amount, bytes calldata encodedData, bytes calldata signature) external;
}

interface IMarketing {
    function transferFrom(uint256 amount, address wallet, bytes32 code, bytes calldata signature) external;
}

library AddressTypeLib {
    uint256 public constant EXECUTOR_EOA = 1000;
    uint256 public constant ARBITRATOR_EOA = 2000;
    uint256 public constant MARKETING = 3000;
    uint256 public constant ERC20 = 4000;
    uint256 public constant IMPLEMENTATION = 5000;
    uint256 public constant WALLET_FACTORY = 6000;
    uint256 public constant WALLET = 7000;
    uint256 public constant PREDICTION_FACTORY = 8000;
    uint256 public constant PREDICTION = 9000;
    uint256 public constant ORACLE = 10000;
}

library OutcomeTypeLib {
    uint256 public constant ZERO = 0;
    uint256 public constant YES = 1;
    uint256 public constant NO = 2;
    uint256 public constant UNCLEAR = 3;
    uint256 public constant PENDING = 4;
    uint256 public constant CANCELLED = 5; 
}

library EIP712Lib {
    bytes32 public constant EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    function recoverEIP712(bytes32 domainSeparator, bytes memory encodedData, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) {
            return address(0);
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))          
        }
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }
        bytes32 structHash = keccak256(encodedData);
        bytes32 digest;
        assembly ("memory-safe") { 
            let ptr := mload(0x40)
            mstore(ptr, hex"19_01")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)            
        }
        return ecrecover(digest, v, r, s);
    }
}