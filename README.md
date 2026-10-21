# mod-guild-chat-bridge

Guild chat for AzerothCore (3.3.5a) that you can fix after sending, and that reaches Discord.

- **GuildChatEdit addon**: in guild chat, press **Up** in an empty chat box. It fills with
  `/edit <your last message>`; fix the text and press Enter. Guild members with the addon see the
  line change to the new text, marked *(edited)*. `/gdelete` (or `/unsay`) removes the line.
  Members without the addon keep seeing what you first sent.
- **Server module**: checks every edit (mute, rate, text, links) and blocks the ones it refuses,
  so nobody sees them. For the guilds you link to Discord it also records real players' guild
  chat and its edits (bots and ranks that may not speak are skipped), and shows messages from
  Discord to the members who may listen to guild chat.
- **Discord bridge** (`discord-bridge/`): a small container that posts each guild's chat to its
  own Discord channel under each character's name and class icon, edits or deletes the Discord
  message when the line is edited or deleted in game, and sends the channel's messages back to
  that guild. All the channels can be in one Discord server.

The addon works on its own; with the module the server judges edits, and with the bridge they
reach Discord too.

## Requirements

- AzerothCore wotlk (master) with the WotLK 3.3.5a (12340) client, MySQL 8 (or MariaDB).
- The addon alone needs nothing on the server; with the module the server also judges edits.
- For Discord: Docker (or any Python 3.11 host that reaches the database), a Discord bot and one
  text channel per guild you link.
- Optional: [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots). Bots are never
  relayed; the module detects them with `WorldSession::IsHeadless()` when the core has it.
- Optional: DragonUI, whose chat settings let the Up key reach the chat box.

## The addon

| You do | What happens |
| --- | --- |
| Up in an empty guild chat box | The box fills with `/edit <your last guild message>`. Up again goes on through the normal chat history (it skips the newest history line). |
| `/edit <text>` (or `/gedit`) | Your last guild message becomes `<text>` for members with the addon. |
| `/edit` alone | Shows how to edit and your last message's current text. |
| `/gdelete` (or `/unsay`) | Your last guild message shows as *(message deleted)*. |

Only your last guild message can be changed, and only by you; saying something new makes that
the one. An edit is a hidden guild addon message: nobody without the addon sees anything, and
the original line stays in their chat. Your last message is remembered per character for a
day, so Up still works after a `/reload` or a relog. After a worldserver restart, messages from
before it can't be changed any more in guilds linked to Discord (the server answers "there's no
recent guild message of yours to change"); say something new and edit that.

With the module the server decides, and an edit or delete it refuses reaches nobody. It tells
you why: muted, more than one change a second, the message is over a day old or was deleted,
or the text has line breaks, broken characters or links that don't check out (the same link
check as normal chat, so textures and other escapes are refused). Runs of spaces in an edit
show as one space. Without the module, the addon itself keeps item, spell, quest, achievement,
talent, glyph and profession links and shows any other escape (textures, player links) as
plain text. Messages over 249 letters can't be pre-filled with Up (the chat box would cut
them); type `/edit <new text>` for those. With the mature language filter on, Up pre-fills
your message as your client shows it, symbols included.

**Up needs arrow keys that move the cursor in the chat box.** DragonUI's chat module sets
that. With the stock chat settings, arrow keys may turn your character instead; use
`/edit <new text>` then.

How it shows an edit: a 3.3.5 chat window can't change a line it already shows, so the addon
keeps a copy of each window's lines and, on an edit, clears the window and adds them all back.
Lines that had faded show up again for a few seconds, and a window is redrawn at most five times
a second. The send path is never replaced (that would break `/cast` typed into chat during
combat); editing is an ordinary slash command.

Discord messages arrive as green system lines starting with `[Discord]`. With the addon they
show as guild chat instead, in the windows that show guild chat.

Copy `addon/GuildChatEdit` into the client's `Interface/AddOns`, or hand it out with
Portalkeeper (`sql/portalkeeper_addon.sql`).

## Install the module

```sh
cd <azerothcore>/modules
git clone https://github.com/buildthehomelab/wow-mod-guild-chat-bridge.git mod-guild-chat-bridge
```

Clone into `mod-guild-chat-bridge` (without `wow-`): AzerothCore derives the loader name from the
folder. Re-run CMake, rebuild, copy `conf/mod_guild_chat_bridge.conf.dist` to
`mod_guild_chat_bridge.conf` and set `GuildChatBridge.Enable = 1`. The tables are created by the
database import (`data/sql/db-characters`).

| Setting | Default | |
| --- | --- | --- |
| `GuildChatBridge.Enable` | 0 | Record guild chat and show Discord messages. |
| `GuildChatBridge.Guilds` | "" | Guild ids to relay, comma-separated. Empty = all; set it to the guilds that have a Discord channel. |
| `GuildChatBridge.PollInterval` | 1000 | ms between checks for Discord messages (async query). |
| `GuildChatBridge.KeepDays` | 30 | Recorded chat older than this is deleted (at startup and hourly); 0 keeps it. |
| `GuildChatBridge.LoginNotice` | 1 | Tell members of linked guilds at login that their guild chat is shown in Discord. |

Guild ids are in `guild.guildid` of the characters database:

```sql
SELECT guildid, name FROM guild;
```

The edit checks run in every guild, linked or not, whenever the module is installed; `Enable`
only turns recording and Discord on.

## Set up Discord

1. At <https://discord.com/developers/applications> create an application, open **Bot**, reset
   and copy the **token**, and turn on **Message Content Intent**.
2. Invite the bot to your server with the permissions it needs (View Channel, Send Messages,
   Read Message History, Manage Webhooks); put your application id into
   `https://discord.com/oauth2/authorize?client_id=<application id>&scope=bot&permissions=536939520`.
