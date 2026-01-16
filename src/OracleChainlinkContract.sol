// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseContract.sol";

// Chainlink Oracle Contract
contract OracleChainlinkContract is BaseContract, IOracle {
    uint256 public constant CANCELLATION_DURATION = 7 days; // Cancellation period in days

    mapping(address => mapping(uint256 => int256)) private prices; // Price mapping: address=prediction contract, uint256=round no, int256=price

    event PriceSaved(uint256 requestId, uint80 roundId, int256 price); // Event emitted when price is saved

    // Fetch price via Chainlink and save it on-chain
    function savePrice(uint256 requestId, address prediction, uint256 optionId, uint80 startRoundId, uint256 length) external {
        // Check if price has already been saved
        require(prices[prediction][optionId] == 0, "saved");

        // Retrieve parameters from the prediction contract
        PredictionSetting memory setting = IPrediction(prediction).getSetting(0);
        uint256 endTime = setting.startTime + setting.interval * optionId;
        require(block.timestamp < (CANCELLATION_DURATION + endTime), "cancelled");

        // Get the aggregator contract address
        address addr = _getAggregator(setting.aggregator);
        require(addr != address(0), "aggregator err");

        // Check the timestamp of the latest price, ensure it is greater than or equal to the prediction end time
        AggregatorV3Interface aggregatorV3 = AggregatorV3Interface(addr);
        (uint80 roundId, int256 answer, , uint256 updatedAt, ) = aggregatorV3.latestRoundData();
        require(updatedAt >= endTime, "time err");

        // Default to using the latest roundId
        uint80 rid;
        int256 price;
        if (startRoundId != 0) {
            // First find the first roundId less than endTime
            while (length != 0) {
                unchecked {
                    --length;
                }
                (, answer, , updatedAt, ) = _tryGetRoundData(aggregatorV3, startRoundId);
                if (updatedAt != 0) {
                    if (updatedAt < endTime) {
                        if (price > 0) {
                            prices[prediction][optionId] = price;
                            emit PriceSaved(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA) ? requestId : 0, rid, price);
                            return;
                        } else {
                            break;
                        }
                    } else {
                        rid = startRoundId;
                        price = answer;
                    }
                }
                unchecked {
                    --startRoundId;
                }                
            }
            // Starting from lessRoundId, find the first price greater than or equal to endTime, which is the correct price
            while (length != 0) {
                unchecked {
                    --length;
                    ++startRoundId;
                }                
                (, answer, , updatedAt, ) = _tryGetRoundData(aggregatorV3, startRoundId);
                if (updatedAt >= endTime) {
                    prices[prediction][optionId] = answer;
                    emit PriceSaved(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA) ? requestId : 0, startRoundId, answer);
                    return;
                }
            }
        } else {
            rid = roundId;
            price = answer;
            while (length != 0) {
                unchecked {
                    --length;
                    --roundId;
                }
                (, answer, , updatedAt, ) = _tryGetRoundData(aggregatorV3, roundId);
                if (updatedAt != 0) {
                    if (updatedAt < endTime) {
                        prices[prediction][optionId] = price;
                        emit PriceSaved(IPERMISSION.checkAddress(msg.sender, AddressTypeLib.EXECUTOR_EOA) ? requestId : 0, rid, price);
                        return;
                    } else {
                        rid = roundId;
                        price = answer;
                    }
                }
            }
        }

        // If the correct price cannot be found, need to change startRoundId and continue searching
        revert("recall");
    }

    // Get outcome
    function getOutcome(address prediction, uint256 optionId) external view returns (uint256) {
        // get price
        int256 currPrice = prices[prediction][optionId];
        int256 prevPrice = prices[prediction][optionId - 1];
        if (currPrice == 0 || prevPrice == 0) {
            // If no result beyond this period, mark as: 5 = Cancelled
            PredictionSetting memory setting = IPrediction(prediction).getSetting(0);
            if (block.timestamp > (CANCELLATION_DURATION + setting.startTime + setting.interval * optionId)) {
                return OutcomeTypeLib.CANCELLED;
            }

            // In Process
            return OutcomeTypeLib.ZERO;
        }

        // compare price
        if (currPrice >= prevPrice) {
            return OutcomeTypeLib.YES;
        } else {
            return OutcomeTypeLib.NO;
        }
    }

    // Get price
    function getPrice(address prediction, uint256 optionId) external view returns (int256) {
        return prices[prediction][optionId];
    }

    // Get the latest roundId
    function getLatestRoundId(address prediction) external view returns (uint256) {
        PredictionSetting memory setting = IPrediction(prediction).getSetting(0);
        address addr = _getAggregator(setting.aggregator);
        if (addr == address(0)) {
            return 0;
        }
        (uint80 roundId, , , , ) = AggregatorV3Interface(addr).latestRoundData();
        return roundId;
    }

    // Get the aggregator contract address.
    function _getAggregator(uint16 aggregator) private pure returns (address) {
        address addr;
        assembly {
            switch aggregator
            case 1 { addr := 0xc907E116054Ad103354f2D350FD2514433D57F6f }  // BTC: https://data.chain.link/feeds/polygon/mainnet/btc-usd
            case 2 { addr := 0xF9680D99D6C9589e2a93a78A04A279e509205945 }  // ETH: https://data.chain.link/feeds/polygon/mainnet/eth-usd
            case 3 { addr := 0x0A6513e40db6EB1b165753AD52E80663aeA50545 }  // USDT: https://data.chain.link/feeds/polygon/mainnet/usdt-usd
            case 4 { addr := 0x785ba89291f676b5386652eB12b30cF361020694 }  // XRP: https://data.chain.link/feeds/polygon/mainnet/xrp-usd
            case 5 { addr := 0x82a6c4AF830caa6c97bb504425f6A66165C2c26e }  // BNB: https://data.chain.link/feeds/polygon/mainnet/bnb-usd
            case 6 { addr := 0x10C8264C0935b3B9870013e057f330Ff3e9C56dC }  // SOL: https://data.chain.link/feeds/polygon/mainnet/sol-usd
            case 7 { addr := 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7 }  // USDC: https://data.chain.link/feeds/polygon/mainnet/usdc-usd
            case 8 { addr := 0xbaf9327b6564454F4a3364C33eFeEf032b4b4444 }  // DOGE: https://data.chain.link/feeds/polygon/mainnet/doge-usd
            case 9 { addr := 0x882554df528115a743c4537828DA8D5B58e52544 }  // ADA：https://data.chain.link/feeds/polygon/mainnet/ada-usd
            case 10 { addr := 0xd9FFdb71EbE7496cC440152d43986Aae0AB76665 } // LINK：https://data.chain.link/feeds/polygon/mainnet/link-usd
            case 11 { addr := 0xacb51F1a83922632ca02B25a8164c10748001BdE } // DOT：https://data.chain.link/feeds/polygon/mainnet/dot-usd
            case 12 { addr := 0xdf0Fb4e4F928d2dCB76f438575fDD8682386e13C } // UNI：https://data.chain.link/feeds/polygon/mainnet/uni-usd
            case 13 { addr := 0x4746DeC9e833A82EC7C2C1356372CcF2cfcD2F3D } // DAI：https://data.chain.link/feeds/polygon/mainnet/dai-usd
            case 14 { addr := 0x72484B12719E23115761D5DA1646945632979bB6 } // AAVE：https://data.chain.link/feeds/polygon/mainnet/aave-usd
            case 15 { addr := 0x3FabBfb300B1e2D7c9B84512fe9D30aeDF24C410 } // GRT：https://data.chain.link/feeds/polygon/mainnet/grt-usd
            case 16 { addr := 0x0f6914d8e7e1214CDb3A4C6fbf729b75C69DF608 } // PAXG：https://data.chain.link/feeds/polygon/mainnet/paxg-usd
            case 17 { addr := 0xA1CbF3Fe43BC3501e3Fc4b573e822c70e76A7512 } // MANA：https://data.chain.link/feeds/polygon/mainnet/mana-usd
            case 18 { addr := 0x7C5D415B64312D38c56B54358449d0a4058339d2 } // TUSD：https://data.chain.link/feeds/polygon/mainnet/tusd-usd
            case 19 { addr := 0x2A8758b7257102461BC958279054e372C2b1bDE6 } // COMP：https://data.chain.link/feeds/polygon/mainnet/comp-usd
            case 20 { addr := 0x443C5116CdF663Eb387e72C688D276e702135C87 } // 1INCH：https://data.chain.link/feeds/polygon/mainnet/1inch-usd
            case 21 { addr := 0xbF90A5D9B6EE9019028dbFc2a9E50056d5252894 } // SNX：https://data.chain.link/feeds/polygon/mainnet/snx-usd
            case 22 { addr := 0x2346Ce62bd732c62618944E51cbFa09D985d86D2 } // BAT：https://data.chain.link/feeds/polygon/mainnet/bat-usd
            case 23 { addr := 0x9d3A43c111E7b2C6601705D9fcF7a70c95b1dc55 } // YFI：https://data.chain.link/feeds/polygon/mainnet/yfi-usd
            case 24 { addr := 0x33D9B1BAaDcF4b26ab6F8E83e9cb8a611B2B3956 } // UMA：https://data.chain.link/feeds/polygon/mainnet/uma-usd
            case 25 { addr := 0x10e5f3DFc81B3e5Ef4e648C4454D04e79E1E41E2 } // KNC：https://data.chain.link/feeds/polygon/mainnet/knc-usd
        }
        return addr;
    }

    // Try to get round data
    function _tryGetRoundData(AggregatorV3Interface agg, uint80 rid) private view returns (uint80, int256, uint256, uint256, uint80) {
        try agg.getRoundData(rid) returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        } catch {
            return (rid, 0, 0, 0, 0);
        }
    }
}