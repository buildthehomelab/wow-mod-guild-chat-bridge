/*
 * mod-guild-chat-bridge: links guild chat with Discord through two tables in the characters
 * database, so the worldserver never talks to the internet itself.
 *
 *   guild_chat_bridge_message  guild chat of real players, with later edits and deletes from the
 *                              GuildChatEdit addon (`rev` goes up on each change). The Discord
 *                              bridge (discord-bridge/) posts and edits these.
 *   guild_chat_bridge_inbound  messages from the Discord channel. This module shows each one to
 *                              the guild's online players once.
 *   guild_chat_bridge_name     the name a player chose for Discord with .chatname, per account.
 *                              Without one, Discord shows the character name.
 *
 * It also judges the addon's edits in every guild, recorded or not: addon messages skip the
 * core's mute, flood, UTF-8 and link checks, so refused edits are blocked here before anyone
 * sees them.
 *
 * Bots (sessions without a socket) are never relayed, so the channel only carries real players.
 *
 * Released under the MIT License, see LICENSE.
 */

#include "GuildChatBridgeText.h"

#include "CharacterCache.h"
#include "Chat.h"
#include "ChatCommand.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Guild.h"
#include "GuildMgr.h"
#include "Hyperlinks.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "QueryCallback.h"
#include "ScriptMgr.h"
#include "StringFormat.h"
#include "Timer.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include <algorithm>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <utility>

using namespace Acore::ChatCommands;

namespace GuildChatBridge
{
    namespace
    {
        struct Config
        {
            bool enable = false;
            std::unordered_set<uint32_t> guilds;  // empty = no guild
            uint32 pollInterval = 1000;
            uint32 keepDays = 30;
            bool loginNotice = true;
        };

        Config config;

        constexpr uint32 PruneInterval = HOUR * IN_MILLISECONDS;

        // Never destroyed: a static processor could outlive the database pools at shutdown.
        QueryCallbackProcessor& Queries()
        {
            static QueryCallbackProcessor* processor = new QueryCallbackProcessor();
            return *processor;
        }

        bool pollInFlight = false;
        uint32 pollTimer = 0;
        uint32 pruneTimer = 0;
        uint64 lastInboundId = 0;

        // Row ids are handed out here, not by AUTO_INCREMENT, so an edit knows its row before the
        // INSERT has run: the async queue spreads statements over several workers, and an edit's
        // statement may run first.
        uint64 nextMessageId = 0;

        // Kept across logouts, so an edit after a relog still finds its message; entries older
        // than a day are pruned with the tables.
        std::unordered_map<ObjectGuid::LowType, EditGate> gates;

        NameBook names;

        // Bots are sessions without a socket. AzerothCore marks them with
        // WorldSession::IsHeadless(); older playerbots core forks have WorldSession::IsBot()
        // instead, and older stock cores have neither. Looking for both at compile time lets the
        // module build on all of them.
        template <typename Session, typename = void>
        struct HasIsHeadless : std::false_type { };

        template <typename Session>
        struct HasIsHeadless<Session, std::void_t<decltype(std::declval<Session&>().IsHeadless())>> : std::true_type { };

        template <typename Session, typename = void>
        struct HasIsBot : std::false_type { };

        template <typename Session>
        struct HasIsBot<Session, std::void_t<decltype(std::declval<Session&>().IsBot())>> : std::true_type { };

        template <typename Session>
        bool IsBotSession(Session* session)
        {
            if constexpr (HasIsHeadless<Session>::value)
                return session->IsHeadless();
            else if constexpr (HasIsBot<Session>::value)
                return session->IsBot();
            else
                return false;
        }

        bool IsRealPlayer(Player const* player)
        {
            WorldSession* session = player ? player->GetSession() : nullptr;
            return session && !IsBotSession(session);
        }

        bool Relays(uint32 guildId)
        {
            return config.enable && config.guilds.count(guildId);
        }

        uint64 Now()
        {
            return uint64(GameTime::GetGameTime().count());
        }

        std::string Escaped(std::string text)
        {
            CharacterDatabase.EscapeString(text);
            return text;
        }

