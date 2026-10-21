"""python3 -m unittest discover -s tests -p 'test_*.py' (from the repo root)"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "discord-bridge"))

from text import class_icon, discord_to_game, game_to_discord, parse_channels, webhook_username  # noqa: E402


class GameToDiscord(unittest.TestCase):
    def test_links_colours_textures(self):
        text = "need |cffa335ee|Hitem:19019:0:0:0:0:0:0:0:60|h[Thunderfury]|h|r |TInterface\\Icons\\x:0|tnow"
        self.assertEqual(game_to_discord(text), "need \\[Thunderfury\\] now")

    def test_markdown_and_pipes_are_literal(self):
        self.assertEqual(game_to_discord("**hi** a||b _x_"), "\\*\\*hi\\*\\* a\\|b \\_x\\_")

    def test_urls_stay_clickable(self):
        self.assertEqual(game_to_discord("see https://wow.example.com/a_b-c ok_"),
                         "see https://wow.example.com/a_b-c ok\\_")

    def test_raid_icons_and_edit(self):
        self.assertEqual(game_to_discord("{skull} first {rt1}", edited=True), "\U0001f480 first ⭐ *(edited)*")

    def test_empty(self):
        self.assertEqual(game_to_discord("|TInterface\\x:0|t"), "​")


class DiscordToGame(unittest.TestCase):
    def test_one_line(self):
        self.assertEqual(discord_to_game("on my\nway  <:pepe:123456>"), "on my way :pepe:")

    def test_attachments(self):
        self.assertEqual(discord_to_game("", ["map.png"]), "[map.png]")
        self.assertEqual(discord_to_game("look", ["a.png", "b.png"]), "look [a.png] [b.png]")

    def test_limit(self):
        self.assertEqual(len(discord_to_game("x" * 5000)), 1024)


class Misc(unittest.TestCase):
    def test_webhook_username(self):
        self.assertEqual(webhook_username("Pawster"), "Pawster")
        self.assertNotIn("discord", webhook_username("Discordia").lower())
        self.assertNotIn("clyde", webhook_username("Clyde").lower())
        self.assertNotIn("clyde", webhook_username("Clydeclyde").lower())
        self.assertEqual(webhook_username("Clydeclyde").replace("\u200b", ""), "Clydeclyde")
        self.assertNotEqual(webhook_username("Here").lower(), "here")
        self.assertNotEqual(webhook_username("Everyone").lower(), "everyone")

    def test_class_icon(self):
        self.assertTrue(class_icon(6).endswith("classicon_deathknight.jpg"))
        self.assertIsNone(class_icon(10))
        self.assertIsNone(class_icon(6, ""))
        self.assertEqual(class_icon(1, "https://portal/{}.png"), "https://portal/warrior.png")

    def test_channels(self):
        self.assertEqual(parse_channels("1=111, 4=444,"), {1: 111, 4: 444})
        self.assertEqual(parse_channels(""), {})

    def test_one_channel_per_guild(self):
        with self.assertRaisesRegex(ValueError, "gives channel 111 to guilds 1 and 4"):
            parse_channels("1=111,4=111")
        with self.assertRaisesRegex(ValueError, "guild 1 twice"):
            parse_channels("1=111,1=222")
        with self.assertRaisesRegex(ValueError, "not <guild id>=<channel id>"):
            parse_channels("1:111")


if __name__ == "__main__":
    unittest.main()
