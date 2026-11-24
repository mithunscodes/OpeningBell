// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { DemoStage } from "../src/origin/DemoStage.sol";
import { MockToken } from "../src/venue/MockToken.sol";

/// @notice The play-money token: plain ERC-20 rules, minting only by authorised minters.
contract MockTokenTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockToken internal token;

    function setUp() public {
        token = new MockToken("Stock", "STK");
        token.mint(alice, 100e18);
    }

    function test_ApproveThenTransferFromSpendsTheAllowance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, 40e18));
        assertEq(token.allowance(alice, bob), 40e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 30e18));
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(carol), 30e18);
        assertEq(token.allowance(alice, bob), 10e18, "allowance spent");
    }

    function test_AnUnlimitedAllowanceIsNeverSpent() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 60e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_TransfersNeedBalanceAndAllowance() public {
        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(MockToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 11e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(MockToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 101e18);

        vm.prank(carol);
        vm.expectRevert(MockToken.InsufficientBalance.selector);
        token.transfer(alice, 1);
    }

    function test_BurnRemovesSupply() public {
        vm.prank(alice);
        token.burn(25e18);
        assertEq(token.balanceOf(alice), 75e18);
        assertEq(token.totalSupply(), 75e18);

        vm.prank(alice);
        vm.expectRevert(MockToken.InsufficientBalance.selector);
        token.burn(76e18);
    }

    function test_OnlyTheOwnerManagesMinters() public {
        vm.startPrank(bob);
        vm.expectRevert(MockToken.NotMinter.selector);
        token.mint(bob, 1);
        vm.expectRevert(MockToken.NotOwner.selector);
        token.setMinter(bob, true);
        vm.expectRevert(MockToken.NotOwner.selector);
        token.transferOwnership(bob);
        vm.stopPrank();

        token.transferOwnership(bob);
        vm.expectRevert(MockToken.NotOwner.selector);
        token.setMinter(carol, true);

        vm.prank(bob);
        token.setMinter(carol, true);
        vm.prank(carol);
        token.mint(carol, 5e18);
        assertEq(token.balanceOf(carol), 5e18);
    }
}

/// @notice The feed refuses input that the rest of the system could misread.
contract MarketFeedRulesTest is Test {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    address internal publisher = makeAddr("publisher");
    address internal stranger = makeAddr("stranger");

    MarketFeed internal feed;

    function setUp() public {
        feed = new MarketFeed();
        feed.setPublisher(publisher, true);
    }

    function test_UnknownStatusAndZeroPriceAreRefused() public {
        vm.startPrank(publisher);
        vm.expectRevert(abi.encodeWithSelector(MarketFeed.BadStatus.selector, uint8(3)));
        feed.publish(NVDA, 3, 140e18, 0);
        vm.expectRevert(MarketFeed.BadPrice.selector);
        feed.publish(NVDA, MarketTypes.OPEN, 0, 0);
        vm.stopPrank();
    }

    function test_OwnershipCanMoveAndOnlyTheOwnerAppointsPublishers() public {
        vm.startPrank(stranger);
        vm.expectRevert(MarketFeed.NotOwner.selector);
        feed.setPublisher(stranger, true);
        vm.expectRevert(MarketFeed.NotOwner.selector);
        feed.transferOwnership(stranger);
        vm.stopPrank();

        feed.transferOwnership(stranger);
        assertEq(feed.owner(), stranger);
        vm.expectRevert(MarketFeed.NotOwner.selector);
        feed.setPublisher(address(this), true);
    }

    function test_TheFeedKeepsEveryFieldAndAnnouncesEveryChange() public {
        vm.expectEmit(true, true, false, false);
        emit MarketFeed.OwnershipTransferred(address(0), address(this));
        MarketFeed fresh = new MarketFeed();

        vm.expectEmit(true, false, false, true, address(fresh));
        emit MarketFeed.PublisherSet(publisher, true);
        fresh.setPublisher(publisher, true);

        vm.prank(publisher);
        fresh.publish(NVDA, MarketTypes.OPEN, 140e18, 1_795_000_000);
        (uint8 status, uint64 seq, uint64 sourceTime, uint256 price) = fresh.markets(NVDA);
        assertEq(status, MarketTypes.OPEN);
        assertEq(seq, 1);
        assertEq(sourceTime, 1_795_000_000, "the time at the source is kept");
        assertEq(price, 140e18);

        vm.expectEmit(true, true, false, false, address(fresh));
        emit MarketFeed.OwnershipTransferred(address(this), stranger);
        fresh.transferOwnership(stranger);
    }
}

/// @notice Owner controls of the public buttons.
contract DemoStageOwnerTest is Test {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    address internal stranger = makeAddr("stranger");

    MarketFeed internal feed;
    DemoStage internal stage;

    function setUp() public {
        feed = new MarketFeed();
        stage = new DemoStage(feed, NVDA, 10, 3);
        feed.setPublisher(address(stage), true);
    }

    function test_OwnershipCanMove() public {
        vm.prank(stranger);
        vm.expectRevert(DemoStage.NotOwner.selector);
        stage.transferOwnership(stranger);

        stage.transferOwnership(stranger);
        assertEq(stage.owner(), stranger);
        vm.expectRevert(DemoStage.NotOwner.selector);
        stage.setLimits(0, 0, true);
    }
}