        // What Discord shows for this player: the name chosen for the account, else the character.
        std::string DisplayName(Player* player)
        {
            uint32 const account = player->GetSession()->GetAccountId();
            if (std::string const* chosen = names.Get(account))
                return *chosen;
            // A character created after someone else chose that name mustn't pass for them, and
            // one named "System" mustn't pass for the system.
            std::string const& name = player->GetName();
            return names.IsTakenByOther(name, account) || IsReservedChosenName(name) ? name + "*" : name;
        }

        void LoadConfig()
        {
            config.enable = sConfigMgr->GetOption<bool>("GuildChatBridge.Enable", false);
            config.pollInterval = std::max<uint32>(250, sConfigMgr->GetOption<uint32>("GuildChatBridge.PollInterval", 1000));
            config.keepDays = sConfigMgr->GetOption<uint32>("GuildChatBridge.KeepDays", 30);
            config.loginNotice = sConfigMgr->GetOption<bool>("GuildChatBridge.LoginNotice", true);

            std::vector<std::string> bad;
            config.guilds = ParseGuildIds(sConfigMgr->GetOption<std::string>("GuildChatBridge.Guilds", ""), bad);
            for (std::string const& token : bad)
                LOG_ERROR("module", "mod-guild-chat-bridge: GuildChatBridge.Guilds has '{}', which is not a guild id", token);
            if (config.enable && config.guilds.empty())
                LOG_WARN("module", "mod-guild-chat-bridge: GuildChatBridge.Guilds is empty, so no guild goes to Discord");
        }

        void LoadNextMessageId()
        {
            if (QueryResult result = CharacterDatabase.Query("SELECT COALESCE(MAX(`id`), 0) FROM `guild_chat_bridge_message`"))
                nextMessageId = std::max(nextMessageId, result->Fetch()[0].Get<uint64>());
        }

        void LoadNames()
        {
            QueryResult result = CharacterDatabase.Query("SELECT `account_id`, `display_name` FROM `guild_chat_bridge_name`");
            if (!result)
                return;
            do
            {
                Field* fields = result->Fetch();
                uint32 const account = fields[0].Get<uint32>();
                std::string const name = fields[1].Get<std::string>();
                if (!names.Load(account, name))
                    LOG_ERROR("module", "mod-guild-chat-bridge: account {} and another both hold the name '{}'; ignoring it for this one", account, name);
            } while (result->NextRow());
        }

        void SaveName(uint32 account, std::string const& name)
        {
            CharacterDatabase.Execute("REPLACE INTO `guild_chat_bridge_name` (`account_id`, `display_name`) VALUES ({}, '{}')", account, Escaped(name));
        }

        void DeleteName(uint32 account)
        {
            CharacterDatabase.Execute("DELETE FROM `guild_chat_bridge_name` WHERE `account_id` = {}", account);
        }

        void Prune()
        {
            if (config.keepDays)
                CharacterDatabase.Execute("DELETE FROM `guild_chat_bridge_message` WHERE `created_at` < NOW() - INTERVAL {} DAY", config.keepDays);
            CharacterDatabase.Execute("DELETE FROM `guild_chat_bridge_inbound` WHERE `created_at` < NOW() - INTERVAL 1 DAY");
        }

        void PruneGates()
        {
            uint64 const now = Now();
            for (auto it = gates.begin(); it != gates.end();)
            {
                auto const& last = it->second.Last();
                if (!last || now - last->sentAt > EditGate::MaxAge)
                    it = gates.erase(it);
                else
                    ++it;
            }
        }

        // The INSERT leaves a row alone that an edit created first (see nextMessageId).
        uint64 Record(Player* player, Guild* guild, std::string const& message)
        {
            uint64 const id = ++nextMessageId;
            CharacterDatabase.Execute(
                "INSERT INTO `guild_chat_bridge_message` (`id`, `guild_id`, `sender_guid`, `sender_name`, `sender_class`, `text`) "
                "VALUES ({}, {}, {}, '{}', {}, '{}') ON DUPLICATE KEY UPDATE `id` = `id`",
                id, guild->GetId(), player->GetGUID().GetCounter(), Escaped(DisplayName(player)), uint32(player->getClass()),
                Escaped(message));
            return id;
        }

