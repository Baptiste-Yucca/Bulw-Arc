// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {BulwArc} from "../src/BulwArc.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
    BulwArc public shield;
    MockOracle public oracle;
    MockUSDC public usdc;

    address worker = makeAddr("worker");
    address guardian = makeAddr("guardian");

    uint256 constant STRIKE = 92_000_000; // 0.92 EUR/USD
    uint256 constant NOTIONAL = 1000e6;   // 1000 USDC
    uint256 constant PREMIUM = 5e6;       // 5 USDC

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockUSDC();
        shield = new BulwArc(address(usdc), address(oracle));

        usdc.mint(worker, 100e6);
        usdc.mint(guardian, 10_000e6);
    }

    function test_createShield() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.startPrank(worker);
        usdc.approve(address(shield), PREMIUM);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(s.strike, STRIKE);
        assertEq(s.notional, NOTIONAL);
        assertEq(s.premium, PREMIUM);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(s.guardian, address(0));
    }

    function test_matchShield() public {
        uint256 expiry = block.timestamp + 30 days;
        _createShield(expiry);

        uint256 cpBalanceBefore = usdc.balanceOf(guardian);

        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.MATCHED));
        assertEq(s.guardian, guardian);
        // Counterparty received premium
        assertEq(usdc.balanceOf(guardian), cpBalanceBefore - NOTIONAL + PREMIUM);
    }

    function test_exercise_inTheMoney() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);

        // EUR/USD drops to 0.88 — worker is in the money
        oracle.setPrice(88_000_000);

        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 cpBefore = usdc.balanceOf(guardian);

        vm.prank(worker);
        shield.exercise(0);

        // payoff = (0.92 - 0.88) * 1000 / 1 = 40 USDC
        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
        assertEq(usdc.balanceOf(guardian), cpBefore + NOTIONAL - expectedPayoff);

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXERCISED));
    }

    function test_expire_outOfMoney() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);

        // EUR/USD goes up — worker out of the money, no exercise
        oracle.setPrice(95_000_000);

        // Warp past expiry
        vm.warp(expiry + 1);

        uint256 cpBefore = usdc.balanceOf(guardian);

        shield.expire(0);

        // Counterparty gets full collateral back
        assertEq(usdc.balanceOf(guardian), cpBefore + NOTIONAL);

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXPIRED));
    }

    function test_cancel_pending() public {
        uint256 expiry = block.timestamp + 30 days;
        _createShield(expiry);

        uint256 workerBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        shield.cancel(0);

        assertEq(usdc.balanceOf(worker), workerBefore + PREMIUM);
    }

    function test_revert_exercise_notMaker() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);
        oracle.setPrice(88_000_000);

        vm.prank(guardian);
        vm.expectRevert("Not subscriber");
        shield.exercise(0);
    }

    function test_revert_exercise_pastExpiry() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);
        oracle.setPrice(88_000_000);

        vm.warp(expiry + 1);
        vm.prank(worker);
        vm.expectRevert("Past expiry");
        shield.exercise(0);
    }

    function test_revert_exercise_outOfMoney() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);
        oracle.setPrice(95_000_000);

        vm.prank(worker);
        vm.expectRevert("Not in the money");
        shield.exercise(0);
    }

    function test_revert_doubleExercise() public {
        uint256 expiry = block.timestamp + 30 days;
        _createAndMatch(expiry);
        oracle.setPrice(88_000_000);

        vm.startPrank(worker);
        shield.exercise(0);
        vm.expectRevert("Not matched");
        shield.exercise(0);
        vm.stopPrank();
    }

    // --- onBehalf tests ---

    address employer = makeAddr("employer");
    address backer = makeAddr("backer");

    function test_createShieldFor_onBehalf() public {
        uint256 expiry = block.timestamp + 30 days;
        usdc.mint(employer, 100e6);

        // Employer pays premium on behalf of worker
        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        shield.createShieldFor(worker, STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        // Employer paid, not worker
        assertEq(usdc.balanceOf(employer), 100e6 - PREMIUM);
        assertEq(usdc.balanceOf(worker), 100e6); // unchanged
    }

    function test_matchShieldFor_onBehalf() public {
        uint256 expiry = block.timestamp + 30 days;
        _createShield(expiry);
        usdc.mint(backer, 10_000e6);

        // Backer funds collateral on behalf of guardian
        vm.startPrank(backer);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShieldFor(0, guardian);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.guardian, guardian);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.MATCHED));
        // Backer paid collateral, guardian received premium
        assertEq(usdc.balanceOf(backer), 10_000e6 - NOTIONAL);
        assertEq(usdc.balanceOf(guardian), 10_000e6 + PREMIUM);
    }

    function test_exercise_after_createShieldFor() public {
        uint256 expiry = block.timestamp + 30 days;
        usdc.mint(employer, 100e6);

        // Employer creates shield for worker
        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        shield.createShieldFor(worker, STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();

        // Guardian matches
        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();

        // Price drops, worker exercises (not employer)
        oracle.setPrice(88_000_000);
        uint256 workerBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        shield.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    function test_revert_exercise_by_employer() public {
        uint256 expiry = block.timestamp + 30 days;
        usdc.mint(employer, 100e6);

        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        shield.createShieldFor(worker, STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();

        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();

        oracle.setPrice(88_000_000);

        // Employer cannot exercise — only subscriber can
        vm.prank(employer);
        vm.expectRevert("Not subscriber");
        shield.exercise(0);
    }

    // --- helpers ---

    function _createShield(uint256 expiry) internal {
        vm.startPrank(worker);
        usdc.approve(address(shield), PREMIUM);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();
    }

    function _createAndMatch(uint256 expiry) internal {
        _createShield(expiry);
        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();
    }
}
