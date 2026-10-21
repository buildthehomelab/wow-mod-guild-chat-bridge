-- Runs under plain Lua 5.1: lua5.1 tests/protocol.lua
dofile('addon/GuildChatEdit/Protocol.lua')
local P = GuildChatEditProtocol

local function expand(s)
    return (s:gsub('{(.)(%d+)}', function(c, n) return string.rep(c, tonumber(n)) end))
end

-- Short edit: one E part.
local bodies = P.Encode('fixed typo')
assert(#bodies == 1 and bodies[1] == 'E\tfixed typo')
local d = P.NewDecoder()
local kind, text = P.Feed(d, 'Pawster', bodies[1], 0)
assert(kind == 'edit' and text == 'fixed typo')

-- Long edit: S then F, each fitting an addon message, joined again.
-- 241 ASCII bytes then é's: byte 241 would be the second byte of an é, so the cut backs off.
local msg = string.rep('a', 239) .. string.rep('\195\169', 8)  -- 255 bytes
bodies = P.Encode(msg)
assert(#bodies == 2 and bodies[1]:sub(1, 2) == 'S\t' and bodies[2]:sub(1, 2) == 'F\t')
assert(#bodies[1] - 2 == 239, 'cut backed off one byte: ' .. (#bodies[1] - 2))
for _, b in ipairs(bodies) do
    assert(#P.PREFIX + 1 + #b <= 254, 'addon message too long')
    local part = b:sub(3)
    assert(not (part:byte(1) >= 0x80 and part:byte(1) < 0xC0), 'part starts mid-character')
end
assert(not P.Feed(d, 'Pawster', bodies[1], 0))
kind, text = P.Feed(d, 'Pawster', bodies[2], 1)
assert(kind == 'edit' and text == msg)

-- Parts from two senders don't mix.
local a, b = P.Encode(string.rep('x', 250)), P.Encode(string.rep('y', 250))
P.Feed(d, 'A', a[1], 0); P.Feed(d, 'B', b[1], 0)
assert(select(2, P.Feed(d, 'A', a[2], 0)) == string.rep('x', 250))
assert(select(2, P.Feed(d, 'B', b[2], 0)) == string.rep('y', 250))

-- Malformed, empty, delete.
assert(not P.Feed(d, 'A', 'X\tnope', 0))
assert(not P.Feed(d, 'A', 'E\t', 0))
assert(not P.Feed(d, 'A', 'E', 0))
assert(P.Feed(d, 'A', 'D\t', 0) == 'delete')

-- The same sequences as the server's EditGate (tests/text.cpp). The addon only gets what the
-- server let through, and shows SafeText of it.
local f = assert(io.open('tests/vectors.tsv'))
local dec, rows = P.NewDecoder(), 0
for line in f:lines() do
    if line ~= '' and line:sub(1, 1) ~= '#' then
        local ms, op, body, outcome, result = line:match('^(%d+)\t(%a)\t([^\t]*)\t(%a+)\t?(.*)$')
        assert(ms, 'bad vector line: ' .. line)
        if outcome ~= 'refuse' then
            local k, t = P.Feed(dec, 'Pawster', op .. '\t' .. expand(body), tonumber(ms) / 1000)
            if outcome == 'pass' then
                assert(k == nil, line)
            elseif outcome == 'delete' then
                assert(k == 'delete', line)
            else
                assert(k == 'edit' and P.SafeText(t) == expand(result), line .. ' -> ' .. tostring(t))
            end
        end
        rows = rows + 1
    end
end
f:close()
assert(rows > 10)

-- An S whose F never came (the server refused it) doesn't leak into the next edit.
dec = P.NewDecoder()
P.Feed(dec, 'A', 'S\t' .. string.rep('s', 240), 0)
assert(select(2, P.Feed(dec, 'A', 'E\tshort fix', 1)) == 'short fix')
assert(not P.Feed(dec, 'A', 'F\tlate', 2), 'the E ended the S')
-- ... or into an F that comes too late.
P.Feed(dec, 'A', 'S\t' .. string.rep('s', 240), 0)
assert(not P.Feed(dec, 'A', 'F\tlate', 11))

-- Body replacement keeps timestamps and the sender link.
local gline = '12:01 |Hchannel:Guild|h[Guild]|h |Hplayer:Pawster:42|h[Pawster]|h: helo all'
assert(P.ReplaceBody(gline, P.EditedBody('hello all'))
    == '12:01 |Hchannel:Guild|h[Guild]|h |Hplayer:Pawster:42|h[Pawster]|h: hello all |cff808080(edited)|r')
-- A message that itself contains "|h: " (a link) is cut after the sender, not after the link.
gline = '[Guild] |Hplayer:Pawster:1|h[Pawster]|h: look |Hitem:19019|h[Thunderfury]|h: wow'
assert(P.ReplaceBody(gline, 'x') == '[Guild] |Hplayer:Pawster:1|h[Pawster]|h: x')
assert(P.ReplaceBody('no link here', 'x') == nil)

-- Edits can't smuggle textures, line breaks, player links or runs of spaces; item-like links
-- and colours stay.
assert(P.SafeText('|TInterface\\Icons\\x:0|t hi') == '||TInterface\\Icons\\x:0||t hi')
assert(P.SafeText('|cff1eff00|Hitem:1|h[Bread]|h|r') == '|cff1eff00|Hitem:1|h[Bread]|h|r')
assert(P.SafeText('|Hspell:133|h[Fireball]|h') == '|Hspell:133|h[Fireball]|h')
assert(P.SafeText('ok\n|Hplayer:Officer|h[Officer]|h: promote Bob')
    == 'ok ||Hplayer:Officer|h[Officer]|h: promote Bob')
assert(P.SafeText('|Hchannel:Guild|h[Guild]|h') == '||Hchannel:Guild|h[Guild]|h')
assert(P.SafeText('a || b') == 'a || b')
assert(P.SafeText('end|') == 'end||')
assert(P.SafeText('ok' .. string.rep(' ', 200) .. '[Officer]: give gold') == 'ok [Officer]: give gold')

-- Discord lines from the server.
assert(P.ParseDiscordLine('|cff40ff40[Discord] Mira: on my way|r') == 'Mira: on my way')
assert(P.ParseDiscordLine('You have learned a new spell') == nil)

print('PASS: encode/decode, long edits, senders, malformed, server vectors, stale parts, body replace, safe text, Discord lines')
