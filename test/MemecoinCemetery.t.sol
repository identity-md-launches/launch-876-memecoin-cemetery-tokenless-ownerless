// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemecoinCemetery} from "../src/MemecoinCemetery.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract TokenWithoutSymbol {
    uint256 public totalSupply;
    uint256 private _decimals;
    mapping(address => uint256) public balanceOf;
    bool public decimalsRevert;

    constructor(uint256 decimals_, uint256 supply_) {
        _decimals = decimals_;
        totalSupply = supply_;
    }

    function decimals() external view returns (uint256) {
        require(!decimalsRevert, "no decimals");
        return _decimals;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setSupply(uint256 supply) external {
        totalSupply = supply;
    }

    function setDecimals(uint256 value, bool shouldRevert) external {
        _decimals = value;
        decimalsRevert = shouldRevert;
    }
}

contract MockToken is TokenWithoutSymbol {
    string public symbol;

    constructor(uint256 decimals_, uint256 supply_, string memory symbol_) TokenWithoutSymbol(decimals_, supply_) {
        symbol = symbol_;
    }
}

contract RevertingToken {
    fallback() external {
        revert("unreadable");
    }
}

/// @dev Provides deliberately invalid ABI encodings, revert data, and gas/return-data bombs.
contract RawToken {
    mapping(bytes4 => bytes) private _responses;
    mapping(bytes4 => uint8) private _modes;

    function setResponse(bytes4 selector, bytes memory response) external {
        _responses[selector] = response;
        _modes[selector] = 0;
    }

    function setMode(bytes4 selector, uint8 mode) external {
        _modes[selector] = mode;
    }

    fallback() external {
        uint8 mode = _modes[msg.sig];
        if (mode == 1) revert("read failed");
        if (mode == 2) {
            assembly {
                invalid()
            }
        }
        if (mode == 3) {
            assembly {
                return(0, 32768)
            }
        }
        bytes memory response = _responses[msg.sig];
        assembly ("memory-safe") {
            return(add(response, 32), mload(response))
        }
    }
}

contract ReentrantSymbolToken is TokenWithoutSymbol {
    MemecoinCemetery private immutable _cemetery;

    constructor(MemecoinCemetery cemetery) TokenWithoutSymbol(18, 1000 ether) {
        _cemetery = cemetery;
    }

    function symbol() external returns (string memory) {
        // Called under STATICCALL: an attempted state write anywhere in the callback tree must fail.
        (bool ok,) = address(_cemetery).call(abi.encodeCall(MemecoinCemetery.mourn, (address(this))));
        require(!ok, "callback unexpectedly mutated state");
        return "STATIC";
    }
}

/// @dev Exposes pure rendering helpers for independent calendar and XML checks.
contract RenderingHarness is MemecoinCemetery {
    function date(uint256 timestamp) external pure returns (string memory) {
        return _date(timestamp);
    }

    function escape(bytes memory value) external pure returns (string memory) {
        return _escapeXML(value);
    }
}

