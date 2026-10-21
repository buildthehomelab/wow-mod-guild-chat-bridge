-- GuildChatEdit: edit or delete your last guild message.
--
-- In guild chat, press Up in an empty chat box: it fills with "/edit <your last message>".
-- Change the text and press Enter. Guild members with this addon see the line replaced and
-- marked "(edited)"; members without it keep seeing the original. /gdelete removes the line.
--
-- The send path is never replaced: hooking ChatEdit_SendText would taint typed /cast lines.
-- Editing is a normal slash command, and the edit box only gets pre-filled text.
--
-- A 3.3.5 chat window can't change a line it already shows, so the addon keeps its own copy of
-- each window's lines, and on an edit clears the window and adds them all back.
--
-- An edit always means the sender's newest guild message, as on the server. A line is only
-- changed when it is that message, so a message some other addon hid can't send the edit to an
-- older line.

local P = GuildChatEditProtocol

local decoder = P.NewDecoder()
local buffers = {}     -- [chat frame] = { { text, r, g, b, id, sender, msg, deleted }, ... }
local pendingTag = {}  -- [chat frame] = the guild message its next line belongs to
local newest = {}      -- [sender] = text of their newest guild message, as this client got it
local replaying = false
local last             -- your own last guild message: { text = now, time = time() sent }
local dirty = {}       -- [chat frame] = true while a redraw is queued

-- With mod-guild-chat-bridge the server lets one change a second through per sender. Without
-- it nothing limits a script, so windows are redrawn at most this often (seconds); every change
-- still lands, only the drawing waits.
local REDRAW_INTERVAL = 0.2
local MAX_AGE = 24 * 60 * 60

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40Guild Chat Edit:|r " .. text)
end

local function PlayerName()
    return (UnitName("player"))
end

local function GuildTypeId()
    local info = ChatTypeInfo and ChatTypeInfo.GUILD
    return info and info.id
end

-- Runs functions on the next frame, after the chat box has finished handling the key or Enter.
local deferred = {}
local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function(self)
    self:Hide()
    local list = deferred
    deferred = {}
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn)
        if not ok then
            geterrorhandler()(err)
        end
    end
end)

