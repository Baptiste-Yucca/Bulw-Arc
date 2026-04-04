// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IOracle {
    function getPrice() external view returns (int256 price, uint256 updatedAt);
}

contract BulwArc {
    enum ShieldStatus { CREATED, PENDING, LOCKED, EXERCISED, EXPIRED }

    struct Fill {
        address guardian;
        uint256 amount;
    }

    struct Shield {
        address subscriber;
        uint256 strike;       // EUR/USD price in 1e8
        uint256 notional;     // total amount to cover in USDC (1e6)
        uint256 premium;      // premium in USDC (1e6)
        uint256 filled;       // total filled so far
        uint256 expiry;
        ShieldStatus status;
    }

    IERC20 public immutable usdc;
    IOracle public immutable oracle;

    Shield[] public shields;
    mapping(uint256 => Fill[]) public fills; // shieldId => fills

    event ShieldCreated(uint256 indexed shieldId, address indexed subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry);
    event ShieldFunded(uint256 indexed shieldId, address indexed funder);
    event ShieldFilled(uint256 indexed shieldId, address indexed guardian, uint256 amount);
    event ShieldLocked(uint256 indexed shieldId);
    event ShieldExercised(uint256 indexed shieldId, uint256 payoff);
    event ShieldExpired(uint256 indexed shieldId);

    constructor(address _usdc, address _oracle) {
        usdc = IERC20(_usdc);
        oracle = IOracle(_oracle);
    }

    // ========== CREATE ==========

    function createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external {
        require(strike > 0, "Invalid strike");
        require(notional > 0, "Invalid notional");
        require(premium > 0, "Invalid premium");
        require(expiry > block.timestamp, "Expiry in the past");

        uint256 shieldId = shields.length;
        shields.push(Shield({
            subscriber: msg.sender,
            strike: strike,
            notional: notional,
            premium: premium,
            filled: 0,
            expiry: expiry,
            status: ShieldStatus.CREATED
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
    }

    function createAndFundShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external {
        require(strike > 0, "Invalid strike");
        require(notional > 0, "Invalid notional");
        require(premium > 0, "Invalid premium");
        require(expiry > block.timestamp, "Expiry in the past");

        usdc.transferFrom(msg.sender, address(this), premium);

        uint256 shieldId = shields.length;
        shields.push(Shield({
            subscriber: msg.sender,
            strike: strike,
            notional: notional,
            premium: premium,
            filled: 0,
            expiry: expiry,
            status: ShieldStatus.PENDING
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== FUND ==========

    function fundShield(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED, "Not created");
        require(block.timestamp < s.expiry, "Expired");

        usdc.transferFrom(msg.sender, address(this), s.premium);
        s.status = ShieldStatus.PENDING;

        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== MATCH (partial fill) ==========

    function matchShield(uint256 shieldId, uint256 amount) external {
        _matchShield(shieldId, msg.sender, amount);
    }

    function matchShieldFor(uint256 shieldId, address guardian, uint256 amount) external {
        require(guardian != address(0), "Invalid guardian");
        _matchShield(shieldId, guardian, amount);
    }

    function _matchShield(uint256 shieldId, address guardian, uint256 amount) internal {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING, "Not pending");
        require(block.timestamp < s.expiry, "Expired");
        require(amount > 0, "Invalid amount");

        uint256 remaining = s.notional - s.filled;
        require(amount <= remaining, "Exceeds remaining");

        usdc.transferFrom(msg.sender, address(this), amount);

        fills[shieldId].push(Fill({guardian: guardian, amount: amount}));
        s.filled += amount;

        // Distribute premium pro-rata to this guardian
        uint256 premiumShare = s.premium * amount / s.notional;
        if (premiumShare > 0) {
            usdc.transfer(guardian, premiumShare);
        }

        emit ShieldFilled(shieldId, guardian, amount);

        if (s.filled == s.notional) {
            s.status = ShieldStatus.LOCKED;
            emit ShieldLocked(shieldId);
        }
    }

    // ========== EXERCISE ==========

    function exercise(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot exercise");
        require(s.filled > 0, "No fills");
        require(msg.sender == s.subscriber, "Not subscriber");
        require(block.timestamp <= s.expiry, "Past expiry");

        (int256 spot, uint256 updatedAt) = oracle.getPrice();
        require(block.timestamp <= updatedAt + 5 minutes, "Stale oracle price");
        require(spot > 0, "Invalid oracle price");
        require(uint256(spot) < s.strike, "Not in the money");

        uint256 payoffPerUnit = s.strike - uint256(spot); // in 1e8

        s.status = ShieldStatus.EXERCISED;

        uint256 totalPayoff;
        Fill[] storage f = fills[shieldId];
        for (uint256 i = 0; i < f.length; i++) {
            uint256 guardianPayoff = payoffPerUnit * f[i].amount / 1e8;
            if (guardianPayoff > f[i].amount) guardianPayoff = f[i].amount;

            totalPayoff += guardianPayoff;

            // Return remaining collateral to guardian
            uint256 guardianRemaining = f[i].amount - guardianPayoff;
            if (guardianRemaining > 0) {
                usdc.transfer(f[i].guardian, guardianRemaining);
            }
        }

        // Pay subscriber total payoff
        if (totalPayoff > 0) {
            usdc.transfer(s.subscriber, totalPayoff);
        }

        emit ShieldExercised(shieldId, totalPayoff);
    }

    // ========== EXPIRE ==========

    function expire(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot expire");
        require(block.timestamp > s.expiry, "Not expired yet");

        s.status = ShieldStatus.EXPIRED;

        // Return collateral to each guardian
        Fill[] storage f = fills[shieldId];
        for (uint256 i = 0; i < f.length; i++) {
            usdc.transfer(f[i].guardian, f[i].amount);
        }

        emit ShieldExpired(shieldId);
    }

    // ========== CANCEL ==========

    function cancel(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED || s.status == ShieldStatus.PENDING, "Cannot cancel");
        require(s.filled == 0, "Already has fills");

        ShieldStatus prev = s.status;
        s.status = ShieldStatus.EXPIRED;

        if (prev == ShieldStatus.PENDING) {
            usdc.transfer(s.subscriber, s.premium);
        }
    }

    // ========== VIEWS ==========

    function getShield(uint256 shieldId) external view returns (Shield memory) {
        return shields[shieldId];
    }

    function getShieldCount() external view returns (uint256) {
        return shields.length;
    }

    function getFills(uint256 shieldId) external view returns (Fill[] memory) {
        return fills[shieldId];
    }

    function getFillCount(uint256 shieldId) external view returns (uint256) {
        return fills[shieldId].length;
    }
}
