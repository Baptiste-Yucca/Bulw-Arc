// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {BulwArc} from "../src/BulwArc.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = 0x3600000000000000000000000000000000000000;
        address eurc = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock oracle with initial EUR/USD = 0.92
        MockOracle oracle = new MockOracle(92_000_000);
        console.log("MockOracle deployed at:", address(oracle));
        console.log("  -> https://testnet.arcscan.app/address/", address(oracle));

        // Deploy BulwArc with 1% fee (100 bps)
        BulwArc shield = new BulwArc(usdc, eurc, address(oracle), 100);
        console.log("BulwArc deployed at:", address(shield));
        console.log("  -> https://testnet.arcscan.app/address/", address(shield));

        vm.stopBroadcast();
    }
}