local function Defer(fn)
    deferred[#deferred + 1] = fn
    ticker:Show()
end

-- Line buffers ----------------------------------------------------------------------------------

local function OnAddMessage(frame, text, r, g, b, id)
    if replaying or type(text) ~= "string" then
        return
    end
    local list = buffers[frame]
    local entry = { text = text, r = r, g = g, b = b, id = id }

    -- The guild filter tagged this frame just before Blizzard formatted the line. The same
    -- frame tick and the guild colour id make sure the tag isn't left over from a line some
    -- other filter hid.
    local tag = pendingTag[frame]
    if tag then
        pendingTag[frame] = nil
        local guildId = GuildTypeId()
        if tag.time == GetTime() and (id == nil or guildId == nil or id == guildId) then
            entry.sender, entry.msg, entry.time = tag.sender, tag.msg, time()
        end
    end

    list[#list + 1] = entry
    local max = frame.GetMaxLines and frame:GetMaxLines() or 128
    while #list > max do
        table.remove(list, 1)
    end
end

local function GuildFilter(frame, _, msg, sender)
    if buffers[frame] and type(msg) == "string" then
        pendingTag[frame] = { sender = sender, msg = msg, time = GetTime() }
    end
    return false
end

-- Put a message filter first in line, so it sees the text as sent and not as rewritten by
-- another addon's filter (URL links, for example). Without ChatFrame_GetMessageEventFilters it
-- simply runs last; only messages another filter rewrote can't be edited then.
local function AddFilterFirst(event, fn)
    ChatFrame_AddMessageEventFilter(event, fn)
    local filters = ChatFrame_GetMessageEventFilters and ChatFrame_GetMessageEventFilters(event)
    if filters and filters[#filters] == fn then
        table.remove(filters)
        table.insert(filters, 1, fn)
    end
end

-- Everything runs under pcall, so an error can't leave `replaying` set (which would stop the
-- buffers) or a window half drawn without a report.
local function Redraw(frame)
    local list = buffers[frame]
    replaying = true
    local ok, err = pcall(function()
        local scroll = frame.GetCurrentScroll and frame:GetCurrentScroll() or 0
        -- The widget's own AddMessage, past every addon's hook: the lines are formatted already.
        local add = getmetatable(frame).__index.AddMessage
        frame:Clear()
        for _, e in ipairs(list) do
            add(frame, e.text, e.r, e.g, e.b, e.id)
        end
        if scroll > 0 then
            if frame.SetScrollOffset then
                frame:SetScrollOffset(scroll)
            else
                for _ = 1, scroll do
                    frame:ScrollUp()
                end
            end
        end
    end)
    replaying = false
    if not ok then
        geterrorhandler()(err)
    end
end

local lastRedraw = 0
local redrawer = CreateFrame("Frame")
redrawer:Hide()
redrawer:SetScript("OnUpdate", function(self)
    if GetTime() - lastRedraw < REDRAW_INTERVAL then
        return
    end
    self:Hide()
    lastRedraw = GetTime()
    local frames = dirty
    dirty = {}
    for frame in pairs(frames) do
        Redraw(frame)
    end
end)

-- Replaces `sender`'s newest line in every window that shows it, if that line is their newest
-- message and less than a day old (as on the server). A deleted line stays deleted.
local function Apply(sender, body, delete)
    for frame, list in pairs(buffers) do
        for i = #list, 1, -1 do
            local e = list[i]
            if e.sender == sender then
                local text = e.msg == newest[sender] and not e.deleted and time() - e.time < MAX_AGE
                    and P.ReplaceBody(e.text, body)
                if text then
                    e.text = text
                    e.deleted = delete
                    dirty[frame] = true
                    redrawer:Show()
                end
                break
            end
        end
    end
end

local function ShowsGuild(frame)
    for _, t in ipairs(frame.messageTypeList or {}) do
        if t == "GUILD" then
            return true
        end
    end
    return false
end

-- Discord lines from mod-guild-chat-bridge arrive as system lines. Show them as guild chat in
-- the windows that show guild chat instead.
local function DiscordFilter(_, _, msg)
    return type(msg) == "string" and P.ParseDiscordLine(msg) ~= nil
end

local function ShowDiscordLine(msg)
    local rest = P.ParseDiscordLine(msg)
    if not rest then
        return
    end
    local info = ChatTypeInfo.GUILD
    for frame in pairs(buffers) do
        if ShowsGuild(frame) then
            frame:AddMessage("|Hchannel:Guild|h[Guild]|h [Discord] " .. rest, info.r, info.g, info.b, info.id)
        end
    end
end

-- Editing --------------------------------------------------------------------------------------

-- The chat box holds 255 bytes, "/edit " included; a longer prefill would be cut off and the
-- cut text sent as the edit.
local function PrefillText()
    local text = "/edit " .. last.text
    if #text > P.MAX_TEXT then
        Print("that message is too long to edit with Up; type /edit and the new text.")
        return nil
    end
    return text
end

local function SendBodies(bodies)
    for _, body in ipairs(bodies) do
        SendAddonMessage(P.PREFIX, body, "GUILD")
    end
end

local function Edit(text)
    text = strtrim(text or "")
    if text == "" then
        -- Opening the chat box from here would mean ChatFrame_OpenChat, which writes the box's
        -- fields from addon code; Up in the box does it without that.
        if last then
            Print("type /edit and the new text, or press Up in an empty guild chat box. Your last message: " .. P.SafeText(last.text))
        else
            Print("you haven't said anything in guild chat yet.")
        end
        return
    end
    if not last then
        Print("you haven't said anything in guild chat yet.")
        return
    end
    if not IsInGuild() or text == last.text then
        return
    end
    if #text > P.MAX_TEXT then
        Print("that's longer than a chat message.")
        return
    end
    SendBodies(P.Encode(text))
end

local function Delete()
    if not last then
        Print("you haven't said anything in guild chat yet.")
        return
    end
    if IsInGuild() then
        SendBodies(P.Encode(nil))
    end
end

SLASH_GUILDCHATEDIT1 = "/edit"
SLASH_GUILDCHATEDIT2 = "/gedit"
SlashCmdList.GUILDCHATEDIT = Edit

SLASH_GUILDCHATDELETE1 = "/gdelete"
SLASH_GUILDCHATDELETE2 = "/unsay"
SlashCmdList.GUILDCHATDELETE = Delete

-- Up in an empty guild chat box starts an edit. Pressing Up again goes on through the normal
-- history. The text is set on the next frame, after the box's own history handling.
local function HookEditBox(box)
    if not box or box.gceHooked then
        return
    end
    box.gceHooked = true
    box:HookScript("OnTextChanged", function(self)
        self.gcePrev, self.gceText, self.gceChanged = self.gceText, self:GetText(), GetTime()
    end)
    box:HookScript("OnArrowPressed", function(self, key)
        if key ~= "UP" or not last or self:GetAttribute("chatType") ~= "GUILD" then
            return
        end
        local wasEmpty = self:GetText() == "" or (self.gcePrev == "" and self.gceChanged == GetTime())
        if not wasEmpty then
            return
        end
        local text = PrefillText()
        if not text then
            return
        end
        Defer(function()
            if self:IsShown() then
                self:SetText(text)
            end
        end)
    end)
end

-- Events ---------------------------------------------------------------------------------------

-- Your last message is kept per character (GuildChatEditLast), so Up still works after a
-- /reload or a relog, for a day.
local function SetLast(value)
    last = value
    GuildChatEditLast = value
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHAT_MSG_GUILD")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 == "GuildChatEdit" then
            local saved = GuildChatEditLast
            if type(saved) == "table" and type(saved.text) == "string" and type(saved.time) == "number"
                and time() - saved.time < MAX_AGE then
                last = saved
            end
        end
    elseif event == "CHAT_MSG_GUILD" then
        if type(a1) == "string" then
            newest[a2] = a1
            if a2 == PlayerName() then
                SetLast({ text = a1, time = time() })
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        if a1 ~= P.PREFIX or a3 ~= "GUILD" then
            return
        end
        local kind, text = P.Feed(decoder, a4, a2, GetTime())
        local mine = a4 == PlayerName() and last
        if kind == "edit" then
            Apply(a4, P.EditedBody(P.SafeText(text)))
            if mine then
                last.text = text
                GuildChatEditLast = last
            end
        elseif kind == "delete" then
            Apply(a4, P.DELETED_BODY, true)
            if mine then
                SetLast(nil)
            end
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        if type(a1) == "string" then
            ShowDiscordLine(a1)
        end
    end
end)

-- Hooked at load, before the login lines, so the buffers match what the windows show. Window 2
-- is the combat log: it never shows guild chat and would only fill a buffer.
for i = 1, NUM_CHAT_WINDOWS do
    local frame = _G["ChatFrame" .. i]
    if frame and i ~= 2 then
        buffers[frame] = {}
        hooksecurefunc(frame, "AddMessage", OnAddMessage)
        -- Another addon clearing the window: forget its lines too, or a redraw would bring
        -- them back.
        hooksecurefunc(frame, "Clear", function(self)
            if not replaying then
                buffers[self] = {}
            end
        end)
    end
    HookEditBox(_G["ChatFrame" .. i .. "EditBox"])
end
HookEditBox(ChatFrameEditBox)

AddFilterFirst("CHAT_MSG_GUILD", GuildFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", DiscordFilter)
