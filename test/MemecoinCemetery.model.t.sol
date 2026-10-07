// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemecoinCemetery} from "src/MemecoinCemetery.sol";
import {MockToken} from "./MemecoinCemetery.t.sol";

/// @dev The oracle predicts call eligibility before calling the application. All expected
/// fields, histories and mourner sets come from inputs, never from cemetery getters.
contract CemeteryModelHandler is Test {
    MemecoinCemetery public immutable cemetery;
    MockToken[5] public tokens;
    MemecoinCemetery.Grave[5] private expected;
    uint256[5] private cooldowns;
    uint256[5] private supplies;
    uint256[5] private decimals;
    bool[5] private missingDecimals;
    uint256[4][5] private balances;
    mapping(uint256 => mapping(uint256 => MemecoinCemetery.Burial)) private history;
    mapping(uint256 => mapping(uint256 => uint256)) private mournerMasks;
    address[] private seals;
    uint256[5] public successes;
    uint256[5] public rejections;

    constructor(MemecoinCemetery cemetery_) {
        cemetery = cemetery_;
        for (uint256 i; i < 5; ++i) {
            decimals[i] = i == 0 ? 0 : i == 1 ? 6 : i == 2 ? 18 : i == 3 ? 36 : 37;
            supplies[i] = i == 0 ? 999 : type(uint256).max;
            tokens[i] = new MockToken(decimals[i], supplies[i], "MODEL");
            for (uint256 j; j < 3; ++j) {
                balances[i][j] = 1e36;
                tokens[i].setBalance(_actor(j), 1e36);
            }
        }
    }

    /// @dev Operations: dig, save, seal, mourn, rise. Include invalid epitaphs and a nonholder.
    function act(uint256 tokenSeed, uint8 operationSeed, uint8 actorSeed, uint8 epitaphSeed) public {
        uint256 i = tokenSeed % 5;
        uint256 op = operationSeed % 5;
        uint256 actor = actorSeed % 4;
        uint8 id = epitaphSeed % 26;
        address token = address(tokens[i]);
        uint256 now_ = vm.getBlockTimestamp();
        MemecoinCemetery.Grave storage g = expected[i];
        bool shouldSucceed;
        bytes memory callData;
        if (op == 0) {
            shouldSucceed = id < 24 && supplies[i] > 0 && now_ >= cooldowns[i]
                && (g.state == MemecoinCemetery.State.None
                    || g.state == MemecoinCemetery.State.Saved
                    || g.state == MemecoinCemetery.State.Risen);
            callData = abi.encodeCall(MemecoinCemetery.dig, (token, id));
        } else if (op == 1) {
            shouldSucceed =
                g.state == MemecoinCemetery.State.Wake && now_ < g.wakeEndsAt && balances[i][actor] >= _threshold(i);
            callData = abi.encodeCall(MemecoinCemetery.itLives, (token));
        } else if (op == 2) {
            shouldSucceed = g.state == MemecoinCemetery.State.Wake && now_ >= g.wakeEndsAt;
            callData = abi.encodeCall(MemecoinCemetery.seal, (token));
        } else if (op == 3) {
            shouldSucceed = g.state == MemecoinCemetery.State.Buried && (mournerMasks[i][g.burials] & (1 << actor)) == 0;
            callData = abi.encodeCall(MemecoinCemetery.mourn, (token));
        } else {
            shouldSucceed = g.state == MemecoinCemetery.State.Buried && balances[i][actor] >= _threshold(i);
            callData = abi.encodeCall(MemecoinCemetery.rise, (token));
        }

        vm.prank(_actor(actor));
        (bool ok,) = address(cemetery).call(callData);
        assertEq(ok, shouldSucceed, "call result disagrees with independent lifecycle/holder model");
        if (shouldSucceed) {
            ++successes[op];
            _apply(i, op, actor, id, now_);
        } else {
            ++rejections[op];
        }
        // Includes rejected calls: no attempt, cooldown, history or recent entry may change.
        assertModel();
    }

    /// @dev Mutate live token reads across the whole-token, fractional and one-unit regimes.
    function changeToken(uint256 tokenSeed, uint8 modeSeed, uint8 actorSeed, uint8 balanceSeed) external {
        uint256 i = tokenSeed % 5;
        uint256 mode = modeSeed % 9;
        uint256 actor = actorSeed % 4;
        if (mode == 0) supplies[i] = 0;
        if (mode == 1) supplies[i] = 999;
        if (mode == 2) supplies[i] = 1001;
        if (mode == 3) supplies[i] = 500 ether;
        if (mode == 4) supplies[i] = type(uint256).max;
        if (mode == 5) decimals[i] = 6;
        if (mode == 6) decimals[i] = 36;
        if (mode == 7) decimals[i] = 37;
        missingDecimals[i] = mode == 8;
        tokens[i].setSupply(supplies[i]);
        tokens[i].setDecimals(decimals[i], missingDecimals[i]);
        uint256 minimum = _threshold(i);
        uint256 balanceMode = balanceSeed % 4;
        uint256 balance =
            balanceMode == 0 ? 0 : balanceMode == 1 ? minimum - 1 : balanceMode == 2 ? minimum : minimum + 1;
        balances[i][actor] = balance;
        tokens[i].setBalance(_actor(actor), balance);
        assertModel();
    }

    /// @dev Bias time movement toward the second before and at wake/cooldown deadlines.
    function advance(uint256 tokenSeed, uint8 modeSeed, uint32 delta) public {
        uint256 i = tokenSeed % 5;
        uint256 now_ = vm.getBlockTimestamp();
        uint256 mode = modeSeed % 5;
        uint256 deadline = mode < 2 ? expected[i].wakeEndsAt : cooldowns[i];
        if (mode == 4) {
            vm.warp(now_ + uint256(delta) % (8 days + 1));
        } else if (deadline > now_) {
            vm.warp(deadline - (mode % 2 == 0 ? 1 : 0));
        }
        assertModel();
    }

    function assertModel() public view {
        uint256 buried;
        for (uint256 i; i < 5; ++i) {
            address token = address(tokens[i]);
            MemecoinCemetery.Grave memory actual = cemetery.graveOf(token);
            assertEq(
                abi.encode(actual), abi.encode(expected[i]), "latest attempt or lifetime counter changed incorrectly"
            );
            assertEq(cemetery.cooldownEndsAt(token), cooldowns[i], "cooldown starts at the save/rise transaction");
            if (expected[i].state == MemecoinCemetery.State.Buried) ++buried;
            for (uint256 n = 1; n <= expected[i].burials; ++n) {
                assertEq(abi.encode(cemetery.burialOf(token, n)), abi.encode(history[i][n]), "permanent burial changed");
            }
        }
        assertEq(cemetery.graveCount(), buried, "graveCount must count exactly the buried tokens");
        assertEq(address(cemetery).balance, 0);
        uint256[5] memory requests = [uint256(0), 1, 19, 20, type(uint256).max];
        for (uint256 i; i < requests.length; ++i) {
            uint256 count = requests[i] > 20 ? 20 : requests[i];
            if (count > seals.length) count = seals.length;
            address[] memory actual = cemetery.recentBurials(requests[i]);
            assertEq(actual.length, count, "recent burial length");
            for (uint256 j; j < count; ++j) {
                assertEq(actual[j], seals[seals.length - 1 - j], "recent burials must follow seal order");
            }
        }
    }

    function _apply(uint256 i, uint256 op, uint256 actor, uint8 id, uint256 now_) private {
        MemecoinCemetery.Grave storage g = expected[i];
        if (op == 0) {
            g.state = MemecoinCemetery.State.Wake;
            g.digger = _actor(actor);
            g.epitaphId = id;
            g.dugAt = now_;
            g.wakeEndsAt = now_ + 72 hours;
            g.sealedAt = 0;
            g.mourners = 0;
        } else if (op == 1) {
            g.state = MemecoinCemetery.State.Saved;
            ++g.saves;
            cooldowns[i] = now_ + 7 days;
        } else if (op == 2) {
            g.state = MemecoinCemetery.State.Buried;
            g.sealedAt = now_;
            ++g.burials;
            history[i][g.burials] = MemecoinCemetery.Burial(g.digger, g.epitaphId, g.dugAt, now_, 0);
            seals.push(address(tokens[i]));
        } else if (op == 3) {
            mournerMasks[i][g.burials] |= 1 << actor;
            ++g.mourners;
            ++history[i][g.burials].mourners;
        } else {
            g.state = MemecoinCemetery.State.Risen;
            ++g.rises;
            cooldowns[i] = now_ + 7 days;
        }
    }

    function _threshold(uint256 i) private view returns (uint256) {
        uint256 whole = 10 ** (missingDecimals[i] || decimals[i] > 36 ? 18 : decimals[i]);
        uint256 fraction = supplies[i] / 1000;
        if (fraction == 0) return 1;
        return whole < fraction ? whole : fraction;
    }

    function _actor(uint256 i) private pure returns (address) {
        return address(uint160(0xCAFE00 + i));
    }
}

