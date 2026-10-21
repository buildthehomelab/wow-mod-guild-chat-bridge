/*
 * mod-guild-chat-bridge loader.
 *
 * AzerothCore looks up a loader symbol derived from the module's folder name: for folder
 * "mod-guild-chat-bridge" that symbol is exactly "Addmod_guild_chat_bridgeScripts". If you
 * clone the repo under a different folder name, rename this function to match.
 */

void AddGuildChatBridgeScripts();

void Addmod_guild_chat_bridgeScripts()
{
    AddGuildChatBridgeScripts();
}
