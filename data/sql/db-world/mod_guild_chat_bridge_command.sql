-- mod-guild-chat-bridge: help text for the .chatname command.
DELETE FROM `command` WHERE `name` = 'chatname';
INSERT INTO `command` (`name`, `security`, `help`) VALUES
('chatname', 0, 'Syntax: .chatname [$name]\nShows or sets the name Discord shows for you on all your characters. .chatname clear goes back to your character name.');