        // An edit or delete as revision `rev` of row `id`. Whichever of the INSERT and the
        // changes runs first, the row ends at the highest revision: MySQL applies these
        // assignments left to right, so `rev` comes last. The new values are written out again
        // in the UPDATE part instead of VALUES(), which MySQL 8.0.20+ deprecates and a row alias
        // would need MySQL 8.0.19+ and rule out MariaDB.
        void StoreChange(Player* player, EditGate::LastMessage const& last, uint32 rev, bool deleted, std::string const& text)
        {
            std::string const escapedText = Escaped(text);
            uint32 const deletedFlag = deleted ? 1 : 0;
            CharacterDatabase.Execute(
                "INSERT INTO `guild_chat_bridge_message` (`id`, `guild_id`, `sender_guid`, `sender_name`, `sender_class`, `text`, `deleted`, `rev`, `edited_at`) "
                "VALUES ({}, {}, {}, '{}', {}, '{}', {}, {}, NOW()) ON DUPLICATE KEY UPDATE "
                "`text` = IF({} > `rev` AND {} = 0, '{}', `text`), "
                "`deleted` = IF({} > `rev`, {}, `deleted`), "
                "`edited_at` = IF({} > `rev`, NOW(), `edited_at`), "
                "`pending` = 1, "
                "`rev` = GREATEST(`rev`, {})",
                last.id, last.guildId, player->GetGUID().GetCounter(), Escaped(DisplayName(player)), uint32(player->getClass()),
                escapedText, deletedFlag, rev,
                rev, deletedFlag, escapedText,
                rev, deletedFlag,
                rev,
                rev);
        }

        void Notify(Player* player, EditGate::Refusal refusal)
        {
            char const* reason = nullptr;
            switch (refusal)
            {
                case EditGate::Refusal::TooFast: reason = "wait a moment between edits."; break;
                case EditGate::Refusal::NothingToEdit: reason = "there's no recent guild message of yours to change."; break;
                case EditGate::Refusal::Deleted: reason = "that message was deleted."; break;
                case EditGate::Refusal::TooOld: reason = "messages older than a day can't be changed."; break;
                case EditGate::Refusal::BadText: reason = "that edit has text or links that aren't allowed."; break;
                case EditGate::Refusal::Malformed:
                case EditGate::Refusal::None:
                    return;
            }
            ChatHandler(player->GetSession()).SendSysMessage(std::string("|cff40ff40Guild Chat Edit:|r ") + reason);
        }

        // Returns false for an edit or delete the server refuses, so it isn't broadcast either:
        // the server decides for the game and Discord alike. Other addons' messages pass.
        bool ApplyAddonMessage(Player* player, Guild* guild, std::string const& message)
        {
            std::optional<AddonMessage> parsed = ParseAddonMessage(message);
            if (!parsed)
                return true;
            if (!player->CanSpeak())
            {
                if (parsed->op != AddonOp::Finish)
                    ChatHandler(player->GetSession()).SendSysMessage("|cff40ff40Guild Chat Edit:|r you can't change messages while muted.");
                return false;
            }

            bool const recorded = Relays(guild->GetId());
            EditGate& gate = gates[player->GetGUID().GetCounter()];
            uint32 const nowMs = getMSTime();
            EditGate::Outcome outcome = gate.Feed(*parsed, guild->GetId(), recorded, nowMs, Now());

            if (outcome.kind == EditGate::Outcome::Kind::Edit && !Acore::Hyperlinks::CheckAllLinks(outcome.text))
            {
                outcome.kind = EditGate::Outcome::Kind::Refuse;
                outcome.refusal = EditGate::Refusal::BadText;
            }

            switch (outcome.kind)
            {
                case EditGate::Outcome::Kind::Pass:
                    return true;
                case EditGate::Outcome::Kind::Refuse:
                    Notify(player, outcome.refusal);
                    return false;
                case EditGate::Outcome::Kind::Edit:
                case EditGate::Outcome::Kind::Delete:
                    break;
            }

            uint32 const rev = gate.Commit(outcome, nowMs);
            auto const& last = gate.Last();
            if (recorded && last && last->id)
                StoreChange(player, *last, rev, outcome.kind == EditGate::Outcome::Kind::Delete, outcome.text);
            // The addon collapses spaces the same way when it shows the edit.
            return true;
        }

