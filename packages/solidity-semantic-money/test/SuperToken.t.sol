// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import "../src/SuperToken.sol";

contract SuperTokenTest is Test {
    using MonetaryTypes for Time;
    using MonetaryTypes for Value;
    using MonetaryTypes for FlowRate;
    using SemanticMoney for BasicParticle;
    using SemanticMoney for PDPoolMemberMU;

    address internal constant admin = address(0x420);
    address internal constant alice = address(0x421);
    address internal constant bob = address(0x422);
    address internal constant carol = address(0x423);
    address internal constant dan = address(0x424);
    address internal constant eve = address(0x425);
    address internal constant frank = address(0x426);
    address internal constant grace = address(0x427);
    address internal constant heidi = address(0x428);
    address internal constant ivan = address(0x429);
    uint internal immutable N_TESTERS;

    address[] internal TEST_ACCOUNTS = [admin,alice,bob,carol,dan,eve,frank,grace,heidi,ivan];
    SuperToken internal token;

    constructor () {
        N_TESTERS = TEST_ACCOUNTS.length;
    }

    function setUp() public {
        token = new SuperToken();
        for (uint i = 1; i < N_TESTERS; ++i) {
            vm.startPrank(admin);
            token.transferFrom(admin, TEST_ACCOUNTS[i], type(uint64).max);
            vm.stopPrank();
        }
    }

    function testERC20Transfer(uint32 x) external {
        uint256 a1 = token.balanceOf(alice);
        uint256 b1 = token.balanceOf(bob);
        vm.startPrank(alice);
        token.transferFrom(alice, bob, x);
        vm.stopPrank();
        uint256 a2 = token.balanceOf(alice);
        uint256 b2 = token.balanceOf(bob);
        assertEq(a1 - a2, x);
        assertEq(b2 - b1, x);
    }

    function testERC20Transfer(uint32 r, uint16 t2) external {
        uint256 a1 = token.balanceOf(alice);
        uint256 b1 = token.balanceOf(bob);
        uint256 t1 = block.timestamp;
        vm.startPrank(alice);
        token.flow(alice, bob, FlowId.wrap(0), FlowRate.wrap(int64(uint64(r))));
        vm.stopPrank();
        vm.warp(t1 + uint256(t2));
        uint256 a2 = token.balanceOf(alice);
        uint256 b2 = token.balanceOf(bob);
        emit log_named_uint("a1 - a2", a1 - a2);
        emit log_named_uint("r", r);
        emit log_named_uint("t2", t2);
        emit log_named_uint("r * t2", uint256(r) * uint256(t2));
        assertEq(a1 - a2, uint256(r) * uint256(t2));
        assertEq(b2 - b1, uint256(r) * uint256(t2));
    }

}