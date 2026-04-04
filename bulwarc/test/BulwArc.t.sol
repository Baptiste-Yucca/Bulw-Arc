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
    BulwArc public bulwarc;
    MockOracle public oracle;
    MockUSDC public usdc;

    address worker = makeAddr("worker");
    address guardianA = makeAddr("guardianA");
    address guardianB = makeAddr("guardianB");
    address guardianC = makeAddr("guardianC");
    address employer = makeAddr("employer");

    uint256 constant STRIKE = 92_000_000;
    uint256 constant NOTIONAL = 1000e6;
    uint256 constant PREMIUM = 5e6;

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockUSDC();
        bulwarc = new BulwArc(address(usdc), address(oracle));

        usdc.mint(worker, 100e6);
        usdc.mint(guardianA, 10_000e6);
        usdc.mint(guardianB, 10_000e6);
        usdc.mint(guardianC, 10_000e6);
        usdc.mint(employer, 100e6);
    }

    // ========== CREATE ==========

    function test_createShield() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.CREATED));
        assertEq(s.filled, 0);
    }

    function test_createAndFundShield() public {
        _createAndFund();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(usdc.balanceOf(worker), 100e6 - PREMIUM);
    }

    // ========== FUND ==========

    function test_fundShield_by_employer() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        vm.startPrank(employer);
        usdc.approve(address(bulwarc), PREMIUM);
        bulwarc.fundShield(0);
        vm.stopPrank();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(usdc.balanceOf(employer), 100e6 - PREMIUM);
        assertEq(usdc.balanceOf(worker), 100e6);
    }

    // ========== MATCH — single guardian ==========

    function test_matchShield_full() public {
        _createAndFund();

        uint256 gBefore = usdc.balanceOf(guardianA);

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), NOTIONAL);
        bulwarc.matchShield(0, NOTIONAL);
        vm.stopPrank();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.LOCKED));
        assertEq(s.filled, NOTIONAL);
        assertEq(bulwarc.getFillCount(0), 1);
        assertEq(usdc.balanceOf(guardianA), gBefore - NOTIONAL + PREMIUM);
    }

    // ========== MATCH — multiple guardians (partial fill) ==========

    function test_matchShield_partial_multi_guardians() public {
        _createAndFund();

        // Guardian A fills 200
        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 200e6);
        bulwarc.matchShield(0, 200e6);
        vm.stopPrank();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(s.filled, 200e6);

        // Guardian B fills 500
        vm.startPrank(guardianB);
        usdc.approve(address(bulwarc), 500e6);
        bulwarc.matchShield(0, 500e6);
        vm.stopPrank();

        s = bulwarc.getShield(0);
        assertEq(s.filled, 700e6);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.PENDING));

        // Guardian C fills remaining 300 → LOCKED
        vm.startPrank(guardianC);
        usdc.approve(address(bulwarc), 300e6);
        bulwarc.matchShield(0, 300e6);
        vm.stopPrank();

        s = bulwarc.getShield(0);
        assertEq(s.filled, NOTIONAL);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.LOCKED));
        assertEq(bulwarc.getFillCount(0), 3);
    }

    function test_premium_distributed_prorata() public {
        _createAndFund();

        uint256 aBefore = usdc.balanceOf(guardianA);
        uint256 bBefore = usdc.balanceOf(guardianB);

        // A fills 200/1000 → gets 20% of premium = 1 USDC
        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 200e6);
        bulwarc.matchShield(0, 200e6);
        vm.stopPrank();

        // B fills 800/1000 → gets 80% of premium = 4 USDC
        vm.startPrank(guardianB);
        usdc.approve(address(bulwarc), 800e6);
        bulwarc.matchShield(0, 800e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(guardianA), aBefore - 200e6 + 1e6);
        assertEq(usdc.balanceOf(guardianB), bBefore - 800e6 + 4e6);
    }

    // ========== MATCH — on behalf ==========

    function test_matchShieldFor() public {
        _createAndFund();

        address backer = makeAddr("backer");
        usdc.mint(backer, 10_000e6);

        vm.startPrank(backer);
        usdc.approve(address(bulwarc), NOTIONAL);
        bulwarc.matchShieldFor(0, guardianA, NOTIONAL);
        vm.stopPrank();

        BulwArc.Shield memory s = bulwarc.getShield(0);
        BulwArc.Fill[] memory f = bulwarc.getFills(0);
        assertEq(f[0].guardian, guardianA);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.LOCKED));
        // Backer paid, guardianA got premium
        assertEq(usdc.balanceOf(backer), 10_000e6 - NOTIONAL);
        assertEq(usdc.balanceOf(guardianA), 10_000e6 + PREMIUM);
    }

    // ========== EXERCISE — fully matched ==========

    function test_exercise_inTheMoney_single_guardian() public {
        _createFundAndMatch();

        oracle.setPrice(88_000_000);
        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 gBefore = usdc.balanceOf(guardianA);

        vm.prank(worker);
        bulwarc.exercise(0);

        // payoff = (0.92 - 0.88) * 1000 = 40 USDC
        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
        assertEq(usdc.balanceOf(guardianA), gBefore + NOTIONAL - expectedPayoff);
    }

    function test_exercise_inTheMoney_multi_guardians() public {
        _createAndFund();

        // A fills 400, B fills 600
        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 400e6);
        bulwarc.matchShield(0, 400e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        usdc.approve(address(bulwarc), 600e6);
        bulwarc.matchShield(0, 600e6);
        vm.stopPrank();

        oracle.setPrice(88_000_000);

        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 aBefore = usdc.balanceOf(guardianA);
        uint256 bBefore = usdc.balanceOf(guardianB);

        vm.prank(worker);
        bulwarc.exercise(0);

        // payoff per unit = (92000000 - 88000000) = 4000000 out of 1e8
        // A: payoff = 4000000 * 400e6 / 1e8 = 16e6, remaining = 384e6
        // B: payoff = 4000000 * 600e6 / 1e8 = 24e6, remaining = 576e6
        uint256 payoffA = 4_000_000 * 400e6 / 1e8;
        uint256 payoffB = 4_000_000 * 600e6 / 1e8;

        assertEq(usdc.balanceOf(worker), workerBefore + payoffA + payoffB);
        assertEq(usdc.balanceOf(guardianA), aBefore + 400e6 - payoffA);
        assertEq(usdc.balanceOf(guardianB), bBefore + 600e6 - payoffB);
    }

    // ========== EXERCISE — partially filled ==========

    function test_exercise_partial_fill() public {
        _createAndFund();

        // Only 800/1000 filled
        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 800e6);
        bulwarc.matchShield(0, 800e6);
        vm.stopPrank();

        oracle.setPrice(88_000_000);
        uint256 workerBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        // Payoff only on 800 covered: (0.92-0.88)*800 = 32 USDC
        uint256 expectedPayoff = 4_000_000 * 800e6 / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    // ========== EXERCISE — employer funded ==========

    function test_exercise_after_employer_funds() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        vm.startPrank(employer);
        usdc.approve(address(bulwarc), PREMIUM);
        bulwarc.fundShield(0);
        vm.stopPrank();

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), NOTIONAL);
        bulwarc.matchShield(0, NOTIONAL);
        vm.stopPrank();

        oracle.setPrice(88_000_000);
        uint256 workerBefore = usdc.balanceOf(worker);

        vm.prank(worker);
        bulwarc.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / 1e8;
        assertEq(usdc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    // ========== EXPIRE ==========

    function test_expire_multi_guardians() public {
        _createAndFund();

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 400e6);
        bulwarc.matchShield(0, 400e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        usdc.approve(address(bulwarc), 600e6);
        bulwarc.matchShield(0, 600e6);
        vm.stopPrank();

        vm.warp(bulwarc.getShield(0).expiry + 1);

        uint256 aBefore = usdc.balanceOf(guardianA);
        uint256 bBefore = usdc.balanceOf(guardianB);

        bulwarc.expire(0);

        assertEq(usdc.balanceOf(guardianA), aBefore + 400e6);
        assertEq(usdc.balanceOf(guardianB), bBefore + 600e6);
    }

    function test_expire_partial_fill() public {
        _createAndFund();

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 500e6);
        bulwarc.matchShield(0, 500e6);
        vm.stopPrank();

        vm.warp(bulwarc.getShield(0).expiry + 1);

        uint256 aBefore = usdc.balanceOf(guardianA);
        bulwarc.expire(0);

        assertEq(usdc.balanceOf(guardianA), aBefore + 500e6);
    }

    // ========== CANCEL ==========

    function test_cancel_created() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        bulwarc.cancel(0);
        assertEq(uint8(bulwarc.getShield(0).status), uint8(BulwArc.ShieldStatus.EXPIRED));
    }

    function test_cancel_pending_no_fills() public {
        _createAndFund();

        uint256 workerBefore = usdc.balanceOf(worker);
        bulwarc.cancel(0);

        assertEq(usdc.balanceOf(worker), workerBefore + PREMIUM);
    }

    function test_revert_cancel_with_fills() public {
        _createAndFund();

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), 200e6);
        bulwarc.matchShield(0, 200e6);
        vm.stopPrank();

        vm.expectRevert("Already has fills");
        bulwarc.cancel(0);
    }

    // ========== REVERTS ==========

    function test_revert_exercise_notSubscriber() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.prank(guardianA);
        vm.expectRevert("Not subscriber");
        bulwarc.exercise(0);
    }

    function test_revert_exercise_pastExpiry() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.warp(bulwarc.getShield(0).expiry + 1);
        vm.prank(worker);
        vm.expectRevert("Past expiry");
        bulwarc.exercise(0);
    }

    function test_revert_exercise_outOfMoney() public {
        _createFundAndMatch();
        oracle.setPrice(95_000_000);

        vm.prank(worker);
        vm.expectRevert("Not in the money");
        bulwarc.exercise(0);
    }

    function test_revert_doubleExercise() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);

        vm.startPrank(worker);
        bulwarc.exercise(0);
        vm.expectRevert("Cannot exercise");
        bulwarc.exercise(0);
        vm.stopPrank();
    }

    function test_revert_match_exceeds() public {
        _createAndFund();

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), NOTIONAL + 1);
        vm.expectRevert("Exceeds remaining");
        bulwarc.matchShield(0, NOTIONAL + 1);
        vm.stopPrank();
    }

    function test_revert_match_not_funded() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        bulwarc.createShield(STRIKE, NOTIONAL, PREMIUM, expiry);

        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), NOTIONAL);
        vm.expectRevert("Not pending");
        bulwarc.matchShield(0, NOTIONAL);
        vm.stopPrank();
    }

    function test_revert_exercise_no_fills() public {
        _createAndFund();

        oracle.setPrice(88_000_000);
        vm.prank(worker);
        vm.expectRevert("No fills");
        bulwarc.exercise(0);
    }

    // ========== HELPERS ==========

    function _createAndFund() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(bulwarc), PREMIUM);
        bulwarc.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry);
        vm.stopPrank();
    }

    function _createFundAndMatch() internal {
        _createAndFund();
        vm.startPrank(guardianA);
        usdc.approve(address(bulwarc), NOTIONAL);
        bulwarc.matchShield(0, NOTIONAL);
        vm.stopPrank();
    }
}
