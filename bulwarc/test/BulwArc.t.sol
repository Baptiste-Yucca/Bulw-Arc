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

    address worker = makeAddr("worker");
    address employer = makeAddr("employer");
    address guardianA = makeAddr("guardianA");
    address guardianB = makeAddr("guardianB");
    address validatorAddr = makeAddr("validator");

    uint256 constant STRIKE = 92_000_000;  // 0.92 EUR/USD
    uint256 constant SALARY = 1000e6;      // 1000 USDC salary
    uint256 constant PREMIUM = 50e6;       // 50 USDC premium
    uint256 constant FEE_BPS = 100;        // 1%
    uint256 constant SUB_FEE = (SALARY + PREMIUM) * FEE_BPS / 10000;
    uint256 constant GUARD_FEE_FULL = SALARY * FEE_BPS / 10000;

    function setUp() public {
        oracle = new MockOracle(int256(STRIKE));
        usdc = new MockERC20("USDC", "USDC");
        eurc = new MockERC20("EURC", "EURC");
        b = new BulwArc(address(usdc), address(eurc), address(oracle), FEE_BPS);

        usdc.mint(worker, 10_000e6);
        usdc.mint(employer, 10_000e6);
        usdc.mint(guardianA, 10_000e6);
        usdc.mint(guardianB, 10_000e6);
        eurc.mint(worker, 10_000e6);
        eurc.mint(employer, 10_000e6);
        eurc.mint(guardianA, 10_000e6);
        eurc.mint(guardianB, 10_000e6);
    }

    // ================================================================
    // CREATE
    // ================================================================

    function test_createShield() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, SALARY, PREMIUM, expiry, address(0), false);

        BulwArc.Shield memory s = b.getShield(0);
        assertEq(s.subscriber, worker);
        assertEq(s.notional, SALARY);
        assertEq(s.premium, PREMIUM);
        assertEq(uint8(s.status), uint8(BulwArc.ShieldStatus.CREATED));
    }

    // ================================================================
    // FUND — employer deposits salary + premium + fee
    // ================================================================

    function test_fund_deposits_salary_and_premium() public {
        _create();

        uint256 empBefore = usdc.balanceOf(employer);

        vm.startPrank(employer);
        usdc.approve(address(b), SALARY + PREMIUM + SUB_FEE);
        b.fundShield(0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(employer), empBefore - SALARY - PREMIUM - SUB_FEE);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.PENDING));
        assertEq(b.getShield(0).subscriberFee, SUB_FEE);
        assertEq(b.treasuryUSDC(), SUB_FEE);
    }

    // ================================================================
    // MATCH — guardian deposits EURC, receives USDC premium
    // ================================================================

    function test_match_full() public {
        _createAndFund();

        uint256 gEurcBefore = eurc.balanceOf(guardianA);
        uint256 gUsdcBefore = usdc.balanceOf(guardianA);

        vm.startPrank(guardianA);
        eurc.approve(address(b), SALARY + GUARD_FEE_FULL);
        b.matchShield(0, guardianA, SALARY);
        vm.stopPrank();

        assertEq(eurc.balanceOf(guardianA), gEurcBefore - SALARY - GUARD_FEE_FULL);
        assertEq(usdc.balanceOf(guardianA), gUsdcBefore + PREMIUM);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.LOCKED));
    }

    // ================================================================
    // SETTLE — IN THE MONEY (swap)
    // ================================================================

    function test_settle_in_the_money() public {
        _createFundAndMatch();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(88_000_000); // spot < strike → in the money

        uint256 wEurcBefore = eurc.balanceOf(worker);
        uint256 wUsdcBefore = usdc.balanceOf(worker);
        uint256 gEurcBefore = eurc.balanceOf(guardianA);
        uint256 gUsdcBefore = usdc.balanceOf(guardianA);

        b.settle(0);

        // Worker gets EURC collateral
        assertEq(eurc.balanceOf(worker), wEurcBefore + SALARY);
        // Worker USDC unchanged
        assertEq(usdc.balanceOf(worker), wUsdcBefore);
        // Guardian gets USDC salary
        assertEq(usdc.balanceOf(guardianA), gUsdcBefore + SALARY);
        // Guardian lost EURC collateral
        assertEq(eurc.balanceOf(guardianA), gEurcBefore);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.EXERCISED));
    }

    function test_settle_50pct_delivery() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, SALARY, PREMIUM, expiry, validatorAddr, false);

        vm.startPrank(employer);
        usdc.approve(address(b), SALARY + PREMIUM + SUB_FEE);
        b.fundShield(0);
        vm.stopPrank();

        vm.startPrank(guardianA);
        eurc.approve(address(b), SALARY + GUARD_FEE_FULL);
        b.matchShield(0, guardianA, SALARY);
        vm.stopPrank();

        vm.prank(validatorAddr);
        b.validateDelivery(0, 50);

        vm.warp(expiry + 1);
        oracle.setPrice(88_000_000);

        uint256 wEurcBefore = eurc.balanceOf(worker);
        uint256 gEurcBefore = eurc.balanceOf(guardianA);

        b.settle(0);

        // Worker gets 50% of EURC collateral
        assertEq(eurc.balanceOf(worker), wEurcBefore + SALARY * 50 / 100);
        // Guardian gets back 50% of EURC collateral
        assertEq(eurc.balanceOf(guardianA), gEurcBefore + SALARY * 50 / 100);
    }

    function test_settle_multi_guardians() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 600e6 + 6e6);
        b.matchShield(0, guardianA, 600e6);
        vm.stopPrank();

        vm.startPrank(guardianB);
        eurc.approve(address(b), 400e6 + 4e6);
        b.matchShield(0, guardianB, 400e6);
        vm.stopPrank();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(88_000_000);

        uint256 wEurcBefore = eurc.balanceOf(worker);
        uint256 gaUsdcBefore = usdc.balanceOf(guardianA);
        uint256 gbUsdcBefore = usdc.balanceOf(guardianB);

        b.settle(0);

        assertEq(eurc.balanceOf(worker), wEurcBefore + SALARY);
        assertEq(usdc.balanceOf(guardianA), gaUsdcBefore + 600e6);
        assertEq(usdc.balanceOf(guardianB), gbUsdcBefore + 400e6);
    }

    function test_settle_partial_fill_in_money() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 600e6 + 6e6);
        b.matchShield(0, guardianA, 600e6);
        vm.stopPrank();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(88_000_000);

        uint256 wEurcBefore = eurc.balanceOf(worker);
        uint256 gUsdcBefore = usdc.balanceOf(guardianA);

        b.settle(0);

        // Worker gets 600 EURC (only what was filled)
        assertEq(eurc.balanceOf(worker), wEurcBefore + 600e6);
        // Guardian gets full salary (1000 * 600/600 = 1000)
        assertEq(usdc.balanceOf(guardianA), gUsdcBefore + SALARY);
    }

    // ================================================================
    // SETTLE — OUT OF THE MONEY (refund)
    // ================================================================

    function test_settle_out_of_money() public {
        _createFundAndMatch();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(95_000_000); // spot > strike → out of money

        uint256 wUsdcBefore = usdc.balanceOf(worker);
        uint256 gEurcBefore = eurc.balanceOf(guardianA);

        b.settle(0);

        // Worker gets salary back
        assertEq(usdc.balanceOf(worker), wUsdcBefore + SALARY);
        // Guardian gets EURC collateral back
        assertEq(eurc.balanceOf(guardianA), gEurcBefore + SALARY);
        assertEq(uint8(b.getShield(0).status), uint8(BulwArc.ShieldStatus.EXPIRED));
    }

    function test_settle_out_of_money_partial_fill() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 600e6 + 6e6);
        b.matchShield(0, guardianA, 600e6);
        vm.stopPrank();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(95_000_000);

        uint256 wUsdcBefore = usdc.balanceOf(worker);
        uint256 gEurcBefore = eurc.balanceOf(guardianA);

        b.settle(0);

        uint256 usedFee = SUB_FEE * 600e6 / SALARY;
        uint256 feeRefund = SUB_FEE - usedFee;

        assertEq(usdc.balanceOf(worker), wUsdcBefore + SALARY + feeRefund);
        assertEq(eurc.balanceOf(guardianA), gEurcBefore + 600e6);
    }

    // ================================================================
    // CANCEL
    // ================================================================

    function test_cancel_pending_refunds_all() public {
        _createAndFund();

        uint256 wUsdcBefore = usdc.balanceOf(worker);
        b.cancel(0);

        assertEq(usdc.balanceOf(worker), wUsdcBefore + SALARY + PREMIUM + SUB_FEE);
        assertEq(b.treasuryUSDC(), 0);
    }

    function test_revert_cancel_with_fills() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 200e6 + 2e6);
        b.matchShield(0, guardianA, 200e6);
        vm.stopPrank();

        vm.expectRevert("Already has fills");
        b.cancel(0);
    }

    // ================================================================
    // FEES
    // ================================================================

    function test_fees_both_sides() public {
        _createFundAndMatch();

        assertEq(b.treasuryUSDC(), SUB_FEE);
        assertEq(b.treasuryEURC(), GUARD_FEE_FULL);
    }

    function test_fee_refund_partial_fill() public {
        _createAndFund();

        vm.startPrank(guardianA);
        eurc.approve(address(b), 500e6 + 5e6);
        b.matchShield(0, guardianA, 500e6);
        vm.stopPrank();

        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(95_000_000); // out of money

        uint256 wUsdcBefore = usdc.balanceOf(worker);
        uint256 treasuryBefore = b.treasuryUSDC();

        b.settle(0);

        uint256 usedFee = SUB_FEE * 500e6 / SALARY;
        uint256 refund = SUB_FEE - usedFee;
        assertEq(usdc.balanceOf(worker), wUsdcBefore + SALARY + refund);
        assertEq(b.treasuryUSDC(), treasuryBefore - refund);
    }

    // ================================================================
    // REVERSE MODE — subscriber=EURC, guardian=USDC
    // ================================================================

    function test_reverse_settle_in_money() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(worker);
        b.createShield(STRIKE, SALARY, PREMIUM, expiry, address(0), true);

        uint256 revSubFee = (SALARY + PREMIUM) * FEE_BPS / 10000;
        vm.startPrank(employer);
        eurc.approve(address(b), SALARY + PREMIUM + revSubFee);
        b.fundShield(0);
        vm.stopPrank();

        uint256 revGuardFee = SALARY * FEE_BPS / 10000;
        vm.startPrank(guardianA);
        usdc.approve(address(b), SALARY + revGuardFee);
        b.matchShield(0, guardianA, SALARY);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setPrice(96_000_000); // spot > strike → in the money for reverse

        uint256 wUsdcBefore = usdc.balanceOf(worker);
        uint256 gEurcBefore = eurc.balanceOf(guardianA);

        b.settle(0);

        assertEq(usdc.balanceOf(worker), wUsdcBefore + SALARY);
        assertEq(eurc.balanceOf(guardianA), gEurcBefore + SALARY);
    }

    // ================================================================
    // REVERTS
    // ================================================================

    function test_revert_settle_before_expiry() public {
        _createFundAndMatch();
        oracle.setPrice(88_000_000);
        vm.expectRevert("Not expired yet");
        b.settle(0);
    }

    function test_revert_settle_not_validated() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, SALARY, PREMIUM, expiry, validatorAddr, false);

        vm.startPrank(employer);
        usdc.approve(address(b), SALARY + PREMIUM + SUB_FEE);
        b.fundShield(0);
        vm.stopPrank();

        vm.startPrank(guardianA);
        eurc.approve(address(b), SALARY + GUARD_FEE_FULL);
        b.matchShield(0, guardianA, SALARY);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setPrice(88_000_000);

        vm.expectRevert("Not validated");
        b.settle(0);
    }

    function test_revert_double_settle() public {
        _createFundAndMatch();
        vm.warp(b.getShield(0).expiry + 1);
        oracle.setPrice(88_000_000);
        b.settle(0);
        vm.expectRevert("Cannot settle");
        b.settle(0);
    }

    // ================================================================
    // HELPERS
    // ================================================================

    function _create() internal {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(worker);
        b.createShield(STRIKE, SALARY, PREMIUM, expiry, address(0), false);
    }

    function _createAndFund() internal {
        _create();
        vm.startPrank(employer);
        usdc.approve(address(b), SALARY + PREMIUM + SUB_FEE);
        b.fundShield(0);
        vm.stopPrank();
    }

    function _createFundAndMatch() internal {
        _createAndFund();
        vm.startPrank(guardianA);
        eurc.approve(address(b), SALARY + GUARD_FEE_FULL);
        b.matchShield(0, guardianA, SALARY);
        vm.stopPrank();
    }
}
