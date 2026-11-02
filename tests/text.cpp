// The module's protocol, edit rules and text handling, without a core. Run from the repo root:
//   c++ -std=c++17 -Wall -Wextra -Werror -Isrc tests/text.cpp -o /tmp/text && /tmp/text
#include "GuildChatBridgeText.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <regex>
#include <sstream>

using namespace GuildChatBridge;
using Kind = EditGate::Outcome::Kind;
using Refusal = EditGate::Refusal;

static std::string Expand(std::string const& s)
{
    static std::regex const repeat(R"(\{(.)(\d+)\})");
    std::string out;
    std::sregex_iterator it(s.begin(), s.end(), repeat), end;
    std::size_t pos = 0;
    for (; it != end; ++it)
    {
        out += s.substr(pos, it->position() - pos);
        out += std::string(std::stoul((*it)[2]), (*it)[1].str()[0]);
        pos = it->position() + it->length();
    }
    return out + s.substr(pos);
}

static EditGate::Outcome Feed(EditGate& gate, char op, std::string const& text, uint32_t ms, bool recorded = true, uint32_t guild = 1)
{
    auto message = ParseAddonMessage(std::string("GCE1\t") + op + "\t" + text);
    assert(message);
    EditGate::Outcome out = gate.Feed(*message, guild, recorded, ms, ms / 1000);
    if (out.kind == Kind::Edit || out.kind == Kind::Delete)
        gate.Commit(out, ms);
    return out;
}

// tests/vectors.tsv, the same sequences tests/protocol.lua runs through the addon's decoder.
static int RunVectors()
{
    std::ifstream file("tests/vectors.tsv");
    assert(file && "run from the repo root");
    EditGate gate;
    gate.Said(1, 1, 0);
    std::string line;
    int rows = 0;
    while (std::getline(file, line))
    {
        if (line.empty() || line[0] == '#')
            continue;
        std::stringstream fields(line);
        std::string ms, op, text, outcome, result;
        std::getline(fields, ms, '\t');
        std::getline(fields, op, '\t');
        std::getline(fields, text, '\t');
        std::getline(fields, outcome, '\t');
        std::getline(fields, result, '\t');

        EditGate::Outcome out = Feed(gate, op[0], Expand(text), uint32_t(std::stoul(ms)));
        bool ok = (outcome == "pass" && out.kind == Kind::Pass)
            || (outcome == "refuse" && out.kind == Kind::Refuse)
            || (outcome == "delete" && out.kind == Kind::Delete)
            || (outcome == "edit" && out.kind == Kind::Edit && out.text == Expand(result));
        if (!ok)
            std::fprintf(stderr, "vector failed: %s\n", line.c_str());
        assert(ok);
        ++rows;
    }
    return rows;
}