contract MemecoinCemeteryModelTest is Test {
    CemeteryModelHandler internal handler;

    function setUp() public {
        vm.warp(1_735_689_600); // 2025-01-01 UTC
        handler = new CemeteryModelHandler(new MemecoinCemetery());
        // Begin in all five states, with different holders and a successful nonholder mourner.
        handler.act(0, 0, 3, 23);
        handler.act(3, 0, 0, 4);
        handler.advance(0, 1, 0);
        handler.act(0, 2, 3, 0);
        handler.act(0, 3, 3, 0);
        handler.act(3, 2, 1, 0);
        handler.act(3, 4, 0, 0);
        handler.act(2, 0, 2, 0);
        handler.act(2, 1, 0, 0);
        handler.act(1, 0, 3, 8);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.act.selector;
        selectors[1] = handler.changeToken.selector;
        selectors[2] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // The handler catches expected application reverts; a handler assertion must fail the run.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_callsAndEntireHistoryMatchIndependentModel() public view {
        handler.assertModel();
    }

    function test_modelExercisesEveryActionAndRejectedAction() public {
        handler.act(0, 0, 0, 0); // Cannot dig a buried token.
        handler.act(4, 1, 0, 0); // No wake.
        handler.act(4, 2, 0, 0); // No wake to seal.
        handler.act(0, 3, 3, 0); // Already mourned.
        handler.act(0, 4, 3, 0); // Nonholder.
        for (uint256 i; i < 5; ++i) {
            assertGt(handler.successes(i), 0, "seed must exercise every successful action");
            assertGt(handler.rejections(i), 0, "seed must exercise every rejected action");
        }
    }

    function test_modelTracksMourningAcrossRepeatedBurialsAndSaves() public {
        // Start with token 0 buried and actor 3 already counted in its first burial.
        for (uint8 cycle; cycle < 3; ++cycle) {
            handler.act(0, 4, 0, 0);
            handler.advance(0, 2, 0); // One second before cooldown.
            handler.act(0, 0, 1, cycle);
            handler.advance(0, 3, 0); // Exactly cooldown.
            handler.act(0, 0, 1, cycle);
            handler.act(0, 1, 0, 0);
            handler.advance(0, 3, 0);
            handler.act(0, 0, 2, cycle);
            handler.advance(0, 0, 0); // One second before wake expiry.
            handler.act(0, 2, 3, 0);
            handler.advance(0, 1, 0);
            handler.act(0, 1, 0, 0); // Objection deadline has passed.
            handler.act(0, 2, 3, 0);
            handler.act(0, 3, 3, 0); // Same mourner is eligible in each new burial.
            handler.act(0, 3, 3, 0);
        }
    }
}
