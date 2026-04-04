// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IOracle {
    function getPrice() external view returns (int256 price, uint256 updatedAt);
}

contract BulwArc {
    enum ShieldStatus { CREATED, PENDING, MATCHED, EXERCISED, EXPIRED }

    struct Shield {
        address subscriber;        // worker who buys protection
        uint256 strike;       // EUR/USD price in 1e8 (e.g. 92_000_000 = 0.92)
        uint256 notional;     // amount covered in USDC (1e6)
        uint256 premium;      // premium paid in USDC (1e6)
        uint256 expiry;       // unix timestamp
        ShieldStatus status;
        address guardian; // address(0) until matched
    }

    IERC20 public immutable usdc;
    IOracle public immutable oracle;

    Shield[] public shields;

    event ShieldCreated(uint256 indexed shieldId, address indexed subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry);
    event ShieldFunded(uint256 indexed shieldId, address indexed funder);
    event ShieldMatched(uint256 indexed shieldId, address indexed guardian);
    event ShieldExercised(uint256 indexed shieldId, uint256 payoff);
    event ShieldExpired(uint256 indexed shieldId);

    constructor(address _usdc, address _oracle) {
        usdc = IERC20(_usdc);
        oracle = IOracle(_oracle);
    }

    // ========== CREATE ==========

    /// @notice Create a shield (status = CREATED, no funds yet)
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
            expiry: expiry,
            status: ShieldStatus.CREATED,
            guardian: address(0)
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
    }

    /// @notice Create a shield AND fund the premium in one tx
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
            expiry: expiry,
            status: ShieldStatus.PENDING,
            guardian: address(0)
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== FUND ==========

    /// @notice Fund the premium of a CREATED shield (subscriber or anyone on behalf)
    function fundShield(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED, "Not created");
        require(block.timestamp < s.expiry, "Expired");

        usdc.transferFrom(msg.sender, address(this), s.premium);
        s.status = ShieldStatus.PENDING;

        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== MATCH ==========

    /// @notice Match a shield yourself as guardian
    function matchShield(uint256 shieldId) external {
        _matchShield(shieldId, msg.sender);
    }

    /// @notice Match a shield on behalf of another address as guardian
    function matchShieldFor(uint256 shieldId, address guardian) external {
        require(guardian != address(0), "Invalid guardian");
        _matchShield(shieldId, guardian);
    }

    function _matchShield(uint256 shieldId, address guardian) internal {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING, "Not pending");
        require(block.timestamp < s.expiry, "Expired");

        usdc.transferFrom(msg.sender, address(this), s.notional);

        s.status = ShieldStatus.MATCHED;
        s.guardian = guardian;

        // Transfer premium to guardian immediately
        usdc.transfer(guardian, s.premium);

        emit ShieldMatched(shieldId, guardian);
    }

    // ========== EXERCISE ==========

    /// @notice Worker exercises the shield if EUR/USD spot < strike
    function exercise(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.MATCHED, "Not matched");
        require(msg.sender == s.subscriber, "Not subscriber");
        require(block.timestamp <= s.expiry, "Past expiry");

        (int256 spot, uint256 updatedAt) = oracle.getPrice();
        require(block.timestamp <= updatedAt + 5 minutes, "Stale oracle price");
        require(spot > 0, "Invalid oracle price");
        require(uint256(spot) < s.strike, "Not in the money");

        // payoff = (strike - spot) * notional / 1e8
        uint256 payoff = (s.strike - uint256(spot)) * s.notional / 1e8;
        if (payoff > s.notional) payoff = s.notional; // cap at collateral

        s.status = ShieldStatus.EXERCISED;

        // Pay worker
        usdc.transfer(s.subscriber, payoff);
        // Return remaining collateral to guardian
        uint256 remaining = s.notional - payoff;
        if (remaining > 0) {
            usdc.transfer(s.guardian, remaining);
        }

        emit ShieldExercised(shieldId, payoff);
    }

    // ========== EXPIRE ==========

    /// @notice Reclaim collateral after expiry if shield was not exercised
    function expire(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.MATCHED, "Not matched");
        require(block.timestamp > s.expiry, "Not expired yet");

        s.status = ShieldStatus.EXPIRED;

        // Return full collateral to guardian
        usdc.transfer(s.guardian, s.notional);

        emit ShieldExpired(shieldId);
    }

    // ========== CANCEL ==========

    /// @notice Cancel a shield that is not yet matched. Premium returned to subscriber.
    function cancel(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED || s.status == ShieldStatus.PENDING, "Cannot cancel");

        ShieldStatus prev = s.status;
        s.status = ShieldStatus.EXPIRED;

        // If funded, return premium to subscriber
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
}
