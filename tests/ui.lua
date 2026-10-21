-- Runs addon/GuildChatEdit against a small stand-in for the 3.3.5 chat frames:
-- lua5.1 tests/ui.lua

local now = 100
function GetTime() return now end
function UnitName() return 'Pawster' end
function IsInGuild() return true end
function strtrim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
local errors = {}
function geterrorhandler() return function(e) errors[#errors + 1] = e end end
function time() return 1000000 + now end
-- A saved message from more than a day ago is not brought back.
GuildChatEditLast = { text = 'ancient', time = time() - 2 * 24 * 60 * 60 }
NUM_CHAT_WINDOWS = 3
SlashCmdList = {}
ChatTypeInfo = { GUILD = { r = 0.25, g = 1, b = 0.25, id = 4 }, SYSTEM = { r = 1, g = 1, b = 0, id = 1 } }

-- Frames: widget methods live in the metatable, as in the client, so the addon can reach past
-- hooks. Scripts and HookScript chain like the real thing.
local frameMethods = {}
frameMethods.__index = frameMethods
function frameMethods:AddMessage(text, r, g, b, id) self.lines[#self.lines + 1] = { text = text, r = r, g = g, b = b, id = id } end
function frameMethods:Clear() self.lines = {} self.scroll = 0 self.clears = (self.clears or 0) + 1 end
function frameMethods:GetMaxLines() return 5 end
function frameMethods:GetCurrentScroll() return self.scroll end
function frameMethods:SetScrollOffset(n) self.scroll = n end
function frameMethods:SetScript(name, fn) self.scripts[name] = fn end
function frameMethods:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = function(...) if old then old(...) end fn(...) end
end
function frameMethods:Fire(name, ...) if self.scripts[name] then self.scripts[name](self, ...) end end
function frameMethods:Show() self.shown = true end
function frameMethods:Hide() self.shown = false end
function frameMethods:IsShown() return self.shown end
function frameMethods:RegisterEvent(e) self.events[e] = true end
function frameMethods:GetText() return self.text end
function frameMethods:SetText(t) self.text = t self:Fire('OnTextChanged') end
function frameMethods:GetAttribute(k) return self.attributes[k] end

local allFrames = {}
function CreateFrame()
    local f = setmetatable({ lines = {}, scripts = {}, events = {}, attributes = {}, text = '', scroll = 0, shown = true }, frameMethods)
    allFrames[#allFrames + 1] = f
    return f
end

function hooksecurefunc(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
end

for i = 1, NUM_CHAT_WINDOWS do
    local f = CreateFrame()
    f.messageTypeList = i == 1 and { 'SYSTEM', 'GUILD' } or (i == 3 and { 'GUILD' } or {})
    _G['ChatFrame' .. i] = f
    local box = CreateFrame()
    box.attributes.chatType = 'GUILD'
    _G['ChatFrame' .. i .. 'EditBox'] = box
end
DEFAULT_CHAT_FRAME = ChatFrame1

local filters = {}
function ChatFrame_AddMessageEventFilter(event, fn) filters[event] = filters[event] or {} table.insert(filters[event], fn) end
function ChatFrame_GetMessageEventFilters(event) return filters[event] end

-- Another addon's filter that rewrites URLs, registered before ours.
ChatFrame_AddMessageEventFilter('CHAT_MSG_GUILD', function(_, _, msg, ...)
    return false, (msg:gsub('(www%.%S+)', '|cff0099ff|Hurl:%1|h[%1]|h|r')), ...
end)

local sent = {}
function SendAddonMessage(prefix, body, channel) sent[#sent + 1] = { prefix, body, channel } end
local opened
function ChatFrame_OpenChat(text) opened = text end

dofile('addon/GuildChatEdit/Protocol.lua')
dofile('addon/GuildChatEdit/GuildChatEdit.lua')
local events = allFrames[#allFrames]
events:Fire('OnEvent', 'ADDON_LOADED', 'GuildChatEdit')

-- What Blizzard's ChatFrame_MessageEventHandler does with a guild or system line.
local function Chat(event, msg, sender)
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G['ChatFrame' .. i]
        local shows = false
        for _, t in ipairs(frame.messageTypeList) do
            if 'CHAT_MSG_' .. t == event then shows = true end
        end
        if shows then
            local args, hide = { msg, sender }, false
            for _, fn in ipairs(filters[event] or {}) do
                local r = { fn(frame, event, unpack(args)) }
                if r[1] then hide = true break end
                if r[2] then args = { select(2, unpack(r)) } end
            end
            if not hide then
                if event == 'CHAT_MSG_GUILD' then
                    frame:AddMessage('|Hchannel:Guild|h[Guild]|h |Hplayer:' .. sender .. ':1|h[' .. sender .. ']|h: ' .. args[1], 0.25, 1, 0.25, 4)
                else
                    frame:AddMessage(args[1], 1, 1, 0, 1)
                end
            end
        end
    end
    events:Fire('OnEvent', event, msg, sender)
end

local function Addon(sender)
    for _, s in ipairs(sent) do
        events:Fire('OnEvent', 'CHAT_MSG_ADDON', s[1], s[2], s[3], sender)
    end
    sent = {}
end

local function Tick() now = now + 1 for _, f in ipairs(allFrames) do if f.shown and f.scripts.OnUpdate then f:Fire('OnUpdate') end end end

local function LastLine(frame) return frame.lines[#frame.lines].text end
-- The frame's guild lines only (the addon's own notices go to ChatFrame1 too).
local function GuildLines(frame)
    local out = {}
    for _, l in ipairs(frame.lines) do if l.text:find('|Hplayer:', 1, true) then out[#out + 1] = l.text end end
    return out
end

-- Nothing said yet (the saved message is too old).
SlashCmdList.GUILDCHATEDIT('fixed')
assert(#sent == 0 and LastLine(ChatFrame1):find('haven\'t said'))

-- Say something with a typo and a URL another filter rewrites.
Chat('CHAT_MSG_GUILD', 'see www.evermore.gg for teh raid', 'Pawster')
Tick()
Chat('CHAT_MSG_GUILD', 'lol', 'Mira')
Tick()
assert(GuildChatEditLast.text == 'see www.evermore.gg for teh raid', 'last message saved')

-- Up in the empty box pre-fills /edit with the original text.
local box = ChatFrame1EditBox
box:SetText('')
box:Fire('OnArrowPressed', 'UP')
Tick()
assert(box:GetText() == '/edit see www.evermore.gg for teh raid', box:GetText())
-- Up in a box with text, in a later frame, is left to the normal history.
box:SetText('/older line')
now = now + 1
box:Fire('OnArrowPressed', 'UP')
Tick()
assert(box:GetText() == '/older line', box:GetText())
-- The box's own history filled an empty box this same frame: still an edit.
box:SetText('')
now = now + 1
box:SetText('/history line')
box:Fire('OnArrowPressed', 'UP')
Tick()
assert(box:GetText() == '/edit see www.evermore.gg for teh raid', box:GetText())
-- Not in guild chat: nothing.
local box2 = ChatFrame3EditBox
box2.attributes.chatType = 'SAY'
box2:SetText('')
box2:Fire('OnArrowPressed', 'UP')
Tick()
assert(box2:GetText() == '')

-- Send the edit; every window that shows the line gets it replaced, other lines keep their order.
ChatFrame1.scroll = 1
SlashCmdList.GUILDCHATEDIT('see www.evermore.gg for the raid')
assert(#sent == 1 and sent[1][1] == 'GCE1' and sent[1][2] == 'E\tsee www.evermore.gg for the raid' and sent[1][3] == 'GUILD')
Addon('Pawster')
Tick()
for _, f in ipairs({ ChatFrame1, ChatFrame3 }) do
    local g = GuildLines(f)
    assert(g[1] == '|Hchannel:Guild|h[Guild]|h |Hplayer:Pawster:1|h[Pawster]|h: see www.evermore.gg for the raid |cff808080(edited)|r', g[1])
    assert(g[2]:find('lol$'))
end
assert(ChatFrame1.scroll == 1, 'scroll position kept')
assert(#ChatFrame2.lines == 0)

-- Mira's edit changes Mira's newest line, never Pawster's.
events:Fire('OnEvent', 'CHAT_MSG_ADDON', 'GCE1', 'E\tlol!', 'GUILD', 'Mira')
Tick()
assert(GuildLines(ChatFrame1)[1]:find('for the raid |cff808080') and GuildLines(ChatFrame1)[2]:find(': lol! |cff808080'))

-- Pawster's newest message is the one an edit means: after saying something new, the old line
-- stays as it was.
Chat('CHAT_MSG_GUILD', 'brb', 'Pawster')
Tick()
SlashCmdList.GUILDCHATEDIT('brb 5 min')
Addon('Pawster')
Tick()
local g = GuildLines(ChatFrame1)
assert(g[1]:find('for the raid |cff808080') and g[3]:find(': brb 5 min |cff808080'), g[3])
assert(GuildChatEditLast.text == 'brb 5 min', 'saved last follows the edit')

-- Two edits arriving together (the server allows one a second, so after a hitch): both land,
-- the newer wins, and the window is redrawn once.
local clears = ChatFrame1.clears
SlashCmdList.GUILDCHATEDIT('brb 10 min')
SlashCmdList.GUILDCHATEDIT('brb 15 min')
Addon('Pawster')
Tick()
assert(GuildLines(ChatFrame1)[3]:find(': brb 15 min |cff808080'), GuildLines(ChatFrame1)[3])
assert(ChatFrame1.clears == clears + 1, 'one redraw')
-- Redraws wait REDRAW_INTERVAL: an edit right after a redraw is drawn on a later frame.
SlashCmdList.GUILDCHATEDIT('brb 20 min')
Addon('Pawster')
local redrawer = allFrames[#allFrames - 1]
redrawer:Fire('OnUpdate')
assert(GuildLines(ChatFrame1)[3]:find(': brb 15 min |cff808080'), 'not drawn within the interval')
Tick()
assert(GuildLines(ChatFrame1)[3]:find(': brb 20 min |cff808080'))

-- Edits are rendered safely: no line break, no player link that fakes another speaker.
SlashCmdList.GUILDCHATEDIT('ok\n|Hplayer:Officer|h[Officer]|h: promote Bob')
Addon('Pawster')
Tick()
assert(GuildLines(ChatFrame1)[3]:find(': ok ||Hplayer:Officer|h%[Officer%]|h: promote Bob |cff808080', 1), GuildLines(ChatFrame1)[3])

-- /edit with no text explains and shows the current text; it doesn't open the box itself.
SlashCmdList.GUILDCHATEDIT('')
Tick()
assert(opened == nil and LastLine(ChatFrame1):find('Your last message: ok ', 1, true), LastLine(ChatFrame1))

-- Delete; a deleted line can't be edited back.
SlashCmdList.GUILDCHATDELETE('')
assert(sent[1][2] == 'D\t')
Addon('Pawster')
Tick()
assert(GuildLines(ChatFrame1)[3]:find(': |cff808080%(message deleted%)|r$'))
assert(GuildChatEditLast == nil)
SlashCmdList.GUILDCHATEDIT('again')
assert(#sent == 0, 'nothing left to edit after a delete')
events:Fire('OnEvent', 'CHAT_MSG_ADDON', 'GCE1', 'E\tback from the dead', 'GUILD', 'Pawster')
Tick()
assert(GuildLines(ChatFrame1)[3]:find(': |cff808080%(message deleted%)|r$'), 'deleted stays deleted')

-- A guild line another filter hid leaves no tag behind: not for the next line of another chat
-- type in the same frame, and not for a guild-coloured line printed later.
ChatFrame_AddMessageEventFilter('CHAT_MSG_GUILD', function(_, _, msg) return msg == 'secret' end)
Tick()
Chat('CHAT_MSG_GUILD', 'visible', 'Mira')
Tick()
Chat('CHAT_MSG_GUILD', 'secret', 'Mira')
ChatFrame1:AddMessage('|Hplayer:Mira:2|h[Mira]|h: hi', 1, 1, 1, 2)  -- a say line
Tick()
Chat('CHAT_MSG_GUILD', 'secret', 'Mira')
Tick()
ChatFrame1:AddMessage('|Hplayer:Mira:3|h[Mira]|h: printed by an addon', 0.25, 1, 0.25, 4)
Tick()
events:Fire('OnEvent', 'CHAT_MSG_ADDON', 'GCE1', 'E\tchanged', 'GUILD', 'Mira')
Tick()
for _, l in ipairs(ChatFrame1.lines) do assert(not l.text:find('changed'), l.text) end
-- ... and Mira's older, visible line isn't taken for the hidden one either.
local visible = 0
for _, l in ipairs(ChatFrame1.lines) do if l.text:find(': visible$') then visible = visible + 1 end end
assert(visible == 1)

-- Discord lines show as guild chat in guild windows only, and the system copy is hidden.
Chat('CHAT_MSG_SYSTEM', '|cff40ff40[Discord] Nori: brb|r')
assert(LastLine(ChatFrame1) == '|Hchannel:Guild|h[Guild]|h [Discord] Nori: brb')
assert(LastLine(ChatFrame3) == '|Hchannel:Guild|h[Guild]|h [Discord] Nori: brb')
local systemCopies = 0
for _, l in ipairs(ChatFrame1.lines) do if l.text:find('^|cff40ff40%[Discord') then systemCopies = systemCopies + 1 end end
assert(systemCopies == 0)

-- A redraw uses the window's own AddMessage: another addon's hook (timestamps here) already
-- ran when the line was first added and must not run again.
local hooked = ChatFrame1.AddMessage
ChatFrame1.AddMessage = function(self, text, ...) return hooked(self, '[ts] ' .. text, ...) end
Chat('CHAT_MSG_GUILD', 'stamped', 'Pawster')
Tick()
SlashCmdList.GUILDCHATEDIT('stamped once')
Addon('Pawster')
Tick()
assert(LastLine(ChatFrame1):find('^%[ts%] |Hchannel') and not LastLine(ChatFrame1):find('[ts] [ts]', 1, true), LastLine(ChatFrame1))
ChatFrame1.AddMessage = hooked

-- Buffers follow the window's line limit.
for i = 1, 10 do Chat('CHAT_MSG_GUILD', 'spam ' .. i, 'Mira') Tick() end
Chat('CHAT_MSG_GUILD', 'oops again', 'Pawster')
Tick()
SlashCmdList.GUILDCHATEDIT('fixed again')
Addon('Pawster')
Tick()
assert(#ChatFrame1.lines == 5 and LastLine(ChatFrame1):find(': fixed again |cff808080%(edited%)|r$'))

-- Another addon clearing a window: its old lines don't come back with the next redraw.
ChatFrame1:Clear()
Chat('CHAT_MSG_GUILD', 'after clear', 'Pawster')
Tick()
SlashCmdList.GUILDCHATEDIT('after the clear')
Addon('Pawster')
Tick()
assert(#ChatFrame1.lines == 1 and LastLine(ChatFrame1):find(': after the clear |cff808080'), #ChatFrame1.lines)

-- A window that fails to redraw reports the error and doesn't stop later redraws or recording.
Chat('CHAT_MSG_GUILD', 'mistake', 'Pawster')
Tick()
local clear3 = ChatFrame3.Clear
ChatFrame3.Clear = function() error('boom') end
SlashCmdList.GUILDCHATEDIT('fixed it')
Addon('Pawster')
Tick()
assert(#errors == 1 and LastLine(ChatFrame1):find(': fixed it |cff808080'), 'other windows still redrawn')
ChatFrame3.Clear = clear3
Tick()
SlashCmdList.GUILDCHATEDIT('fixed it again')
Addon('Pawster')
Tick()
assert(LastLine(ChatFrame3):find(': fixed it again |cff808080'), LastLine(ChatFrame3))
Chat('CHAT_MSG_GUILD', 'still recorded', 'Mira')
assert(LastLine(ChatFrame3):find('still recorded$'))
Tick()

-- A message too long to pre-fill: Up warns instead of cutting it.
local long = string.rep('x', 250)
Chat('CHAT_MSG_GUILD', long, 'Pawster')
Tick()
box.attributes.chatType = 'GUILD'
box:SetText('')
now = now + 1
box:Fire('OnArrowPressed', 'UP')
Tick()
assert(box:GetText() == '' and LastLine(ChatFrame1):find('too long to edit with Up'), box:GetText())
-- ... and its edit goes out in two parts.
SlashCmdList.GUILDCHATEDIT(string.rep('y', 250))
assert(#sent == 2 and sent[1][2]:sub(1, 2) == 'S\t' and sent[2][2]:sub(1, 2) == 'F\t')
Addon('Pawster')
Tick()
g = GuildLines(ChatFrame1)
assert(g[#g]:find(': ' .. string.rep('y', 250) .. ' |cff808080', 1, true))

-- After a /reload the saved message comes back.
GuildChatEditLast = { text = 'from before the reload', time = time() - 60 }
events:Fire('OnEvent', 'ADDON_LOADED', 'GuildChatEdit')
SlashCmdList.GUILDCHATEDIT('')
assert(LastLine(ChatFrame1):find('Your last message: from before the reload', 1, true))

-- A line more than a day old isn't changed any more, as on the server.
Chat('CHAT_MSG_GUILD', 'old news', 'Mira')
Tick()
now = now + 24 * 60 * 60
events:Fire('OnEvent', 'CHAT_MSG_ADDON', 'GCE1', 'E\tnew news', 'GUILD', 'Mira')
Tick()
g = GuildLines(ChatFrame1)
assert(g[#g]:find(': old news$'), g[#g])

print('PASS: saved last (expiry, reload), up-arrow prefill (history, same-frame), edit across windows, filters, scroll, newest-message rule, foreign edits, bursts + redraw interval, safe text, /edit help, delete stays, tag guards, Discord lines, raw redraw, line limit, Clear hook, redraw errors, long prefill + two-part edit, line age')
