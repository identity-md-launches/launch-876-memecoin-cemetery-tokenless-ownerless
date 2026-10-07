// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemecoinCemetery} from "../src/MemecoinCemetery.sol";
import {MockToken} from "./MemecoinCemetery.t.sol";

/// @dev Exercise real state transitions with independent counters and immutable history fingerprints.
contract CemeteryHandler is Test {
    MemecoinCemetery public immutable cemetery;
    address[5] public tokens;
    mapping(address => uint256) public expectedBurials;
    mapping(address => uint256) public expectedRises;
    mapping(address => uint256) public expectedSaves;
    mapping(address => mapping(uint256 => bytes32)) public identities;

    constructor(MemecoinCemetery cemetery_) {
        cemetery = cemetery_;
        for (uint256 i; i < tokens.length; ++i) {
            MockToken token = new MockToken(i % 2 == 0 ? 18 : 6, 100_000 ether, "INVARIANT");
            tokens[i] = address(token);
            for (uint256 j; j < 3; ++j) {
                token.setBalance(address(uint160(j + 100)), 1 ether);
            }
        }
    }

    function dig(uint256 index, uint8 epitaphId, uint256 actor) external {
        address token = tokens[index % tokens.length];
        vm.prank(_actor(actor));
        (bool ok,) = address(cemetery).call(abi.encodeCall(MemecoinCemetery.dig, (token, epitaphId % 24)));
        if (ok) assertEq(uint256(cemetery.graveOf(token).state), uint256(MemecoinCemetery.State.Wake));
    }

    function save(uint256 index, uint256 actor) external {
        address token = tokens[index % tokens.length];
        vm.prank(_actor(actor));
        (bool ok,) = address(cemetery).call(abi.encodeCall(MemecoinCemetery.itLives, (token)));
        if (ok) ++expectedSaves[token];
    }

    function seal(uint256 index) external {
        address token = tokens[index % tokens.length];
        (bool ok,) = address(cemetery).call(abi.encodeCall(MemecoinCemetery.seal, (token)));
        if (ok) {
            uint256 number = ++expectedBurials[token];
            MemecoinCemetery.Burial memory b = cemetery.burialOf(token, number);
            identities[token][number] = keccak256(abi.encode(b.digger, b.epitaphId, b.dugAt, b.sealedAt));
        }
    }

    function mourn(uint256 index, uint256 actor) external {
        address token = tokens[index % tokens.length];
        vm.prank(_actor(actor));
        // Failed calls (wrong state or duplicate mourner) are intentionally part of the action stream.
        (bool ok,) = address(cemetery).call(abi.encodeCall(MemecoinCemetery.mourn, (token)));
        if (ok) assertGt(cemetery.graveOf(token).mourners, 0);
    }

    function rise(uint256 index, uint256 actor) external {
        address token = tokens[index % tokens.length];
        vm.prank(_actor(actor));
        (bool ok,) = address(cemetery).call(abi.encodeCall(MemecoinCemetery.rise, (token)));
        if (ok) ++expectedRises[token];
    }

    function advance(uint256 seconds_) external {
        vm.warp(block.timestamp + seconds_ % (8 days + 1));
    }

    function _actor(uint256 seed) private pure returns (address) {
        // Three holders and one nonholder; all four can dig, seal or mourn.
        return address(uint160(100 + seed % 4));
    }
}

contract MemecoinCemeteryInvariantTest is Test {
    MemecoinCemetery internal cemetery;
    CemeteryHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        cemetery = new MemecoinCemetery();
        handler = new CemeteryHandler(cemetery);
        // Seed all five states so every randomized run begins with nonempty history and a live burial.
        handler.dig(0, 0, 0);
        handler.dig(3, 3, 0);
        handler.advance(72 hours);
        handler.seal(0);
        handler.seal(3);
        handler.rise(3, 0);
        handler.dig(2, 2, 0);
        handler.save(2, 0);
        handler.dig(1, 1, 0);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.dig.selector;
        selectors[1] = handler.save.selector;
        selectors[2] = handler.seal.selector;
        selectors[3] = handler.mourn.selector;
        selectors[4] = handler.rise.selector;
        selectors[5] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_graveCountEqualsNumberOfBuriedTokens() public view {
        uint256 buried;
        for (uint256 i; i < 5; ++i) {
            address token = handler.tokens(i);
            MemecoinCemetery.Grave memory g = cemetery.graveOf(token);
            if (g.state == MemecoinCemetery.State.Buried) ++buried;
            assertEq(g.burials, handler.expectedBurials(token));
            assertEq(g.rises, handler.expectedRises(token));
            assertEq(g.saves, handler.expectedSaves(token));
            assertEq(g.burials - g.rises, g.state == MemecoinCemetery.State.Buried ? 1 : 0);
        }
        assertEq(cemetery.graveCount(), buried);
    }

    function invariant_sealedBurialIdentitiesNeverChange() public view {
        for (uint256 i; i < 5; ++i) {
            address token = handler.tokens(i);
            for (uint256 n = 1; n <= handler.expectedBurials(token); ++n) {
                MemecoinCemetery.Burial memory b = cemetery.burialOf(token, n);
                assertEq(
                    keccak256(abi.encode(b.digger, b.epitaphId, b.dugAt, b.sealedAt)), handler.identities(token, n)
                );
            }
        }
    }
}
