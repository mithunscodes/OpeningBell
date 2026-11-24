// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { DemoStage } from "../src/origin/DemoStage.sol";

contract DemoStageTest is Test {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MarketFeed internal feed;
    DemoStage internal stage;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MarketFeed();
        stage = new DemoStage(feed, NVDA, 10, 3);
        feed.setPublisher(address(stage), true);
    }

    function _market() internal view returns (uint8 status, uint64 seq, uint256 price) {
        (status, seq,, price) = feed.markets(NVDA);
    }

    function test_FirstActionStartsAtTheResetPrice() public {
        vm.prank(alice);
        stage.open(500);

        (uint8 status, uint64 seq, uint256 price) = _market();
        assertEq(status, MarketTypes.OPEN);
        assertEq(seq, 1);
        assertEq(price, 140e18);
    }

    function test_ButtonsMoveTheMarket() public {
        stage.open(0);
        stage.halt();
        (uint8 status,, uint256 price) = _market();
        assertEq(status, MarketTypes.HALTED);
        assertEq(price, 140e18, "a halt does not move the price");

        stage.open(-1_000);
        (status,, price) = _market();
        assertEq(status, MarketTypes.OPEN);
        assertEq(price, 126e18, "reopened 10% lower");

        stage.close();
        (status,, price) = _market();
        assertEq(status, MarketTypes.CLOSED);
        assertEq(price, 126e18);

        stage.act(MarketTypes.OPEN, 2_000);
        (,, price) = _market();
        assertEq(price, 151.2e18);
    }

    function test_PublicActionsShareOneCooldown() public {
        vm.prank(alice);
        stage.halt();

        vm.expectRevert(abi.encodeWithSelector(DemoStage.CoolingDown.selector, block.timestamp + 10));
        vm.prank(bob);
        stage.open(0);

        skip(10);
        vm.prank(bob);
        stage.open(0);
    }

    function test_DailyCapResetsAtMidnight() public {
        for (uint256 i = 0; i != 3; ++i) {
            vm.prank(alice);
            stage.halt();
            skip(10);
        }

        (, uint256 left) = stage.availability();
        assertEq(left, 0);

        vm.expectRevert(DemoStage.DailyCapReached.selector);
        vm.prank(alice);
        stage.halt();

        skip(1 days);
        (, left) = stage.availability();
        assertEq(left, 3);
        vm.prank(alice);
        stage.halt();
    }

    function test_OwnerIsNotLimitedAndCanPause() public {
        for (uint256 i = 0; i != 10; ++i) {
            stage.halt();
        }

        stage.setLimits(10, 3, true);
        skip(10);
        vm.expectRevert(DemoStage.Paused.selector);
        vm.prank(alice);
        stage.halt();

        vm.expectRevert(DemoStage.NotOwner.selector);
        vm.prank(alice);
        stage.setLimits(0, 1000, false);
    }

    function test_MovesAreCapped() public {
        vm.expectRevert(DemoStage.MoveTooLarge.selector);
        stage.open(2_001);
        vm.expectRevert(DemoStage.MoveTooLarge.selector);
        stage.open(-2_001);
    }

    function test_ThePriceSnapsBackWhenItLeavesTheCorridor() public {
        stage.open(0); // 140
        for (uint256 i = 0; i != 10; ++i) {
            stage.open(2_000);
        }
        (,, uint256 price) = _market();
        assertEq(price, 866.843099136e18, "ten rises of 20% stay inside");
        stage.open(2_000); // 1,040.21 would be outside
        (,, price) = _market();
        assertEq(price, 140e18, "the eleventh snaps back");

        for (uint256 i = 0; i != 8; ++i) {
            stage.open(-2_000);
        }
        (,, price) = _market();
        assertEq(price, 23.4881024e18, "eight falls of 20% stay inside");
        stage.open(-2_000); // 18.79 would be outside
        (,, price) = _market();
        assertEq(price, 140e18, "the ninth snaps back");
    }

    function test_AvailabilityCountsDownAndFollowsNewLimits() public {
        (uint256 readyAt, uint256 left) = stage.availability();
        assertEq(readyAt, 10, "never used");
        assertEq(left, 3);

        vm.prank(alice);
        stage.halt();
        (readyAt, left) = stage.availability();
        assertEq(readyAt, block.timestamp + 10);
        assertEq(left, 2);

        skip(10);
        vm.prank(bob);
        stage.halt();

        // The owner lowers the cap below what was already used today.
        stage.setLimits(20, 1, false);
        assertEq(stage.cooldown(), 20);
        assertEq(stage.dailyCap(), 1);
        (readyAt, left) = stage.availability();
        assertEq(readyAt, block.timestamp + 20, "the new cooldown counts at once");
        assertEq(left, 0, "over the cap is none left, not an underflow");

        skip(20);
        vm.expectRevert(DemoStage.DailyCapReached.selector);
        vm.prank(alice);
        stage.halt();
    }

    function test_EveryActionAndLimitChangeIsAnnounced() public {
        vm.expectEmit(true, false, false, true, address(stage));
        emit DemoStage.Staged(alice, MarketTypes.OPEN, 500, 140e18, 1);
        vm.prank(alice);
        stage.open(500);
        (,, uint64 sourceTime,) = feed.markets(NVDA);
        assertEq(sourceTime, block.timestamp, "stamped with the time of the press");

        vm.expectEmit(false, false, false, true, address(stage));
        emit DemoStage.LimitsSet(15, 100, true);
        stage.setLimits(15, 100, true);
        assertTrue(stage.paused());
    }

    function testFuzz_PriceStaysInsideTheCorridor(int16[20] memory moves) public {
        for (uint256 i = 0; i != moves.length; ++i) {
            int16 move = int16(bound(moves[i], -2_000, 2_000));
            stage.act(uint8(i % 3), move);
            (,, uint256 price) = _market();
            assertGe(price, stage.MIN_PRICE());
            assertLe(price, stage.MAX_PRICE());
        }
    }
}
