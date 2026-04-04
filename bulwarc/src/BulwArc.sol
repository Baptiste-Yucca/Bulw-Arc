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
        uint256 amount; // effective collateral in EURC (after fee)
    }

    struct Shield {
        address subscriber;
        uint256 strike;          // EUR/USD price in 1e8
        uint256 notional;        // amount to cover in EURC (1e6)
        uint256 premium;         // premium in USDC (1e6)
        uint256 subscriberFee;   // fee taken from subscriber in USDC (1e6)
        uint256 filled;          // total EURC filled so far (after guardian fees)
        uint256 expiry;
        uint8 deliveryRate;      // 0-100, validated % of work delivered
        address validator;       // address authorized to set deliveryRate
        ShieldStatus status;
    }

    struct CreateParams {
        uint256 strike;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
        address validator;
    }

    struct MatchParams {
        uint256 shieldId;
        address guardian;
        uint256 amount;
    }

    IERC20 public immutable usdc;
    IERC20 public immutable eurc;
    IOracle public immutable oracle;

    uint256 public feeBps; // fee in basis points (100 = 1%)
    address public owner;

    // Protocol treasury
    uint256 public treasuryUSDC;
    uint256 public treasuryEURC;

    Shield[] public shields;
    mapping(uint256 => Fill[]) public fills;

    event ShieldCreated(uint256 indexed shieldId, address indexed subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry);
    event ShieldFunded(uint256 indexed shieldId, address indexed funder);
    event ShieldFilled(uint256 indexed shieldId, address indexed guardian, uint256 amount);
    event ShieldLocked(uint256 indexed shieldId);
    event ShieldExercised(uint256 indexed shieldId, uint256 payoff);
    event ShieldExpired(uint256 indexed shieldId);

    constructor(address _usdc, address _eurc, address _oracle, uint256 _feeBps) {
        usdc = IERC20(_usdc);
        eurc = IERC20(_eurc);
        oracle = IOracle(_oracle);
        feeBps = _feeBps;
        owner = msg.sender;
    }

    // ========== CREATE ==========

    /// @param validator Address that can validate delivery (address(0) = no validation required)
    function createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry, address validator) external {
        _createShield(strike, notional, premium, expiry, validator);
    }

    function createShieldBatch(CreateParams[] calldata params) external {
        for (uint256 i = 0; i < params.length; i++) {
            _createShield(params[i].strike, params[i].notional, params[i].premium, params[i].expiry, params[i].validator);
        }
    }

    function _createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry, address validator) internal {
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
            subscriberFee: 0,
            filled: 0,
            expiry: expiry,
            deliveryRate: 0,
            validator: validator,
            status: ShieldStatus.CREATED
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
    }

    function createAndFundShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry, address validator) external {
        require(strike > 0, "Invalid strike");
        require(notional > 0, "Invalid notional");
        require(premium > 0, "Invalid premium");
        require(expiry > block.timestamp, "Expiry in the past");

        uint256 fee = premium * feeBps / 10000;
        usdc.transferFrom(msg.sender, address(this), premium + fee);
        treasuryUSDC += fee;

        uint256 shieldId = shields.length;
        shields.push(Shield({
            subscriber: msg.sender,
            strike: strike,
            notional: notional,
            premium: premium,
            subscriberFee: fee,
            filled: 0,
            expiry: expiry,
            deliveryRate: 0,
            validator: validator,
            status: ShieldStatus.PENDING
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry);
        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== FUND ==========

    function fundShield(uint256 shieldId) external {
        _fundShield(shieldId);
    }

    function fundShieldBatch(uint256[] calldata shieldIds) external {
        for (uint256 i = 0; i < shieldIds.length; i++) {
            _fundShield(shieldIds[i]);
        }
    }

    function _fundShield(uint256 shieldId) internal {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED, "Not created");
        require(block.timestamp < s.expiry, "Expired");

        // Subscriber fee on premium
        uint256 fee = s.premium * feeBps / 10000;
        usdc.transferFrom(msg.sender, address(this), s.premium + fee);
        treasuryUSDC += fee;
        s.subscriberFee = fee;
        s.status = ShieldStatus.PENDING;

        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== MATCH (partial fill) — guardian deposits EURC ==========

    function matchShield(uint256 shieldId, address guardian, uint256 amount) external {
        _matchShield(shieldId, guardian, amount);
    }

    function matchShieldBatch(MatchParams[] calldata params) external {
        for (uint256 i = 0; i < params.length; i++) {
            _matchShield(params[i].shieldId, params[i].guardian, params[i].amount);
        }
    }

    function _matchShield(uint256 shieldId, address guardian, uint256 amount) internal {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING, "Not pending");
        require(block.timestamp < s.expiry, "Expired");
        require(guardian != address(0), "Invalid guardian");
        require(amount > 0, "Invalid amount");

        uint256 remaining = s.notional - s.filled;
        require(amount <= remaining, "Exceeds remaining");

        // Guardian fee on collateral
        uint256 fee = amount * feeBps / 10000;
        eurc.transferFrom(msg.sender, address(this), amount + fee);
        treasuryEURC += fee;

        fills[shieldId].push(Fill({guardian: guardian, amount: amount}));
        s.filled += amount;

        // Distribute premium (USDC) pro-rata to guardian
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

    // ========== VALIDATE ==========

    /// @notice Validator confirms delivery rate (0-100%)
    function validateDelivery(uint256 shieldId, uint8 rate) external {
        Shield storage s = shields[shieldId];
        require(s.validator != address(0), "No validator set");
        require(msg.sender == s.validator, "Not validator");
        require(rate <= 100, "Rate must be 0-100");
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot validate");

        s.deliveryRate = rate;
    }

    // ========== EXERCISE ==========

    function exercise(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot exercise");
        require(s.filled > 0, "No fills");
        require(msg.sender == s.subscriber, "Not subscriber");
        require(block.timestamp <= s.expiry, "Past expiry");

        // If a validator is set, deliveryRate must be > 0
        if (s.validator != address(0)) {
            require(s.deliveryRate > 0, "Not validated");
        }

        (int256 spot, uint256 updatedAt) = oracle.getPrice();
        require(block.timestamp <= updatedAt + 5 minutes, "Stale oracle price");
        require(spot > 0, "Invalid oracle price");
        require(uint256(spot) < s.strike, "Not in the money");

        uint256 strikeDiff = s.strike - uint256(spot);

        // Effective delivery rate: 100 if no validator, otherwise deliveryRate
        uint256 rate = s.validator == address(0) ? 100 : uint256(s.deliveryRate);

        s.status = ShieldStatus.EXERCISED;

        // Refund subscriber fee pro-rata (accounts for fill ratio + delivery rate)
        _refundSubscriberFee(s, rate);

        uint256 totalPayoff;
        Fill[] storage f = fills[shieldId];
        for (uint256 i = 0; i < f.length; i++) {
            // Payoff scaled by deliveryRate
            uint256 guardianPayoff = strikeDiff * f[i].amount * rate / (s.strike * 100);
            if (guardianPayoff > f[i].amount) guardianPayoff = f[i].amount;

            totalPayoff += guardianPayoff;

            uint256 guardianRemaining = f[i].amount - guardianPayoff;
            if (guardianRemaining > 0) {
                eurc.transfer(f[i].guardian, guardianRemaining);
            }
        }

        if (totalPayoff > 0) {
            eurc.transfer(s.subscriber, totalPayoff);
        }

        emit ShieldExercised(shieldId, totalPayoff);
    }

    // ========== EXPIRE ==========

    function expire(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot expire");
        require(block.timestamp > s.expiry, "Not expired yet");

        s.status = ShieldStatus.EXPIRED;

        // On expire, delivery doesn't matter — refund fee based on fill ratio only
        _refundSubscriberFee(s, 100);

        Fill[] storage f = fills[shieldId];
        for (uint256 i = 0; i < f.length; i++) {
            eurc.transfer(f[i].guardian, f[i].amount);
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
            // Return premium + full fee (nothing was filled)
            uint256 refund = s.premium + s.subscriberFee;
            treasuryUSDC -= s.subscriberFee;
            s.subscriberFee = 0;
            usdc.transfer(s.subscriber, refund);
        }
    }

    // ========== ADMIN ==========

    function setFeeBps(uint256 _feeBps) external {
        require(msg.sender == owner, "Not owner");
        require(_feeBps <= 1000, "Fee too high"); // max 10%
        feeBps = _feeBps;
    }

    function withdrawTreasury(address to) external {
        require(msg.sender == owner, "Not owner");
        if (treasuryUSDC > 0) {
            uint256 amount = treasuryUSDC;
            treasuryUSDC = 0;
            usdc.transfer(to, amount);
        }
        if (treasuryEURC > 0) {
            uint256 amount = treasuryEURC;
            treasuryEURC = 0;
            eurc.transfer(to, amount);
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

    // ========== INTERNAL ==========

    /// @dev Refund subscriber fee pro-rata based on fill ratio and delivery rate
    /// usedFee = subscriberFee * (filled / notional) * (rate / 100)
    function _refundSubscriberFee(Shield storage s, uint256 rate) internal {
        if (s.subscriberFee == 0) return;

        uint256 usedFee = s.subscriberFee * s.filled * rate / (s.notional * 100);
        uint256 refund = s.subscriberFee - usedFee;
        if (refund > 0) {
            treasuryUSDC -= refund;
            usdc.transfer(s.subscriber, refund);
        }
    }
}
