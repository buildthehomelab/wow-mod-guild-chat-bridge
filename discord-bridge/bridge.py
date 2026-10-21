"""Discord side of mod-guild-chat-bridge.

Game -> Discord: posts the rows of guild_chat_bridge_message through a webhook in each guild's
channel (named after the character, with its class icon), and edits or deletes the Discord
message when the GuildChatEdit addon changes the row.

Discord -> game: writes messages from those channels into guild_chat_bridge_inbound; the
worldserver shows them to the guild.

Settings come from the environment, see the README.
"""

import asyncio
import logging
import os
import sys
import time

import discord
import pymysql

from text import ICON_URL, class_icon, discord_to_game, game_to_discord, parse_channels, webhook_username

log = logging.getLogger("guild-chat-bridge")

# Discord JSON error codes.
UNKNOWN_MESSAGE = 10008
UNKNOWN_WEBHOOK = 10015


class Settings:
    def __init__(self, env):
        self.token = env.get("GCB_DISCORD_TOKEN", "").strip()
        self.channels = parse_channels(env.get("GCB_CHANNELS", ""))
        self.db = dict(
            host=env.get("GCB_DB_HOST", "ac-database"),
            port=int(env.get("GCB_DB_PORT", "3306")),
            user=env.get("GCB_DB_USER", "root"),
            password=env.get("GCB_DB_PASSWORD", ""),
            database=env.get("GCB_DB_NAME", "acore_characters"),
        )
        self.interval = float(env.get("GCB_INTERVAL", "1"))
        self.backlog_minutes = int(env.get("GCB_BACKLOG_MINUTES", "10"))
        self.webhook_name = env.get("GCB_WEBHOOK_NAME", "Guild Chat")
        self.icon_url = env.get("GCB_ICON_URL", ICON_URL)


class Database:
    """One connection, used from a worker thread, one call at a time."""

    def __init__(self, settings):
        self.settings = settings
        self.connection = None
        self.lock = asyncio.Lock()

    def _run(self, sql, args, fetch):
        if self.connection is None:
            # Timeouts: a hung query would hold the lock and stop both directions.
            self.connection = pymysql.connect(charset="utf8mb4", autocommit=True,
                                              cursorclass=pymysql.cursors.DictCursor,
                                              connect_timeout=10, read_timeout=30, write_timeout=30,
                                              **self.settings.db)
        else:
            self.connection.ping(reconnect=True)
        with self.connection.cursor() as cursor:
            cursor.execute(sql, args)
            return cursor.fetchall() if fetch else cursor.lastrowid

    async def query(self, sql, args=()):
        async with self.lock:
            return await asyncio.to_thread(self._run, sql, args, True)

    async def execute(self, sql, args=()):
        async with self.lock:
            return await asyncio.to_thread(self._run, sql, args, False)


