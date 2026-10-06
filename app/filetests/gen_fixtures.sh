#!/bin/sh
# Regenerates the fixtures of the settings app's tests from the game's own code:
#   src/SelfTestFixtures.txt.gz  (embedded in the exe and in filetests)
#
#   sh gen_fixtures.sh [<G1R_MegaMod folder>]        default: ../../G1R_MegaMod
#
# Needs lua5.4 and gzip. Run it whenever Scripts/core/settings.lua, Scripts/core/kit.lua or the
# schema.lua / config.lua of the modules xp and general changed ("filetests --live" tells).
set -e
here=$(cd "$(dirname "$0")" && pwd)
mod=${1:-"$here/../../G1R_MegaMod"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
lua5.4 "$here/gen_fixtures.lua" "$mod" "$work/fixtures.txt" "$work"
gzip -n -9 < "$work/fixtures.txt" > "$here/../src/SelfTestFixtures.txt.gz"
ls -l "$here/../src/SelfTestFixtures.txt.gz"
