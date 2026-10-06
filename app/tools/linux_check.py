"""Checks the settings app on Linux (the cloud), where the program itself cannot be built or run.

    python3 app/tools/linux_check.py [--work FOLDER] [--keep]

Needs the .NET 8 SDK (sudo apt-get install -y dotnet-sdk-8.0) and lua5.4. Works on copies in a folder of its own
(default: a new temporary folder, removed at the end unless --keep); nothing in the repository is written.

1. filetests (app/filetests, a net8.0 console program with the app's settings code): built, then
   --selftest on a copy of G1R_MegaMod and --live against it (the app's reading and writing against the mod's Lua).
2. The whole app (app/src/*.cs) compiled for net8.0-windows against the WinForms reference assemblies: a compile
   check only - the app's own self test, UI test and pictures need Windows.

app/src/StartupLoadingScreen.txt is the game's data (app/tools/make_startup_screen.py makes it on the player's PC)
and never committed. Without it the copy gets a stand-in, and the one self-test check of that value is expected to
fail; it is reported, not counted.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
STAND_IN = '(PlaybackType=MT_LoadingLoop,MoviePaths=("LoopingEngineLoadScreen"),bShuffle=False,bStandIn=True)'
STAND_IN_CHECK = "FAIL the value the app writes:"      # the self-test check that needs the game's real value
COMPILE_PROJECT = """<Project Sdk="Microsoft.NET.Sdk">
  <!-- written by app/tools/linux_check.py: the app's sources, compiled only -->
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <RootNamespace>G1RRepopulateSettings</RootNamespace>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.WindowsDesktop.App.WindowsForms" />
    <Compile Include="../app/src/*.cs" />
    <Using Include="System.Drawing" />
    <Using Include="System.Windows.Forms" />
  </ItemGroup>
</Project>
"""


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def fails(report):
    with open(report, encoding="utf-8", errors="replace") as f:
        return [line.rstrip("\n") for line in f if line.startswith("FAIL")]


def check(work):
    for tool in ("dotnet", "lua5.4"):
        if shutil.which(tool) is None:
            print("missing: " + tool + " (dotnet: sudo apt-get install -y dotnet-sdk-8.0; lua5.4: sudo apt-get install -y lua5.4)")
            return 2
    shutil.copytree(os.path.join(ROOT, "app"), os.path.join(work, "app"),
                    ignore=shutil.ignore_patterns("bin", "obj"))
    shutil.copytree(os.path.join(ROOT, "G1R_MegaMod"), os.path.join(work, "G1R_MegaMod"),
                    ignore=shutil.ignore_patterns("out"))
    screen = os.path.join(work, "app", "src", "StartupLoadingScreen.txt")
    stand_in = not os.path.isfile(screen)
    if stand_in:
        with open(screen, "w", encoding="ascii", newline="") as f:
            f.write(STAND_IN)
    bad = 0

    code, out = run(["dotnet", "build", "-c", "Release", "-nologo"], os.path.join(work, "app", "filetests"))
    if code != 0:
        print("FAIL filetests: build\n" + out[-4000:])
        return 1
    dll = os.path.join(work, "app", "filetests", "bin", "Release", "net8.0", "filetests.dll")
    mod = os.path.join(work, "G1R_MegaMod")
    reports = os.path.join(work, "reports")
    os.makedirs(reports)

    report = os.path.join(reports, "selftest.txt")
    run(["dotnet", dll, "--selftest", os.path.join(mod, "modules", "repopulate", "Scripts", "config.lua"), report], reports)
    failed = fails(report) if os.path.isfile(report) else ["FAIL no report written"]
    expected = [f for f in failed if stand_in and f.startswith(STAND_IN_CHECK)]
    real = [f for f in failed if f not in expected]
    with open(report, encoding="utf-8", errors="replace") as f:
        oks = sum(1 for line in f if line.startswith("ok"))
    print("filetests --selftest: %d ok, %d failed%s" % (oks, len(real),
          " (+1 expected: the stand-in start screen value)" if expected else ""))
    for f in real:
        print("    " + f)
    bad += len(real)

    report = os.path.join(reports, "live.txt")
    code, out = run(["dotnet", dll, "--live", mod, report], reports)
    failed = fails(report) if os.path.isfile(report) else ["FAIL no report written"]
    print("filetests --live: " + ("ALL OK" if code == 0 and not failed else "%d failed" % max(1, len(failed))))
    for f in failed:
        print("    " + f)
    bad += 0 if code == 0 and not failed else max(1, len(failed))

    project = os.path.join(work, "compile")
    os.makedirs(project)
    with open(os.path.join(project, "compile.csproj"), "w", encoding="utf-8") as f:
        f.write(COMPILE_PROJECT)
    code, out = run(["dotnet", "build", "-c", "Release", "-nologo"], project)
    errors = sorted({line.strip() for line in out.splitlines() if ": error " in line})
    warnings = sorted({line.strip() for line in out.splitlines() if ": warning " in line})
    print("app compile (net8.0-windows): " + ("ok" if code == 0 else "FAILED")
          + ", %d error(s), %d warning(s)" % (len(errors), len(warnings)))
    for line in (errors + warnings)[:40]:
        print("    " + line.replace(work + os.sep, ""))
    if code != 0:
        bad += max(1, len(errors))
        if not errors:
            print(out[-4000:])

    print("LINUX CHECK OK" if bad == 0 else "LINUX CHECK FAILED: %d problem(s)" % bad)
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--work", help="folder to work in (made if missing; must be empty)")
    ap.add_argument("--keep", action="store_true", help="keep the work folder (reports in <work>/reports)")
    a = ap.parse_args()
    work = os.path.abspath(a.work) if a.work else tempfile.mkdtemp(prefix="g1r-app-check-")
    os.makedirs(work, exist_ok=True)
    if os.listdir(work):
        print("the work folder is not empty: " + work)
        return 2
    try:
        return check(work)
    finally:
        if a.keep or a.work:
            print("work folder: " + work)
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
