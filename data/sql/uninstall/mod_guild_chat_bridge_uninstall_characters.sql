-- mod-guild-chat-bridge: undo the module's characters database changes. Run it by hand on the
-- characters database after removing the module and stopping the Discord bridge. Messages
-- already posted in Discord stay there. Idempotent.

DROP TABLE IF EXISTS `guild_chat_bridge_message`;
DROP TABLE IF EXISTS `guild_chat_bridge_inbound`;
DROP TABLE IF EXISTS `guild_chat_bridge_name`;

DELETE FROM `updates` WHERE `name` LIKE 'mod\_guild\_chat\_bridge\_%';
