"""MySQL smoke test for mod-guild-chat-bridge. Needs a throwaway MySQL 8 server; it DROPS and
recreates the database named in GCB_TEST_DB_NAME (default gcb_smoke_test). Run from the repo root:

    docker run -d --rm --name gcb-sqltest -e MYSQL_ROOT_PASSWORD=test -p 127.0.0.1:33061:3306 mysql:8.4
    pip install -r discord-bridge/requirements.txt
    python3 tests/sql_smoke.py

The module's statements are taken from src/GuildChatBridge.cpp itself (string literals of the
Execute/AsyncQuery calls), with {} filled in the way fmt would, so the test runs exactly what the
worldserver would send. The bridge runs with its real Database class and a fake Discord webhook.
"""
import asyncio
import os
import re
import sys
import types

import pymysql

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, REPO + "/discord-bridge")
import bridge  # noqa: E402

DB = dict(host=os.environ.get("GCB_TEST_DB_HOST", "127.0.0.1"), port=int(os.environ.get("GCB_TEST_DB_PORT", "33061")),
          user=os.environ.get("GCB_TEST_DB_USER", "root"), password=os.environ.get("GCB_TEST_DB_PASSWORD", "test"))
NAME = os.environ.get("GCB_TEST_DB_NAME", "gcb_smoke_test")
CPP = open(REPO + "/src/GuildChatBridge.cpp").read()


def function_body(name):
    start = CPP.index(name + "(")
    brace = CPP.index("{", start)
    depth, i = 0, brace
    while True:
        if CPP[i] == "{":
            depth += 1
        elif CPP[i] == "}":
            depth -= 1
            if depth == 0:
                return CPP[brace:i]
        i += 1


