// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {BulwArc} from "../src/BulwArc.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BulwArcTest is Test {
    BulwArc public bulwarc;
    MockOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public eurc;

    address worker = makeAddr("worker");
    address guardianA = makeAddr("guardianA");
    address guardianB = makeAddr("guardianB");
    address guardianC = makeAddr("guardianC");
    address employer = makeAddr("employer");
    address validatorAddr = makeAddr("validator");

    uint256 constant STRIKE = 92_000_000;
    uint256 constant NOTIONAL = 1000e6;
    uint256 constant PREMIUM = 100e6;
    uint256 constant FEE_BPS = 100; // 1%

    uint256 constant SUB_FEE = PREMIUM * FEE_BPS / 10000;           // 1 USDC
    uint256 constant GUARDIAN_FEE_FULL = NOTIONAL * FEE_BPS / 10000; // 10 EURC

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockERC20("USD Coin", "USDC");
        eurc = new MockERC20("Euro Coin", "EURC");
        bulwarc = new BulwArc(address(usdc), address(eurc), address(oracle), FEE_BPS);

        usdc.mint(worker, 1000e6);
        usdc.mint(employer, 1000e6);
        eurc.mint(guardianA, 10_000e6);
        eurc.mint(guardianB, 10_000e6);
        eurc.mint(guardianC, 10_000e6);
    }

    // ========== CREATE ==========

    function test_createShield() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0));

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.CREATED));
        assertEq(s.validator, address(0));
    }

    function test_createShield_with_validator() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry, validatorAddr);

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(s.validator, validatorAddr);
        assertEq(s.deliveryRate, 0);
    }

    function test_createAndFundShield_takes_fee() public {
        _createAndFund();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(s.subscriberFee, SUB_FEE);
        assertEq(usdc.balanceOf(worker), 1000e6 - PREMIUM - SUB_FEE);
        assertEq(bulwarc.treasuryUSDC(), SUB_FEE);
    }

    // ========== VALIDATE ==========

    function test_validateDelivery() public {
        _createAndFundWithValidator();
        _matchFull();

        vm.prank(validatorAddr);
        bulwarc.validateDelivery(0, 80);

        assertEq(bulwarc.getShield(0).deliveryRate, 80);
    }

    function test_revert_validate_notValidator() public {
        _createAndFundWithValidator();
        _matchFull();

        vm.prank(worker);
        vm.expectRevert("Not validator");
        bulwarc.validateDelivery(0, 80);
    }

    function test_revert_validate_noValidatorSet() public {
        _createAndFund();
        _matchFull();

        vm.prank(validatorAddr);
        vm.expectRevert("No validator set");
        bulwarc.validateDelivery(0, 80);
    }

    // ========== EXERCISE — no validator (100% by default) ==========

    function test_exercise_no_validator_full_payoff() public {
        _createAndFund();
        _matchFull();

        oracle.setPrice(88_000_000);
        uint256 workerBefore = eurc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / STRIKE;
        assertEq(eurc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    // ========== EXERCISE — with validator ==========

    function test_exercise_100pct_delivery() public {
        _createAndFundWithValidator();
        _matchFull();

        vm.prank(validatorAddr);
        bulwarc.validateDelivery(0, 100);

        oracle.setPrice(88_000_000);
        uint256 workerBefore = eurc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / STRIKE;
        assertEq(eurc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    function test_exercise_50pct_delivery() public {
        _createAndFundWithValidator();
        _matchFull();

        vm.prank(validatorAddr);
        bulwarc.validateDelivery(0, 50);

        oracle.setPrice(88_000_000);

        uint256 workerEurcBefore = eurc.balanceOf(worker);
        uint256 guardianEurcBefore = eurc.balanceOf(guardianA);
        uint256 workerUsdcBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        // payoff = (0.92-0.88) * 1000 * 50% / 0.92
        uint256 strikeDiff = STRIKE - 88_000_000;
        uint256 expectedPayoff = strikeDiff * NOTIONAL * 50 / (STRIKE * 100);
        assertEq(eurc.balanceOf(worker), workerEurcBefore + expectedPayoff);
        // Guardian gets back more collateral
        assertEq(eurc.balanceOf(guardianA), guardianEurcBefore + NOTIONAL - expectedPayoff);

        // Subscriber fee refund: usedFee = 1e6 * 1000/1000 * 50/100 = 0.5 USDC
        // refund = 1e6 - 0.5e6 = 0.5 USDC
        uint256 usedFee = SUB_FEE * NOTIONAL * 50 / (NOTIONAL * 100);
        uint256 expectedRefund = SUB_FEE - usedFee;
        assertEq(usdc.balanceOf(worker), workerUsdcBefore + expectedRefund);
    }

    function test_exercise_50pct_delivery_partial_fill() public {
        _createAndFundWithValidator();

        // Only 500/1000 filled
        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), 500e6 + 5e6);
        bulwarc.matchShield(0, guardianA, 500e6);
        vm.stopPrank();

        vm.prank(validatorAddr);
        bulwarc.validateDelivery(0, 50);

        oracle.setPrice(88_000_000);

        uint256 workerEurcBefore = eurc.balanceOf(worker);
        uint256 workerUsdcBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        // Payoff on 500 EURC at 50% delivery
        uint256 strikeDiff = STRIKE - 88_000_000;
        uint256 expectedPayoff = strikeDiff * 500e6 * 50 / (STRIKE * 100);
        assertEq(eurc.balanceOf(worker), workerEurcBefore + expectedPayoff);

        // Fee refund: usedFee = 1e6 * 500/1000 * 50/100 = 0.25 USDC
        uint256 usedFee = SUB_FEE * 500e6 * 50 / (NOTIONAL * 100);
        uint256 expectedRefund = SUB_FEE - usedFee;
        assertEq(usdc.balanceOf(worker), workerUsdcBefore + expectedRefund);
    }

    function test_revert_exercise_not_validated() public {
        _createAndFundWithValidator();
        _matchFull();

        oracle.setPrice(88_000_000);

        vm.prank(worker);
        vm.expectRevert("Not validated");
        bulwarc.exercise(0);
    }

    // ========== MATCH — fees ==========

    function test_matchShield_takes_eurc_fee() public {
        _createAndFund();

        uint256 eurcBefore = eurc.balanceOf(guardianA);

        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), NOTIONAL + GUARDIAN_FEE_FULL);
        bulwarc.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        assertEq(eurc.balanceOf(guardianA), eurcBefore - NOTIONAL - GUARDIAN_FEE_FULL);
        assertEq(bulwarc.treasuryEURC(), GUARDIAN_FEE_FULL);
        assertEq(usdc.balanceOf(guardianA), PREMIUM);
    }

    function test_matchShield_multi_guardians() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), 200e6 + 2e6);
        bulwarc.matchShield(0, guardianA, 200e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        eurc.approve(address(bulwarc), 500e6 + 5e6);
        bulwarc.matchShield(0, guardianB, 500e6);
        vm.stopPrank();

        vm.startPrank(guardianC);
        eurc.approve(address(bulwarc), 300e6 + 3e6);
        bulwarc.matchShield(0, guardianC, 300e6);
        vm.stopPrank();

        assertEq(bulwarc.getShield(0).filled, NOTIONAL);
        assertEq(uint8(bulwarc.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
        assertEq(bulwarc.treasuryEURC(), 10e6);
    }

    // ========== EXPIRE ==========

    function test_expire_fully_locked() public {
        _createAndFund();
        _matchFull();

        vm.warp(bulwarc.getShield(0).expiry + 1);

        uint256 aBefore = eurc.balanceOf(guardianA);
        uint256 treasuryBefore = bulwarc.treasuryUSDC();

        bulwarc.expire(0);

        assertEq(eurc.balanceOf(guardianA), aBefore + NOTIONAL);
        // Fully filled, rate=100 for expire → no fee refund
        assertEq(bulwarc.treasuryUSDC(), treasuryBefore);
    }

    function test_expire_partial_refunds_fee() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), 300e6 + 3e6);
        bulwarc.matchShield(0, guardianA, 300e6);
        vm.stopPrank();

        vm.warp(bulwarc.getShield(0).expiry + 1);

        uint256 workerBefore = usdc.balanceOf(worker);

        bulwarc.expire(0);

        // 30% filled, rate=100 → usedFee = 1e6 * 300/1000 * 100/100 = 0.3 USDC
        uint256 usedFee = SUB_FEE * 300e6 / NOTIONAL;
        uint256 expectedRefund = SUB_FEE - usedFee;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedRefund);
    }

    // ========== CANCEL ==========

    function test_cancel_pending_refunds_all() public {
        _createAndFund();

        uint256 workerBefore = usdc.balanceOf(worker);
        bulwarc.cancel(0);

        assertEq(usdc.balanceOf(worker), workerBefore + PREMIUM + SUB_FEE);
        assertEq(bulwarc.treasuryUSDC(), 0);
    }

    function test_revert_cancel_with_fills() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), 200e6 + 2e6);
        bulwarc.matchShield(0, guardianA, 200e6);
        vm.stopPrank();

        vm.expectRevert("Already has fills");
        bulwarc.cancel(0);
    }

    // ========== ADMIN ==========

    function test_withdrawTreasury() public {
        _createAndFund();
        _matchFull();

        address treasury = makeAddr("treasury");
        bulwarc.withdrawTreasury(treasury);

        assertEq(usdc.balanceOf(treasury), SUB_FEE);
        assertEq(eurc.balanceOf(treasury), GUARDIAN_FEE_FULL);
    }

    // ========== REVERTS ==========

    function test_revert_exercise_notSubscriber() public {
        _createAndFund();
        _matchFull();
        oracle.setPrice(88_000_000);

        vm.prank(guardianA);
        vm.expectRevert("Not subscriber");
        bulwarc.exercise(0);
    }

    function test_revert_exercise_pastExpiry() public {
        _createAndFund();
        _matchFull();
        oracle.setPrice(88_000_000);

        vm.warp(bulwarc.getShield(0).expiry + 1);
        vm.prank(worker);
        vm.expectRevert("Past expiry");
        bulwarc.exercise(0);
    }

    function test_revert_exercise_outOfMoney() public {
        _createAndFund();
        _matchFull();
        oracle.setPrice(95_000_000);

        vm.prank(worker);
        vm.expectRevert("Not in the money");
        bulwarc.exercise(0);
    }

    function test_revert_doubleExercise() public {
        _createAndFund();
        _matchFull();
        oracle.setPrice(88_000_000);

        vm.startPrank(worker);
        bulwarc.exercise(0);
        vm.expectRevert("Cannot exercise");
        bulwarc.exercise(0);
        vm.stopPrank();
    }

    // ========== HELPERS ==========

    function _createAndFund() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(bulwarc), PREMIUM + SUB_FEE);
        bulwarc.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0));
        vm.stopPrank();
    }

    function _createAndFundWithValidator() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(bulwarc), PREMIUM + SUB_FEE);
        bulwarc.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, validatorAddr);
        vm.stopPrank();
    }

    function _matchFull() internal {
        vm.startPrank(guardianA);
        eurc.approve(address(bulwarc), NOTIONAL + GUARDIAN_FEE_FULL);
        bulwarc.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();
    }
}
