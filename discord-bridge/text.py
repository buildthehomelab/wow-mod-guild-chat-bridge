"""Text conversion between 3.3.5 chat markup and Discord. No Discord or MySQL imports, so
tests/test_text.py can run it alone."""

import re

ICON_URL = "https://wow.zamimg.com/images/wow/icons/large/classicon_{}.jpg"
CLASS_ICONS = {
    1: "warrior", 2: "paladin", 3: "hunter", 4: "rogue", 5: "priest",
    6: "deathknight", 7: "shaman", 8: "mage", 9: "warlock", 11: "druid",
}

# Raid target icons, both spellings the client accepts.
RAID_ICONS = ["⭐", "\U0001f7e0", "\U0001f7e3", "\U0001f53a", "\U0001f319", "\U0001f7e6", "❌", "\U0001f480"]
RAID_ICON_NAMES = ["star", "circle", "diamond", "triangle", "moon", "square", "cross", "skull"]

_PIPE = "\x00"
_LINK = re.compile(r"\|H[^|]*\|h(.*?)\|h", re.S)
_COLOUR = re.compile(r"\|c[0-9a-fA-F]{8}")
_TEXTURE = re.compile(r"\|T.*?\|t", re.S)
_MARKDOWN = re.compile(r"([\\*_`~|>#\[\]()-])")
_RAID = re.compile(r"\{(rt[1-8]|star|circle|diamond|triangle|moon|square|cross|x|skull)\}", re.I)
_CUSTOM_EMOJI = re.compile(r"<a?:(\w+):\d+>")
_SPACE = re.compile(r"\s+")
_URL = re.compile(r"(https?://\S+)")
_RESERVED = re.compile(r"discord|clyde", re.I)


def _raid_icon(match):
    name = match.group(1).lower()
    if name.startswith("rt"):
        return RAID_ICONS[int(name[2:]) - 1]
    if name == "x":
        name = "cross"
    return RAID_ICONS[RAID_ICON_NAMES.index(name)]


def game_to_discord(text, edited=False):
    """Guild chat text with client markup -> Discord message content (plain, escaped)."""
    text = text.replace("||", _PIPE)
    text = _LINK.sub(lambda m: m.group(1), text)
    text = _TEXTURE.sub("", text)
    text = _COLOUR.sub("", text).replace("|r", "")
    # Links stay clickable; everything else is shown as typed.
    text = "".join(part if i % 2 else _MARKDOWN.sub(r"\\\1", part) for i, part in enumerate(_URL.split(text)))
    text = text.replace(_PIPE, "\\|")
    text = _RAID.sub(_raid_icon, text)
    if edited:
        text += " *(edited)*"
    return text or "​"


def discord_to_game(content, attachments=(), limit=1024):
    """A Discord message -> one line for guild chat. The worldserver escapes '|' itself."""
    text = _CUSTOM_EMOJI.sub(r":\1:", content)
    text = _SPACE.sub(" ", text).strip()
    extra = " ".join("[%s]" % name for name in attachments)
    text = (text + " " + extra).strip() if extra else text
    return text[:limit]


def webhook_username(name):
    """Discord refuses webhook names containing "discord" or "clyde", and the names "everyone"
    and "here"."""
    name = _RESERVED.sub(lambda m: m.group(0)[0] + "\u200b" + m.group(0)[1:], name)
    if name.lower() in ("everyone", "here"):
        name = name[0] + "\u200b" + name[1:]
    return name or "?"


def class_icon(class_id, template=ICON_URL):
    """The avatar for a class; `template` "" turns avatars off."""
    slug = CLASS_ICONS.get(class_id)
    return template.format(slug) if slug and template else None


def parse_channels(value):
    """'1=123456789012345678,4=...' -> {1: 123456789012345678, 4: ...}: one Discord channel per
    guild. Raises ValueError for a malformed entry, a guild listed twice, or a channel given to
    two guilds (its replies could only go to one of them)."""
    channels, owner = {}, {}
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        guild, sep, channel = (x.strip() for x in part.partition("="))
        if not sep or not guild.isdigit() or not channel.isdigit():
            raise ValueError("GCB_CHANNELS entry %r is not <guild id>=<channel id>" % part)
        guild, channel = int(guild), int(channel)
        if guild in channels:
            raise ValueError("GCB_CHANNELS lists guild %d twice" % guild)
        if channel in owner:
            raise ValueError("GCB_CHANNELS gives channel %d to guilds %d and %d; each guild needs its own channel"
                             % (channel, owner[channel], guild))
        channels[guild] = channel
        owner[channel] = guild
    return channels
