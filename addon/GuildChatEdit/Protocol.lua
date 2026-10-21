-- GuildChatEdit protocol: no WoW API here, so tests/protocol.lua can run it under plain Lua 5.1.
--
-- Only the sender's LAST guild message can change. Edits and deletes go out as guild addon
-- messages with prefix GCE1:
--   E \t <new text>     edit
--   S \t <first part>   start of a two-part edit (text over one addon message)
--   F \t <second part>  finish of it; needs the S from the same sender within 10 seconds
--   D \t                delete
-- With mod-guild-chat-bridge (src/GuildChatBridgeText.h) the server reads the same messages,
-- keeps Discord in step and blocks any it refuses, so no client shows those.

GuildChatEditProtocol = {}
local P = GuildChatEditProtocol

P.PREFIX = "GCE1"
P.MAX_TEXT = 255
-- An addon message holds 254 bytes of prefix, tab and body; the body header is 2 bytes.
P.CHUNK = 240
P.PART_TIMEOUT = 10
P.DISCORD_PREFIX = "|cff40ff40[Discord] "

-- The addon message bodies for an edit (text) or a delete (text == nil).
function P.Encode(text)
    if not text then
        return { "D\t" }
    end
    if #text <= P.CHUNK then
        return { "E\t" .. text }
    end
    -- Cut before a UTF-8 continuation byte would split a character.
    local cut = P.CHUNK
    while cut > 1 and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return { "S\t" .. text:sub(1, cut), "F\t" .. text:sub(cut + 1) }
end

function P.NewDecoder()
    return { open = {} }
end

-- Feeds one body from `sender` at time `now` (seconds). Returns "edit", text or "delete" once
-- complete. Any message but F ends a pending S, so a refused or lost F can't leak into the next
-- edit.
function P.Feed(decoder, sender, body, now)
    local op, text = body:match("^([ESFD])\t(.*)$")
    if not op then
        return nil
    end
    local open = decoder.open[sender]
    decoder.open[sender] = nil
    if op == "S" then
        if text ~= "" and #text < P.MAX_TEXT then
            decoder.open[sender] = { text = text, time = now }
        end
        return nil
    elseif op == "F" then
        if not open or now - open.time > P.PART_TIMEOUT then
            return nil
        end
        text = open.text .. text
    elseif op == "D" then
        return "delete"
    end
    if text == "" or #text > P.MAX_TEXT then
        return nil
    end
    return "edit", text
end

-- Where the message text starts in a formatted guild line: right after the sender's player
-- link, "|Hplayer:Name...|h[Name]|h: ". Timestamps or a channel tag before it don't matter.
function P.BodyStart(line)
    local link = line:find("|Hplayer:", 1, true)
    if not link then
        return nil
    end
    local _, close = line:find("|h: ", link, true)
    return close and close + 1 or nil
end

-- The line with its message text replaced; nil when the line doesn't have the usual shape.
function P.ReplaceBody(line, body)
    local start = P.BodyStart(line)
    if not start then
        return nil
    end
    return line:sub(1, start - 1) .. body
end

-- Links an edit may carry. Player and channel links are left out on purpose: with them an
-- edit could draw a line that looks like someone else said it.
P.LINK_TYPES = {
    item = true, spell = true, enchant = true, quest = true,
    achievement = true, talent = true, trade = true, glyph = true,
}

-- Edits come from other players' addons. Control characters (newlines) become spaces and runs
-- of spaces one space, so an edit can't push text onto a wrapped line of its own that looks
-- like someone else's (the server stores edits the same way). Colours and the links above stay;
-- any other escape (textures, player links) shows as plain text.
function P.SafeText(text)
    text = text:gsub("[%z\1-\31\127]", " "):gsub("  +", " ")
    local out, i = {}, 1
    while true do
        local p = text:find("|", i, true)
        if not p then
            out[#out + 1] = text:sub(i)
            break
        end
        out[#out + 1] = text:sub(i, p - 1)
        local c = text:sub(p + 1, p + 1)
        if c == "|" or c == "c" or c == "r" or c == "h"
            or (c == "H" and P.LINK_TYPES[text:match("^(%a+):", p + 2) or ""]) then
            out[#out + 1] = "|" .. c
            i = p + 2
        else
            out[#out + 1] = "||"
            i = p + 1
        end
    end
    return table.concat(out)
end

function P.EditedBody(text)
    return text .. " |cff808080(edited)|r"
end

P.DELETED_BODY = "|cff808080(message deleted)|r"

-- "Name: text" from a Discord system line, or nil for any other line.
function P.ParseDiscordLine(msg)
    if msg:sub(1, #P.DISCORD_PREFIX) ~= P.DISCORD_PREFIX then
        return nil
    end
    local rest = msg:sub(#P.DISCORD_PREFIX + 1)
    if rest:sub(-2) == "|r" then
        rest = rest:sub(1, -3)
    end
    return rest
end
