-- mod-guild-chat-bridge: undo the module's world database changes. Run it by hand on the world
-- database after removing the module. Idempotent.

DELETE FROM `command` WHERE `name` = 'chatname';

DELETE FROM `updates` WHERE `name` LIKE 'mod\_guild\_chat\_bridge\_%';
