-- mod-guild-chat-bridge: characters database. The tables the worldserver and the Discord bridge
-- (discord-bridge/) share, neither side calling the other directly, and the players' chosen names.
-- Undo with data/sql/uninstall/mod_guild_chat_bridge_uninstall_characters.sql.

-- Guild chat of real players. The worldserver gives each message its id (so an edit knows its row
-- even before the INSERT has run) and on each edit or delete from the GuildChatEdit addon raises
-- `rev` and sets `pending`. The bridge posts the row to Discord, keeps the Discord message id,
-- edits or deletes that message, records the `rev` it sent in `synced_rev` and clears `pending`
-- once nothing newer came in.
CREATE TABLE IF NOT EXISTS `guild_chat_bridge_message` (
  `id` BIGINT UNSIGNED NOT NULL COMMENT 'given by the worldserver',
  `guild_id` INT UNSIGNED NOT NULL,
  `sender_guid` INT UNSIGNED NOT NULL COMMENT 'characters.guid',
  `sender_name` VARCHAR(16) NOT NULL COMMENT 'as Discord shows it: the chosen name, else the character',
  `sender_class` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `text` VARCHAR(255) NOT NULL COMMENT 'current text, raw client markup (links, colours)',
  `deleted` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `rev` INT UNSIGNED NOT NULL DEFAULT 1,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `edited_at` TIMESTAMP NULL DEFAULT NULL,
  `discord_id` BIGINT UNSIGNED NULL DEFAULT NULL COMMENT 'set by the bridge',
  `synced_rev` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'set by the bridge',
  `pending` TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1 = Discord is behind this row',
  PRIMARY KEY (`id`),
  KEY `idx_pending` (`pending`, `id`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='mod-guild-chat-bridge: guild chat for Discord';

-- Tables from before chosen names have VARCHAR(12), too short for one.
ALTER TABLE `guild_chat_bridge_message`
  MODIFY `sender_name` VARCHAR(16) NOT NULL COMMENT 'as Discord shows it: the chosen name, else the character';

-- Messages from the Discord channel, written by the bridge. The worldserver shows each one to the
-- guild once and sets `delivered`.
CREATE TABLE IF NOT EXISTS `guild_chat_bridge_inbound` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `guild_id` INT UNSIGNED NOT NULL,
  `author` VARCHAR(64) NOT NULL,
  `text` VARCHAR(1024) NOT NULL,
  `delivered` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_pending` (`delivered`, `id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='mod-guild-chat-bridge: Discord messages for the game';

-- The name each account chose with .chatname. The worldserver holds these in memory and checks
-- that a name is free there; this table only keeps them across restarts.
CREATE TABLE IF NOT EXISTS `guild_chat_bridge_name` (
  `account_id` INT UNSIGNED NOT NULL,
  `display_name` VARCHAR(16) NOT NULL,
  PRIMARY KEY (`account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='mod-guild-chat-bridge: chosen Discord names';