        // A system line, sent to the guild's real players who may listen to guild chat. Bots
        // have no use for it.
        void Deliver(uint32 guildId, std::string const& author, std::string const& text)
        {
            Guild* guild = Relays(guildId) ? sGuildMgr->GetGuildById(guildId) : nullptr;
            if (!guild)
                return;

            WorldPacket data;
            ChatHandler::BuildChatPacket(data, CHAT_MSG_SYSTEM, LANG_UNIVERSAL, static_cast<WorldObject const*>(nullptr),
                static_cast<WorldObject const*>(nullptr), FormatDiscordLine(author, text));

            for (auto const& [guid, player] : ObjectAccessor::GetPlayers())
                if (player && player->IsInWorld() && player->GetGuildId() == guildId && IsRealPlayer(player)
                    && guild->HasRankRight(player, GR_RIGHT_GCHATLISTEN))
                    player->SendDirectMessage(&data);
        }

        // Only rows from the last five minutes are shown, so messages written while the
        // worldserver was down don't flood in at startup. `lastInboundId` keeps a row from being
        // shown twice while its `delivered` update is still queued.
        void Poll()
        {
            pollInFlight = true;
            Queries().AddCallback(CharacterDatabase.AsyncQuery(Acore::StringFormat(
                "SELECT `id`, `guild_id`, `author`, `text` FROM `guild_chat_bridge_inbound` "
                "WHERE `delivered` = 0 AND `id` > {} AND `created_at` > NOW() - INTERVAL 5 MINUTE ORDER BY `id` LIMIT 20",
                lastInboundId))
                .WithCallback([](QueryResult result)
                {
                    pollInFlight = false;
                    if (!result)
                        return;

                    std::string ids;
                    do
                    {
                        Field* fields = result->Fetch();
                        uint64 const id = fields[0].Get<uint64>();
                        Deliver(fields[1].Get<uint32>(), fields[2].Get<std::string>(), fields[3].Get<std::string>());
                        lastInboundId = std::max(lastInboundId, id);
                        if (!ids.empty())
                            ids += ',';
                        ids += std::to_string(id);
                    } while (result->NextRow());

                    CharacterDatabase.Execute("UPDATE `guild_chat_bridge_inbound` SET `delivered` = 1 WHERE `id` IN ({})", ids);
                }));
        }

        void Update(uint32 diff)
        {
            Queries().ProcessReadyCallbacks();

            pruneTimer += diff;
            if (pruneTimer >= PruneInterval)
            {
                pruneTimer = 0;
                PruneGates();
                if (config.enable)
                    Prune();
            }

            if (!config.enable || pollInFlight)
                return;

            pollTimer += diff;
            if (pollTimer < config.pollInterval)
                return;
            pollTimer = 0;
            Poll();
        }
    }

    class GuildChatBridgePlayerScript : public PlayerScript
    {
    public:
        GuildChatBridgePlayerScript() : PlayerScript("GuildChatBridgePlayerScript",
            {
                PLAYERHOOK_CAN_PLAYER_USE_GUILD_CHAT,
                PLAYERHOOK_ON_LOGIN
            }) { }

        // Called for normal guild chat and for guild addon messages alike. Only refused edits and
        // deletes of the GuildChatEdit addon are blocked.
        bool OnPlayerCanUseChat(Player* player, uint32 type, uint32 language, std::string& msg, Guild* guild) override
        {
            // The core checks the rank's speak right later, inside BroadcastToGuild; a line nobody
            // in game hears doesn't count, here or in Discord.
            if (type != CHAT_MSG_GUILD || !guild || !IsRealPlayer(player) || !guild->HasRankRight(player, GR_RIGHT_GCHATSPEAK))
                return true;

            if (language == LANG_ADDON)
                return ApplyAddonMessage(player, guild, msg);
            if (msg.empty())
                return true;

            uint64 const id = Relays(guild->GetId()) ? Record(player, guild, msg) : 0;
            gates[player->GetGUID().GetCounter()].Said(id, guild->GetId(), Now());
            return true;
        }

        void OnPlayerLogin(Player* player) override
        {
            if (config.loginNotice && player->GetGuildId() && Relays(player->GetGuildId()) && IsRealPlayer(player))
                ChatHandler(player->GetSession()).SendSysMessage(
                    "|cff40ff40Guild chat:|r your guild's chat also goes to its Discord channel, and messages from there appear here. "
                    "Discord shows your character name, or the name you set with .chatname <name>.");
        }
    };

    class GuildChatBridgeCommandScript : public CommandScript
    {
    public:
        GuildChatBridgeCommandScript() : CommandScript("GuildChatBridgeCommandScript") { }

