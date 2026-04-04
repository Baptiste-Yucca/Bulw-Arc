// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockOracle {
    int256 public price; // EUR/USD in 1e8 (e.g. 92_000_000 = 0.92)
    uint256 public updatedAt;
    address public owner;

    constructor(int256 _initialPrice) {
        owner = msg.sender;
        price = _initialPrice;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        require(msg.sender == owner, "Only owner");
        price = _price;
        updatedAt = block.timestamp;
    }

    function getPrice() external view returns (int256, uint256) {
        return (price, updatedAt);
    }
}
