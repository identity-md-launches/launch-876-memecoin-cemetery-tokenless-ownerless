// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MemecoinCemetery} from "../src/MemecoinCemetery.sol";

/// @notice Reviewable deployment entry point; the operator supplies the signer through Foundry's CLI.
contract Deploy is Script {
    error WrongChain(uint256 actualChainId);

    /// @notice Deploy a zero-argument cemetery on Robinhood Chain (4663) only.
    /// @dev With no --broadcast this only simulates. No environment or private keys are read by this script.
    function run() external returns (MemecoinCemetery cemetery) {
        if (block.chainid != 4663) revert WrongChain(block.chainid);
        vm.startBroadcast();
        cemetery = new MemecoinCemetery();
        vm.stopBroadcast();
    }
}
