-- Optional. Only for realms that hand out addons with Portalkeeper
-- (https://github.com/buildthehomelab/wow-Portalkeeper) through mod-realm-config.
-- Makes the GuildChatEdit addon required for every player. Run it by hand against acore_world.
-- It is kept out of data/sql on purpose: the table belongs to mod-realm-config, and a
-- failing statement there would stop the database import at startup.

DELETE FROM `mod_realm_config_addon` WHERE `addon_key` = 'GuildChatEdit';
INSERT INTO `mod_realm_config_addon`
    (`addon_key`, `name`, `requirement`, `source_type`, `source_url`, `source_ref`, `install_directory`, `sort_order`, `enabled`)
VALUES
    ('GuildChatEdit', 'Guild Chat Edit', 'Required', 'GitHub', 'https://github.com/buildthehomelab/wow-mod-guild-chat-bridge', 'main', 'GuildChatEdit', 97, 1);