def statements(name):
    """Every SQL format string in function `name`, adjacent literals joined."""
    body = function_body(name)
    out = []
    for m in re.finditer(r'(?:Execute|StringFormat)\(\s*((?:"(?:[^"\\]|\\.)*"\s*)+)', body):
        out.append("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))))
    return out


def fill(fmt, *args):
    parts = fmt.split("{}")
    assert len(parts) == len(args) + 1, (fmt, args)
    s = parts[0]
    for a, p in zip(args, parts[1:]):
        s += str(a) + p
    return s


def esc(text):
    return pymysql.converters.escape_string(text)


conn = pymysql.connect(autocommit=True, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor, **DB)
cur = conn.cursor()


def q(sql, args=None):
    cur.execute(sql, args)
    return cur.fetchall()


def warnings():
    return [w["Message"] for w in q("SHOW WARNINGS")]


def run_file(path):
    sql = open(path).read()
    sql = "\n".join(line for line in sql.splitlines() if not line.strip().startswith("--"))
    for stmt in sql.split(";"):
        if stmt.strip():
            cur.execute(stmt)


print("MySQL", q("SELECT VERSION() v")[0]["v"], "sql_mode:", q("SELECT @@sql_mode m")[0]["m"])
q("DROP DATABASE IF EXISTS `%s`" % NAME)
q("CREATE DATABASE `%s`" % NAME)
q("USE `%s`" % NAME)
q("CREATE TABLE updates (name VARCHAR(200) PRIMARY KEY)")
q("CREATE TABLE guild (guildid INT UNSIGNED PRIMARY KEY, name VARCHAR(24))")
q("INSERT INTO guild VALUES (1, 'Raiders'), (4, 'Crafters')")

INSTALL = REPO + "/data/sql/db-characters/mod_guild_chat_bridge_characters.sql"
UNINSTALL = REPO + "/data/sql/uninstall/mod_guild_chat_bridge_uninstall_characters.sql"
run_file(INSTALL)
run_file(INSTALL)  # re-runnable
print("install applied twice: ok")

(RECORD,) = statements("uint64 Record")
(STORE,) = statements("void StoreChange")
PRUNE = statements("void Prune")
POLL, DELIVERED = statements("void Poll")
print("statements from the C++:", 2 + len(PRUNE) + 2)


def record(id_, text, guild=1, guid=42, name="Pawster", cls=3):
    q(fill(RECORD, id_, guild, guid, esc(name), cls, esc(text)))


def change(id_, rev, text="", deleted=False, guild=1, guid=42, name="Pawster", cls=3):
    d = 1 if deleted else 0
    # The same argument order as StoreChange in the C++.
    q(fill(STORE, id_, guild, guid, esc(name), cls, esc(text), d, rev, rev, d, esc(text), rev, d, rev, rev))
    return warnings()


def row(id_):
    return q("SELECT text, deleted, rev, pending, synced_rev, edited_at IS NOT NULL AS edited, "
             "guild_id, sender_name FROM guild_chat_bridge_message WHERE id = %s", (id_,))[0]


def reset():
    q("DELETE FROM guild_chat_bridge_message")
    q("DELETE FROM guild_chat_bridge_inbound")


# Every order the async workers can run a message and its changes in.
reset()
record(1, "helo")
r = row(1)
assert (r["text"], r["rev"], r["deleted"], r["pending"], r["edited"]) == ("helo", 1, 0, 1, 0), r
w = change(1, 2, "hello")
change(1, 3, "hello all")
r = row(1)
assert (r["text"], r["rev"], r["edited"]) == ("hello all", 3, 1), r
assert not w, w
print("insert, edit, edit: ok (no warnings)")

reset()
change(2, 2, "hello")          # the edit's worker ran first
record(2, "helo")              # then the INSERT: a no-op
r = row(2)
assert (r["text"], r["rev"], r["edited"], r["deleted"]) == ("hello", 2, 1, 0), r
print("edit before insert: ok")

reset()
change(3, 2, "", deleted=True)
record(3, "oops")
r = row(3)
assert (r["deleted"], r["rev"]) == (1, 2), r
print("delete before insert: ok (text %r, never posted)" % r["text"])

reset()
record(4, "a")
change(4, 3, "c")
change(4, 2, "b")              # the older edit's worker ran last
r = row(4)
assert (r["text"], r["rev"]) == ("c", 3), r
print("newer edit before older: ok")

reset()
record(5, "a")
change(5, 2, "b")
change(5, 3, "", deleted=True)
r = row(5)
assert (r["deleted"], r["rev"], r["text"]) == (1, 3, "b"), r
print("edit then delete: ok")

reset()
text = "it's a \\ test with \"quotes\", café, \U0001f600 and |cff1eff00|Hitem:1|h[Bread]|h|r"
record(6, text)
assert row(6)["text"] == text
long = "é" * 255
record(7, long)
assert row(7)["text"] == long
change(7, 2, "x" * 255)
assert row(7)["text"] == "x" * 255
print("escaping, utf8mb4, 255 characters: ok")

for p in PRUNE:
    q(fill(p, 30) if "{}" in p else p)
print("prune statements: ok")


# The bridge with its real Database class.
class Hook:
    def __init__(self):
        self.calls = []

    async def send(self, content, **kw):
        self.calls.append(("send", content, kw["username"]))
        return types.SimpleNamespace(id=900 + len(self.calls))

    async def edit_message(self, mid, content, allowed_mentions):
        self.calls.append(("edit", mid, content))

    async def delete_message(self, mid):
        self.calls.append(("delete", mid))


async def bridge_checks():
    env = {"GCB_DISCORD_TOKEN": "x", "GCB_CHANNELS": "1=111,4=444", "GCB_DB_HOST": DB["host"],
           "GCB_DB_PORT": str(DB["port"]), "GCB_DB_USER": DB["user"], "GCB_DB_PASSWORD": DB["password"],
           "GCB_DB_NAME": NAME}
    b = bridge.Bridge(bridge.Settings(env))
    hook = Hook()
    b.webhooks = {1: hook, 4: hook}
    reset()

    # Backlog: a row from before the bridge started is not posted.
    record(10, "old")
    q("UPDATE guild_chat_bridge_message SET created_at = NOW() - INTERVAL 1 HOUR WHERE id = 10")
    await b.db.execute(
        "UPDATE guild_chat_bridge_message SET synced_rev = rev, pending = 0 "
        "WHERE pending = 1 AND discord_id IS NULL AND created_at < NOW() - INTERVAL %s MINUTE", (10,))
    assert row(10)["pending"] == 0

    # Post, edit while syncing, delete.
    record(11, "helo")
    record(12, "unlinked guild", guild=7)
    await b.sync_once()
    assert hook.calls == [("send", "helo", "Pawster")], hook.calls
    r = row(11)
    assert (r["pending"], r["synced_rev"]) == (0, 1), r
    assert row(12)["pending"] == 0, "unserved guild cleared"

    rows = await b.db.query("SELECT id, guild_id, sender_name, sender_class, text, deleted, rev, discord_id, edited_at "
                            "FROM guild_chat_bridge_message WHERE id = 11")
    change(11, 2, "hello")
    stale = dict(rows[0])
    stale.update(rev=2, text="hello", edited_at="x")
    change(11, 3, "hello all")           # the worldserver changed it again during the sync
    await b.sync_row(stale)
    r = row(11)
    assert (r["pending"], r["synced_rev"], r["rev"]) == (1, 2, 3), r
    await b.sync_once()
    assert hook.calls[-1] == ("edit", 901, "hello all *(edited)*"), hook.calls
    assert row(11)["pending"] == 0

    change(11, 4, "", deleted=True)
    await b.sync_once()
    assert hook.calls[-1] == ("delete", 901)
    assert row(11)["pending"] == 0
    print("bridge sync (backlog, post, concurrent edit, edit, delete, unserved guild): ok")

    # Discord -> game: AUTO_INCREMENT ids, the worldserver's poll and delivered update.
    for name in ("Nori", "Mira"):
        msg = types.SimpleNamespace(webhook_id=None, author=types.SimpleNamespace(bot=False, display_name=name),
                                    channel=types.SimpleNamespace(id=444), clean_content="hi from " + name, attachments=[])
        await b.on_message(msg)
    rows = q(fill(POLL, 0))
    assert [(r["guild_id"], r["author"], r["text"]) for r in rows] == [(4, "Nori", "hi from Nori"), (4, "Mira", "hi from Mira")], rows
    ids = ",".join(str(r["id"]) for r in rows)
    q(fill(DELIVERED, ids))
    assert not q(fill(POLL, 0))  # PyMySQL returns () for no rows
    print("Discord -> game (inbound ids %s, poll, delivered): ok" % ids)

    names = await b.db.query("SELECT guildid, name FROM guild WHERE guildid IN (%s,%s)", [1, 4])
    assert {r["guildid"]: r["name"] for r in names} == {1: "Raiders", 4: "Crafters"}
    print("guild names for the start-up log: ok")
    await b.close()


asyncio.run(bridge_checks())

run_file(UNINSTALL)
left = q("SHOW TABLES LIKE 'guild_chat_bridge%'")
assert not left, left
run_file(INSTALL)
print("uninstall, then install again: ok")
q("DROP DATABASE `%s`" % NAME)
print("PASS: schema install/re-run/uninstall, every order of message and changes, escaping, prune, bridge sync and inbound on MySQL")
