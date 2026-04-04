// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
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
    address employer = makeAddr("employer");

    uint256 constant STRIKE = 92_000_000; // 0.92 EUR/USD
    uint256 constant NOTIONAL = 1000e6;   // 1000 USDC
    uint256 constant PREMIUM = 5e6;       // 5 USDC

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockUSDC();
        shield = new BulwArc(address(usdc), address(oracle));

        usdc.mint(worker, 100e6);
        usdc.mint(guardian, 10_000e6);
        usdc.mint(employer, 100e6);
    }

    // ========== CREATE ==========

    function test_createShield() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.CREATED));
        // No funds moved
        assertEq(usdc.balanceOf(worker), 100e6);
    }

    function test_createAndFundShield() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.startPrank(worker);
        usdc.approve(address(shield), PREMIUM);
        shield.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(usdc.balanceOf(worker), 100e6 - PREMIUM);
    }

    // ========== FUND ==========

    function test_fundShield_by_subscriber() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        vm.startPrank(worker);
        usdc.approve(address(shield), PREMIUM);
        shield.fundShield(0);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(usdc.balanceOf(worker), 100e6 - PREMIUM);
    }

    function test_fundShield_by_employer() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        // Employer funds on behalf
        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        shield.fundShield(0);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(s.subscriber, worker); // subscriber unchanged
        assertEq(usdc.balanceOf(employer), 100e6 - PREMIUM);
        assertEq(usdc.balanceOf(worker), 100e6); // worker didn't pay
    }

    // ========== MATCH ==========

    function test_matchShield() public {
        _createAndFund();

        uint256 guardianBefore = usdc.balanceOf(guardian);

        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.MATCHED));
        assertEq(s.guardian, guardian);
        assertEq(usdc.balanceOf(guardian), guardianBefore - NOTIONAL + PREMIUM);
    }

    function test_matchShieldFor() public {
        _createAndFund();

        address backer = makeAddr("backer");
        usdc.mint(backer, 10_000e6);

        vm.startPrank(backer);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShieldFor(0, guardian);
        vm.stopPrank();

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(s.guardian, guardian);
        // Backer paid, guardian got premium
        assertEq(usdc.balanceOf(backer), 10_000e6 - NOTIONAL);
        assertEq(usdc.balanceOf(guardian), 10_000e6 + PREMIUM);
    }

    // ========== EXERCISE ==========

    function test_exercise_inTheMoney() public {
        _createFundAndMatch();

        oracle.setPrice(88_000_000);

        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 guardianBefore = usdc.balanceOf(guardian);

        vm.prank(worker);
        shield.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
        assertEq(usdc.balanceOf(guardian), guardianBefore + NOTIONAL - expectedPayoff);

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXERCISED));
    }

    function test_exercise_after_employer_funds() public {
        uint256 expiry = block.timestamp + 30 days;

        // Worker creates
        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        // Employer funds
        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        shield.fundShield(0);
        vm.stopPrank();

        // Guardian matches
        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();

        // Price drops, worker exercises
        oracle.setPrice(88_000_000);
        uint256 workerBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        shield.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    // ========== EXPIRE ==========

    function test_expire_outOfMoney() public {
        _createFundAndMatch();

        oracle.setPrice(95_000_000);
        vm.warp(shields_expiry() + 1);

        uint256 guardianBefore = usdc.balanceOf(guardian);
        shield.expire(0);

        assertEq(usdc.balanceOf(guardian), guardianBefore + NOTIONAL);
        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXPIRED));
    }

    // ========== CANCEL ==========

    function test_cancel_created() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        shield.cancel(0);

        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXPIRED));
        // No funds to return
        assertEq(usdc.balanceOf(worker), 100e6);
    }

    function test_cancel_pending_returns_premium() public {
        _createAndFund();

        uint256 workerBefore = usdc.balanceOf(worker);
        shield.cancel(0);

        assertEq(usdc.balanceOf(worker), workerBefore + PREMIUM);
        BulwArc.Shield memory s = shield.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.EXPIRED));
    }

    // ========== REVERTS ==========

    function test_revert_exercise_notSubscriber() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.prank(guardian);
        vm.expectRevert("Not subscriber");
        shield.exercise(0);
    }

    function test_revert_exercise_pastExpiry() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.warp(shields_expiry() + 1);
        vm.prank(worker);
        vm.expectRevert("Past expiry");
        shield.exercise(0);
    }

    function test_revert_exercise_outOfMoney() public {
        _createFundAndMatch();
        oracle.setPrice(95_000_000);

        vm.prank(worker);
        vm.expectRevert("Not in the money");
        shield.exercise(0);
    }

    function test_revert_doubleExercise() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.startPrank(worker);
        shield.exercise(0);
        vm.expectRevert("Not matched");
        shield.exercise(0);
        vm.stopPrank();
    }

    function test_revert_fund_already_pending() public {
        _createAndFund();

        vm.startPrank(employer);
        usdc.approve(address(shield), PREMIUM);
        vm.expectRevert("Not created");
        shield.fundShield(0);
        vm.stopPrank();
    }

    function test_revert_match_created_not_funded() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        shield.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        vm.expectRevert("Not pending");
        shield.matchShield(0);
        vm.stopPrank();
    }

    // ========== HELPERS ==========

    function _createAndFund() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(shield), PREMIUM);
        shield.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();
    }

    function _createFundAndMatch() internal {
        _createAndFund();
        vm.startPrank(guardian);
        usdc.approve(address(shield), NOTIONAL);
        shield.matchShield(0);
        vm.stopPrank();
    }

    function shields_expiry() internal view returns (uint256) {
        return shield.getShield(0).expiry;
    }
}
