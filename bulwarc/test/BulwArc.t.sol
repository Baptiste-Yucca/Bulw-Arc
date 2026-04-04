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

    constructor(string memory _name, string memory _symbol) { name = _name; symbol = _symbol; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

contract BulwArcTest is Test {
    BulwArc public b;
    MockOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public eurc;

    address worker = makeAddr("worker");       // EU worker (normal subscriber)
    address traveller = makeAddr("traveller"); // US traveller (reverse subscriber)
    address guardianA = makeAddr("guardianA");
    address guardianB = makeAddr("guardianB");
    address employer = makeAddr("employer");
    address validatorAddr = makeAddr("validator");

    uint256 constant STRIKE = 92_000_000;
    uint256 constant NOTIONAL = 1000e6;
    uint256 constant PREMIUM = 100e6;
    uint256 constant FEE_BPS = 100;
    uint256 constant SUB_FEE = PREMIUM * FEE_BPS / 10000;
    uint256 constant GUARD_FEE = NOTIONAL * FEE_BPS / 10000;

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockERC20("USDC", "USDC");
        eurc = new MockERC20("EURC", "EURC");
        b = new BulwArc(address(usdc), address(eurc), address(oracle), FEE_BPS);

        // Everyone gets both tokens for flexibility
        usdc.mint(worker, 10_000e6);
        usdc.mint(traveller, 10_000e6);
        usdc.mint(guardianA, 10_000e6);
        usdc.mint(guardianB, 10_000e6);
        usdc.mint(employer, 10_000e6);
        eurc.mint(worker, 10_000e6);
        eurc.mint(traveller, 10_000e6);
        eurc.mint(guardianA, 10_000e6);
        eurc.mint(guardianB, 10_000e6);
        eurc.mint(employer, 10_000e6);
    }

    // ================================================================
    // NORMAL MODE (isReverse=false): sub=USDC premium, guard=EURC collateral
    // Exercise when spot < strike (USD weakens)
    // ================================================================

    function test_normal_create() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0), false);

        BulwArc.Shield memory s = b.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(s.isReverse, false);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.CREATED));
    }

    function test_normal_createAndFund() public {
        _normalCreateAndFund();

        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(usdc.balanceOf(worker), 10_000e6 - PREMIUM - SUB_FEE);
        assertEq(b.treasuryUSDC(), SUB_FEE);
    }

    function test_normal_fund_by_employer() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0), false);

        vm.startPrank(employer);
        usdc.approve(address(b), PREMIUM + SUB_FEE);
        b.fundShield(0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(employer), 10_000e6 - PREMIUM - SUB_FEE);
        assertEq(usdc.balanceOf(worker), 10_000e6); // untouched
    }

    function test_normal_match() public {
        _normalCreateAndFund();

        uint256 eurcBefore = eurc.balanceOf(guardianA);

        vm.startPrank(guardianA);
        eurc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
        assertEq(eurc.balanceOf(guardianA), eurcBefore - NOTIONAL - GUARD_FEE);
        assertEq(usdc.balanceOf(guardianA), 10_000e6 + PREMIUM); // got premium in USDC
        assertEq(b.treasuryEURC(), GUARD_FEE);
    }

    function test_normal_exercise() public {
        _normalCreateFundAndMatch();

        oracle.setPrice(88_000_000); // USD weakens
        uint256 workerEurcBefore = eurc.balanceOf(worker);

        vm.prank(worker);
        b.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL / STRIKE;
        assertEq(eurc.balanceOf(worker), workerEurcBefore + expectedPayoff);
    }

    function test_normal_expire() public {
        _normalCreateFundAndMatch();

        vm.warp(b.getShield(0).expiry + 1);

        uint256 guardianBefore = eurc.balanceOf(guardianA);
        b.expire(0);

        assertEq(eurc.balanceOf(guardianA), guardianBefore + NOTIONAL);
    }

    function test_normal_exercise_notInMoney() public {
        _normalCreateFundAndMatch();

        oracle.setPrice(95_000_000); // USD strengthens — not in the money

        vm.prank(worker);
        vm.expectRevert("Not in the money");
        b.exercise(0);
    }

    // ================================================================
    // REVERSE MODE (isReverse=true): sub=EURC premium, guard=USDC collateral
    // Exercise when spot > strike (EUR weakens)
    // ================================================================

    function test_reverse_create() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(traveller);
        b.createShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0), true);

        BulwArc.Shield memory s = b.getShield(0);
        assertEq(s.subscriber, traveller);
        assertEq(s.isReverse, true);
    }

    function test_reverse_createAndFund() public {
        _reverseCreateAndFund();

        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.PENDING));
        // Traveller paid EURC premium + fee
        assertEq(eurc.balanceOf(traveller), 10_000e6 - PREMIUM - SUB_FEE);
        assertEq(b.treasuryEURC(), SUB_FEE);
    }

    function test_reverse_match() public {
        _reverseCreateAndFund();

        uint256 usdcBefore = usdc.balanceOf(guardianA);

        // Guardian deposits USDC as collateral
        vm.startPrank(guardianA);
        usdc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
        // Guardian spent USDC, received EURC premium
        assertEq(usdc.balanceOf(guardianA), usdcBefore - NOTIONAL - GUARD_FEE);
        assertEq(eurc.balanceOf(guardianA), 10_000e6 + PREMIUM);
        assertEq(b.treasuryUSDC(), GUARD_FEE);
    }

    function test_reverse_exercise_eur_weakens() public {
        _reverseCreateFundAndMatch();

        oracle.setPrice(96_000_000); // EUR weakens (spot > strike)
        uint256 travellerUsdcBefore = usdc.balanceOf(traveller);
        uint256 guardianUsdcBefore = usdc.balanceOf(guardianA);

        vm.prank(traveller);
        b.exercise(0);

        // payoff = (0.96 - 0.92) / 0.92 * 1000 USDC
        uint256 expectedPayoff = (96_000_000 - STRIKE) * NOTIONAL / STRIKE;
        assertEq(usdc.balanceOf(traveller), travellerUsdcBefore + expectedPayoff);
        assertEq(usdc.balanceOf(guardianA), guardianUsdcBefore + NOTIONAL - expectedPayoff);
    }

    function test_reverse_expire() public {
        _reverseCreateFundAndMatch();

        vm.warp(b.getShield(0).expiry + 1);

        uint256 guardianBefore = usdc.balanceOf(guardianA);
        b.expire(0);

        // Guardian gets USDC collateral back
        assertEq(usdc.balanceOf(guardianA), guardianBefore + NOTIONAL);
    }

    function test_reverse_exercise_notInMoney() public {
        _reverseCreateFundAndMatch();

        oracle.setPrice(88_000_000); // EUR strengthens — not in the money for reverse

        vm.prank(traveller);
        vm.expectRevert("Not in the money");
        b.exercise(0);
    }

    // ================================================================
    // DELIVERY VALIDATION (works for both modes)
    // ================================================================

    function test_normal_delivery_50pct() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(b), PREMIUM + SUB_FEE);
        b.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, validatorAddr, false);
        vm.stopPrank();

        vm.startPrank(guardianA);
        eurc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        vm.prank(validatorAddr);
        b.validateDelivery(0, 50);

        oracle.setPrice(88_000_000);
        uint256 workerBefore = eurc.balanceOf(worker);

        vm.prank(worker);
        b.exercise(0);

        uint256 expectedPayoff = (STRIKE - 88_000_000) * NOTIONAL * 50 / (STRIKE * 100);
        assertEq(eurc.balanceOf(worker), workerBefore + expectedPayoff);
    }

    function test_reverse_delivery_50pct() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(traveller);
        eurc.approve(address(b), PREMIUM + SUB_FEE);
        b.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, validatorAddr, true);
        vm.stopPrank();

        vm.startPrank(guardianA);
        usdc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        vm.prank(validatorAddr);
        b.validateDelivery(0, 50);

        oracle.setPrice(96_000_000); // EUR weakens
        uint256 travellerBefore = usdc.balanceOf(traveller);

        vm.prank(traveller);
        b.exercise(0);

        uint256 expectedPayoff = (96_000_000 - STRIKE) * NOTIONAL * 50 / (STRIKE * 100);
        assertEq(usdc.balanceOf(traveller), travellerBefore + expectedPayoff);
    }

    function test_revert_not_validated() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(b), PREMIUM + SUB_FEE);
        b.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, validatorAddr, false);
        vm.stopPrank();

        vm.startPrank(guardianA);
        eurc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();

        oracle.setPrice(88_000_000);

        vm.prank(worker);
        vm.expectRevert("Not validated");
        b.exercise(0);
    }

    // ================================================================
    // PARTIAL FILL
    // ================================================================

    function test_normal_partial_fill() public {
        _normalCreateAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 400e6 + 4e6);
        b.matchShield(0, guardianA, 400e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        eurc.approve(address(b), 600e6 + 6e6);
        b.matchShield(0, guardianB, 600e6);
        vm.stopPrank();

        assertEq(b.getShield(0).filled, NOTIONAL);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
        assertEq(b.getFillCount(0), 2);
    }

    function test_reverse_partial_fill() public {
        _reverseCreateAndFund();

        vm.startPrank(guardianA);
        usdc.approve(address(b), 400e6 + 4e6);
        b.matchShield(0, guardianA, 400e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        usdc.approve(address(b), 600e6 + 6e6);
        b.matchShield(0, guardianB, 600e6);
        vm.stopPrank();

        assertEq(b.getShield(0).filled, NOTIONAL);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
    }

    // ================================================================
    // CANCEL
    // ================================================================

    function test_normal_cancel() public {
        _normalCreateAndFund();

        uint256 workerBefore = usdc.balanceOf(worker);
        b.cancel(0);

        assertEq(usdc.balanceOf(worker), workerBefore + PREMIUM + SUB_FEE);
    }

    function test_reverse_cancel() public {
        _reverseCreateAndFund();

        uint256 travellerBefore = eurc.balanceOf(traveller);
        b.cancel(0);

        assertEq(eurc.balanceOf(traveller), travellerBefore + PREMIUM + SUB_FEE);
    }

    // ================================================================
    // FEES TREASURY
    // ================================================================

    function test_fees_normal() public {
        _normalCreateFundAndMatch();
        assertEq(b.treasuryUSDC(), SUB_FEE);   // subscriber fee in USDC
        assertEq(b.treasuryEURC(), GUARD_FEE);  // guardian fee in EURC
    }

    function test_fees_reverse() public {
        _reverseCreateFundAndMatch();
        assertEq(b.treasuryEURC(), SUB_FEE);   // subscriber fee in EURC
        assertEq(b.treasuryUSDC(), GUARD_FEE);  // guardian fee in USDC
    }

    function test_withdraw_treasury() public {
        _normalCreateFundAndMatch();
        address treasury = makeAddr("treasury");
        b.withdrawTreasury(treasury);
        assertEq(usdc.balanceOf(treasury), SUB_FEE);
        assertEq(eurc.balanceOf(treasury), GUARD_FEE);
    }

    // ================================================================
    // REVERTS
    // ================================================================

    function test_revert_exercise_notSubscriber() public {
        _normalCreateFundAndMatch();
        oracle.setPrice(88_000_000);
        vm.prank(guardianA);
        vm.expectRevert("Not subscriber");
        b.exercise(0);
    }

    function test_revert_exercise_pastExpiry() public {
        _normalCreateFundAndMatch();
        oracle.setPrice(88_000_000);
        vm.warp(b.getShield(0).expiry + 1);
        vm.prank(worker);
        vm.expectRevert("Past expiry");
        b.exercise(0);
    }

    function test_revert_doubleExercise() public {
        _normalCreateFundAndMatch();
        oracle.setPrice(88_000_000);
        vm.startPrank(worker);
        b.exercise(0);
        vm.expectRevert("Cannot exercise");
        b.exercise(0);
        vm.stopPrank();
    }

    function test_revert_cancel_with_fills() public {
        _normalCreateAndFund();
        vm.startPrank(guardianA);
        eurc.approve(address(b), 200e6 + 2e6);
        b.matchShield(0, guardianA, 200e6);
        vm.stopPrank();
        vm.expectRevert("Already has fills");
        b.cancel(0);
    }

    // ================================================================
    // HELPERS
    // ================================================================

    function _normalCreateAndFund() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(worker);
        usdc.approve(address(b), PREMIUM + SUB_FEE);
        b.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0), false);
        vm.stopPrank();
    }

    function _normalCreateFundAndMatch() internal {
        _normalCreateAndFund();
        vm.startPrank(guardianA);
        eurc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();
    }

    function _reverseCreateAndFund() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.startPrank(traveller);
        eurc.approve(address(b), PREMIUM + SUB_FEE);
        b.createAndFundShield(STRIKE, NOTIONAL, PREMIUM, expiry, address(0), true);
        vm.stopPrank();
    }

    function _reverseCreateFundAndMatch() internal {
        _reverseCreateAndFund();
        vm.startPrank(guardianA);
        usdc.approve(address(b), NOTIONAL + GUARD_FEE);
        b.matchShield(0, guardianA, NOTIONAL);
        vm.stopPrank();
    }
}