class Bridge(discord.Client):
    def __init__(self, settings):
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(intents=intents, allowed_mentions=discord.AllowedMentions.none())
        self.settings = settings
        self.db = Database(settings)
        self.guild_of_channel = {channel: guild for guild, channel in settings.channels.items()}
        self.webhooks = {}
        self.failures = {}  # guild id -> failures in a row
        self.retry_at = {}  # guild id -> time.monotonic() before which it is skipped
        self.posted = {}    # row id -> Discord message id not yet saved in the row
        self.next_cleanup = 0.0
        self.sync_task = None
        self.reported = False

    async def setup_hook(self):
        self.sync_task = asyncio.create_task(self.sync_loop())

    async def on_ready(self):
        log.info("logged in as %s", self.user)
        if not self.reported:
            self.reported = True
            await self.report_channels()

    # Each guild has its own channel; all of them can be in one Discord server. Logged once at
    # start, so a wrong id or a missing permission shows straight away.
    async def report_channels(self):
        guilds = list(self.settings.channels)
        names = {}
        try:
            rows = await self.db.query(
                "SELECT guildid, name FROM guild WHERE guildid IN (" + ",".join(["%s"] * len(guilds)) + ")", guilds)
            names = {row["guildid"]: row["name"] for row in rows}
        except Exception as error:
            log.warning("could not read guild names: %s", error)
        for guild_id, channel_id in self.settings.channels.items():
            label = "guild %s (%s)" % (guild_id, names.get(guild_id, "not in the guild table"))
            try:
                channel = self.get_channel(channel_id) or await self.fetch_channel(channel_id)
            except discord.HTTPException as error:
                log.error("%s -> channel %s: the bot can't see it (%s)", label, channel_id, error)
                continue
            if not isinstance(channel, discord.TextChannel):
                log.error("%s -> channel %s is not a text channel; webhooks need one", label, channel_id)
                continue
            permissions = channel.permissions_for(channel.guild.me)
            missing = [name for name in ("view_channel", "send_messages", "read_message_history", "manage_webhooks")
                       if not getattr(permissions, name)]
            if missing:
                log.error("%s -> #%s in %s: missing permissions %s", label, channel.name, channel.guild.name, ", ".join(missing))
            else:
                log.info("%s -> #%s in %s", label, channel.name, channel.guild.name)

    async def webhook_for(self, guild_id):
        hook = self.webhooks.get(guild_id)
        if hook:
            return hook
        channel_id = self.settings.channels[guild_id]
        channel = self.get_channel(channel_id) or await self.fetch_channel(channel_id)
        for existing in await channel.webhooks():
            if existing.user == self.user and existing.name == self.settings.webhook_name:
                hook = existing
                break
        else:
            hook = await channel.create_webhook(name=self.settings.webhook_name)
        self.webhooks[guild_id] = hook
        return hook

    # Game -> Discord --------------------------------------------------------------------------

    async def sync_loop(self):
        await self.wait_until_ready()
        backlog_done = False
        while not self.is_closed():
            try:
                if not backlog_done:
                    # Rows from while the bridge was down are not posted all at once. Inside the
                    # loop, so a database that isn't up yet only delays the start.
                    await self.db.execute(
                        "UPDATE guild_chat_bridge_message SET synced_rev = rev, pending = 0 "
                        "WHERE pending = 1 AND discord_id IS NULL AND created_at < NOW() - INTERVAL %s MINUTE",
                        (self.settings.backlog_minutes,))
                    backlog_done = True
                await self.sync_once()
            except Exception:
                log.exception("sync failed")
                await asyncio.sleep(10)
            await asyncio.sleep(self.settings.interval)

    async def sync_once(self):
        now = time.monotonic()
        if now >= self.next_cleanup:
            # Guilds without a channel here would otherwise stay pending until pruned, and the
            # poll would walk past them every time.
            guilds = list(self.settings.channels)
            await self.db.execute(
                "UPDATE guild_chat_bridge_message SET pending = 0 WHERE pending = 1 AND guild_id NOT IN ("
                + ",".join(["%s"] * len(guilds)) + ")", guilds)
            self.next_cleanup = now + 60
        guilds = [g for g in self.settings.channels if self.retry_at.get(g, 0) <= now]
        if not guilds:
            return
        placeholders = ",".join(["%s"] * len(guilds))
        rows = await self.db.query(
            "SELECT id, guild_id, sender_name, sender_class, text, deleted, rev, discord_id, edited_at "
            "FROM guild_chat_bridge_message WHERE pending = 1 AND guild_id IN (" + placeholders + ") "
            "ORDER BY id LIMIT 25", guilds)
        failed = set()
        for row in rows:
            guild_id = row["guild_id"]
            if guild_id in failed:
                continue  # keep that guild's messages in order
            try:
                await self.sync_row(row)
                self.failures.pop(guild_id, None)
            except Exception:
                # One channel's trouble (permissions, a deleted channel, the webhook limit)
                # doesn't hold up the other guilds; that guild waits longer after each failure.
                failed.add(guild_id)
                count = self.failures[guild_id] = self.failures.get(guild_id, 0) + 1
                delay = min(300, 5 * 2 ** (count - 1))
                self.retry_at[guild_id] = time.monotonic() + delay
                log.exception("guild %s: message %s failed, retrying in %ss", guild_id, row["id"], delay)

    async def sync_row(self, row):
        hook = await self.webhook_for(row["guild_id"])
        # A message posted earlier whose row update failed: edit it instead of posting it again.
        discord_id = row["discord_id"] or self.posted.get(row["id"])
        content = game_to_discord(row["text"], edited=row["edited_at"] is not None)
        try:
            if discord_id is None:
                if not row["deleted"]:
                    message = await hook.send(content, username=webhook_username(row["sender_name"]),
                                              avatar_url=class_icon(row["sender_class"], self.settings.icon_url), wait=True,
                                              allowed_mentions=discord.AllowedMentions.none())
                    discord_id = message.id
                    self.posted[row["id"]] = discord_id
            elif row["deleted"]:
                await hook.delete_message(discord_id)
            else:
                await hook.edit_message(discord_id, content=content, allowed_mentions=discord.AllowedMentions.none())
        except discord.NotFound as error:
            if error.code == UNKNOWN_WEBHOOK:
                # Someone deleted the webhook: make a new one and try the row again.
                self.webhooks.pop(row["guild_id"], None)
                raise
            if discord_id is None or error.code != UNKNOWN_MESSAGE:
                raise  # an unknown channel, say: not something to skip silently
            # The message was deleted in Discord; leave it gone.
        except discord.HTTPException as error:
            if error.status != 400:
                raise  # permissions, rate limits, outages: try again later
            log.warning("Discord refused message %s (%s); skipping it", row["id"], error)
        # `pending` stays set when the worldserver changed the row again meanwhile.
        await self.db.execute(
            "UPDATE guild_chat_bridge_message SET discord_id = %s, synced_rev = %s, pending = (rev <> %s) WHERE id = %s",
            (discord_id, row["rev"], row["rev"], row["id"]))
        self.posted.pop(row["id"], None)

    # Discord -> game --------------------------------------------------------------------------

    async def on_message(self, message):
        if message.webhook_id or message.author.bot:
            return
        guild_id = self.guild_of_channel.get(message.channel.id)
        if guild_id is None:
            return
        text = discord_to_game(message.clean_content, [a.filename for a in message.attachments])
        if not text:
            return
        author = message.author.display_name[:64]
        for attempt in range(3):
            try:
                await self.db.execute(
                    "INSERT INTO guild_chat_bridge_inbound (guild_id, author, text) VALUES (%s, %s, %s)",
                    (guild_id, author, text))
                return
            except Exception:
                log.exception("could not store a Discord message (attempt %s of 3)", attempt + 1)
                await asyncio.sleep(2 * (attempt + 1))


async def idle():
    while True:
        await asyncio.sleep(3600)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        settings = Settings(os.environ)
    except ValueError as error:
        # A settings mistake: say so and wait for the fix, instead of restarting in a loop.
        log.error("%s", error)
        asyncio.run(idle())
        return
    if not settings.token or not settings.channels:
        # Started without settings (the container is in the stack but not set up yet): stay up
        # quietly instead of restarting in a loop.
        log.warning("GCB_DISCORD_TOKEN and GCB_CHANNELS are not set; the bridge does nothing")
        asyncio.run(idle())
        return
    Bridge(settings).run(settings.token, log_handler=None)


if __name__ == "__main__":
    sys.exit(main())
