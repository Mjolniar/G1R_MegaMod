// File-layer tests of the settings app on any OS (no window): the same
// SelfTest.Run / SelfTest.Migrate code the Windows build runs, and (--live)
// comparisons with the game's own Lua code, run with lua5.4.
namespace G1RRepopulateSettings;

internal static class TestMain
{
    private const string Usage = "usage: --selftest <config.lua> <report> | --live <G1R_MegaMod folder> <report> [--seed <number>] | --migrate <in> <out>"
        + " | --presets <G1R_MegaMod folder> <PRESETS.txt>";

    private static int Main(string[] args)
    {
        if (args.Length >= 3 && args[0] == "--migrate") return SelfTest.Migrate(args[1], args[2]);
        if (args.Length >= 3 && args[0] == "--selftest") return SelfTest.Run(args[1], args[2]);
        if (args.Length >= 3 && args[0] == "--presets")
        {
            // the text about the presets that the mod ships (the live test checks that it is up to date)
            var mega = MegaMod.Find(Path.Combine(args[1], "modules", "repopulate", "Scripts", "config.lua"));
            if (mega == null) { Console.Error.WriteLine("no megamod in " + args[1]); return 1; }
            File.WriteAllText(args[2], Presets.Document(mega), new System.Text.UTF8Encoding(false));
            return 0;
        }
        if (args.Length >= 3 && args[0] == "--live")
        {
            // the random cases are the same on every run; another seed gives other cases
            int seed = 20261002;
            if (args.Length >= 5 && args[3] == "--seed" && !int.TryParse(args[4], out seed)) { Console.Error.WriteLine(Usage); return 2; }
            return SelfTest.RunLive(args[1], args[2], seed);
        }
        Console.Error.WriteLine(Usage);
        return 2;
    }
}
