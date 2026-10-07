// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Memecoin Cemetery
/// @notice Permissionless wakes, holder vetoes and permanent burial histories. No owner or fees.
/// @dev Token responses are untrusted; reads are static and size-bounded. Holder checks use caller-funded gas.
contract MemecoinCemetery {
    enum State {
        None,
        Wake,
        Buried,
        Saved,
        Risen
    }

    struct Grave {
        State state;
        address digger;
        uint8 epitaphId;
        uint256 dugAt;
        uint256 wakeEndsAt;
        uint256 sealedAt;
        uint256 burials;
        uint256 rises;
        uint256 saves;
        uint256 mourners;
    }

    /// @dev Identity and dates never change after sealing. Mourners increase only while this burial is active.
    struct Burial {
        address digger;
        uint8 epitaphId;
        uint256 dugAt;
        uint256 sealedAt;
        uint256 mourners;
    }

    error InvalidToken(address token);
    error TokenReadFailed(address token, bytes4 selector);
    error InvalidEpitaph(uint8 id);
    error InvalidState(address token, State current);
    error CooldownActive(uint256 endsAt);
    error WakeStillOpen(uint256 endsAt);
    error WakeClosed(uint256 endsAt);
    error NotHolder(address holder, uint256 requiredBalance);
    error AlreadyMourned(address token, uint256 burialNumber, address mourner);
    error NeverDug(address token);
    error UnknownBurial(address token, uint256 burialNumber);
    error ETHNotAccepted();

    event WakeOpened(address indexed token, address indexed digger, uint8 epitaphId, uint256 endsAt);
    event Resurrected(address indexed token, address indexed holder);
    event Buried(address indexed token, uint8 epitaphId, address indexed digger, uint256 sealedAt);
    event Mourned(address indexed token, address indexed mourner, uint256 mourners);
    event Rose(address indexed token, address indexed holder);

    uint256 private constant WAKE_DURATION = 72 hours;
    uint256 private constant COOLDOWN = 7 days;
    uint256 private constant TOKEN_GAS = 50_000;
    uint256 private constant MAX_SYMBOL_BYTES = 64;
    bytes4 private constant TOTAL_SUPPLY = 0x18160ddd;
    bytes4 private constant BALANCE_OF = 0x70a08231;
    bytes4 private constant DECIMALS = 0x313ce567;
    bytes4 private constant SYMBOL = 0x95d89b41;

    mapping(address => Grave) private _graves;
    mapping(address => uint256) private _cooldownEnds;
    mapping(address => mapping(uint256 => Burial)) private _burials;
    mapping(address => mapping(uint256 => mapping(address => bool))) private _mourned;
    address[] private _recent;
    uint256 private _graveCount;

    string[24] private _epitaphs = [
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

    /// @notice Open a 72-hour wake for a token with code and a positive, readable total supply.
    /// @param token ERC-20 being nominated; ownership of it is not required.
    /// @param epitaphId Index into the immutable list of 24 epitaphs.
    function dig(address token, uint8 epitaphId) external {
        if (epitaphId >= 24) revert InvalidEpitaph(epitaphId);
        Grave storage g = _graves[token];
        if (g.state != State.None && g.state != State.Saved && g.state != State.Risen) {
            revert InvalidState(token, g.state);
        }
        if (block.timestamp < _cooldownEnds[token]) revert CooldownActive(_cooldownEnds[token]);
        if (token.code.length == 0) revert InvalidToken(token);
        uint256 supply = _requiredWord(token, abi.encodeWithSelector(TOTAL_SUPPLY), TOTAL_SUPPLY, TOKEN_GAS);
        if (supply == 0) revert InvalidToken(token);

        g.state = State.Wake;
        g.digger = msg.sender;
        g.epitaphId = epitaphId;
        g.dugAt = block.timestamp;
        g.wakeEndsAt = block.timestamp + WAKE_DURATION;
        g.sealedAt = 0;
        g.mourners = 0;
        emit WakeOpened(token, msg.sender, epitaphId, g.wakeEndsAt);
    }

    /// @notice A current holder vetoes a wake strictly before its deadline, starting a seven-day cooldown.
    /// @param token Token whose wake the caller wants to cancel.
    function itLives(address token) external {
        Grave storage g = _inState(token, State.Wake);
        if (block.timestamp >= g.wakeEndsAt) revert WakeClosed(g.wakeEndsAt);
        _requireHolder(token);
        g.state = State.Saved;
        ++g.saves;
        _cooldownEnds[token] = block.timestamp + COOLDOWN;
        emit Resurrected(token, msg.sender);
    }

    /// @notice Anyone may seal an unopposed wake at or after its deadline; stores a new permanent record.
    /// @param token Token to bury.
    function seal(address token) external {
        Grave storage g = _inState(token, State.Wake);
        if (block.timestamp < g.wakeEndsAt) revert WakeStillOpen(g.wakeEndsAt);
        g.state = State.Buried;
        g.sealedAt = block.timestamp;
        ++g.burials;
        ++_graveCount;
        _burials[token][g.burials] = Burial(g.digger, g.epitaphId, g.dugAt, g.sealedAt, 0);
        _recent.push(token);
        emit Buried(token, g.epitaphId, g.digger, g.sealedAt);
    }

    /// @notice Pay respects once per caller per burial, only while the token is buried.
    /// @param token Token to mourn. Holding it is not required.
    function mourn(address token) external {
        Grave storage g = _inState(token, State.Buried);
        if (_mourned[token][g.burials][msg.sender]) revert AlreadyMourned(token, g.burials, msg.sender);
        _mourned[token][g.burials][msg.sender] = true;
        ++g.mourners;
        _burials[token][g.burials].mourners = g.mourners;
        emit Mourned(token, msg.sender, g.mourners);
    }

    /// @notice A current holder raises a buried token, preserving its record and starting a seven-day cooldown.
    /// @param token Token to mark as risen.
    function rise(address token) external {
        Grave storage g = _inState(token, State.Buried);
        _requireHolder(token);
        g.state = State.Risen;
        ++g.rises;
        --_graveCount;
        _cooldownEnds[token] = block.timestamp + COOLDOWN;
        emit Rose(token, msg.sender);
    }

    /// @notice Return the latest attempt and lifetime counters; never-dug tokens return zeroed fields.
    /// @dev New wakes reset the latest attempt's dates and mourners, but never its history counters.
    function graveOf(address token) external view returns (Grave memory) {
        return _graves[token];
    }

    /// @notice Number of tokens currently in the Buried state, excluding saved and risen tokens.
    function graveCount() external view returns (uint256) {
        return _graveCount;
    }

    /// @notice Read a permanent sealed burial by its one-based number, including its final/current mourners.
    function burialOf(address token, uint256 burialNumber) external view returns (Burial memory) {
        if (burialNumber == 0 || burialNumber > _graves[token].burials) {
            revert UnknownBurial(token, burialNumber);
        }
        return _burials[token][burialNumber];
    }

    /// @notice Earliest time a saved or risen token may enter a new wake; zero if no cooldown ever started.
    function cooldownEndsAt(address token) external view returns (uint256) {
        return _cooldownEnds[token];
    }

    /// @notice Return the fixed text at an index from 0 through 23.
    function epitaph(uint8 id) public view returns (string memory) {
        if (id >= 24) revert InvalidEpitaph(id);
        return _epitaphs[id];
    }

    /// @notice Last min(n, 20, total seals) tokens, newest first; includes repeat burials and risen tokens.
    function recentBurials(uint256 n) external view returns (address[] memory tokens) {
        uint256 length = _recent.length;
        if (n > 20) n = 20;
        if (n > length) n = length;
        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = _recent[length - 1 - i];
        }
    }

    /// @notice Draw the latest headstone as standalone SVG, with UTC dates and a RISEN banner when applicable.
    /// @dev Invalid, empty, non-ASCII or over-64-byte symbols use a shortened lowercase token address.
    function headstone(address token) external view returns (string memory) {
        Grave storage g = _graves[token];
        if (g.state == State.None) revert NeverDug(token);
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 600" role="img">'
            '<title>Memecoin Cemetery</title><rect width="720" height="600" fill="#101916"/>'
            '<path d="M100 540V210a260 170 0 0 1 520 0v330Z" fill="#adb4aa" stroke="#667369" stroke-width="8"/>'
            '<path d="M70 540h580v25H70Z" fill="#667369"/>'
            '<g fill="#17231d" text-anchor="middle" font-family="monospace">'
            '<text x="360" y="125" font-size="20">REST IN PEACE</text>'
            '<text x="360" y="210" font-size="32" textLength="460" lengthAdjust="spacingAndGlyphs">',
            _escapeXML(bytes(_symbol(token))),
            '</text><text x="360" y="280" font-size="16">',
            epitaph(g.epitaphId),
            "</text>"
        );
        svg = string.concat(
            svg,
            '<text x="360" y="355" font-size="18">Dug: ',
            _date(g.dugAt),
            '</text><text x="360" y="390" font-size="18">Sealed: ',
            g.sealedAt == 0 ? "-" : _date(g.sealedAt),
            '</text><text x="360" y="440" font-size="20">Mourners: ',
            _decimal(g.mourners),
            "</text>"
        );
        if (g.state == State.Risen) {
            svg = string.concat(
                svg,
                '<rect x="200" y="465" width="320" height="45" rx="8" fill="#d7f579"/>',
                '<text x="360" y="495" font-size="24">RISEN: ',
                _decimal(g.rises),
                "</text>"
            );
        }
        return string.concat(svg, "</g></svg>");
    }

    /// @notice Reject direct ETH transfers, including zero-value calls with empty calldata.
    receive() external payable {
        revert ETHNotAccepted();
    }

    /// @notice Reject unknown selectors and all fallback ETH transfers.
    fallback() external payable {
        revert ETHNotAccepted();
    }

    /// @dev Return a storage reference only if the token is in the required state.
    function _inState(address token, State expected) private view returns (Grave storage g) {
        g = _graves[token];
        if (g.state != expected) revert InvalidState(token, g.state);
    }

    /// @dev Require balance >= max(1, min(10**decimals, supply/1000)) using current token responses.
    /// @dev Forward available gas (subject to EIP-150) so costly token reads can be funded by the defending holder.
    function _requireHolder(address token) private view {
        uint256 supply = _requiredWord(token, abi.encodeWithSelector(TOTAL_SUPPLY), TOTAL_SUPPLY, gasleft());
        (bool ok, uint256 decimals) = _readWord(token, abi.encodeWithSelector(DECIMALS), gasleft());
        if (!ok || decimals > 36) decimals = 18;
        uint256 threshold = 10 ** decimals;
        uint256 fraction = supply / 1000;
        if (fraction < threshold) threshold = fraction;
        if (threshold == 0) threshold = 1;
        uint256 balance = _requiredWord(token, abi.encodeWithSelector(BALANCE_OF, msg.sender), BALANCE_OF, gasleft());
        if (balance < threshold) revert NotHolder(msg.sender, threshold);
    }

    /// @dev Read a mandatory ABI word, turning reverts, oversized and truncated results into a custom error.
    function _requiredWord(address token, bytes memory data, bytes4 selector, uint256 gasLimit)
        private
        view
        returns (uint256 value)
    {
        bool ok;
        (ok, value) = _readWord(token, data, gasLimit);
        if (!ok) revert TokenReadFailed(token, selector);
    }

    /// @dev Use the caller-selected gas allowance and copy at most one word, regardless of return/revert size.
    function _readWord(address token, bytes memory data, uint256 gasLimit)
        private
        view
        returns (bool ok, uint256 value)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, token, add(data, 32), mload(data), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            value := mload(0)
        }
    }

    /// @dev Decode only bounded canonical ABI strings; failed or unsafe metadata never prevents rendering.
    function _symbol(address token) private view returns (string memory) {
        bytes memory data = abi.encodeWithSelector(SYMBOL);
        bytes memory result = new bytes(64 + MAX_SYMBOL_BYTES);
        bool ok;
        uint256 size;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            ok := staticcall(TOKEN_GAS, token, add(data, 32), mload(data), add(result, 32), mload(result))
            size := returndatasize()
            offset := mload(add(result, 32))
            length := mload(add(result, 64))
        }
        if (!ok || size < 96 || size > result.length || offset != 32 || length == 0 || length > MAX_SYMBOL_BYTES) {
            return _shortAddress(token);
        }
        if (size != 64 + ((length + 31) / 32) * 32) return _shortAddress(token);
        bytes memory symbol = new bytes(length);
        for (uint256 i; i < length; ++i) {
            bytes1 c = result[64 + i];
            if (uint8(c) < 32 || uint8(c) > 126) return _shortAddress(token);
            symbol[i] = c;
        }
        return string(symbol);
    }

    /// @dev Render 0x1234...abcd without any external metadata or checksum dependencies.
    function _shortAddress(address token) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory label = bytes("0x0000...0000");
        uint160 value = uint160(token);
        for (uint256 i; i < 4; ++i) {
            label[2 + i] = digits[(value >> (156 - 4 * i)) & 15];
            label[9 + i] = digits[(value >> (12 - 4 * i)) & 15];
        }
        return string(label);
    }

    /// @dev Escape all five XML metacharacters; defensively replace non-printable bytes with '?'.
    function _escapeXML(bytes memory value) internal pure returns (string memory) {
        bytes memory escaped = new bytes(value.length * 6);
        uint256 used;
        for (uint256 i; i < value.length; ++i) {
            bytes1 c = value[i];
            bytes memory entity;
            if (c == "&") {
                entity = bytes("&amp;");
            } else if (c == "<") {
                entity = bytes("&lt;");
            } else if (c == ">") {
                entity = bytes("&gt;");
            } else if (c == '"') {
                entity = bytes("&quot;");
            } else if (c == "'") {
                entity = bytes("&apos;");
            } else {
                escaped[used++] = uint8(c) < 32 || uint8(c) > 126 ? bytes1("?") : c;
                continue;
            }
            for (uint256 j; j < entity.length; ++j) {
                escaped[used++] = entity[j];
            }
        }
        assembly ("memory-safe") {
            mstore(escaped, used)
        }
        return string(escaped);
    }

    /// @dev Gregorian UTC date from Unix seconds, using 400-year eras with March as the first month.
    /// @dev Arithmetic described by https://howardhinnant.github.io/date_algorithms.html#civil_from_days.
    function _date(uint256 timestamp) internal pure returns (string memory) {
        uint256 daysSinceMarch = timestamp / 1 days + 719468;
        uint256 era = daysSinceMarch / 146097;
        uint256 dayOfEra = daysSinceMarch % 146097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
        uint256 year = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 marchMonth = (5 * dayOfYear + 2) / 153;
        uint256 day = dayOfYear - (153 * marchMonth + 2) / 5 + 1;
        uint256 month = marchMonth < 10 ? marchMonth + 3 : marchMonth - 9;
        if (month <= 2) ++year;
        return string.concat(
            _decimal(year), "-", month < 10 ? "0" : "", _decimal(month), "-", day < 10 ? "0" : "", _decimal(day)
        );
    }

    /// @dev Convert an unsigned integer to decimal ASCII without an external library.
    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 copy = value;
        uint256 length;
        while (copy != 0) {
            ++length;
            copy /= 10;
        }
        bytes memory result = new bytes(length);
        while (value != 0) {
            result[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(result);
    }
}