3. Make a text channel for each guild you want to link (one Discord server can hold them all).
   In Discord turn on **Developer Mode** (Settings, Advanced), right-click each channel and
   **Copy Channel ID**.
4. Run the bridge next to the worldserver, on AzerothCore's Docker network:

```yaml
  guild-chat-bridge:
    image: python:3.11-slim
    working_dir: /app
    command: bash -c "pip install --quiet -r requirements.txt && exec python bridge.py"
    volumes:
      - ./modules/mod-guild-chat-bridge/discord-bridge:/app:ro
    networks:
      - ac-network
    environment:
      PYTHONUNBUFFERED: "1"
      GCB_DISCORD_TOKEN: ${GCB_DISCORD_TOKEN}
      GCB_CHANNELS: "1=111111111111111111,4=444444444444444444"   # <guild id>=<channel id>, one channel per guild
      GCB_DB_HOST: ac-database
      GCB_DB_PASSWORD: ${DOCKER_DB_ROOT_PASSWORD}
    restart: unless-stopped
    depends_on:
      ac-database:
        condition: service_healthy
```

5. Set `GuildChatBridge.Guilds` to the same guild ids (`"1,4"` here).

Keep the token in your `.env`, never in a file you commit.

### One Discord server, a channel per guild

Each `<guild id>=<channel id>` pair links one guild to one channel. The bridge makes its own
webhook in each channel, posts that guild's chat there, and sends that channel's messages to
that guild only. A channel can't serve two guilds: the bridge refuses to start and says which
entries clash. To add a guild later, make its channel, add the pair to `GCB_CHANNELS` and the id
to `GuildChatBridge.Guilds`, and restart both.

At start the bridge logs every link, for example:

```
guild 1 (Raiders) -> #raiders in Evermore
guild 4 (Crafters) -> #crafters in Evermore: missing permissions manage_webhooks
```

so a wrong id, a channel the bot can't see, or a missing permission shows straight away. If one
channel fails later (permission removed, channel deleted), the bridge retries that guild with a
growing delay and keeps posting for the others.

| Variable | Default | |
| --- | --- | --- |
| `GCB_DISCORD_TOKEN` | | The bot token. Without it the bridge starts and does nothing. |
| `GCB_CHANNELS` | | `<guild id>=<channel id>` pairs. |
| `GCB_DB_HOST` / `GCB_DB_PORT` | ac-database / 3306 | |
| `GCB_DB_USER` / `GCB_DB_PASSWORD` | root / | Only needs SELECT, INSERT, UPDATE on the two `guild_chat_bridge_*` tables and SELECT on `guild` (for the names in the start-up log). |
| `GCB_DB_NAME` | acore_characters | |
| `GCB_INTERVAL` | 1 | Seconds between checks for new guild chat. |
| `GCB_BACKLOG_MINUTES` | 10 | Guild chat older than this when the bridge starts is not posted. |
| `GCB_WEBHOOK_NAME` | Guild Chat | The bridge creates this webhook in each channel. |
| `GCB_ICON_URL` | Wowhead class icons | Avatar URL with `{}` for the class (`warrior`, `deathknight`, ...); empty turns avatars off. |

What gets through: item and spell links become their names, colours and textures are removed,
raid target icons become emoji, and nothing from the game can ping `@everyone` or anyone else.
From Discord: one line per message, mentions as names, custom emoji as `:name:`, attachments as
`[file name]`, long messages cut to one chat line ending in `...`. Emoji other than custom ones
may show as blanks in the 3.3.5 client. Edits made in Discord are not sent to the game.

Players are told at login that their guild's chat goes to Discord (`GuildChatBridge.LoginNotice`);
recorded chat is kept for `GuildChatBridge.KeepDays` days.

## Troubleshooting

- **Up does nothing.** Arrow keys turn your character instead of moving in the chat box (stock
  chat settings), or you haven't said anything in guild chat this day. Type `/edit <new text>`.
- **"there's no recent guild message of yours to change".** In a linked guild the server only
  knows messages since its last restart, and only from the guild you're in now.
- **Nothing reaches Discord.** Look at the bridge's start-up log: each `guild N -> #channel`
  line says whether the bot can see the channel and has its permissions. Check that
  `GuildChatBridge.Enable = 1` and the guild id is in `GuildChatBridge.Guilds`.
- **"sync failed" over and over.** The bridge can't reach the database: is it on `ac-network`
  and is `GCB_DB_PASSWORD` right?
- **Discord messages don't show in game.** Message Content Intent must be on for the bot, and
  the worldserver polls only while `GuildChatBridge.Enable = 1`. Messages older than five
  minutes when the worldserver sees them are skipped.

## Uninstall

Remove the module folder, stop the bridge, rebuild, then run
`data/sql/uninstall/mod_guild_chat_bridge_uninstall_characters.sql` on the characters database.
Messages already in Discord stay there.

## Tests

```sh
c++ -std=c++17 -Wall -Wextra -Werror -Isrc tests/text.cpp -o /tmp/text && /tmp/text
lua5.1 tests/protocol.lua && lua5.1 tests/ui.lua
python3 -m unittest discover -s tests -p 'test_*.py'
```

`tests/sql_smoke.py` runs the module's SQL (read from the C++) and the bridge against a throwaway
MySQL 8 server; see the top of the file for the `docker run` line. It drops and recreates its own
test database.

## Credits

Author: [buildthehomelab](https://github.com/buildthehomelab). Class icons in Discord are
Blizzard's art as hosted by Wowhead (`GCB_ICON_URL` to change or turn off).

## License

MIT, see [LICENSE](LICENSE).
