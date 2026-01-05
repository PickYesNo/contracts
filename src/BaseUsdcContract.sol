// SPDX-License-Identifier: UNLICENSED

/*
Copyright © 2025 PickYesNo.com. All Rights Reserved.
This source code is provided for viewing purposes only. No copying, distribution, modification, or commercial use is permitted without explicit written permission from the copyright holder.
Contact PickYesNo.com for licensing inquiries.
*/

pragma solidity 0.8.28;

import "./BaseContract.sol";

// USDC Base Contract
abstract contract BaseUsdcContract is BaseContract {
    address public constant USDC = 0x0000000000000000000000000000000000000000; // Built-in official USDC contract address

    IERC20 internal constant IUSDC = IERC20(USDC); // Official USDC contract interface

    event UsdcTransferredError(string reason);             // Event emitted when an error occurs while attempting to transfer USDC
    event UsdcTransferredLowLevelData(bytes lowLevelData); // Event emitted when an error occurs while attempting to transfer USDC

    // Transfer
    function transferUsdc(address to, uint256 amount) internal {
        try IUSDC.transfer(to, amount) returns (bool success) {
            require(success, "usdc err");
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("usdc err 1,", reason)));
        } catch (bytes memory lowLevelData) {
            revert(string(abi.encodePacked("usdc err 2,", lowLevelData)));
        }
    }

    // Attempt Transfer
    function tryTransferUsdc(address to, uint256 amount) internal returns (bool) {
        try IUSDC.transfer(to, amount) returns (bool success) {
            return success;
        } catch Error(string memory reason) {
            emit UsdcTransferredError(reason);
        } catch (bytes memory lowLevelData) {
            emit UsdcTransferredLowLevelData(lowLevelData);
        }
        return false;
    }
}