int main()
{
    auto edit = ParseAddonMessage("GCE1\tE\tfixed typo");
    assert(edit && edit->op == AddonOp::Edit && edit->text == "fixed typo");
    assert(ParseAddonMessage("GCE1\tD\t")->op == AddonOp::Delete);
    assert(ParseAddonMessage("GCE1\tS\tpart")->op == AddonOp::Start);
    assert(ParseAddonMessage("GCE1\tF\tpart")->op == AddonOp::Finish);
    assert(!ParseAddonMessage("OTHER\tE\tx"));
    assert(!ParseAddonMessage("GCE1\tX\tx"));
    assert(!ParseAddonMessage("GCE1\tE"));
    assert(!ParseAddonMessage("GCE1"));

    assert(RunVectors() > 10);

    // A recorded guild needs a recorded message, in that guild.
    {
        EditGate gate;
        assert(Feed(gate, 'E', "x", 1000).refusal == Refusal::NothingToEdit);
        gate.Said(0, 1, 0);  // said in a guild that isn't recorded
        assert(Feed(gate, 'E', "x", 2000).refusal == Refusal::NothingToEdit);
        gate.Said(7, 2, 0);
        assert(Feed(gate, 'E', "x", 3000).refusal == Refusal::NothingToEdit);  // other guild
        assert(Feed(gate, 'E', "x", 4000, true, 2).kind == Kind::Edit);
        assert(gate.Last()->rev == 2);
    }

    // A guild that isn't recorded: the throttle, age and text rules still apply.
    {
        EditGate gate;
        assert(Feed(gate, 'E', "x", 1000, false).kind == Kind::Edit);
        assert(Feed(gate, 'E', "y", 1500, false).refusal == Refusal::TooFast);
        assert(Feed(gate, 'E', "bad\nline", 3000, false).refusal == Refusal::BadText);
        gate.Said(0, 1, 0);
        assert(Feed(gate, 'D', "", 5000, false).kind == Kind::Delete);
        assert(Feed(gate, 'E', "z", 7000, false).refusal == Refusal::Deleted);
        gate.Said(0, 1, 8);
        assert(Feed(gate, 'E', "other guild", 9000, false, 2).refusal == Refusal::NothingToEdit);
    }

    // Too old.
    {
        EditGate gate;
        gate.Said(3, 1, 0);
        auto message = ParseAddonMessage("GCE1\tE\tlate");
        assert(gate.Feed(*message, 1, true, 1000, EditGate::MaxAge + 1).refusal == Refusal::TooOld);
        assert(gate.Feed(*message, 1, true, 3000, EditGate::MaxAge).kind == Kind::Edit);
    }

    // A new message starts over: revision 1, not deleted, pending S dropped.
    {
        EditGate gate;
        gate.Said(3, 1, 0);
        Feed(gate, 'D', "", 1000);
        gate.Said(4, 1, 2);
        assert(gate.Last()->id == 4 && gate.Last()->rev == 1 && !gate.Last()->deleted);
        assert(Feed(gate, 'S', std::string(240, 's'), 3000).kind == Kind::Pass);
        gate.Said(5, 1, 3);
        assert(Feed(gate, 'F', "x", 3500).refusal == Refusal::Malformed);
    }

    // Edits skip the core's chat checks, so they are checked here.
    assert(IsValidEditText("fixed caf\xc3\xa9 |cff1eff00|Hitem:1|h[Bread]|h|r \xf0\x9f\x98\x80"));
    assert(!IsValidEditText("two\nlines"));
    assert(!IsValidEditText("bad \xff byte"));
    assert(!IsValidEditText("cut \xc3"));
    assert(!IsValidEditText("overlong \xc0\xaf"));
    assert(!IsValidEditText("surrogate \xed\xa0\x80"));
    assert(CollapseSpaces("ok    [Officer]:  give") == "ok [Officer]: give");

    // The guild list: only listed guilds, in either form; empty is none.
    {
        std::vector<std::string> bad;
        assert(ParseGuildIds("", bad).empty() && bad.empty());
        assert(ParseGuildIds(" , ", bad).empty() && bad.empty());
        auto ids = ParseGuildIds("1, 4 ,7=111111111111111111", bad);
        assert(ids.size() == 3 && ids.count(1) && ids.count(4) && ids.count(7) && bad.empty());
        ids = ParseGuildIds("1,x,-3,1x,12345678901", bad);
        assert(ids.size() == 1 && ids.count(1) && bad.size() == 4);
    }

    // A link with no guild id is a mistake to report; blank tokens are not.
    {
        std::vector<std::string> bad;
        assert(ParseGuildIds("=5, ,", bad).empty() && bad.size() == 1 && bad[0] == "=5");
    }

    // Chosen names.
    {
        std::string name;
        assert(NormalizeChosenName("  Red   Panda ", name) == NameRefusal::None && name == "Red Panda");
        assert(NormalizeChosenName("R2-d_2", name) == NameRefusal::None && name == "R2-D_2");
        assert(NormalizeChosenName("aLIce", name) == NameRefusal::None && name == "Alice");
        assert(NormalizeChosenName("red PANDA", name) == NameRefusal::None && name == "Red Panda");
        assert(NormalizeChosenName("A-", name) == NameRefusal::Length);
        for (char const* faked : { "Adm1n", "D1scord", "M0d Bob", "A1ice", "R0b" })
            assert(NormalizeChosenName(faked, name) == NameRefusal::Characters);
        assert(NormalizeChosenName("\xd0\xb0\xd0\xb1\xd0\xb2\xd0\xb3\xd0\xb4\xd0\xb5\xd0\xb6\xd0\xb7\xd0\xb8", name) == NameRefusal::Characters);
        assert(NormalizeChosenName("   ", name) == NameRefusal::Length);
        assert(NormalizeChosenName("R", name) == NameRefusal::Length);
        assert(NormalizeChosenName(std::string(17, 'a'), name) == NameRefusal::Length);
        assert(NormalizeChosenName(std::string(16, 'a'), name) == NameRefusal::None);
        assert(NormalizeChosenName("2fast", name) == NameRefusal::Characters);
        assert(NormalizeChosenName(" -xy", name) == NameRefusal::Characters);
        assert(NormalizeChosenName("|cffff0000Red", name) == NameRefusal::Characters);
        assert(NormalizeChosenName("caf\xc3\xa9", name) == NameRefusal::Characters);
        assert(NormalizeChosenName("Everyone", name) == NameRefusal::Reserved);
        assert(NormalizeChosenName("DISCORD", name) == NameRefusal::Reserved);
        assert(NormalizeChosenName("clear", name) == NameRefusal::Reserved);
        for (char const* staff : { "Game Master", "GameMaster", "Moderator", "Administrator", "Bob GM", "GM Bob", "G-M",
                                   "Staff", "Server", "Blizzard", "System Message", "Sys-tem", "Discord Mod", "xDiscordx", "Dis cord", "Cl-yde", "Every One" })
            assert(NormalizeChosenName(staff, name) == NameRefusal::Reserved);
        for (char const* fine : { "Modest", "Ragmar", "Hereward", "Devin", "Red Panda" })
            assert(NormalizeChosenName(fine, name) == NameRefusal::None);
        assert(IsReservedChosenName("System") && IsReservedChosenName("Admin") && !IsReservedChosenName("Alice"));

        NameBook book;
        assert(!book.Get(1));
        assert(book.Load(1, "Red"));
        assert(!book.Load(2, "RED"));  // the same name in other letter case is taken
        assert(*book.Get(1) == "Red" && !book.Get(2));
        for (char const* lookalike : { "R-ed", "Re d", "r_e_d" })
            assert(book.IsTakenByOther(lookalike, 2));
        assert(book.Load(3, "Alice") && book.IsTakenByOther("Al-ice", 2) && book.IsTakenByOther("ALICE", 2));
        assert(!book.IsTakenByOther("Kai", 2) && book.Load(5, "Kal") && !book.IsTakenByOther("Kai", 2));
        assert(NameKey("A2-i_c e") == "a2ice");
        assert(book.IsTakenByOther("red", 2) && !book.IsTakenByOther("red", 1) && !book.IsTakenByOther("blue", 2));
        book.Set(1, "Blue");  // a rename frees the old name
        assert(*book.Get(1) == "Blue" && !book.IsTakenByOther("Red", 2) && book.IsTakenByOther("BLUE", 2));
        book.Clear(1);
        assert(!book.Get(1) && !book.IsTakenByOther("Blue", 2));
        book.Clear(1);

        assert(!book.TooSoon(1, 1000));
        assert(book.TooSoon(1, 1000 + NameBook::ChangeInterval - 1));
        assert(!book.TooSoon(2, 1001));  // per account
        assert(!book.TooSoon(1, 1000 + NameBook::ChangeInterval));
    }

    // Discord text can't inject client escapes; control characters go, UTF-8 isn't split, a cut
    // line says so.
    assert(SanitizeForGame("|TInterface\\x:0|t hi", 255) == "||TInterface\\x:0||t hi");
    assert(SanitizeForGame("two\nlines\t ", 255) == "two lines");
    assert(SanitizeForGame("abcd caf\xc3\xa9", 9) == "abcd c...");
    assert(SanitizeForGame("abcd\xc3\xa9xyz", 8) == "abcd...");
    assert(SanitizeForGame("abcd|xyz", 8) == "abcd...");  // never half of "||"
    assert(SanitizeForGame("   ", 255).empty());
    assert(FormatDiscordLine("Nori", "brb") == "|cff40ff40[Discord] Nori: brb|r");
    assert(FormatDiscordLine("x|cffff0000", "y").find("x||cffff0000") != std::string::npos);

    std::puts("PASS: parsing, server vectors, recorded/unrecorded guilds, age, new message reset, edit text checks, guild list, chosen names, Discord text sanitizing");
}
