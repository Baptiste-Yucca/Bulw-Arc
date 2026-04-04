// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IOracle {
    function getPrice() external view returns (int256 price, uint256 updatedAt);
}

contract BulwArc {
    enum ShieldStatus { PENDING, MATCHED, EXERCISED, EXPIRED }

    struct Shield {
        address subscriber;        // worker who buys protection
        uint256 strike;       // EUR/USD price in 1e8 (e.g. 92_000_000 = 0.92)
        uint256 notional;     // amount covered in USDC (1e6)
        uint256 premium;      // premium paid in USDC (1e6)
        uint256 expiry;       // unix timestamp
        ShieldStatus status;
        address guardian; // address(0) if PENDING
    }

    IERC20 public immutable usdc;
    IOracle public immutable oracle;

    Shield[] public shields;

    event ShieldCreated(uint256 indexed shieldId, address indexed subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry);
    event ShieldMatched(uint256 indexed shieldId, address indexed guardian);
    event ShieldExercised(uint256 indexed shieldId, uint256 payoff);
    event ShieldExpired(uint256 indexed shieldId);

    constructor(address _usdc, address _oracle) {
        usdc = IERC20(_usdc);
        oracle = IOracle(_oracle);
    }

    /// @notice Create a shield for yourself
    function createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external {
        _createShield(msg.sender, strike, notional, premium, expiry);
    }

    /// @notice Create a shield on behalf of another address (payer funds the premium)
    function createShieldFor(address subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry) external {
        require(subscriber != address(0), "Invalid subscriber");
        _createShield(subscriber, strike, notional, premium, expiry);
    }

    /// @notice Match a shield yourself as guardian
    function matchShield(uint256 shieldId) external {
        _matchShield(shieldId, msg.sender);
    }

    /// @notice Match a shield on behalf of another address as guardian (payer funds the collateral)
    function matchShieldFor(uint256 shieldId, address guardian) external {
        require(guardian != address(0), "Invalid guardian");
        _matchShield(shieldId, guardian);
    }

    function _createShield(address subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry) internal {
        require(strike > 0, "Invalid strike");
        require(notional > 0, "Invalid notional");
        require(premium > 0, "Invalid premium");
        _validateExpiry(expiry);

        usdc.transferFrom(msg.sender, address(this), premium);

        uint256 shieldId = shields.length;
        shields.push(Shield({
            subscriber: subscriber,
            strike: strike,
            notional: notional,
            premium: premium,
            expiry: expiry,
            status: ShieldStatus.PENDING,
            guardian: address(0)
        }));

        emit ShieldCreated(shieldId, subscriber, strike, notional, premium, expiry);
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

    /// @notice Cancel a pending (unmatched) shield and reclaim premium
    function cancel(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING, "Not pending");
        require(msg.sender == s.subscriber, "Not subscriber");

        s.status = ShieldStatus.EXPIRED;
        usdc.transfer(s.subscriber, s.premium);
    }

    function getShield(uint256 shieldId) external view returns (Shield memory) {
        return shields[shieldId];
    }

    function getShieldCount() external view returns (uint256) {
        return shields.length;
    }

    function _validateExpiry(uint256 expiry) internal view {
        uint256 duration = expiry - block.timestamp;
        require(
            _approxEqual(duration, 7 days) ||
            _approxEqual(duration, 30 days) ||
            _approxEqual(duration, 90 days),
            "Expiry must be ~7, ~30 or ~90 days"
        );
    }

    function _approxEqual(uint256 a, uint256 b) internal pure returns (bool) {
        uint256 tolerance = 1 hours;
        return a > b ? (a - b <= tolerance) : (b - a <= tolerance);
    }
}
