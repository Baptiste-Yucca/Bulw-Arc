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
        uint256 amount; // EURC collateral (normal) or USDC collateral (reverse)
    }

    struct Shield {
        address subscriber;
        uint256 strike;          // EUR/USD price in 1e8
        uint256 notional;        // salary in USDC (normal) or EURC (reverse)
        uint256 premium;         // protection cost in same token as notional
        uint256 subscriberFee;   // fee on (notional + premium)
        uint256 filled;          // total collateral filled
        uint256 expiry;
        uint8 deliveryRate;
        address validator;
        bool isReverse;
        ShieldStatus status;
    }

    struct CreateParams {
        uint256 strike;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
        address validator;
        bool isReverse;
    }

    struct MatchParams {
        uint256 shieldId;
        address guardian;
        uint256 amount;
    }

    IERC20 public immutable usdc;
    IERC20 public immutable eurc;
    IOracle public immutable oracle;

    uint256 public feeBps;
    address public owner;

    uint256 public treasuryUSDC;
    uint256 public treasuryEURC;

    Shield[] public shields;
    mapping(uint256 => Fill[]) public fills;

    event ShieldCreated(uint256 indexed shieldId, address indexed subscriber, uint256 strike, uint256 notional, uint256 premium, uint256 expiry, bool isReverse);
    event ShieldFunded(uint256 indexed shieldId, address indexed funder);
    event ShieldFilled(uint256 indexed shieldId, address indexed guardian, uint256 amount);
    event ShieldLocked(uint256 indexed shieldId);
    event ShieldSettled(uint256 indexed shieldId, bool inTheMoney, uint256 payoff);

    constructor(address _usdc, address _eurc, address _oracle, uint256 _feeBps) {
        usdc = IERC20(_usdc);
        eurc = IERC20(_eurc);
        oracle = IOracle(_oracle);
        feeBps = _feeBps;
        owner = msg.sender;
    }

    // ========== TOKEN HELPERS ==========

    /// @dev Salary/premium token: USDC (normal), EURC (reverse)
    function _salaryToken(bool isReverse) internal view returns (IERC20) {
        return isReverse ? eurc : usdc;
    }

    /// @dev Collateral token: EURC (normal), USDC (reverse)
    function _collateralToken(bool isReverse) internal view returns (IERC20) {
        return isReverse ? usdc : eurc;
    }

    function _addTreasurySalary(bool isReverse, uint256 amount) internal {
        if (isReverse) { treasuryEURC += amount; } else { treasuryUSDC += amount; }
    }

    function _subTreasurySalary(bool isReverse, uint256 amount) internal {
        if (isReverse) { treasuryEURC -= amount; } else { treasuryUSDC -= amount; }
    }

    function _addTreasuryCollateral(bool isReverse, uint256 amount) internal {
        if (isReverse) { treasuryUSDC += amount; } else { treasuryEURC += amount; }
    }

    // ========== CREATE ==========
    // EU REMOTE WORKER 

    function createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry, address validator, bool isReverse) external {
        _createShield(strike, notional, premium, expiry, validator, isReverse);
    }

    function createShieldBatch(CreateParams[] calldata params) external {
        for (uint256 i = 0; i < params.length; i++) {
            _createShield(params[i].strike, params[i].notional, params[i].premium, params[i].expiry, params[i].validator, params[i].isReverse);
        }
    }

    function _createShield(uint256 strike, uint256 notional, uint256 premium, uint256 expiry, address validator, bool isReverse) internal {
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
            isReverse: isReverse,
            status: ShieldStatus.CREATED
        }));

        emit ShieldCreated(shieldId, msg.sender, strike, notional, premium, expiry, isReverse);
    }

    // ========== FUND ==========
    // US COMPANY

    /// @notice Fund a CREATED shield. Deposits notional + premium + fee.
    function fundShield(uint256 shieldId) external {
        _fundShield(shieldId);
    }

    // if several EU remote worker
    function fundShieldBatch(uint256[] calldata shieldIds) external {
        for (uint256 i = 0; i < shieldIds.length; i++) {
            _fundShield(shieldIds[i]);
        }
    }

    // MVP for this subscription is pai by US comapny
    // as healthcare

    function _fundShield(uint256 shieldId) internal {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED, "Not created");
        require(block.timestamp < s.expiry, "Expired");

        // salary + subscription
        uint256 total = s.notional + s.premium;
        uint256 fee = total  * feeBps / 10000; // add protocol fee
        _salaryToken(s.isReverse).transferFrom(msg.sender, address(this), total + fee);
        _addTreasurySalary(s.isReverse, fee);
        s.subscriberFee = fee;
        s.status = ShieldStatus.PENDING;

        emit ShieldFunded(shieldId, msg.sender);
    }

    // ========== MATCH ==========
    // FX Collateral trader

    function matchShield(uint256 shieldId, address guardian, uint256 amount) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING, "Not pending");
        require(block.timestamp < s.expiry, "Expired");
        require(guardian != address(0), "Invalid guardian");
        require(amount > 0, "Invalid amount");

        uint256 remaining = s.notional - s.filled;
        require(amount <= remaining, "Exceeds remaining");

        // Guardian deposits collateral + fee
        uint256 fee = amount * feeBps / 10000;
        _collateralToken(s.isReverse).transferFrom(msg.sender, address(this), amount + fee);
        _addTreasuryCollateral(s.isReverse, fee);

        fills[shieldId].push(Fill({guardian: guardian, amount: amount}));
        s.filled += amount;

        // Distribute premium pro-rata to guardian (in salary token)
        uint256 premiumShare = s.premium * amount / s.notional;
        if (premiumShare > 0) {
            _salaryToken(s.isReverse).transfer(guardian, premiumShare);
        }

        emit ShieldFilled(shieldId, guardian, amount);

        if (s.filled == s.notional) {
            s.status = ShieldStatus.LOCKED;
            emit ShieldLocked(shieldId);
        }
    }

    // ========== VALIDATE ==========
    // logtracker or HR dept 

    function validateDelivery(uint256 shieldId, uint8 rate) external {
        Shield storage s = shields[shieldId];
        require(s.validator != address(0), "No validator set");
        require(msg.sender == s.validator, "Not validator");
        require(rate <= 100, "Rate must be 0-100");
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot validate");

        s.deliveryRate = rate;
    }

    // ========== SETTLE ==========

    /// @notice Settle after expiry. Oracle decides: swap or refund.
    function settle(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.PENDING || s.status == ShieldStatus.LOCKED, "Cannot settle");
        require(s.filled > 0, "No fills");
        require(block.timestamp > s.expiry, "Not expired yet");

        if (s.validator != address(0)) {
            require(s.deliveryRate > 0, "Not validated");
        }

        (int256 spot, uint256 updatedAt) = oracle.getPrice();
        require(block.timestamp <= updatedAt + 5 minutes, "Stale oracle price");
        require(spot > 0, "Invalid oracle price");

        bool inTheMoney = s.isReverse
            ? uint256(spot) > s.strike
            : uint256(spot) < s.strike;

        uint256 rate = s.validator == address(0) ? 100 : uint256(s.deliveryRate);

        IERC20 collateral = _collateralToken(s.isReverse);
        IERC20 salary = _salaryToken(s.isReverse);
        Fill[] storage f = fills[shieldId];

        if (inTheMoney) {
            // SWAP — worker gets collateral, guardians get salary
            s.status = ShieldStatus.EXERCISED;
            _refundSubscriberFee(s, rate);

            uint256 totalCollateralToWorker;

            for (uint256 i = 0; i < f.length; i++) {
                uint256 collateralToWorker = f[i].amount * rate / 100;
                uint256 collateralBack = f[i].amount - collateralToWorker;
                totalCollateralToWorker += collateralToWorker;

                if (collateralBack > 0) {
                    collateral.transfer(f[i].guardian, collateralBack);
                }
            }

            if (totalCollateralToWorker > 0) {
                collateral.transfer(s.subscriber, totalCollateralToWorker);
            }

            // Salary to guardians pro-rata
            for (uint256 i = 0; i < f.length; i++) {
                uint256 salaryShare = s.notional * f[i].amount / s.filled;
                if (i == f.length - 1) {
                    uint256 sent;
                    for (uint256 j = 0; j < i; j++) {
                        sent += s.notional * f[j].amount / s.filled;
                    }
                    salaryShare = s.notional - sent;
                }
                if (salaryShare > 0) {
                    salary.transfer(f[i].guardian, salaryShare);
                }
            }

            emit ShieldSettled(shieldId, true, totalCollateralToWorker);
        } else {
            // REFUND — worker gets salary back, guardians get collateral back
            s.status = ShieldStatus.EXPIRED;
            _refundSubscriberFee(s, 100);

            for (uint256 i = 0; i < f.length; i++) {
                collateral.transfer(f[i].guardian, f[i].amount);
            }

            salary.transfer(s.subscriber, s.notional);

            emit ShieldSettled(shieldId, false, 0);
        }
    }

    // ========== CANCEL ==========
    // NO guardians REFUNDS
    function cancel(uint256 shieldId) external {
        Shield storage s = shields[shieldId];
        require(s.status == ShieldStatus.CREATED || s.status == ShieldStatus.PENDING, "Cannot cancel");
        require(s.filled == 0, "Already has fills");

        ShieldStatus prev = s.status;
        s.status = ShieldStatus.EXPIRED;

        if (prev == ShieldStatus.PENDING) {
            uint256 refund = s.notional + s.premium + s.subscriberFee;
            _subTreasurySalary(s.isReverse, s.subscriberFee);
            s.subscriberFee = 0;
            _salaryToken(s.isReverse).transfer(s.subscriber, refund);
        }
    }

    // ========== ADMIN ==========

    function setFeeBps(uint256 _feeBps) external {
        require(msg.sender == owner, "Not owner");
        require(_feeBps <= 1000, "Fee too high");
        feeBps = _feeBps;
    }

    function withdrawTreasury(address to) external {
        require(msg.sender == owner, "Not owner");
        if (treasuryUSDC > 0) {
            uint256 a = treasuryUSDC;
            treasuryUSDC = 0;
            usdc.transfer(to, a);
        }
        if (treasuryEURC > 0) {
            uint256 a = treasuryEURC;
            treasuryEURC = 0;
            eurc.transfer(to, a);
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

    function _refundSubscriberFee(Shield storage s, uint256 rate) internal {
        if (s.subscriberFee == 0) return;

        uint256 usedFee = s.subscriberFee * s.filled * rate / (s.notional * 100);
        uint256 refund = s.subscriberFee - usedFee;
        if (refund > 0) {
            _subTreasurySalary(s.isReverse, refund);
            _salaryToken(s.isReverse).transfer(s.subscriber, refund);
        }
    }
}
