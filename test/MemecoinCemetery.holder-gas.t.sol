// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemecoinCemetery} from "../src/MemecoinCemetery.sol";

/// @dev Models reads that iterate over many accounts, as reflection-token balance calculations do.
contract ExpensiveReadsToken {
    address private immutable _holder;
    uint256 private _balance = 1e6;
    bytes4 private _expensiveSelector = this.balanceOf.selector;
    uint256[256] private _entries;

    constructor(address holder) {
        _holder = holder;
        for (uint256 i; i < _entries.length; ++i) {
            _entries[i] = 1;
        }
    }

    function setExpensiveSelector(bytes4 selector) external {
        _expensiveSelector = selector;
    }

    function setBalance(uint256 balance) external {
        _balance = balance;
    }

    function totalSupply() external view returns (uint256) {
        return _read(1e24);
    }

    function decimals() external view returns (uint256) {
        return _read(6);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _read(account == _holder ? _balance : 0);
    }

    function symbol() external view returns (string memory) {
        return _read(1) == 1 ? "SLOW" : "OTHER";
    }

    /// @dev Reading all cold entries exceeds the old cap; tests assert behavior, not exact gas usage.
    function _read(uint256 value) private view returns (uint256) {
        if (msg.sig != _expensiveSelector) return value;
        uint256 sum;
        for (uint256 i; i < _entries.length; ++i) {
            sum += _entries[i];
        }
        return value + sum - _entries.length;
    }
}

contract HolderReadGasRegressionTest is Test {
    MemecoinCemetery private cemetery;
    ExpensiveReadsToken private token;
    address private constant HOLDER = address(0xBEEF);
    address private constant DIGGER = address(0xD166E2);

    function setUp() public {
        vm.warp(1_735_689_600);
        cemetery = new MemecoinCemetery();
        token = new ExpensiveReadsToken(HOLDER);
    }

    function test_expensiveBalanceCanSaveWake() public {
        _dig();
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Resurrected(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        assertEq(uint256(cemetery.graveOf(address(token)).state), uint256(MemecoinCemetery.State.Saved));
        assertEq(cemetery.graveOf(address(token)).saves, 1);
        assertEq(cemetery.cooldownEndsAt(address(token)), block.timestamp + 7 days);
    }

    function test_expensiveBalanceCanRiseAndPreservesBurial() public {
        _bury();
        bytes32 record = keccak256(abi.encode(cemetery.burialOf(address(token), 1)));
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Rose(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        assertEq(uint256(cemetery.graveOf(address(token)).state), uint256(MemecoinCemetery.State.Risen));
        assertEq(cemetery.graveOf(address(token)).rises, 1);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.cooldownEndsAt(address(token)), block.timestamp + 7 days);
        assertEq(keccak256(abi.encode(cemetery.burialOf(address(token), 1))), record);
    }

    function test_expensiveBalanceStillRejectsBelowThreshold() public {
        _dig();
        token.setBalance(1e6 - 1);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1e6));
        cemetery.itLives(address(token));
        assertEq(uint256(cemetery.graveOf(address(token)).state), uint256(MemecoinCemetery.State.Wake));
        vm.warp(cemetery.graveOf(address(token)).wakeEndsAt);
        cemetery.seal(address(token));
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1e6));
        cemetery.rise(address(token));
        assertEq(cemetery.graveCount(), 1);
    }

    function testFuzz_expensiveSupplyAndDecimalsCanDefend(bool useSupply, bool useRise) public {
        _dig();
        // Supply can become expensive after nomination; neither defensive path should impose the dig cap.
        token.setExpensiveSelector(useSupply ? token.totalSupply.selector : token.decimals.selector);
        if (useRise) {
            vm.warp(cemetery.graveOf(address(token)).wakeEndsAt);
            cemetery.seal(address(token));
            vm.prank(HOLDER);
            cemetery.rise(address(token));
        } else {
            vm.prank(HOLDER);
            cemetery.itLives(address(token));
        }
        assertEq(
            uint256(cemetery.graveOf(address(token)).state),
            uint256(useRise ? MemecoinCemetery.State.Risen : MemecoinCemetery.State.Saved)
        );
        assertEq(cemetery.graveCount(), 0);
    }

    function test_nominationSupplyStillHasFixedCap() public {
        token.setExpensiveSelector(token.totalSupply.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                MemecoinCemetery.TokenReadFailed.selector, address(token), token.totalSupply.selector
            )
        );
        cemetery.dig(address(token), 2);
        assertEq(uint256(cemetery.graveOf(address(token)).state), uint256(MemecoinCemetery.State.None));
    }

    function test_symbolStillHasFixedCapAndFallsBack() public {
        _dig();
        assertNotEq(vm.indexOf(cemetery.headstone(address(token)), ">SLOW</text>"), type(uint256).max);
        token.setExpensiveSelector(token.symbol.selector);
        string memory svg = cemetery.headstone(address(token));
        assertEq(vm.indexOf(svg, ">SLOW</text>"), type(uint256).max);
        assertNotEq(vm.indexOf(svg, ">0x"), type(uint256).max);
    }

    function _dig() private {
        vm.prank(DIGGER);
        cemetery.dig(address(token), 2);
    }

    function _bury() private {
        _dig();
        vm.warp(cemetery.graveOf(address(token)).wakeEndsAt);
        cemetery.seal(address(token));
        assertEq(cemetery.graveCount(), 1);
    }
}