        ChatCommandTable GetCommands() const override
        {
            static ChatCommandTable commands =
            {
                { "chatname", HandleChatName, SEC_PLAYER, Console::No }
            };
            return commands;
        }

        // .chatname            shows the name
        // .chatname <name>     sets it for every character of the account
        // .chatname clear      goes back to the character name
        static bool HandleChatName(ChatHandler* handler, Tail text)
        {
            Player* player = handler->GetPlayer();
            if (!IsRealPlayer(player))
                return true;

            auto say = [handler](std::string const& message)
            {
                handler->SendSysMessage("|cff40ff40Guild chat:|r " + message);
            };

            if (!config.enable)
            {
                say("guild chat isn't linked to Discord on this realm.");
                return true;
            }

            uint32 const account = player->GetSession()->GetAccountId();
            std::string const wanted(text);
            if (wanted.find_first_not_of(' ') == std::string::npos)
            {
                std::string const* chosen = names.Get(account);
                say(chosen ? "Discord shows you as " + *chosen + ". Change it with .chatname <name>, or .chatname clear for your character name."
                           : "Discord shows your character name. Choose one name for all your characters with .chatname <name>.");
                return true;
            }

            std::string name;
            NameRefusal const refusal = NormalizeChosenName(wanted, name);

            // Checked ahead of the reserved names, which include this word.
            if (LowerAscii(name) == "clear")
            {
                if (names.TooSoon(account, getMSTime()))
                {
                    say("wait a few seconds between name changes.");
                    return true;
                }
                names.Clear(account);
                DeleteName(account);
                say("Discord will show your character name.");
                return true;
            }

            switch (refusal)
            {
                case NameRefusal::Length:
                    say("a name is " + std::to_string(MinChosenName) + " to " + std::to_string(MaxChosenName) + " characters, with at least two letters or digits.");
                    return true;
                case NameRefusal::Characters:
                    say("a name starts with a letter and uses English letters, digits from 2 to 9, spaces, - and _.");
                    return true;
                case NameRefusal::Reserved:
                    say("that name is reserved.");
                    return true;
                case NameRefusal::None:
                    break;
            }

            // The lists the realm's admins keep for character names.
            std::string const key = NameKey(name);
            if (sObjectMgr->IsReservedName(name) || sObjectMgr->IsProfanityName(name)
                || sObjectMgr->IsReservedName(key) || sObjectMgr->IsProfanityName(key))
            {
                say("that name is reserved.");
                return true;
            }

            // Not another player's chosen name, and not a character on someone else's account.
            std::string characterName = key;
            ObjectGuid const character = normalizePlayerName(characterName) ? sCharacterCache->GetCharacterGuidByName(characterName) : ObjectGuid::Empty;
            if (names.IsTakenByOther(name, account)
                || (character && sCharacterCache->GetCharacterAccountIdByGuid(character) != account))
            {
                say("that name is taken.");
                return true;
            }

            // The last check, so a typo or a taken name doesn't start the wait.
            if (names.TooSoon(account, getMSTime()))
            {
                say("wait a few seconds between name changes.");
                return true;
            }

            names.Set(account, name);
            SaveName(account, name);
            say("Discord will show you as " + name + " on all your characters. Messages already posted keep their old name.");
            return true;
        }
    };

    class GuildChatBridgeWorldScript : public WorldScript
    {
    public:
        GuildChatBridgeWorldScript() : WorldScript("GuildChatBridgeWorldScript",
            {
                WORLDHOOK_ON_AFTER_CONFIG_LOAD,
                WORLDHOOK_ON_STARTUP,
                WORLDHOOK_ON_UPDATE
            }) { }

        void OnAfterConfigLoad(bool /*reload*/) override
        {
            LoadConfig();
        }

        // Synchronous queries at startup, before players are in.
        void OnStartup() override
        {
            LoadNextMessageId();
            LoadNames();
            if (config.enable)
                Prune();
        }

        void OnUpdate(uint32 diff) override
        {
            Update(diff);
        }
    };
}

void AddGuildChatBridgeScripts()
{
    new GuildChatBridge::GuildChatBridgePlayerScript();
    new GuildChatBridge::GuildChatBridgeCommandScript();
    new GuildChatBridge::GuildChatBridgeWorldScript();
}
