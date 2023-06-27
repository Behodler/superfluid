// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import { FoundrySuperfluidTester, SuperTokenV1Library } from "../FoundrySuperfluidTester.sol";
import { ISuperToken } from "../../../contracts/superfluid/SuperToken.sol";
import { TOGA } from "../../../contracts/utils/TOGA.sol";
import { IERC1820Registry } from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TOGAIntegrationTest
 * @dev A contract for testing the functionality of the TOGA contract.
 */
contract TOGAIntegrationTest is FoundrySuperfluidTester {
    using SuperTokenV1Library for ISuperToken;

    TOGA internal toga;

    uint256 internal immutable MIN_BOND_DURATION;
    uint256 internal constant BOND_AMOUNT_1E18 = 1e18;
    uint256 internal constant BOND_AMOUNT_2E18 = 2e18;
    uint256 internal constant BOND_AMOUNT_10E18 = 10e18;
    int96 internal constant EXIT_RATE_1 = 1;
    int96 internal constant EXIT_RATE_1E3 = 1e3;
    int96 internal constant EXIT_RATE_1E6 = 1e6;
    IERC1820Registry internal constant _ERC1820_REG = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    constructor() FoundrySuperfluidTester(5) {
        MIN_BOND_DURATION = sfDeployer.DEFAULT_TOGA_MIN_BOND_DURATION(); // 1 weeks
    }

    // Events

    event NewPIC(ISuperToken indexed token, address pic, uint256 bond, int96 exitRate);
    event BondIncreased(ISuperToken indexed token, uint256 additionalBond);
    event ExitRateChanged(ISuperToken indexed token, int96 exitRate);

    /**
     * @dev Sets up the contract for testing.
     */
    function setUp() public override {
        super.setUp();
        toga = new TOGA(sf.host, MIN_BOND_DURATION);
    }

    // Helper

    /**
     * @dev Checks the net flow of an asset for an account.
     * @param superToken_ The Super Token representing the asset.
     * @param account The address of the account to check.
     * @param expectedNetFlow The expected net flow.
     */
    function _assertNetFlow(ISuperToken superToken_, address account, int96 expectedNetFlow) internal {
        int96 flowRate = sf.cfa.getNetFlow(superToken_, account);
        assertEq(flowRate, expectedNetFlow, "_assertNetFlow: net flow not equal");
    }

    /**
     * @dev Sends a PIC bid.
     * @param sender The address of the sender.
     * @param superToken_ The Super Token representing the asset.
     * @param newBond The bond amount.
     * @param exitRate The exit rate.
     */
    function _helperSendPICBid(address sender, ISuperToken superToken_, uint256 newBond, int96 exitRate) internal {
        _helperSendPICBid(sender, superToken_, newBond, abi.encode(exitRate));
    }

    function _helperSendPICBid(address newPIC, ISuperToken superToken_, uint256 newBond, bytes memory data) internal {
        uint256 balanceOfTogaBefore = superToken_.balanceOf(address(toga));
        int96 netFlowRateBefore = sf.cfa.getNetFlow(superToken_, newPIC);
        // this should be 0
        (, int96 togaToPicFlowRate,,) = sf.cfa.getFlow(superToken_, address(toga), newPIC);

        (address picBefore, uint256 picBondBefore,) = toga.getCurrentPICInfo(superToken_);

        vm.startPrank(newPIC);
        superToken_.send(address(toga), newBond, data);
        vm.stopPrank();

        int96 desiredExitRate;
        if (data.length > 0) {
            (desiredExitRate) = abi.decode(data, (int96));
        } else {
            // if no exit rate is sent in the send call, we use the default exit rate for the supertoken based on the
            // newBond amount
            desiredExitRate = toga.getDefaultExitRateFor(superToken_, newBond);
        }

        // Assert PIC, Bond and Exit Rate are set correctly after a succesful send
        {
            (address pic, uint256 picBond, int96 picExitRate) = toga.getCurrentPICInfo(superToken_);
            assertEq(newPIC, pic, "_helperSendPICBid: PIC not equal");
            newBond = picBefore == address(0) && balanceOfTogaBefore > 0
                // if there was no pic before and there was balance in the TOGA contract
                // the new PIC gets the bond + existing balance
                ? balanceOfTogaBefore + newBond
                : picBefore == newPIC
                    // if it is the same pic sending tokens, they are just increasing the bond by newBond amount
                    ? newBond + picBondBefore
                    // otherwise, in the outbidding scenario, the new bond amount is set as is
                    : newBond;
            assertEq(newBond, picBond, "_helperSendPICBid: PIC bond not equal");
            assertEq(desiredExitRate, picExitRate, "_helperSendPICBid: PIC exit rate not equal");
        }

        // Assert Net Flow Rate of newPIC is correct after a succesful send
        {
            int96 netFlowRateAfter = sf.cfa.getNetFlow(superToken_, newPIC);
            int96 flowRateDelta = desiredExitRate - togaToPicFlowRate;
            assertEq(netFlowRateAfter, netFlowRateBefore + flowRateDelta, "_helperChangeExitRate: net flow not equal");
        }
    }

    function _helperChangeExitRate(ISuperToken superToken_, address pic, int96 newExitRate) internal {
        int96 netFlowRateBefore = sf.cfa.getNetFlow(superToken_, pic);
        (, int96 togaToPicFlowRate,,) = sf.cfa.getFlow(superToken_, address(toga), pic);
        int96 flowRateDelta = newExitRate - togaToPicFlowRate;

        vm.startPrank(pic);
        toga.changeExitRate(superToken, newExitRate);
        vm.stopPrank();

        int96 netFlowRateAfter = sf.cfa.getNetFlow(superToken_, pic);
        assertEq(netFlowRateAfter, netFlowRateBefore + flowRateDelta, "_helperChangeExitRate: net flow not equal");

        (,, int96 exitRate) = toga.getCurrentPICInfo(superToken_);
        assertEq(exitRate, newExitRate, "_helperChangeExitRate: exit rate not equal");
    }

    function _boundBondValue(uint256 bond_) internal view returns (uint256 bond) {
        // User only has 64 bits test super tokens
        bond = bound(bond_, 1, INIT_SUPER_TOKEN_BALANCE);
    }

    function _boundBondValue(uint256 bond_, uint256 gtValue, uint256 ltValue) internal view returns (uint256 bond) {
        bond = bound(bond_, gtValue, ltValue);
    }

    // test

    /**
     * @dev Tests the contract setup.
     */
    function testContractSetup() public {
        assertEq(toga.minBondDuration(), MIN_BOND_DURATION, "minBondDuration");
    }

    function testNoPICExistsInitially() public {
        assertEq(
            address(0), toga.getCurrentPIC(superToken), "testNoPICExistsInitially: current PIC should be address(0)"
        );
    }

    /**
     * @dev Tests that Alice becomes the PIC.
     */
    function testAliceBecomesPIC(uint256 bond_, int96 exitRate) public {
        bond_ = _boundBondValue(bond_);

        // with small bonds, opening the stream can fail due to CFA deposit having a flow of 1<<32 due to clipping
        vm.assume(bond_ > 1 << 32 || exitRate == 0);

        vm.assume(exitRate >= 0);
        // satisfy exitRate constraints of the TOGA
        vm.assume(exitRate <= toga.getMaxExitRateFor(superToken, bond_));
        // the clipped CFA deposit needs to fit into 64 bits - since that is flowrate multiplied by
        // liquidation period, 14 bits are added for 14400 seconds, so we can't use the full 96 bits
        vm.assume(exitRate <= (type(int96).max) >> 14);

        vm.expectEmit(true, true, true, true, address(toga));
        emit NewPIC(superToken, alice, bond_, exitRate);

        _helperSendPICBid(alice, superToken, bond_, exitRate);
    }

    /**
     * @dev Tests that Bob can outbid Alice with a higher bond.
     */
    function testBobOutBidsAlice(uint256 bobBond, uint256 aliceBond) public {
        bobBond = _boundBondValue(bobBond);
        aliceBond = _boundBondValue(aliceBond);
        vm.assume(bobBond > aliceBond);

        // Send PIC bid from Alice
        _helperSendPICBid(alice, superToken, aliceBond, 0);

        // Assert Alice is the current PIC
        assertEq(toga.getCurrentPIC(superToken), alice);

        // Get the bond amount
        (, uint256 bond,) = toga.getCurrentPICInfo(superToken);
        assertEq(bond, aliceBond);

        vm.expectEmit(true, true, true, true, address(toga));
        emit NewPIC(superToken, bob, bobBond, 0);

        _helperSendPICBid(bob, superToken, bobBond, 0);
    }

    function testTOGARegisteredWithERC1820() public {
        address implementer1 = _ERC1820_REG.getInterfaceImplementer(address(toga), keccak256("TOGAv1"));
        address implementer2 = _ERC1820_REG.getInterfaceImplementer(address(toga), keccak256("TOGAv2"));

        assertEq(implementer1, address(toga), "testTOGARegisteredWithERC1820: TOGA should be registered as TOGAv1");
        assertEq(implementer2, address(toga), "testTOGARegisteredWithERC1820: TOGA should be registered as TOGAv2");
    }

    function testRevertIfNegativeExitRateIsRequested() public {
        // lower limit: 0 wei/second (no negative value allowed)
        vm.expectRevert("TOGA: negative exitRate not allowed");
        vm.startPrank(alice);
        superToken.send(address(toga), BOND_AMOUNT_1E18, abi.encode(-1));
        vm.stopPrank();
    }

    function testRevertIfBondIsEmpty() public {
        // this assumes the flow deletion was not triggered by the PIC - otherwise rewards would be accrued
        (address pic, uint256 bond,) = toga.getCurrentPICInfo(superToken);
        assertEq(bond, 0);

        // alice tries to re-establish stream - fail because no bond left
        vm.startPrank(pic);
        int96 exitRate = toga.getDefaultExitRateFor(superToken, MIN_BOND_DURATION * 4);
        vm.expectRevert("TOGA: exitRate too high");
        toga.changeExitRate(superToken, exitRate);
        vm.stopPrank();
    }

    function testRevertIfBidSmallerThanCurrentPICBond(uint256 bond, uint256 smallerBond) public {
        bond = _boundBondValue(bond);
        smallerBond = _boundBondValue(smallerBond, 0, bond);
        _helperSendPICBid(alice, superToken, bond, 0);

        vm.startPrank(bob);
        vm.expectRevert("TOGA: bid too low");
        superToken.send(address(toga), smallerBond, abi.encode(0));
        vm.stopPrank();
    }

    function testRevertIfExitRateTooHigh(uint256 bond, int96 exitRate) public {
        bond = _boundBondValue(bond);

        // with small bonds, opening the stream can fail due to CFA deposit having a flow of 1<<32 due to clipping
        vm.assume(bond > 1 << 32 || exitRate == 0);
        vm.assume(exitRate >= 0);
        // satisfy maxExitRate constraints of the TOGA
        vm.assume(exitRate == toga.getMaxExitRateFor(superToken, bond));

        // upper limit: 1 wei/second
        int96 highExitRate = toga.getMaxExitRateFor(superToken, BOND_AMOUNT_1E18) + 1;
        vm.startPrank(alice);
        vm.expectRevert("TOGA: exitRate too high");
        superToken.send(address(toga), BOND_AMOUNT_1E18, abi.encode(highExitRate));
        vm.stopPrank();
    }

    function testRevertIfNonPICTriesToChangeExitRate(int96 exitRate) public {
        vm.expectRevert("TOGA: only PIC allowed");
        toga.changeExitRate(superToken, exitRate);
    }

    function testMaxExitRateForGreaterThanOrEqualToDefaultExitRate(uint256 bond) public {
        bond = _boundBondValue(bond);

        // the max exit rate needs to be greater or equal than default exit rate
        assertGe(toga.getMaxExitRateFor(superToken, bond), toga.getDefaultExitRateFor(superToken, bond));
    }

    function testUseDefaultExitRateAsFallbackIfNoExitRateSpecified(uint256 bond) public {
        bond = _boundBondValue(bond);
        vm.assume(bond > 1 << 32);

        _helperSendPICBid(alice, superToken, bond, abi.encode());
    }

    function testFirstBidderGetsTokensPreOwnedByContract(uint256 bond, uint256 outBidBond) public {
        bond = bound(bond, 1 << 32, INIT_SUPER_TOKEN_BALANCE / 2);

        deal(address(superToken), address(toga), 1e6);

        uint256 togaPrelimBal = superToken.balanceOf(address(toga));
        _helperSendPICBid(alice, superToken, bond, 0);
        (, uint256 aliceBond,) = toga.getCurrentPICInfo(superToken);

        // the tokens previously collected in the contract are attributed to Alice's bond
        assertEq(aliceBond, (togaPrelimBal + bond));

        vm.assume(outBidBond > aliceBond);
        vm.assume(outBidBond > 1 << 32);
        vm.assume(outBidBond < INIT_SUPER_TOKEN_BALANCE); // User only has 64 bits test super tokens

        uint256 alicePreOutbidBal = superToken.balanceOf(alice);
        _helperSendPICBid(bob, superToken, outBidBond, 0);

        // the tokens previously collected are paid out to Alice if outbid
        assertEq(superToken.balanceOf(alice), (alicePreOutbidBal + aliceBond));
    }

    function testCurrentPICCanIncreaseBond(uint256 bond, uint256 increaseBond) public {
        bond = bound(bond, 1 << 32, INIT_SUPER_TOKEN_BALANCE / 2);

        _helperSendPICBid(alice, superToken, bond, 0);
        uint256 aliceIntermediateBal = superToken.balanceOf(alice);
        vm.assume(increaseBond > 0);
        vm.assume(increaseBond < aliceIntermediateBal);
        vm.assume(increaseBond > 1 << 32);

        vm.expectEmit(true, true, false, false, address(toga));
        emit BondIncreased(superToken, increaseBond);

        _helperSendPICBid(alice, superToken, increaseBond, 0);

        assertEq(superToken.balanceOf(alice), (aliceIntermediateBal - increaseBond));
    }

    function testPICCanChangeExitRate(int96 exitRate, int96 changeExitRate) public {
        uint256 bond = 1 ether;

        vm.assume(exitRate >= 0);
        // satisfy maxExitRate constraints of the TOGA
        vm.assume(exitRate <= toga.getMaxExitRateFor(superToken, bond));

        vm.assume(changeExitRate >= 0);
        vm.assume(changeExitRate <= toga.getMaxExitRateFor(superToken, bond));

        _helperSendPICBid(alice, superToken, bond, abi.encode());

        vm.expectEmit(true, true, false, false, address(toga));
        emit ExitRateChanged(superToken, changeExitRate);

        _helperChangeExitRate(superToken, alice, changeExitRate);
    }

    function testPICClosesSteam(uint256 bond) public {
        bond = _boundBondValue(bond);
        vm.assume(bond > 1 << 32);

        _helperSendPICBid(alice, superToken, bond, EXIT_RATE_1E3);

        vm.warp(block.timestamp + 1000);
        _helperDeleteFlow(superToken, alice, address(toga), alice);
        _assertNetFlow(superToken, alice, 0);

        _helperChangeExitRate(superToken, alice, 0);
        _helperChangeExitRate(superToken, alice, EXIT_RATE_1);

        // stop again and let bob make a bid
        vm.warp(block.timestamp + 1000);
        _helperDeleteFlow(superToken, alice, address(toga), alice);
        _assertNetFlow(superToken, alice, 0);

        _helperSendPICBid(bob, superToken, bond, EXIT_RATE_1E3);
        _assertNetFlow(superToken, alice, 0);
    }

    function testCollectedRewardsAreAddedToThePICBond(uint256 bond, uint256 rewards) public {
        bond = _boundBondValue(bond);
        vm.assume(bond > 1 << 32);
        vm.assume(rewards > 0);
        vm.assume(rewards < INIT_SUPER_TOKEN_BALANCE);

        _helperSendPICBid(alice, superToken, bond, 0);

        vm.startPrank(admin);
        superToken.transfer(address(toga), rewards);
        vm.stopPrank();

        (, uint256 picBond,) = toga.getCurrentPICInfo(superToken);
        assertEq(picBond, bond + rewards);
    }

    function testBondIsConsumedByExitFlow(uint256 aliceBond) public {
        aliceBond = bound(aliceBond, 1 << 32, INIT_SUPER_TOKEN_BALANCE / 2);

        int96 maxRate = toga.getMaxExitRateFor(superToken, aliceBond);
        _helperSendPICBid(alice, superToken, aliceBond, maxRate);

        // critical stream is liquidated - remaining bond goes to zero
        vm.warp(block.timestamp + 1e6);

        // A sentinel would do this
        vm.startPrank(admin);
        superToken.deleteFlow(address(toga), alice);
        vm.stopPrank();

        _assertNetFlow(superToken, alice, 0);
        _assertNetFlow(superToken, address(toga), 0);

        // this assumes the flow deletion was not triggered by the PIC - otherwise rewards would be accrued
        (, uint256 bond,) = toga.getCurrentPICInfo(superToken);
        assertEq(bond, 0);

        deal(address(superToken), address(toga), 1e15);

        (, uint256 bond2,) = toga.getCurrentPICInfo(superToken);
        assertGe(bond2, 1e12);

        _helperChangeExitRate(superToken, alice, toga.getMaxExitRateFor(superToken, bond2));

        uint256 alicePreBal = superToken.balanceOf(alice);
        (, uint256 aliceBondLeft,) = toga.getCurrentPICInfo(superToken);

        // bob outbids
        _helperSendPICBid(bob, superToken, aliceBondLeft + 1, toga.getMaxExitRateFor(superToken, aliceBondLeft + 1));
        _assertNetFlow(superToken, alice, 0);

        assertEq((alicePreBal + aliceBondLeft), superToken.balanceOf(alice));
    }

    function testMultiplePICsInParallel(uint256 bond) public {
        bond = _boundBondValue(bond);
        vm.assume(bond > 1 << 32);

        (, ISuperToken superToken2) = sfDeployer.deployWrapperSuperToken("TEST2", "TEST2", 18, type(uint256).max);

        deal(address(superToken2), alice, INIT_SUPER_TOKEN_BALANCE);
        deal(address(superToken2), bob, INIT_SUPER_TOKEN_BALANCE);

        _helperSendPICBid(alice, superToken, bond, toga.getDefaultExitRateFor(superToken, bond));
        _helperSendPICBid(bob, superToken2, bond, toga.getDefaultExitRateFor(superToken, bond));

        // let this run for a while...
        vm.warp(block.timestamp + 1e6);

        // alice takes over superToken2
        uint256 bobPreBal = superToken2.balanceOf(bob);
        (, uint256 bobBondLeft,) = toga.getCurrentPICInfo(superToken2);

        _helperSendPICBid(alice, superToken2, bobBondLeft + 1, 0);

        assertEq((bobPreBal + bobBondLeft), superToken2.balanceOf(bob));
    }
}