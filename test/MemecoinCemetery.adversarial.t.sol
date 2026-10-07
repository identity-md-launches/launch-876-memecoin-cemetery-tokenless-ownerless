// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemecoinCemetery} from "src/MemecoinCemetery.sol";
import {RawToken, MockToken} from "./MemecoinCemetery.t.sol";

contract MemecoinCemeteryAdversarialTest is Test {
    MemecoinCemetery internal cemetery;
    RawToken internal raw;
    bytes4 private constant SUPPLY = 0x18160ddd;
    bytes4 private constant BALANCE = 0x70a08231;
    bytes4 private constant DECIMALS = 0x313ce567;
    bytes4 private constant SYMBOL = 0x95d89b41;
    address private constant HOLDER = address(0xBEEF);

    function setUp() public {
        vm.warp(1_735_689_600);
        cemetery = new MemecoinCemetery();
        raw = new RawToken();
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        raw.setResponse(BALANCE, abi.encode(uint256(1 ether)));
        raw.setResponse(DECIMALS, abi.encode(uint256(18)));
        raw.setResponse(SYMBOL, abi.encode("RAW"));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_malformedMandatoryWordsRevertWithoutChangingHistory(
        uint8 sizeSeed,
        uint8 actionSeed,
        bool supplyRead
    ) public {
        uint256 action = actionSeed % 4;
        if (action != 0) cemetery.dig(address(raw), 23);
        if (action >= 2) {
            vm.warp(vm.getBlockTimestamp() + 72 hours);
            cemetery.seal(address(raw));
            cemetery.mourn(address(raw));
        }
        if (action == 3) {
            cemetery.rise(address(raw));
            vm.warp(vm.getBlockTimestamp() + 7 days);
        }
        bytes32 before_ = _snapshot();
        uint256 size = sizeSeed == 32 ? 33 : uint256(sizeSeed);
        bytes memory malformed = new bytes(size);
        for (uint256 i; i < size; ++i) {
            malformed[i] = 0xff;
        }
        bytes4 selector = action == 0 || action == 3 || supplyRead ? SUPPLY : BALANCE;
        raw.setResponse(selector, malformed);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), selector));
        if (action == 0 || action == 3) cemetery.dig(address(raw), 0);
        else if (action == 1) cemetery.itLives(address(raw));
        else cemetery.rise(address(raw));
        assertEq(_snapshot(), before_, "a failed read must leave the complete lifecycle and history unchanged");
    }

    function test_sealAndMournRemainAvailableWhenEveryTokenReadFails() public {
        cemetery.dig(address(raw), 9);
        raw.setMode(SUPPLY, 2);
        raw.setMode(BALANCE, 2);
        raw.setMode(DECIMALS, 2);
        raw.setMode(SYMBOL, 2);
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.prank(address(0xCAFE));
        cemetery.seal(address(raw));
        cemetery.mourn(address(raw));
        vm.prank(address(0xCAFE));
        cemetery.mourn(address(raw));
        assertEq(cemetery.graveCount(), 1);
        assertEq(cemetery.burialOf(address(raw), 1).mourners, 2);
        assertTrue(bytes(cemetery.headstone(address(raw))).length > 0);
        // Repairing the token makes holder defense available again without a new wake.
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        raw.setResponse(BALANCE, abi.encode(uint256(1 ether)));
        cemetery.rise(address(raw));
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.burialOf(address(raw), 1).mourners, 2);
    }

    function test_codeDisappearingAfterDigCannotBlockSealingOrMourning() public {
        cemetery.dig(address(raw), 0);
        vm.etch(address(raw), "");
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), SUPPLY));
        cemetery.itLives(address(raw));
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        cemetery.seal(address(raw));
        cemetery.mourn(address(raw));
        assertEq(cemetery.graveCount(), 1);
        assertEq(cemetery.burialOf(address(raw), 1).mourners, 1);
        assertTrue(bytes(cemetery.headstone(address(raw))).length > 0);
    }

    function test_gasExhaustionIsBoundedForEveryTokenSelector() public {
        raw.setMode(SUPPLY, 2); // INVALID consumes all gas forwarded to the token.
        _boundedFailure(abi.encodeCall(MemecoinCemetery.dig, (address(raw), 0)), SUPPLY);
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        cemetery.dig(address(raw), 0);
        raw.setMode(SUPPLY, 2);
        _boundedFailure(abi.encodeCall(MemecoinCemetery.itLives, (address(raw))), SUPPLY);
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        raw.setMode(BALANCE, 2);
        _boundedFailure(abi.encodeCall(MemecoinCemetery.itLives, (address(raw))), BALANCE);
        raw.setResponse(BALANCE, abi.encode(uint256(1 ether)));
        raw.setMode(SYMBOL, 2);
        (bool ok,) = _boundedCall(abi.encodeCall(MemecoinCemetery.headstone, (address(raw))));
        assertTrue(ok, "unreadable metadata must still render");
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        cemetery.seal(address(raw));
        raw.setMode(SUPPLY, 2);
        _boundedFailure(abi.encodeCall(MemecoinCemetery.rise, (address(raw))), SUPPLY);
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        raw.setMode(BALANCE, 2);
        _boundedFailure(abi.encodeCall(MemecoinCemetery.rise, (address(raw))), BALANCE);
        raw.setResponse(BALANCE, abi.encode(uint256(1 ether)));
        raw.setMode(DECIMALS, 2);
        (ok,) = _boundedCall(abi.encodeCall(MemecoinCemetery.rise, (address(raw))));
        assertTrue(ok, "decimals failure must fall back to 18 with bounded gas");
        assertEq(cemetery.graveOf(address(raw)).rises, 1);
    }

    function test_returnDataBombsHaveBoundedCostAndCannotCorruptState() public {
        raw.setMode(SUPPLY, 3); // Successful read returning 32 KiB, not an ABI word.
        _boundedFailure(abi.encodeCall(MemecoinCemetery.dig, (address(raw), 0)), SUPPLY);
        raw.setResponse(SUPPLY, abi.encode(uint256(1_000_000 ether)));
        cemetery.dig(address(raw), 0);
        raw.setMode(BALANCE, 3);
        _boundedFailure(abi.encodeCall(MemecoinCemetery.itLives, (address(raw))), BALANCE);
        raw.setResponse(BALANCE, abi.encode(uint256(1 ether)));
        raw.setMode(SYMBOL, 3);
        (bool ok,) = _boundedCall(abi.encodeCall(MemecoinCemetery.headstone, (address(raw))));
        assertTrue(ok);
        raw.setMode(DECIMALS, 3);
        (ok,) = _boundedCall(abi.encodeCall(MemecoinCemetery.itLives, (address(raw))));
        assertTrue(ok);
        assertEq(cemetery.graveOf(address(raw)).saves, 1);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.recentBurials(20).length, 0);
    }

    /// @dev Select values around the crossover explicitly; uniform uint256 supplies mostly
    /// exercise the whole-token cap and miss fractional thresholds and rounding.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_thresholdCrossoverAndFloor(uint8 decimalsSeed, uint16 offset, bool rising) public {
        uint256 decimals = decimalsSeed % 37;
        uint256 whole = 10 ** decimals;
        uint256 pivot = 1000 * whole;
        uint256 supply = pivot - 999 + uint256(offset) % 1999;
        uint256 fraction = supply / 1000;
        uint256 required = fraction < whole ? fraction : whole;
        if (required == 0) required = 1;
        MockToken token = new MockToken(decimals, supply, "CROSSOVER");
        cemetery.dig(address(token), 23);
        if (rising) {
            vm.warp(vm.getBlockTimestamp() + 72 hours);
            cemetery.seal(address(token));
        }
        token.setBalance(HOLDER, required - 1);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, required));
        if (rising) cemetery.rise(address(token));
        else cemetery.itLives(address(token));
        token.setBalance(HOLDER, required);
        vm.prank(HOLDER);
        if (rising) cemetery.rise(address(token));
        else cemetery.itLives(address(token));
        assertEq(
            uint256(cemetery.graveOf(address(token)).state),
            uint256(rising ? MemecoinCemetery.State.Risen : MemecoinCemetery.State.Saved)
        );
    }

    function test_currentDecimalsAndExactCallerBalanceDetermineHolderStatus() public {
        MockToken token = new MockToken(18, 1_000_000 ether, "CHANGING");
        token.setBalance(HOLDER, 1 ether);
        cemetery.dig(address(token), 0);
        token.setDecimals(36, false); // Threshold is now supply/1000 = 1000 ether.
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1000 ether));
        cemetery.itLives(address(token));
        token.setDecimals(6, false);
        token.setBalance(HOLDER, 1e6);
        // Having an eligible tx.origin does not give an empty intermediary a holder veto.
        vm.prank(address(0xCAFE), HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, address(0xCAFE), 1e6));
        cemetery.itLives(address(token));
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        assertEq(cemetery.graveOf(address(token)).saves, 1);
    }

    function _boundedFailure(bytes memory callData, bytes4 selector) private {
        bytes32 before_ = _snapshot();
        (bool ok, bytes memory result) = _boundedCall(callData);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), selector));
        assertEq(_snapshot(), before_);
    }

    function _boundedCall(bytes memory callData) private returns (bool ok, bytes memory result) {
        uint256 before_ = gasleft();
        (ok, result) = address(cemetery).call{gas: 1_000_000}(callData);
        uint256 used = before_ - gasleft();
        // A generous ceiling avoids pinning normal execution costs while detecting a read
        // that forwards almost all of the million-gas outer budget to an exceptional halt.
        assertLt(used, 400_000, "hostile token consumed the caller's gas budget");
    }

    function _snapshot() private view returns (bytes32) {
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(raw));
        bytes memory records;
        for (uint256 n = 1; n <= g.burials; ++n) {
            records = bytes.concat(records, abi.encode(cemetery.burialOf(address(raw), n)));
        }
        return keccak256(
            abi.encode(
                g, cemetery.graveCount(), cemetery.cooldownEndsAt(address(raw)), cemetery.recentBurials(20), records
            )
        );
    }
}
