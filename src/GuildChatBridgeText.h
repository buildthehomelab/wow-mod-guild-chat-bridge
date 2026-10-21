/*
 * mod-guild-chat-bridge: the parts that need no core, so tests/text.cpp can run them alone.
 *
 * The GuildChatEdit addon (addon/GuildChatEdit/Protocol.lua) changes the sender's LAST guild
 * message, and only that one, with guild addon messages:
 *
 *   GCE1 \t E \t <new text>     edit
 *   GCE1 \t S \t <first part>   start of a two-part edit (text over one addon message)
 *   GCE1 \t F \t <second part>  finish of that edit; needs the S from the same sender just before
 *   GCE1 \t D \t                delete
 *
 * The server tracks each sender's last message itself (an id it gave the row), so the database
 * and Discord follow the same message the addon shows, whatever the text looks like on each
 * client (the profanity filter can rewrite it). The server is also the judge: an edit or delete
 * it refuses is not broadcast, so no client shows it either.
 *
 * Released under the MIT License, see LICENSE.
 */

#ifndef MOD_GUILD_CHAT_BRIDGE_TEXT_H
#define MOD_GUILD_CHAT_BRIDGE_TEXT_H

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace GuildChatBridge
{
    constexpr std::string_view AddonPrefix = "GCE1";

    // The client's chat box holds 255 bytes; an edit can't be longer than a message.
    constexpr std::size_t MaxMessageLength = 255;

    // The colour and tag every Discord line starts with. The addon looks for this exact prefix
    // to show the line as guild chat; players without it see a green system line.
    constexpr std::string_view DiscordLinePrefix = "|cff40ff40[Discord] ";

    enum class AddonOp : char
    {
        Edit = 'E',
        Start = 'S',
        Finish = 'F',
        Delete = 'D'
    };

    struct AddonMessage
    {
        AddonOp op;
        std::string text;
    };

    // `message` is the guild addon message as the server reads it: "<prefix>\t<body>".
    inline std::optional<AddonMessage> ParseAddonMessage(std::string_view message)
    {
        std::string const head = std::string(AddonPrefix) + "\t";
        if (message.substr(0, head.size()) != head)
            return std::nullopt;
        message.remove_prefix(head.size());

        // "<op>\t<text>"
        if (message.size() < 2 || message[1] != '\t')
            return std::nullopt;

        AddonMessage parsed;
        switch (message[0])
        {
            case 'E': parsed.op = AddonOp::Edit; break;
            case 'S': parsed.op = AddonOp::Start; break;
            case 'F': parsed.op = AddonOp::Finish; break;
            case 'D': parsed.op = AddonOp::Delete; break;
            default: return std::nullopt;
        }
        parsed.text = std::string(message.substr(2));
        return parsed;
    }

    // Whether an edit may be stored. Addon messages skip the core's chat checks (UTF-8,
    // newlines and other control characters), so edits are checked here. The core's link check
    // (Acore::Hyperlinks::CheckAllLinks) runs in GuildChatBridge.cpp.
    inline bool IsValidEditText(std::string_view text)
    {
        std::size_t i = 0;
        while (i < text.size())
        {
            unsigned char const c = static_cast<unsigned char>(text[i]);
            std::size_t extra;
            uint32_t codepoint;
            if (c < 0x80)
            {
                if (c < 0x20 || c == 0x7f)
                    return false;
                ++i;
                continue;
            }
            else if ((c & 0xE0) == 0xC0)
            {
                extra = 1;
                codepoint = c & 0x1F;
            }
            else if ((c & 0xF0) == 0xE0)
            {
                extra = 2;
                codepoint = c & 0x0F;
            }
            else if ((c & 0xF8) == 0xF0)
            {
                extra = 3;
                codepoint = c & 0x07;
            }
            else
                return false;

            if (i + extra >= text.size())
                return false;
            for (std::size_t k = 1; k <= extra; ++k)
            {
                unsigned char const next = static_cast<unsigned char>(text[i + k]);
                if ((next & 0xC0) != 0x80)
                    return false;
                codepoint = (codepoint << 6) | (next & 0x3F);
            }
            // Overlong forms, surrogates and values past Unicode.
            static constexpr uint32_t minimum[] = { 0, 0x80, 0x800, 0x10000 };
            if (codepoint < minimum[extra] || (codepoint >= 0xD800 && codepoint <= 0xDFFF) || codepoint > 0x10FFFF)
                return false;
            i += extra + 1;
        }
        return true;
    }

    // Runs of spaces become one, as the addon shows them: an edit can't push text onto a wrapped
    // line of its own that looks like someone else's.
    inline std::string CollapseSpaces(std::string_view text)
    {
        std::string out;
        out.reserve(text.size());
        for (char c : text)
            if (c != ' ' || out.empty() || out.back() != ' ')
                out += c;
        return out;
    }

    // One sender's last guild message and the edits to it. Pure bookkeeping: the caller checks
    // mute and links, writes the database and blocks what is refused.
    class EditGate
    {
    public:
        // Addon messages have no flood throttle in the core. One change a second per sender
        // keeps a script from hammering the database, Discord and everyone's chat window.
        static constexpr uint32_t ChangeInterval = 1000;   // ms
        static constexpr uint32_t PartTimeout = 10000;     // ms between S and its F
        static constexpr uint64_t MaxAge = 24 * 60 * 60;   // s; older messages can't be changed

        enum class Refusal
        {
            None,
            Malformed,      // an F without its S, too long, empty
            TooFast,
            NothingToEdit,  // no message recorded for this sender (in this guild)
            Deleted,
            TooOld,
            BadText
        };

        struct Outcome
        {
            enum class Kind
            {
                Pass,    // broadcast it; nothing to store (an accepted S)
                Refuse,
                Edit,
                Delete
            } kind = Kind::Refuse;
            Refusal refusal = Refusal::None;
            std::string text;  // Edit: the new text, spaces collapsed
        };

        struct LastMessage
        {
            uint64_t id = 0;       // row id, 0 when the guild isn't recorded
            uint32_t guildId = 0;
            uint64_t sentAt = 0;   // s
            uint32_t rev = 1;
            bool deleted = false;
        };

        // A new guild message from this sender. It becomes the one edits apply to.
        void Said(uint64_t id, uint32_t guildId, uint64_t now)
        {
            _last = LastMessage{ id, guildId, now, 1, false };
            _open.reset();
        }

        std::optional<LastMessage> const& Last() const { return _last; }

        // `recorded`: the guild's chat goes to the database, so an edit needs a recorded message
        // to apply to. Elsewhere the addon alone shows edits, and only the throttle, age and
        // text rules apply.
        Outcome Feed(AddonMessage const& message, uint32_t guildId, bool recorded, uint32_t nowMs, uint64_t now)
        {
            Outcome out;
            if (message.op == AddonOp::Finish)
            {
                if (!_open || nowMs - _open->startedMs > PartTimeout)
                {
                    _open.reset();
                    return Refuse(Refusal::Malformed);
                }
                std::string const text = _open->text + message.text;
                _open.reset();
                return CheckEdit(text);
            }

            // Any other op ends a pending S.
            _open.reset();

            if (_changed && nowMs - _lastChangeMs < ChangeInterval)
                return Refuse(Refusal::TooFast);
            // The last message was said in another guild (the sender switched guilds since).
            if (_last && _last->guildId != guildId)
                return Refuse(Refusal::NothingToEdit);
            if (recorded && (!_last || _last->id == 0))
                return Refuse(Refusal::NothingToEdit);
            if (_last && _last->deleted)
                return Refuse(Refusal::Deleted);
            if (_last && now - _last->sentAt > MaxAge)
                return Refuse(Refusal::TooOld);

            switch (message.op)
            {
                case AddonOp::Start:
                    if (message.text.empty() || message.text.size() >= MaxMessageLength)
                        return Refuse(Refusal::Malformed);
                    // The S counts as the change; its F only has to arrive in time.
                    _open = Open{ message.text, nowMs };
                    Stamp(nowMs);
                    out.kind = Outcome::Kind::Pass;
                    return out;
                case AddonOp::Edit:
                    return CheckEdit(message.text);
                case AddonOp::Delete:
                    out.kind = Outcome::Kind::Delete;
                    return out;
                case AddonOp::Finish:
                    break;
            }
            return Refuse(Refusal::Malformed);
        }

        // An Edit or Delete outcome the caller accepted: returns the message's new revision.
        uint32_t Commit(Outcome const& outcome, uint32_t nowMs)
        {
            Stamp(nowMs);
            if (!_last)
                return 0;
            ++_last->rev;
            if (outcome.kind == Outcome::Kind::Delete)
                _last->deleted = true;
            return _last->rev;
        }

    private:
        struct Open
        {
            std::string text;
            uint32_t startedMs;
        };

        static Outcome Refuse(Refusal refusal)
        {
            Outcome out;
            out.kind = Outcome::Kind::Refuse;
            out.refusal = refusal;
            return out;
        }

        static Outcome CheckEdit(std::string const& text)
        {
            if (text.empty() || text.size() > MaxMessageLength)
                return Refuse(Refusal::Malformed);
            if (!IsValidEditText(text))
                return Refuse(Refusal::BadText);
            Outcome out;
            out.kind = Outcome::Kind::Edit;
            out.text = CollapseSpaces(text);
            return out;
        }

        void Stamp(uint32_t nowMs)
        {
            _changed = true;
            _lastChangeMs = nowMs;
        }

        std::optional<LastMessage> _last;
        std::optional<Open> _open;
        bool _changed = false;
        uint32_t _lastChangeMs = 0;
    };

    // Text from Discord, made safe to show in the 3.3.5 client: '|' starts an escape sequence
    // there (colours, links, textures), so it is doubled, which the client shows as one '|'.
    // Control characters become spaces and the result is cut to `maxBytes` without splitting
    // a UTF-8 character; a cut line ends in "...".
    inline std::string SanitizeForGame(std::string_view text, std::size_t maxBytes)
    {
        std::string out;
        out.reserve(text.size());
        for (unsigned char c : text)
        {
            if (c < 0x20 || c == 0x7f)
                out += ' ';
            else if (c == '|')
                out += "||";
            else
                out += char(c);
        }

        if (out.size() > maxBytes && maxBytes > 3)
        {
            std::size_t cut = maxBytes - 3;
            while (cut > 0 && (static_cast<unsigned char>(out[cut]) & 0xC0) == 0x80)
                --cut;
            // Don't leave half of a doubled pipe behind.
            std::size_t pipes = 0;
            for (std::size_t i = cut; i > 0 && out[i - 1] == '|'; --i)
                ++pipes;
            if (pipes % 2)
                --cut;
            out.resize(cut);
            out += "...";
        }

        std::size_t const first = out.find_first_not_of(' ');
        if (first == std::string::npos)
            return {};
        out.erase(0, first);
        out.erase(out.find_last_not_of(' ') + 1);
        return out;
    }

    inline std::string FormatDiscordLine(std::string_view author, std::string_view text)
    {
        return std::string(DiscordLinePrefix) + SanitizeForGame(author, 32) + ": "
            + SanitizeForGame(text, MaxMessageLength) + "|r";
    }
}

#endif