contract MemecoinCemeteryTest is Test {
    MemecoinCemetery internal cemetery;
    MockToken internal token;
    address internal constant DIGGER = address(0xD166E2);
    address internal constant HOLDER = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);
    uint256 internal constant START = 1_709_164_800; // 2024-02-29 00:00:00 UTC
    bytes4 internal constant SUPPLY = 0x18160ddd;
    bytes4 internal constant BALANCE = 0x70a08231;
    bytes4 internal constant DECIMALS = 0x313ce567;
    bytes4 internal constant SYMBOL = 0x95d89b41;

    function setUp() public {
        vm.warp(START);
        cemetery = new MemecoinCemetery();
        token = new MockToken(18, 1_000_000 ether, "DEAD");
        token.setBalance(HOLDER, 1 ether);
    }

    function test_initialStateAndUnknownQueries() public {
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(uint256(g.state), uint256(MemecoinCemetery.State.None));
        assertEq(g.digger, address(0));
        assertEq(g.burials + g.rises + g.saves + g.mourners + g.dugAt + g.sealedAt + g.wakeEndsAt, 0);
        assertEq(cemetery.cooldownEndsAt(address(token)), 0);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.recentBurials(type(uint256).max).length, 0);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NeverDug.selector, address(token)));
        cemetery.headstone(address(token));
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.UnknownBurial.selector, address(token), 0));
        cemetery.burialOf(address(token), 0);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.UnknownBurial.selector, address(token), 1));
        cemetery.burialOf(address(token), 1);
    }

    function test_digOpensWakeAndEmits() public {
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.WakeOpened(address(token), DIGGER, 23, START + 72 hours);
        vm.prank(DIGGER);
        cemetery.dig(address(token), 23);
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(uint256(g.state), uint256(MemecoinCemetery.State.Wake));
        assertEq(g.digger, DIGGER);
        assertEq(g.epitaphId, 23);
        assertEq(g.dugAt, START);
        assertEq(g.wakeEndsAt, START + 72 hours);
        assertEq(g.sealedAt + g.burials + g.rises + g.saves + g.mourners, 0);
        assertEq(cemetery.graveCount(), 0);
    }

    function test_all24EpitaphsAreExact() public view {
        string[24] memory expected = [
            "Here lies a 1000x that never was",
            "Down only. Rest easy.",
            "LP pulled, soul released",
            "Died as it lived: illiquid",
            "Gone but not forgotten (mostly forgotten)",
            "Number go down",
            "It was never about the tech",
            "Community takeover pending since forever",
            "Wen moon? Never.",
            "Ser, this is a graveyard",
            "Bought the top so you did not have to",
            "Roadmap: complete. Token: deceased.",
            "Diamond hands, paper chart",
            "Last seen in a Telegram with 3 members",
            "Fair launch, unfair ending",
            "The dev is still typing...",
            "Not financial advice. Not financial anything.",
            "Ran out of greater fools",
            "Locked liquidity, lost hope",
            "It had a great logo",
            "Few understood. Fewer bought.",
            "Rug in peace",
            "Still waiting for the CEX listing",
            "Holders: 1 (the deployer)"
        ];
        for (uint8 i; i < 24; ++i) {
            assertEq(cemetery.epitaph(i), expected[i]);
        }
    }

    function test_invalidEpitaph24And255() public {
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidEpitaph.selector, 24));
        cemetery.dig(address(token), 24);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidEpitaph.selector, 24));
        cemetery.epitaph(24);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidEpitaph.selector, 255));
        cemetery.epitaph(255);
    }

    function test_rejectsEOAZeroAddressAndZeroSupply() public {
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidToken.selector, OTHER));
        cemetery.dig(OTHER, 0);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidToken.selector, address(0)));
        cemetery.dig(address(0), 0);
        token.setSupply(0);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.InvalidToken.selector, address(token)));
        cemetery.dig(address(token), 0);
    }

    function test_rejectsRevertingMalformedAndGasBombSupplies() public {
        RevertingToken revertingToken = new RevertingToken();
        vm.expectRevert(
            abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(revertingToken), SUPPLY)
        );
        cemetery.dig(address(revertingToken), 0);
        RawToken raw = new RawToken();
        _badSupply(raw);
        raw.setResponse(SUPPLY, new bytes(31));
        _badSupply(raw);
        raw.setResponse(SUPPLY, abi.encode(uint256(1), uint256(2)));
        _badSupply(raw);
        raw.setMode(SUPPLY, 2);
        _badSupply(raw);
        raw.setMode(SUPPLY, 3);
        _badSupply(raw);
        assertEq(uint256(cemetery.graveOf(address(raw)).state), uint256(MemecoinCemetery.State.None));
        raw.setResponse(SUPPLY, abi.encode(uint256(1)));
        cemetery.dig(address(raw), 0);
    }

    function test_wakeBoundariesAndPermissionlessSeal() public {
        _dig(address(token), 7);
        uint256 ends = START + 72 hours;
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.WakeStillOpen.selector, ends));
        cemetery.seal(address(token));
        vm.warp(ends - 1);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.WakeStillOpen.selector, ends));
        cemetery.seal(address(token));
        vm.warp(ends);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.WakeClosed.selector, ends));
        cemetery.itLives(address(token));
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Buried(address(token), 7, DIGGER, ends);
        vm.prank(OTHER);
        cemetery.seal(address(token));
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(uint256(g.state), uint256(MemecoinCemetery.State.Buried));
        assertEq(g.sealedAt, ends);
        assertEq(g.burials, 1);
        assertEq(g.rises + g.saves + g.mourners, 0);
        assertEq(cemetery.graveCount(), 1);
        MemecoinCemetery.Burial memory b = cemetery.burialOf(address(token), 1);
        assertEq(b.digger, DIGGER);
        assertEq(b.epitaphId, 7);
        assertEq(b.dugAt, START);
        assertEq(b.sealedAt, ends);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.UnknownBurial.selector, address(token), 2));
        cemetery.burialOf(address(token), 2);
    }

    function test_lateSealUsesActualSealTime() public {
        _dig(address(token), 0);
        vm.warp(START + 100 days);
        cemetery.seal(address(token));
        assertEq(cemetery.graveOf(address(token)).sealedAt, START + 100 days);
    }

    function test_holderVetoAtLastSecondAndSavedCooldown() public {
        _dig(address(token), 23);
        vm.warp(START + 72 hours - 1);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Resurrected(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        uint256 ready = START + 72 hours - 1 + 7 days;
        assertEq(cemetery.cooldownEndsAt(address(token)), ready);
        assertEq(uint256(cemetery.graveOf(address(token)).state), uint256(MemecoinCemetery.State.Saved));
        assertEq(cemetery.graveOf(address(token)).saves, 1);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.recentBurials(20).length, 0);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.CooldownActive.selector, ready));
        cemetery.dig(address(token), 1);
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.CooldownActive.selector, ready));
        cemetery.dig(address(token), 1);
        vm.warp(ready);
        vm.prank(OTHER);
        cemetery.dig(address(token), 1);
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(g.saves, 1);
        assertEq(g.digger, OTHER);
        assertEq(g.dugAt, ready);
        assertEq(g.wakeEndsAt, ready + 72 hours);
        assertEq(g.sealedAt + g.mourners + g.burials, 0);
    }

    function test_risePreservesRecordAndHasCooldown() public {
        _bury(address(token), 12);
        cemetery.mourn(address(token));
        MemecoinCemetery.Burial memory original = cemetery.burialOf(address(token), 1);
        uint256 risenAt = block.timestamp;
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Rose(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(uint256(g.state), uint256(MemecoinCemetery.State.Risen));
        assertEq(g.rises, 1);
        assertEq(g.burials, 1);
        assertEq(g.mourners, 1);
        assertEq(g.sealedAt, original.sealedAt);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.recentBurials(1)[0], address(token));
        uint256 ready = risenAt + 7 days;
        assertEq(cemetery.cooldownEndsAt(address(token)), ready);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.CooldownActive.selector, ready));
        cemetery.dig(address(token), 13);
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.CooldownActive.selector, ready));
        cemetery.dig(address(token), 13);
        vm.warp(ready);
        _dig(address(token), 13);
        assertEq(cemetery.graveOf(address(token)).mourners, 0);
        assertEq(cemetery.graveOf(address(token)).sealedAt, 0);
        assertEq(cemetery.graveOf(address(token)).burials, 1);
        assertEq(cemetery.graveOf(address(token)).rises, 1);
        assertEq(keccak256(abi.encode(cemetery.burialOf(address(token), 1))), keccak256(abi.encode(original)));
    }

    function test_allInvalidStateTransitions() public {
        _assertInvalidActions(MemecoinCemetery.State.None);
        _dig(address(token), 0);
        _assertInvalidActions(MemecoinCemetery.State.Wake);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertInvalidActions(MemecoinCemetery.State.Saved);
        vm.warp(cemetery.cooldownEndsAt(address(token)));
        _bury(address(token), 0);
        _assertInvalidActions(MemecoinCemetery.State.Buried);
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        _assertInvalidActions(MemecoinCemetery.State.Risen);
    }

    function test_nonholderCannotVetoOrRise() public {
        _dig(address(token), 0);
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, OTHER, 1 ether));
        cemetery.itLives(address(token));
        vm.warp(START + 72 hours);
        cemetery.seal(address(token));
        token.setBalance(HOLDER, 1 ether - 1);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1 ether));
        cemetery.rise(address(token));
        assertEq(cemetery.graveCount(), 1);
    }

    function test_holderThresholdWholeTokenAndFraction18And6Decimals() public {
        _checkThreshold(18, 1_000_000 ether, 1 ether, false);
        _checkThreshold(18, 500 ether, 0.5 ether, false);
        _checkThreshold(6, 1_000_000e6, 1e6, false);
        _checkThreshold(6, 500e6, 500_000, false);
        _checkThreshold(18, 1_000_000 ether, 1 ether, true);
        _checkThreshold(18, 500 ether, 0.5 ether, true);
        _checkThreshold(6, 1_000_000e6, 1e6, true);
        _checkThreshold(6, 500e6, 500_000, true);
    }

    function test_holderThresholdFloorAndDecimalExtremes() public {
        _checkThreshold(18, 999, 1, false);
        _checkThreshold(6, 1, 1, false);
        _checkThreshold(18, 999, 1, true);
        _checkThreshold(6, 1, 1, true);
        _checkThreshold(0, 1_000_000, 1, false);
        _checkThreshold(36, type(uint256).max, 1e36, true);
        _checkThreshold(37, type(uint256).max, 1 ether, false);
        _checkThreshold(type(uint256).max, type(uint256).max, 1 ether, true);
        _checkThreshold(18, 1000 ether, 1 ether, false);
        _checkThreshold(18, 1001, 1, false);
    }

    function test_decimalsRevertDefaultsTo18() public {
        token.setDecimals(6, true);
        _dig(address(token), 0);
        token.setBalance(HOLDER, 1 ether - 1);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1 ether));
        cemetery.itLives(address(token));
        token.setBalance(HOLDER, 1 ether);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
    }

    function test_missingMalformedAndGasBombDecimalsDefaultTo18() public {
        // Bound each simulated transaction so gas bombs cannot consume the entire multi-call test budget.
        for (uint256 mode; mode < 5; ++mode) {
            RawToken raw = _validRaw();
            if (mode == 0) raw.setResponse(DECIMALS, "");
            if (mode == 1) raw.setResponse(DECIMALS, new bytes(31));
            if (mode == 2) raw.setResponse(DECIMALS, new bytes(64));
            if (mode == 3) raw.setMode(DECIMALS, 2);
            if (mode == 4) raw.setMode(DECIMALS, 3);
            _dig(address(raw), 0);
            raw.setResponse(BALANCE, abi.encode(1 ether - 1));
            vm.prank(HOLDER);
            vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, 1 ether));
            cemetery.itLives{gas: 10_000_000}(address(raw));
            raw.setResponse(BALANCE, abi.encode(1 ether));
            vm.prank(HOLDER);
            cemetery.itLives{gas: 10_000_000}(address(raw));
        }
    }

    function test_holderReadFailuresDoNotChangeState() public {
        RawToken raw = _validRaw();
        _dig(address(raw), 0);
        raw.setMode(SUPPLY, 1);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), SUPPLY));
        cemetery.itLives{gas: 10_000_000}(address(raw));
        raw.setResponse(SUPPLY, abi.encode(1_000_000 ether));
        raw.setResponse(BALANCE, new bytes(31));
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), BALANCE));
        cemetery.itLives{gas: 10_000_000}(address(raw));
        vm.warp(START + 72 hours);
        cemetery.seal(address(raw));
        for (uint8 mode = 1; mode <= 3; ++mode) {
            raw.setMode(BALANCE, mode);
            vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), BALANCE));
            cemetery.rise{gas: 10_000_000}(address(raw));
        }
        raw.setMode(SUPPLY, 2);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), SUPPLY));
        cemetery.rise{gas: 10_000_000}(address(raw));
        assertEq(cemetery.graveCount(), 1);
        assertEq(cemetery.graveOf(address(raw)).rises, 0);
    }

    function test_thresholdUsesCurrentSupplyAndBalancesAndBorrowedBalanceCounts() public {
        _dig(address(token), 0);
        token.setSupply(100 ether);
        token.setBalance(OTHER, 0.1 ether); // Models a temporary borrowed balance.
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        token.setBalance(OTHER, 0); // Repayment does not undo the save.
        assertEq(cemetery.graveOf(address(token)).saves, 1);
        vm.warp(cemetery.cooldownEndsAt(address(token)));
        _bury(address(token), 1);
        token.setSupply(0);
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, OTHER, 1));
        cemetery.rise(address(token));
        token.setSupply(100 ether);
        token.setBalance(OTHER, 0.1 ether);
        vm.prank(OTHER);
        cemetery.rise(address(token));
        token.setBalance(OTHER, 0);
        assertEq(cemetery.graveOf(address(token)).rises, 1);
    }

    function test_mournOncePerAddressAndAgainAfterReburial() public {
        _bury(address(token), 21);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit MemecoinCemetery.Mourned(address(token), OTHER, 1);
        vm.prank(OTHER);
        cemetery.mourn(address(token));
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.AlreadyMourned.selector, address(token), 1, OTHER));
        cemetery.mourn(address(token));
        cemetery.mourn(address(token));
        assertEq(cemetery.graveOf(address(token)).mourners, 2);
        assertEq(cemetery.burialOf(address(token), 1).mourners, 2);
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        vm.warp(cemetery.cooldownEndsAt(address(token)));
        _bury(address(token), 22);
        assertEq(cemetery.graveOf(address(token)).mourners, 0);
        vm.prank(OTHER);
        cemetery.mourn(address(token));
        assertEq(cemetery.graveOf(address(token)).mourners, 1);
        assertEq(cemetery.burialOf(address(token), 1).mourners, 2);
        assertEq(cemetery.burialOf(address(token), 2).mourners, 1);
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.AlreadyMourned.selector, address(token), 2, OTHER));
        cemetery.mourn(address(token));
    }

    function test_recentBurialsNewestFirstCapAndDuplicates() public {
        address[25] memory tokens;
        for (uint256 i; i < 25; ++i) {
            MockToken next = new MockToken(18, 1 ether, "NEXT");
            tokens[i] = address(next);
            _bury(tokens[i], uint8(i % 24));
        }
        assertEq(cemetery.recentBurials(0).length, 0);
        assertEq(cemetery.recentBurials(1)[0], tokens[24]);
        assertEq(cemetery.recentBurials(19).length, 19);
        address[] memory recent = cemetery.recentBurials(type(uint256).max);
        assertEq(recent.length, 20);
        for (uint256 i; i < recent.length; ++i) {
            assertEq(recent[i], tokens[24 - i]);
        }
        MockToken(tokens[24]).setBalance(HOLDER, 1 ether);
        vm.prank(HOLDER);
        cemetery.rise(tokens[24]);
        assertEq(cemetery.recentBurials(1)[0], tokens[24]);
        assertEq(cemetery.graveCount(), 24);
        vm.warp(cemetery.cooldownEndsAt(tokens[24]));
        _bury(tokens[24], 23);
        recent = cemetery.recentBurials(20);
        assertEq(recent[0], tokens[24]);
        assertEq(recent[1], tokens[24]);
        assertEq(recent[2], tokens[23]);
        assertEq(cemetery.graveCount(), 25);
    }

    function test_headstoneEpitaphDatesMournersAndRisenBanner() public {
        _dig(address(token), 23);
        string memory svg = cemetery.headstone(address(token));
        assertTrue(_contains(svg, ">DEAD</text>"));
        assertTrue(_contains(svg, "Holders: 1 (the deployer)"));
        assertTrue(_contains(svg, "Dug: 2024-02-29"));
        assertTrue(_contains(svg, "Sealed: -"));
        assertTrue(_contains(svg, "Mourners: 0"));
        assertFalse(_contains(svg, "RISEN:"));
        vm.warp(START + 72 hours);
        cemetery.seal(address(token));
        cemetery.mourn(address(token));
        svg = cemetery.headstone(address(token));
        assertTrue(_contains(svg, "Sealed: 2024-03-03"));
        assertTrue(_contains(svg, "Mourners: 1"));
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        svg = cemetery.headstone(address(token));
        assertTrue(_contains(svg, "RISEN: 1"));
        assertTrue(_contains(svg, "Mourners: 1"));
        assertTrue(_contains(svg, "Sealed: 2024-03-03"));
        vm.warp(cemetery.cooldownEndsAt(address(token)));
        _dig(address(token), 0);
        svg = cemetery.headstone(address(token));
        assertTrue(_contains(svg, "Here lies a 1000x that never was"));
        assertTrue(_contains(svg, "Dug: 2024-03-10"));
        assertTrue(_contains(svg, "Sealed: -"));
        assertTrue(_contains(svg, "Mourners: 0"));
        assertFalse(_contains(svg, "RISEN:"));
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        assertTrue(_contains(cemetery.headstone(address(token)), "Sealed: -"));
        vm.warp(cemetery.cooldownEndsAt(address(token)));
        _bury(address(token), 1);
        vm.prank(HOLDER);
        cemetery.rise(address(token));
        assertTrue(_contains(cemetery.headstone(address(token)), "RISEN: 2"));
    }

    function test_headstoneEscapesAllXMLMetacharacters() public {
        MockToken xml = new MockToken(18, 1 ether, '<DEAD>&"\'');
        _dig(address(xml), 0);
        string memory svg = cemetery.headstone(address(xml));
        assertTrue(_contains(svg, "&lt;DEAD&gt;&amp;&quot;&apos;"));
        assertFalse(_contains(svg, "<DEAD>"));
        RenderingHarness harness = new RenderingHarness();
        assertEq(harness.escape(hex"001f207e7fff"), "?? ~??");
    }

    function test_headstoneMissingAndNonPrintableSymbolUseAddress() public {
        TokenWithoutSymbol noSymbol = new TokenWithoutSymbol(18, 1 ether);
        _dig(address(noSymbol), 0);
        assertTrue(_contains(cemetery.headstone(address(noSymbol)), _shortAddress(address(noSymbol))));
        for (uint256 i; i < 5; ++i) {
            string memory bad;
            if (i == 0) bad = "";
            if (i == 1) bad = string(hex"4445004144");
            if (i == 2) bad = string(hex"7f");
            if (i == 3) bad = unicode"☠";
            if (i == 4) bad = "DEAD\n";
            MockToken invalidSymbol = new MockToken(18, 1 ether, bad);
            _dig(address(invalidSymbol), 0);
            assertTrue(_contains(cemetery.headstone(address(invalidSymbol)), _shortAddress(address(invalidSymbol))));
        }
    }

    function test_headstoneSymbolBoundsAndMalformedABINeverRevert() public {
        RawToken raw = _validRaw();
        _dig(address(raw), 0);
        string memory fallbackSymbol = _shortAddress(address(raw));
        bytes[7] memory badResponses = [
            bytes(""),
            abi.encode(bytes32("OLD_BYTES32_SYMBOL")),
            abi.encode(uint256(64), uint256(4), bytes32("FAIL")),
            abi.encode(uint256(32), type(uint256).max, bytes32("FAIL")),
            abi.encode(uint256(32), uint256(33), bytes32("TOO_SHORT")),
            abi.encode(string(new bytes(65))),
            abi.encode(uint256(32), uint256(0), bytes32(0))
        ];
        for (uint256 i; i < badResponses.length; ++i) {
            raw.setResponse(SYMBOL, badResponses[i]);
            assertTrue(_contains(cemetery.headstone(address(raw)), fallbackSymbol));
        }
        for (uint8 mode = 1; mode <= 3; ++mode) {
            raw.setMode(SYMBOL, mode);
            assertTrue(_contains(cemetery.headstone(address(raw)), fallbackSymbol));
        }
        bytes memory longest = new bytes(64);
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "A";
        }
        raw.setResponse(SYMBOL, abi.encode(string(longest)));
        assertTrue(_contains(cemetery.headstone(address(raw)), string(longest)));
    }

    function test_staticTokenReadCannotReenterMourn() public {
        ReentrantSymbolToken malicious = new ReentrantSymbolToken(cemetery);
        _bury(address(malicious), 0);
        assertTrue(_contains(cemetery.headstone(address(malicious)), "STATIC"));
        assertEq(cemetery.graveOf(address(malicious)).mourners, 0);
        assertEq(cemetery.burialOf(address(malicious), 1).mourners, 0);
    }

    function test_calendarUTCLeapCenturiesEpochAndYearBoundary() public {
        RenderingHarness harness = new RenderingHarness();
        assertEq(harness.date(0), "1970-01-01");
        assertEq(harness.date(86_399), "1970-01-01");
        assertEq(harness.date(86_400), "1970-01-02");
        assertEq(harness.date(951_782_400), "2000-02-29");
        assertEq(harness.date(START - 1), "2024-02-28");
        assertEq(harness.date(START), "2024-02-29");
        assertEq(harness.date(START + 1 days), "2024-03-01");
        assertEq(harness.date(4_107_542_399), "2100-02-28");
        assertEq(harness.date(4_107_542_400), "2100-03-01");
        assertEq(harness.date(1_735_689_599), "2024-12-31");
        assertEq(harness.date(1_735_689_600), "2025-01-01");
        vm.warp(0);
        _dig(address(token), 0);
        assertTrue(_contains(cemetery.headstone(address(token)), "Dug: 1970-01-01"));
        assertTrue(_contains(cemetery.headstone(address(token)), "Sealed: -"));
    }

    function test_rejectsETHReceiveFallbackAndNonpayableFunctions() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory result) = address(cemetery).call{value: 1}("");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MemecoinCemetery.ETHNotAccepted.selector));
        (ok, result) = address(cemetery).call("");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MemecoinCemetery.ETHNotAccepted.selector));
        (ok, result) = address(cemetery).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MemecoinCemetery.ETHNotAccepted.selector));
        (ok, result) = address(cemetery).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MemecoinCemetery.ETHNotAccepted.selector));
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeCall(MemecoinCemetery.dig, (address(token), 0));
        calls[1] = abi.encodeCall(MemecoinCemetery.itLives, (address(token)));
        calls[2] = abi.encodeCall(MemecoinCemetery.seal, (address(token)));
        calls[3] = abi.encodeCall(MemecoinCemetery.mourn, (address(token)));
        calls[4] = abi.encodeCall(MemecoinCemetery.rise, (address(token)));
        calls[5] = abi.encodeCall(MemecoinCemetery.graveOf, (address(token)));
        calls[6] = abi.encodeCall(MemecoinCemetery.graveCount, ());
        calls[7] = abi.encodeCall(MemecoinCemetery.epitaph, (0));
        calls[8] = abi.encodeCall(MemecoinCemetery.recentBurials, (1));
        calls[9] = abi.encodeCall(MemecoinCemetery.headstone, (address(token)));
        calls[10] = abi.encodeCall(MemecoinCemetery.burialOf, (address(token), 1));
        calls[11] = abi.encodeCall(MemecoinCemetery.cooldownEndsAt, (address(token)));
        calls[12] = hex"00";
        for (uint256 i; i < calls.length; ++i) {
            (ok,) = address(cemetery).call{value: 1}(calls[i]);
            assertFalse(ok);
        }
        assertEq(address(cemetery).balance, 0);
        bytes memory initCode = type(MemecoinCemetery).creationCode;
        address fundedDeployment;
        assembly ("memory-safe") {
            fundedDeployment := create(1, add(initCode, 32), mload(initCode))
        }
        assertEq(fundedDeployment, address(0));
    }

    function test_runtimeFitsAndHasNoForbiddenOpcodes() public view {
        bytes memory code = address(cemetery).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzz_sealedRecordsNeverChange(address firstDigger, uint8 epitaphId, uint32 delay, uint8 cycles)
        public
    {
        epitaphId = uint8(bound(epitaphId, 0, 23));
        cycles = uint8(bound(cycles, 1, 4));
        bytes32[] memory snapshots = new bytes32[](uint256(cycles) + 1);
        vm.prank(firstDigger);
        cemetery.dig(address(token), epitaphId);
        vm.warp(START + 72 hours + uint256(delay));
        cemetery.seal(address(token));
        snapshots[0] = _identityHash(cemetery.burialOf(address(token), 1));
        for (uint256 i; i < cycles; ++i) {
            vm.prank(address(uint160(i + 100)));
            cemetery.mourn(address(token));
            vm.prank(HOLDER);
            cemetery.rise(address(token));
            _checkSnapshots(snapshots, i + 1);
            vm.warp(cemetery.cooldownEndsAt(address(token)));
            vm.prank(OTHER);
            cemetery.dig(address(token), uint8((epitaphId + i + 1) % 24));
            _checkSnapshots(snapshots, i + 1);
            vm.prank(HOLDER);
            cemetery.itLives(address(token));
            _checkSnapshots(snapshots, i + 1);
            vm.warp(cemetery.cooldownEndsAt(address(token)));
            _dig(address(token), uint8((epitaphId + i + 2) % 24));
            vm.warp(block.timestamp + 72 hours);
            cemetery.seal(address(token));
            _checkSnapshots(snapshots, i + 1);
            snapshots[i + 1] = _identityHash(cemetery.burialOf(address(token), i + 2));
        }
        MemecoinCemetery.Grave memory g = cemetery.graveOf(address(token));
        assertEq(g.burials, uint256(cycles) + 1);
        assertEq(g.rises, cycles);
        assertEq(g.saves, cycles);
    }

    function testFuzz_holderThreshold(uint8 decimals_, uint256 supply, bool rising) public {
        supply = bound(supply, 1, type(uint256).max);
        uint256 effectiveDecimals = decimals_ > 36 ? 18 : decimals_;
        uint256 threshold = supply / 1000;
        uint256 whole = 10 ** effectiveDecimals;
        if (threshold > whole) threshold = whole;
        if (threshold < 1) threshold = 1;
        _checkThreshold(decimals_, supply, threshold, rising);
    }

    function _dig(address target, uint8 id) internal {
        vm.prank(DIGGER);
        cemetery.dig(target, id);
    }

    function _bury(address target, uint8 id) internal {
        _dig(target, id);
        vm.warp(block.timestamp + 72 hours);
        cemetery.seal(target);
    }

    function _badSupply(RawToken raw) internal {
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.TokenReadFailed.selector, address(raw), SUPPLY));
        cemetery.dig(address(raw), 0);
    }

    function _validRaw() internal returns (RawToken raw) {
        raw = new RawToken();
        raw.setResponse(SUPPLY, abi.encode(1_000_000 ether));
        raw.setResponse(DECIMALS, abi.encode(uint256(18)));
        raw.setResponse(BALANCE, abi.encode(1 ether));
        raw.setResponse(SYMBOL, abi.encode("RAW"));
    }

    function _assertInvalidActions(MemecoinCemetery.State state) internal {
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(MemecoinCemetery.dig, (address(token), 0));
        calls[1] = abi.encodeCall(MemecoinCemetery.itLives, (address(token)));
        calls[2] = abi.encodeCall(MemecoinCemetery.seal, (address(token)));
        calls[3] = abi.encodeCall(MemecoinCemetery.mourn, (address(token)));
        calls[4] = abi.encodeCall(MemecoinCemetery.rise, (address(token)));
        for (uint256 i; i < calls.length; ++i) {
            bool allowed = i == 0
                ? state == MemecoinCemetery.State.None || state == MemecoinCemetery.State.Saved
                    || state == MemecoinCemetery.State.Risen
                : i <= 2 ? state == MemecoinCemetery.State.Wake : state == MemecoinCemetery.State.Buried;
            if (allowed) continue;
            (bool ok, bytes memory result) = address(cemetery).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(MemecoinCemetery.InvalidState.selector, address(token), state));
        }
    }

    function _checkThreshold(uint256 decimals_, uint256 supply, uint256 threshold, bool rising) internal {
        MockToken candidate = new MockToken(decimals_, supply, "THRESHOLD");
        if (rising) _bury(address(candidate), 0);
        else _dig(address(candidate), 0);
        candidate.setBalance(HOLDER, threshold - 1);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(MemecoinCemetery.NotHolder.selector, HOLDER, threshold));
        if (rising) cemetery.rise(address(candidate));
        else cemetery.itLives(address(candidate));
        candidate.setBalance(HOLDER, threshold);
        vm.prank(HOLDER);
        if (rising) cemetery.rise(address(candidate));
        else cemetery.itLives(address(candidate));
        assertEq(
            uint256(cemetery.graveOf(address(candidate)).state),
            uint256(rising ? MemecoinCemetery.State.Risen : MemecoinCemetery.State.Saved)
        );
    }

    function _checkSnapshots(bytes32[] memory snapshots, uint256 count) internal view {
        for (uint256 j; j < count; ++j) {
            assertEq(_identityHash(cemetery.burialOf(address(token), j + 1)), snapshots[j]);
        }
    }

    function _identityHash(MemecoinCemetery.Burial memory b) internal pure returns (bytes32) {
        return keccak256(abi.encode(b.digger, b.epitaphId, b.dugAt, b.sealedAt));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool matches = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function _shortAddress(address target) internal pure returns (string memory) {
        bytes memory full = bytes(vm.toLowercase(vm.toString(target)));
        bytes memory short = new bytes(13);
        for (uint256 i; i < 6; ++i) {
            short[i] = full[i];
        }
        short[6] = ".";
        short[7] = ".";
        short[8] = ".";
        for (uint256 i; i < 4; ++i) {
            short[9 + i] = full[38 + i];
        }
        return string(short);
    }
}

contract DeployTest is Test {
    function test_deployOn4663WithNoArguments() public {
        vm.chainId(4663);
        Deploy deployer = new Deploy();
        MemecoinCemetery cemetery = deployer.run();
        assertGt(address(cemetery).code.length, 0);
        assertEq(cemetery.graveCount(), 0);
        assertEq(cemetery.epitaph(23), "Holders: 1 (the deployer)");
    }

    function testFuzz_deployRejectsEveryOtherChain(uint64 chainId) public {
        vm.assume(chainId != 4663);
        vm.chainId(chainId);
        Deploy deployer = new Deploy();
        vm.expectRevert(abi.encodeWithSelector(Deploy.WrongChain.selector, chainId));
        deployer.run();
    }
}
