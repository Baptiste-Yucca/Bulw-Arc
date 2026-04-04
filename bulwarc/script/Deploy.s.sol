// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {BulwArc} from "../src/BulwArc.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = 0x3600000000000000000000000000000000000000;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock oracle with initial EUR/USD = 0.92
        MockOracle oracle = new MockOracle(92_000_000);
        console.log("MockOracle deployed at:", address(oracle));
        console.log("  -> https://testnet.arcscan.app/address/", address(oracle));

        // Deploy BulwArc
        BulwArc shield = new BulwArc(usdc, address(oracle));
        console.log("BulwArc deployed at:", address(shield));
        console.log("  -> https://testnet.arcscan.app/address/", address(shield));

        vm.stopBroadcast();
    }
}
