"""Installs or updates the mod G1R_MegaMod and lets its modules take over from the mods that did
the same jobs until now, with the game closed.

What it does
  * Verifies the package (zip against its manifest) and puts it into Mods\\G1R_MegaMod.
      First install: every file of the package.
      Update: package files that differ are replaced and files that only the installed version
      had are removed (copies of both go to the backup folder first). The player's files stay as
      they are: Scripts\\config.lua and every modules\\*\\Scripts\\config.lua that exists, the
      progress files, the diagnostics files, enabled.txt, the settings app, and whatever is part
      of neither package. A new module's default config.lua comes from the package.
  * Takes over from the mods listed in TAKEOVERS (the one table, further down): a mod of that
    table that is installed, and whose module is in the package, is retired. First its settings
    are carried over:
      our own former mods (G1R_Repopulate, NPCMarkers): settings file, progress files and the
          settings app are copied as they are into the module's folder;
      mods of other authors: a converter reads the mod's settings and the installer writes them
          into the module's config.lua - the package's default file with the converted values put
          in line by line, the way the game itself changes a value. Only when that file is not
          there yet or still as a package (or this installer) left it: a file the player changed
          is never overwritten. A mod that is switched off keeps its settings to itself (its job
          was off; the module starts with its defaults).
          The plan (--check) lists every value a module gets - with what it was worked out from
          where that is not plain, and with what was done to it to fit the module's range - and
          every value that is not carried over, with the reason. What cannot be read in a mod's
          file is not carried over (the module's default stays); a mod whose settings file is
          missing or unreadable is retired all the same.
    Then, once G1R_MegaMod is in place and verified, the mod's folder is copied to the backup
    folder, the copy is compared with the folder file by file, the folder is renamed (which fails
    as a whole while a file in it is open) and removed - what makes it a mod first. A mod that
    cannot be retired stays as it is and keeps its job: G1R_MegaMod does not load a module while
    the mod for the same job is installed and enabled.
    A job is never left to nobody: a mod is left alone when the package has no module for it,
    when the player switched that module off in the megamod's Scripts\\config.lua, when the megamod
    itself is switched off, or when the player put the mod back with the rollback script's -Only.
  * --settings-app EXE puts that program in as modules\\repopulate\\G1R_Repopulate_Settings.exe.
  * Points the desktop shortcut of the settings app to the copy inside G1R_MegaMod when it
    pointed into G1R_Repopulate.
  * Writes a rollback script into the backup folder. It puts everything back as it was before
    the run; with -Only <ModName> it puts back that one retired mod and nothing else.

What it does not do
  It does not start the game and refuses while the game, the mod manager or the settings app
  runs. It writes nothing but Mods\\G1R_MegaMod, the folders of the mods it retires, that one
  shortcut and its own backup folder: every other mod, mods.txt, mods.json, UE4SS and the saves
  are only read (checked by hash at the end). mods.txt keeps its lines for the retired mods;
  UE4SS skips a line whose folder is not there. A run with nothing to do creates nothing.

Usage:  python install_megamod.py --check              dry run: prints the plan, changes nothing
        python install_megamod.py                      install or update, retire the mods of the table
        python install_megamod.py --package ZIP        another package than PACKAGE (its manifest next to it)
        python install_megamod.py --settings-app EXE   also install that settings app
        python install_megamod.py --keep MOD           leave that mod of the table alone (repeatable)
        python install_megamod.py --retire MOD         retire it although it would be left alone (put back, module off)
        python install_megamod.py --keep-separate      leave every mod of the table alone
        python install_megamod.py --sync-settings      only carry settings and progress over again
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import zipfile

# This PC's places: deploy_settings.json next to this script (not in the repository; copy
# deploy_settings.example.json and fill it in). sim_megamod.py, which imports this file, sets them itself.
def _local_settings():
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "deploy_settings.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


_LOCAL = _local_settings()
GAME = _LOCAL.get("game", "")                   # the Gothic 1 Remake folder
UE4SS = GAME + r"\G1R\Binaries\Win64\ue4ss"
MODS = UE4SS + r"\Mods"
SAVES = _LOCAL.get("saves", "")                 # ...\AppData\Local\G1R\Saved\SaveGames
WS = _LOCAL.get("project", "")                  # the folder with megamod\ (the packages) and the backup folders
PKGDIR = WS + r"\megamod"
SHORTCUT = _LOCAL.get("shortcut", "")           # the desktop shortcut of the settings app
EXPECTED_UE4SS = "e1909f981e3f4c1dd603e9fc4e133fa679168e5d13d6d280b1dd79ed8f1dcaa3"   # sha256 of UE4SS\UE4SS.dll

NAME = "G1R_MegaMod"
PACKAGE = "G1R_MegaMod-0.3.3-dev.zip"       # in PKGDIR, its manifest next to it; another one: --package
TAG = "megamod-install"
ROLLBACK_NAME = "ROLLBACK-" + TAG + ".ps1"
ROLLED_BACK_NAME = "rolled-back.txt"        # written by the rollback script when it has undone a whole run
PUT_BACK_PREFIX = "put-back-"               # put-back-<Mod>.txt: written by the rollback script with -Only <Mod>
GAME_IMAGES = ("g1r-win64-shipping.exe", "g1r.exe")
OTHER_IMAGES = (("iskllauncher.app.exe", "The mod manager"), ("g1r_repopulate_settings.exe", "The settings app"))
SEP = os.sep

SETTINGS_EXE = "G1R_Repopulate_Settings.exe"
SETTINGS_EXE_REL = "modules/repopulate/" + SETTINGS_EXE

AS_INSTALLED = ("enabled.txt",)             # the loader's / the mod manager's business: never added, replaced or removed in an update
SESSION_DIRS = ("Scripts/diagnostics/", "modules/repopulate/Scripts/state/")     # written by game sessions
MARKERS_CONFIG_HEADER = "NPCMarkers 2.3 configuration"
MOD_MARKERS = ("enabled.txt", "scripts/main.lua", "dlls/main.dll")      # what makes a folder a mod UE4SS starts (lower case)
_ASCII_LOWER = {c: c + 32 for c in range(65, 91)}
_ASCII_UPPER = {c: c - 32 for c in range(97, 123)}


def refuse(msg):
    sys.exit(msg.rstrip() + " Nothing changed.")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha_of(data):
    return hashlib.sha256(data).hexdigest()


def _walk_error(err):
    raise err


def tree_hashes(root):
    """{path relative to root, with '/': sha256} of every file below root."""
    out = {}
    for dirpath, _, filenames in os.walk(root, onerror=_walk_error):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            out[os.path.relpath(p, root).replace("\\", "/")] = sha(p)
    return out


def running_images():
    try:
        r = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    names = []
    for line in r.stdout.decode("ascii", "replace").splitlines():
        line = line.strip()
        if line.startswith('"'):
            names.append(line[1:].split('"', 1)[0].lower())
    return names or None


def _retry(fn, *args):
    for attempt in (1, 2, 3):
        try:
            return fn(*args)
        except PermissionError:
            if attempt == 3:
                raise
            time.sleep(0.4)


def write_file(dst, data):
    os.makedirs(os.path.dirname(dst), exist_ok=True)

    def put():
        with open(dst, "wb") as f:
            f.write(data)
    _retry(put)


def copy_file(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    _retry(shutil.copy2, src, dst)


def copy_tree(src, dst):
    """A copy of the folder src as dst (which must not exist); empty folders included."""
    os.makedirs(dst)
    for dirpath, dirnames, filenames in os.walk(src, onerror=_walk_error):
        rel = os.path.relpath(dirpath, src)
        here = dst if rel == "." else os.path.join(dst, rel)
        for dn in dirnames:
            os.makedirs(os.path.join(here, dn), exist_ok=True)
        for fn in filenames:
            _retry(shutil.copy2, os.path.join(dirpath, fn), os.path.join(here, fn))


def _remove_file(path):
    try:
        os.remove(path)
    except PermissionError:
        os.chmod(path, stat.S_IWRITE)           # a read-only file
        os.remove(path)


def remove_tree(path):
    """Removes a folder tree. What makes it a mod goes first (enabled.txt, Scripts\\main.lua in either spelling,
    dlls\\main.dll), so that whatever is left after a failure is not something UE4SS starts. Raises OSError when
    something cannot be removed."""
    first = []
    for dirpath, _, filenames in os.walk(path, onerror=_walk_error):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.relpath(p, path).replace("\\", "/").lower() in MOD_MARKERS:
                first.append(p)
    for p in sorted(first):
        _retry(_remove_file, p)
    for dirpath, dirnames, filenames in os.walk(path, topdown=False, onerror=_walk_error):
        for fn in filenames:
            _retry(_remove_file, os.path.join(dirpath, fn))
        for dn in dirnames:
            d = os.path.join(dirpath, dn)
            if os.path.islink(d) and os.name != "nt":
                os.unlink(d)
            else:
                _retry(os.rmdir, d)
    _retry(os.rmdir, path)


# ---------------------------------------------------------------------------------------------
# The package
# ---------------------------------------------------------------------------------------------
def manifest_name(package):
    """G1R_MegaMod-0.2.1-dev.zip -> G1R_MegaMod-0.2.1-dev-manifest.sha256"""
    return (package[:-4] if package.lower().endswith(".zip") else package) + "-manifest.sha256"


def version_from_name(package):
    """G1R_MegaMod-0.1.1-dev.zip -> 0.1.1 (None when the name is not a package's)."""
    m = re.match(r"^%s-(.+?)(?:-dev)?\.zip$" % re.escape(NAME), str(package or ""))
    return m.group(1) if m else None


def version_in(data):
    """The version a Scripts/core/version.lua names."""
    m = re.search(rb'\bversion\s*=\s*"([^"]+)"', data)
    return m.group(1).decode("ascii", "replace") if m else None


def read_manifest(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2 or not re.match(r"^[0-9a-fA-F]{64}$", parts[0]) or not parts[1].startswith("./"):
                raise ValueError("bad line in %s: %r" % (os.path.basename(path), line[:80]))
            rel = parts[1][2:]
            if not rel or rel.startswith("/") or ".." in rel.split("/") or "\\" in rel or ":" in rel:
                raise ValueError("bad path in %s: %r" % (os.path.basename(path), rel[:80]))
            out[rel] = parts[0].lower()
    if not out:
        raise ValueError("%s lists no files" % os.path.basename(path))
    return out


def read_package(zip_path, manifest):
    """{relative path: bytes} of the package; raises when it is not exactly what the manifest says."""
    files = {}
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if not info.filename.startswith(NAME + "/"):
                raise ValueError("%s: entry outside the folder %s: %r" % (os.path.basename(zip_path), NAME, info.filename[:80]))
            files[info.filename[len(NAME) + 1:]] = zf.read(info)
    if sorted(files) != sorted(manifest):
        extra = sorted(set(files) - set(manifest))[:3]
        missing = sorted(set(manifest) - set(files))[:3]
        raise ValueError("package and manifest list different files (only in the zip: %s; only in the manifest: %s)" % (extra, missing))
    for rel, data in files.items():
        if sha_of(data) != manifest[rel]:
            raise ValueError("%s in the package does not match the manifest" % rel)
    return files


def has_module(files, module):
    """Whether the package brings the module (the loader loads modules/<name>/Scripts/main.lua)."""
    return ("modules/%s/Scripts/main.lua" % module) in files


def package_modules(files):
    """{module name: [folder names of the mods that do the same job]} from the package's Scripts/core/modules.lua,
    or None when the package has no such file (version 0.1.x: the list was part of the loader). Raises LuaError."""
    listed = package_module_list(files)
    return None if listed is None else {name: entry["separate"] for name, entry in listed.items()}


def package_module_list(files):
    """{module name: {"switch": its key in Config.Modules of Scripts/config.lua, "separate": [mod folders]}}, in the
    order of the package's Scripts/core/modules.lua; None when the package has no such file. Raises LuaError."""
    data = files.get("Scripts/core/modules.lua")
    if data is None:
        return None
    out = {}
    for entry in lua_list(read_lua(data)):
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise LuaError("an entry without a name")
        separate = entry.get("separate")
        out[entry["name"]] = {"switch": entry.get("switch") if isinstance(entry.get("switch"), str) else None,
                              "separate": [separate] if isinstance(separate, str) else [s for s in lua_list(separate) if isinstance(s, str)]}
    return out


LEGACY_SWITCHES = {"repopulate": "Repopulate", "markers": "Markers"}        # version 0.1.x: the list was part of the loader


def modules_switched_off(listed, config_data):
    """{module name: its switch} of the modules that the megamod's Scripts/config.lua switches off
    (Config.Modules.<Switch> = false; anything else, a missing line or an unreadable file means on, as for the loader)."""
    try:
        switches = read_lua(config_data).get("Modules")
    except LuaError:
        return {}
    names = {name: entry["switch"] for name, entry in listed.items()} if listed is not None else LEGACY_SWITCHES
    return {name: switch for name, switch in names.items() if switch and isinstance(switches, dict) and switches.get(switch) is False}


# ---------------------------------------------------------------------------------------------
# Readers for the settings files of other mods. No code of those files is run.
# ---------------------------------------------------------------------------------------------
class LuaError(ValueError):
    """A Lua file that is more than plain values, or not Lua."""


LUA_LIMIT = 4 << 20
_LUA_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_LUA_NUMBER = re.compile(rb"0[xX][0-9a-fA-F]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_LUA_LONG = re.compile(rb"\[(=*)\[")
_LUA_ESCAPES = {ord("a"): 7, ord("b"): 8, ord("f"): 12, ord("n"): 10, ord("r"): 13, ord("t"): 9, ord("v"): 11,
                ord("\\"): 92, ord('"'): 34, ord("'"): 39, 10: 10}
_LUA_WORDS = ("and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "not", "or", "repeat",
              "then", "until", "while")
_LUA_SPACE = b" \t\r\n\f\v"
_LUA_DECIMAL = re.compile(rb"[0-9]{1,3}")
_LUA_UNICODE = re.compile(rb"u\{([0-9a-fA-F]{1,6})\}")
_LUA_HEX2 = re.compile(rb"[0-9a-fA-F]{2}")


def _lua_string(data, i, line):
    """The text of a quoted Lua string that starts at data[i]: (text, index behind it, line)."""
    quote, out, n = data[i], bytearray(), len(data)
    i += 1
    while True:
        if i >= n or data[i] in (10, 13):
            raise LuaError("line %d: a text that does not end on its line" % line)
        b = data[i]
        if b == quote:
            return out.decode("utf-8", "surrogateescape"), i + 1, line
        if b != 92:
            out.append(b)
            i += 1
            continue
        i += 1
        e = data[i] if i < n else -1
        if e in _LUA_ESCAPES:
            out.append(_LUA_ESCAPES[e])
            i += 1
            line += 1 if e == 10 else 0
        elif e == 13:                                   # a line break inside the text, written \ + CR LF
            out.append(10)
            i += 2 if data[i + 1:i + 2] == b"\n" else 1
            line += 1
        elif e == ord("x") and _LUA_HEX2.match(data, i + 1):
            out.append(int(data[i + 1:i + 3], 16))
            i += 3
        elif e == ord("z"):
            i += 1
            while i < n and data[i] in _LUA_SPACE:
                line += 1 if data[i] == 10 else 0
                i += 1
        elif 48 <= e <= 57:
            m = _LUA_DECIMAL.match(data, i)
            if int(m.group(0)) > 255:
                raise LuaError("line %d: an escape it cannot read" % line)
            out.append(int(m.group(0)))
            i = m.end()
        elif e == ord("u"):
            m = _LUA_UNICODE.match(data, i)
            code = int(m.group(1), 16) if m else -1
            if code < 0 or code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
                raise LuaError("line %d: an escape it cannot read" % line)
            out += chr(code).encode("utf-8")
            i = m.end()
        else:
            raise LuaError("line %d: an escape it cannot read" % line)


def _lua_tokens(data):
    """The tokens of a Lua text: [(kind, value, line)]; kind is name, number, string, one of { } [ ] = , ; . - or end.
    Anything else in the text (a call, an operator) raises LuaError."""
    out, i, n, line = [], 0, len(data), 1
    while i < n:
        c = data[i:i + 1]
        if c == b"\n":
            line += 1
            i += 1
        elif c in (b" ", b"\t", b"\r", b"\f", b"\v"):
            i += 1
        elif data.startswith(b"--", i):
            m = _LUA_LONG.match(data, i + 2)
            if m:
                end = data.find(b"]" + m.group(1) + b"]", m.end())
                if end < 0:
                    raise LuaError("line %d: a comment that does not end" % line)
                line += data.count(b"\n", i, end)
                i = end + len(m.group(1)) + 2
            else:
                end = data.find(b"\n", i)
                i = n if end < 0 else end
        elif c in (b'"', b"'"):
            start = line
            value, i, line = _lua_string(data, i, line)
            out.append(("string", value, start))
        elif c == b"[" and _LUA_LONG.match(data, i):
            m = _LUA_LONG.match(data, i)
            end = data.find(b"]" + m.group(1) + b"]", m.end())
            if end < 0:
                raise LuaError("line %d: a text that does not end" % line)
            body = data[m.end():end]
            body = body[2:] if body.startswith(b"\r\n") else (body[1:] if body.startswith(b"\n") else body)
            out.append(("string", body.decode("utf-8", "surrogateescape"), line))
            line += data.count(b"\n", i, end)
            i = end + len(m.group(1)) + 2
        elif c.isdigit() or (c == b"." and data[i + 1:i + 2].isdigit()):
            m = _LUA_NUMBER.match(data, i)
            text, i = m.group(0), m.end()
            if _LUA_NAME.match(data, i) or data[i:i + 1] == b".":
                raise LuaError("line %d: a number it cannot read" % line)
            if text[:2].lower() == b"0x":
                value = int(text, 16)
            elif text.isdigit():
                value = int(text)
            else:
                value = float(text)
            out.append(("number", value, line))
        else:
            m = _LUA_NAME.match(data, i)
            if m:
                out.append(("name", m.group(0).decode("ascii"), line))
                i = m.end()
            elif c in (b"{", b"}", b"[", b"]", b"=", b",", b";", b".", b"-"):
                out.append((c.decode("ascii"), None, line))
                i += 1
            else:
                raise LuaError("line %d: %r is more than plain values" % (line, data[i:i + 12].decode("ascii", "replace")))
    out.append(("end", None, line))
    return out


class _LuaReader:
    def __init__(self, data):
        self.tokens = _lua_tokens(data)
        self.i = 0
        self.names = {}                 # what the file's own names stand for (local Config = { ... })

    def peek(self, ahead=0):
        return self.tokens[min(self.i + ahead, len(self.tokens) - 1)]

    def fail(self):
        kind, value, line = self.peek()
        shown = {"end": "the end of the file", "name": "'%s'" % value, "number": "a number", "string": "a text"}.get(kind, "'%s'" % kind)
        raise LuaError("line %d: %s is more than plain values" % (line, shown))

    def take(self, kind):
        token = self.peek()
        if token[0] != kind:
            self.fail()
        self.i += 1
        return token

    def name(self):
        value = self.take("name")[1]
        if value in _LUA_WORDS or value in ("true", "false", "nil", "local", "return"):
            self.i -= 1
            self.fail()
        return value

    def key(self):
        kind, value, _ = self.peek()
        negative = kind == "-"
        if negative:
            self.i += 1
            kind, value, _ = self.peek()
            if kind != "number":
                self.fail()
        if kind not in ("number", "string"):
            self.fail()
        self.i += 1
        if kind == "string":
            return value
        value = -value if negative else value
        if isinstance(value, float):
            if value != value:
                raise LuaError("a table key that is no number")
            return int(value) if value.is_integer() else value
        return value

    def value(self, depth=0):
        kind, value, _ = self.peek()
        if kind in ("number", "string"):
            self.i += 1
            return value
        if kind == "-" and self.peek(1)[0] == "number":
            self.i += 2
            return -self.peek(-1)[1]
        if kind == "{":
            return self.table(depth + 1)
        if kind == "name":
            if value in ("true", "false", "nil"):
                self.i += 1
                return {"true": True, "false": False, "nil": None}[value]
            if value in self.names and self.peek(1)[0] not in (".", "[", "{", "string"):
                self.i += 1
                return self.names[value]
        self.fail()

    def table(self, depth):
        if depth > 40:
            raise LuaError("tables inside tables, too deep")
        self.take("{")
        out, position, listed = {}, 1, []

        def store():
            # Lua stores the list items of a constructor after the named ones, 50 at a time: where a list item
            # and a written key meet (`{ "a", [1] = "b" }`), the list item is what stays
            for index, item in listed:
                if item is None:
                    out.pop(index, None)
                else:
                    out[index] = item
            del listed[:]
        while self.peek()[0] != "}":
            if len(listed) == 50:
                store()
            kind, value, _ = self.peek()
            if kind == "[":
                self.i += 1
                key = self.key()
                self.take("]")
                self.take("=")
            elif kind == "name" and self.peek(1)[0] == "=":
                key = self.name()
                self.i += 1
            else:
                key, position = None, position + 1
            item = self.value(depth)
            if key is None:
                listed.append((position - 1, item))
                if item is not None:
                    out.setdefault(position - 1, item)      # its place in the order of the file
            elif item is not None:
                out[key] = item
            else:
                out.pop(key, None)
            if self.peek()[0] in (",", ";"):
                self.i += 1
            elif self.peek()[0] != "}":
                self.fail()
        store()
        self.i += 1
        return out

    def run(self):
        while True:
            kind, value, line = self.peek()
            if kind == ";":
                self.i += 1
            elif kind == "name" and value == "local":
                self.i += 1
                name = self.name()
                self.names[name] = None
                if self.peek()[0] == "=":
                    self.i += 1
                    self.names[name] = self.value()
            elif kind == "name" and value == "return":
                self.i += 1
                result = self.value()
                while self.peek()[0] == ";":
                    self.i += 1
                if self.peek()[0] != "end":
                    self.fail()
                if not isinstance(result, dict):
                    raise LuaError("the file does not give back a table")
                return result
            elif kind == "name":
                # an assignment: Name = value, Name.key = value, Name["key"].other = value
                holder, key, path = self.names, self.name(), [value]
                while self.peek()[0] in (".", "["):
                    inner = holder.get(key)
                    if not isinstance(inner, dict):
                        raise LuaError("line %d: %s is not a table" % (line, ".".join(path)))
                    if self.take(self.peek()[0])[0] == ".":
                        holder, key = inner, self.name()
                    else:
                        holder, key = inner, self.key()
                        self.take("]")
                    path.append(str(key))
                self.take("=")
                item = self.value()
                if item is None and holder is not self.names:
                    holder.pop(key, None)
                else:
                    holder[key] = item
            elif kind == "end":
                raise LuaError("the file gives nothing back (no return)")
            else:
                self.fail()


def read_lua(data):
    """The table a plain Lua settings file gives back, as nested dicts (names as texts, list positions as whole
    numbers from 1): `return { key = value, nested = { ... } }`, or `local Config = { ... }`, `Config.key = value`,
    `return Config`. Values: true / false, numbers, texts, tables; comments are skipped. Nothing is run: a file
    that is more than that (a call, a calculation, a function) raises LuaError."""
    if len(data) > LUA_LIMIT:
        raise LuaError("the file is too large")
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        return _LuaReader(data).run()
    except RecursionError:
        raise LuaError("tables inside tables, too deep")


def lua_list(table):
    """The list part of a table read by read_lua: the values at 1, 2, 3, ... in that order."""
    out = []
    while isinstance(table, dict) and (len(out) + 1) in table:
        out.append(table[len(out) + 1])
    return out


def lua_flat(table, prefix="", depth=0):
    """[(dotted name, value)] of the plain values in a table read by read_lua, in the order of the file."""
    out = []
    for key, value in table.items():
        name = prefix + str(key)
        if isinstance(value, dict):
            if depth < 40:
                out.extend(lua_flat(value, name + ".", depth + 1))
        else:
            out.append((name, value))
    return out


def lua_tonumber(text):
    """A number written as text, the way Lua's tonumber reads it (whole numbers stay whole), or None."""
    text = text.strip(" \t\r\n\f\v")
    m = re.match(r"^([+-]?)(?:(0[xX][0-9a-fA-F]+)|((?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?))$", text)
    if not m:
        return None
    if m.group(2):
        value = int(m.group(2), 16)
    elif m.group(3).isdigit():
        value = int(m.group(3))
    else:
        value = float(m.group(3))
    return -value if m.group(1) == "-" else value


def read_ini(data):
    """An ini text as ([(section, key, value, line number)], [(line number, text it could not read)]):
    `[section]` lines, `key=value` lines (the first = splits; spaces around section, key and value are dropped),
    lines starting with ; or # are comments. Keys in front of the first section have the section "". The value is
    the rest of the line as it stands (a ; behind a value is part of it, as most mods read it)."""
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    entries, unread, section = [], [], ""
    for number, line in enumerate(data.decode("utf-8", "surrogateescape").split("\n"), 1):
        line = line.strip(" \t\r\f\v")
        if not line or line[0] in ";#":
            continue
        if line[0] == "[" and line[-1] == "]":
            section = line[1:-1].strip(" \t")
        elif "=" in line and line.split("=", 1)[0].strip(" \t"):
            key, value = line.split("=", 1)
            entries.append((section, key.strip(" \t"), value.strip(" \t"), number))
        else:
            unread.append((number, line[:60]))
    return entries, unread


# ---------------------------------------------------------------------------------------------
# A module's config.lua: the rule of dev/SETTINGS.md section 2, as Scripts/core/settings.lua does it
# ---------------------------------------------------------------------------------------------
_KEY_NAMES = set((
    "MIDDLE_MOUSE_BUTTON XBUTTON_ONE XBUTTON_TWO BACKSPACE TAB RETURN PAUSE CAPS_LOCK SPACE PAGE_UP PAGE_DOWN END HOME "
    "LEFT_ARROW UP_ARROW RIGHT_ARROW DOWN_ARROW INS DEL ZERO ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE "
    "NUM_ZERO NUM_ONE NUM_TWO NUM_THREE NUM_FOUR NUM_FIVE NUM_SIX NUM_SEVEN NUM_EIGHT NUM_NINE MULTIPLY ADD SUBTRACT "
    "DECIMAL DIVIDE NUM_LOCK SCROLL_LOCK OEM_ONE OEM_PLUS OEM_COMMA OEM_MINUS OEM_PERIOD OEM_TWO OEM_THREE OEM_FOUR "
    "OEM_FIVE OEM_SIX OEM_SEVEN OEM_EIGHT OEM_102").split())
_KEY_NAMES.update(chr(c) for c in range(65, 91))
_KEY_NAMES.update("F%d" % n for n in range(1, 13))
_KEY_ALIASES = {
    "0": "ZERO", "1": "ONE", "2": "TWO", "3": "THREE", "4": "FOUR", "5": "FIVE", "6": "SIX", "7": "SEVEN", "8": "EIGHT",
    "9": "NINE", "NUM0": "NUM_ZERO", "NUM1": "NUM_ONE", "NUM2": "NUM_TWO", "NUM3": "NUM_THREE", "NUM4": "NUM_FOUR",
    "NUM5": "NUM_FIVE", "NUM6": "NUM_SIX", "NUM7": "NUM_SEVEN", "NUM8": "NUM_EIGHT", "NUM9": "NUM_NINE", "INSERT": "INS",
    "DELETE": "DEL", "ENTER": "RETURN", "PGUP": "PAGE_UP", "PGDN": "PAGE_DOWN", "PAGEUP": "PAGE_UP", "PAGEDOWN": "PAGE_DOWN",
    "UP": "UP_ARROW", "DOWN": "DOWN_ARROW", "LEFT": "LEFT_ARROW", "RIGHT": "RIGHT_ARROW", "MOUSE3": "MIDDLE_MOUSE_BUTTON",
    "MOUSE4": "XBUTTON_ONE", "MOUSE5": "XBUTTON_TWO", "CAPSLOCK": "CAPS_LOCK", "NUMLOCK": "NUM_LOCK", "SCROLLLOCK": "SCROLL_LOCK",
}
_KEY_MODIFIERS = {"CONTROL": "CTRL", "STRG": "CTRL", "CTRL": "CTRL", "SHIFT": "SHIFT", "ALT": "ALT"}


def key_text(text):
    """The usual spelling of a key combination ("ctrl + y" -> "CTRL+Y", "" = no key), or None when it names no key
    (Kit.keyCombo of Scripts/core/kit.lua)."""
    if not isinstance(text, str):
        return None
    compact = re.sub("[ \t\r\n\f\v]+", "", text).translate(_ASCII_UPPER)
    if compact == "":
        return ""
    held, key = set(), None
    for part in compact.split("+"):
        if part in _KEY_MODIFIERS:
            held.add(_KEY_MODIFIERS[part])
            continue
        part = _KEY_ALIASES.get(part, part)
        if part not in _KEY_NAMES or key is not None:
            return None
        key = part
    if key is None:
        return None
    return "+".join([m for m in ("CTRL", "SHIFT", "ALT") if m in held] + [key])


def number_text(value, decimals):
    """A number as it is written into config.lua: whole numbers plain, others with at most `decimals` places and at
    least one ("1.0", "2.5", "0.75")."""
    decimals = int(decimals or 0)
    if decimals <= 0:
        return "%d" % math.floor(value + 0.5)
    text = ("%.*f" % (decimals, value)).rstrip("0")
    if text.endswith("."):
        text += "0"
    return "0.0" if text == "-0.0" else text


def literal(item, value):
    """A value as it is written into config.lua, for an item of a module's schema."""
    if item.get("Kind") == "bool":
        return "true" if value else "false"
    if item.get("Kind") == "number":
        return number_text(value, item.get("Decimals"))
    return '"' + re.sub("[\x00-\x1f\x7f]", " ", str(value).replace("\\", "\\\\").replace('"', '\\"')) + '"'


def fit_value(item, value):
    """A converted value as the item of the module's schema takes it: (value, None), (value, what was changed about
    it) or (None, why it is not usable). Numbers are pulled into Min..Max and rounded as the item says."""
    kind = item.get("Kind")
    if kind == "bool":
        return (value, None) if isinstance(value, bool) else (None, "is not true or false")
    if kind == "number":
        number = lua_tonumber(value) if isinstance(value, str) else (None if isinstance(value, bool) else value)
        low, high = item.get("Min"), item.get("Max")
        if not isinstance(number, (int, float)) or number != number:
            return None, "is not a number"
        if isinstance(low, bool) or isinstance(high, bool) or not isinstance(low, (int, float)) or not isinstance(high, (int, float)):
            return None, "has no range in the schema"
        fitted = max(low, min(high, number))
        decimals = item.get("Decimals") if isinstance(item.get("Decimals"), (int, float)) else 0
        fitted = math.floor(fitted + 0.5) if decimals <= 0 else float(number_text(fitted, decimals))
        if fitted == number:
            return fitted, None
        if number < low or number > high:
            return fitted, "was %s; the range is %s to %s" % (number, low, high)
        return fitted, "was %s; rounded" % number
    if kind == "choice":
        options = lua_list(item.get("Options"))
        return (value, None) if isinstance(value, str) and value in options else (None, "is not one of: " + ", ".join(str(o) for o in options))
    if kind == "key":
        usual = key_text(value)
        if usual is None:
            return None, "names no key"
        return usual, (None if usual == value else "was written %s" % value)
    if kind == "text":
        return (value, None) if isinstance(value, str) else (None, "is not a text")
    return None, "is not a setting that holds a value"


_SPACE = b" \t\n\v\f\r"


def _key_line(key):
    return re.compile(rb"^[ \t]*Config\." + re.escape(key.encode("ascii")) + rb"[ \t]*=[^\r\n]*", re.M)


def patch_config(text, key, value_text):
    """Sets the value of one key in the text of a config.lua (bytes), exactly as `patch` in Scripts/core/settings.lua:
    the last line `Config.<Key> = ...` gets the new value (its indentation and line end stay, a comment behind the
    value goes); without such a line one is added directly below the last line with text in front of the closing
    `return Config` line, with the file's line ending; without that line it is appended. Nothing else changes."""
    line = b"Config." + key.encode("ascii") + b" = " + value_text
    last = None
    for last in _key_line(key).finditer(text):
        pass
    if last is not None:
        indent = re.match(rb"[ \t]*", last.group(0)).group(0)
        return text[:last.start()] + indent + line + text[last.end():]
    newline = b"\r\n" if b"\r\n" in text else b"\n"
    closing = re.search(rb"\n[ \t]*return[ \t\n\v\f\r]+Config[^\n]*[ \t\n\v\f\r]*\Z", text)
    if closing:
        head = text[:closing.start() + 1]
        body = head.rstrip(_SPACE)
        if body == b"":
            return line + newline + text
        return body + newline + line + head[len(body):] + text[closing.start() + 1:]
    if text != b"" and not text.endswith(b"\n"):
        text += newline
    return text + line + newline


def module_schema(files, module):
    """({key: item}, None) of a module's schema.lua in the package, or (None, why it cannot be used)."""
    rel = "modules/%s/Scripts/schema.lua" % module
    if rel not in files:
        return None, "the package has no %s" % rel
    try:
        schema = read_lua(files[rel])
    except LuaError as e:
        return None, "%s cannot be read (%s)" % (rel, e)
    items = {}
    for group in lua_list(schema.get("Groups")):
        for item in lua_list(group.get("Items") if isinstance(group, dict) else None):
            if isinstance(item, dict) and isinstance(item.get("Key"), str):
                items[item["Key"]] = item
    if not items:
        return None, "%s describes no settings" % rel
    return items, None


# ---------------------------------------------------------------------------------------------
# What a converter gets: the files of the mod it converts (read only)
# ---------------------------------------------------------------------------------------------
def show_value(value, quoted=False):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str) and quoted:
        return '"%s"' % value
    return str(value)


class TheirFile:
    """The values of one settings file of another mod, by name: `Key` (or `Section.Key`) of an ini file, the dotted
    path (`removeConnections.skilled`, `CircleCost.1`) of a Lua file. Names are found without regard to case
    (exact=True: as they are written, the way Lua itself tells names apart).
    A converter asks for the values it knows; a value that is missing or unusable gives None and is listed in the
    plan with the reason, and so is every value nobody asked for."""

    def __init__(self, name, values, typed, problem=None, tree=None, exact=False):
        self.name = name                # the file, for the plan
        self.problem = problem          # why the file gives nothing (not there, not readable), or None
        self.typed = typed              # True: a Lua file (values have their kinds); False: an ini file (all texts)
        self.exact = exact              # True: names are compared as written
        self.tree = tree or {}          # a Lua file's table as read_lua gives it (nested)
        self._values = values           # [(name, value)] in the order of the file
        self._taken = set()
        self.complaints = []            # [(what, why)]: values that were asked for and cannot be used
        self.passed = []                # [(what, why)]: values the converter leaves out on purpose

    def _key(self, name):
        return name if self.exact else name.lower()

    def _find(self, name):
        wanted = self._key(name)
        hits = [i for i, (n, _) in enumerate(self._values) if self._key(n) == wanted]
        if not hits and "." not in name and not self.typed:            # a bare ini key: in whatever section it stands
            hits = [i for i, (n, _) in enumerate(self._values) if n.lower().rsplit(".", 1)[-1] == wanted]
            if len(set(self._values[i][0].lower() for i in hits)) > 1:
                self._taken.update(hits)
                self.complaints.append((name, "stands in several sections of %s: name it as Section.%s" % (self.name, name)))
                return None
        self._taken.update(hits)
        return hits[-1] if hits else None                                # the last one counts, as for the mod itself

    def _below(self, name):
        """The places of the value of that name and of every value below it (a table)."""
        wanted = self._key(name)
        return [i for i, (n, _) in enumerate(self._values) if self._key(n) == wanted or self._key(n).startswith(wanted + ".")]

    def has(self, name):
        wanted = self._key(name)
        return any(self._key(n) == wanted or (not self.typed and "." not in name and n.lower().rsplit(".", 1)[-1] == wanted)
                   for n, _ in self._values)

    def value(self, name):
        """The value as the file has it (an ini value is a text), or None when it is not there."""
        hit = self._find(name)
        if hit is None:
            if not self.problem and not any(what == name for what, _ in self.complaints):
                self.complaints.append((name, "is not in %s" % self.name))
            return None
        return self._values[hit][1]

    def _unusable(self, name, value, why):
        self.complaints.append(("%s=%s" % (name, show_value(value, self.typed)), why))
        return None

    def number(self, name):
        value = self.value(name)
        if value is None:
            return None
        number = lua_tonumber(value) if (isinstance(value, str) and not self.typed) else value
        if isinstance(number, bool) or not isinstance(number, (int, float)) or number != number:
            return self._unusable(name, value, "is not a number")
        return number

    def boolean(self, name):
        """true / false; in an ini file also yes / no, on / off, 1 / 0, in any case."""
        value = self.value(name)
        if value is None or isinstance(value, bool):
            return value
        if isinstance(value, str) and not self.typed:
            word = value.strip().lower()
            if word in ("true", "yes", "on", "1"):
                return True
            if word in ("false", "no", "off", "0"):
                return False
        return self._unusable(name, value, "is not true or false")

    def text(self, name):
        value = self.value(name)
        if value is None or isinstance(value, str):
            return value
        return self._unusable(name, value, "is not a text")

    def table(self, name):
        """Everything below a name, taken as a whole: of a Lua file the table as it stands (nested dicts, list
        positions as whole numbers from 1 - lua_list() makes a list of one); of an ini file {key: value} of that
        section. None when there is nothing of that name."""
        prefix = self._key(name) + "."
        hits = [i for i, (n, _) in enumerate(self._values) if self._key(n).startswith(prefix)]
        self._taken.update(hits)
        if not hits:
            if not self.problem:
                self.complaints.append((name, "is not in %s" % self.name))
            return None
        if not self.typed:
            return {self._values[i][0][len(prefix):]: self._values[i][1] for i in hits}
        return self.peek(name)

    def peek(self, name=""):
        """A Lua file's value or table at a dotted name as it stands ("" = the table of the whole file), or None.
        Nothing is marked as looked at by this: the converter says used() or leave() for what it has dealt with,
        and whatever it says nothing about is listed in the plan as overlooked."""
        found = self.tree
        for part in (name.split(".") if name else []):
            found = next((v for k, v in found.items() if self._key(str(k)) == self._key(part)), None) if isinstance(found, dict) else None
        return found

    def used(self, name):
        """The value of that name - or, for a table, every value below it - went into the conversion."""
        self._taken.update(self._below(name))

    def leave(self, name, why):
        """A value the converter leaves out on purpose (for a table: every value below it): listed with this
        reason instead of as overlooked."""
        hit = self._find(name)
        hits = [hit] if hit is not None else self._below(name)
        self._taken.update(hits)
        for i in hits:
            self.passed.append(("%s=%s" % (self._values[i][0], show_value(self._values[i][1], self.typed)), why))

    def tell(self, what, why):
        """Something of the mod that is not carried over and is no single value of its file (a part of what a
        value did there, a built-in behaviour): listed in the plan like a value that is left out."""
        self.passed.append((what, why))

    def rest(self):
        """[(name, value)] nobody asked for."""
        return [(n, v) for i, (n, v) in enumerate(self._values) if i not in self._taken]


class TheirMod:
    """A mod of the take-over table as its converter sees it: read access to its files, by the path inside its
    folder (found without regard to case, so Scripts and scripts are the same)."""

    def __init__(self, name, root, rels):
        self.name = name
        self._root = root
        self._rels = {r.lower(): r for r in rels}
        self.files = []             # the TheirFile objects handed out
        self.sources = {}           # path inside the mod -> sha256 of what was read
        self.copies = []            # [(path inside the mod, path inside the megamod)]: whole files that move as they are
        self.notes = []
        self.remarks = {}           # (our module, our key) -> what the plan says behind the value

    def has(self, rel):
        return rel.replace("\\", "/").lower() in self._rels

    def matching(self, pattern):
        """The paths inside the mod that match a regular expression (compared with / and without regard to case)."""
        return sorted(r for r in self._rels.values() if re.match(pattern, r, re.I))

    def read(self, rel):
        """The bytes of a file of the mod, or None when it is not there or cannot be read."""
        actual = self._rels.get(rel.replace("\\", "/").lower())
        if actual is None:
            return None
        try:
            with open(os.path.join(self._root, actual.replace("/", SEP)), "rb") as f:
                data = f.read()
        except OSError:
            return None
        self.sources[actual] = sha_of(data)
        return data

    def _hand_out(self, rel, values, typed, problem, tree=None, exact=False):
        self.files.append(TheirFile(rel.replace("/", "\\"), values, typed, problem, tree, exact))
        return self.files[-1]

    def ini(self, rel):
        """An ini file of the mod. When it is missing or not a text file, every value asked of it is None."""
        data = self.read(rel)
        if data is None:
            return self._hand_out(rel, [], False, "not found" if not self.has(rel) else "cannot be read")
        if b"\x00" in data:
            return self._hand_out(rel, [], False, "is not a text file")
        entries, unread = read_ini(data)
        values = [((section + "." + key) if section else key, value) for section, key, value, _ in entries]
        if not values:
            return self._hand_out(rel, [], False, "has no key=value line")
        handed = self._hand_out(rel, values, False, None)
        for number, text in unread[:3]:
            handed.complaints.append(("line %d (%s)" % (number, text), "is not a key=value line"))
        return handed

    def lua(self, rel, exact=False):
        """A Lua settings file of the mod (plain values only, see read_lua). When it is missing or more than plain
        values, every value asked of it is None. exact=True: names are found as they are written (`debug` is not
        `Debug`, as for the mod itself)."""
        data = self.read(rel)
        if data is None:
            return self._hand_out(rel, [], True, "not found" if not self.has(rel) else "cannot be read", None, exact)
        try:
            tree = read_lua(data)
            return self._hand_out(rel, lua_flat(tree), True, None, tree, exact)
        except LuaError as e:
            return self._hand_out(rel, [], True, "could not be read as plain values (%s)" % e, None, exact)

    def fixed(self, values, name="built-in values"):
        """Values the mod has built in (no settings file), as {name: value}: handed out like a file's.
        name: where they stand, for the plan (a mod that keeps them in its script)."""
        return self._hand_out(name, list(values.items()), True, None, dict(values))

    def remark(self, module, key, text):
        """What the plan says behind the value of our key (how it was worked out from theirs)."""
        self.remarks[(module, key)] = text

    def copy(self, rel, target):
        """Our own former mods: a file that moves as it is to `target` inside the megamod."""
        actual = self._rels.get(rel.replace("\\", "/").lower())
        if actual is not None:
            self.copies.append((actual, target))

    def note(self, text):
        self.notes.append(text)


# ---------------------------------------------------------------------------------------------
# The converters. One per mod of the table below: it reads the mod's settings and gives back
#     { "<our module>": { "<our key>": value, ... }, ... }
# (the keys are put into that module's config.lua in the order given; a value of None is left out).
# The installer checks every value against the module's schema.lua in the package: an unknown key or a
# value of the wrong kind is listed as not carried over, a number is pulled into Min..Max and written
# with the schema's Decimals. So a converter only names which value of theirs goes to which key of ours.
#
# HOW TO FILL ONE IN (convert_expmodifier is the worked example):
#   1. open the mod's file:     ini = their.ini("BetterMining.ini")      /   lua = their.lua("Scripts/config.lua")
#   2. ask for their values:    ini.number("StrPerOre"), ini.boolean("Enabled"), ini.text("Name"), ini.value("X")
#                               lua.boolean("removeConnections.untrained"), lua.value("removeConnections.skilled"),
#                               lua.table("Spells") -> { "Feuerball": { "class": ..., "damage": 1.25 }, ... } (taken whole),
#                               lua_list(lua.table("CircleCost")) -> [10, 12, 15, 18, 20, 25]
#                               fixed = their.fixed({"Key": "Y"}); fixed.text("Key")      (a mod without a settings file)
#      A value that is not there or not usable comes back as None and is listed in the plan by itself.
#   3. give back the mapping:   return {"mining": {"StrengthPerOre": ini.number("StrPerOre"), ...}}
#      Calculate freely in between (a percentage into a factor, a word into one of our choices).
#   4. a value of theirs that has no place in our module:  ini.leave("UpdateIntervalMs", "why")  - otherwise it is
#      listed as "not looked at by the converter", which is how a forgotten value shows up in --check.
#   5. for a value worked out from theirs, say how:  their.remark("mining", "YieldEnabled", "its formula: ...")  - the
#      plan prints it behind the value. Something of the mod that is lost and is no value of its file:  ini.tell(what, why).
#      A Lua file whose names must be read as written (as the mod itself does):  their.lua(path, exact=True), and
#      lua.peek(name) / lua.used(name) to walk its tables by hand.
#   6. python sim_megamod.py --part convert: every mapping and every rule of a converter has a case there.
# ---------------------------------------------------------------------------------------------
def carry_repopulate(their):
    """Our own former mod G1R_Repopulate: its settings file, its progress files and the settings app move as they are."""
    if their.has("Scripts/config.lua"):
        their.copy("Scripts/config.lua", "modules/repopulate/Scripts/config.lua")
    else:
        their.note("G1R_Repopulate has no settings file: the default settings of the module are used")
    for rel in their.matching(r"^Scripts/state/profile_[A-Za-z0-9_]+\.lua$"):
        their.copy(rel, "modules/repopulate/Scripts/state/" + rel.rsplit("/", 1)[-1])
    their.copy(SETTINGS_EXE, SETTINGS_EXE_REL)


def carry_markers(their):
    """Our own former mod NPCMarkers: its settings file moves as it is (only a 2.3 file)."""
    if their.has("Scripts/config.lua"):
        head = (their.read("Scripts/config.lua") or b"")[:4096].decode("latin-1")
        if MARKERS_CONFIG_HEADER in head:
            their.copy("Scripts/config.lua", "modules/markers/Scripts/config.lua")
        else:
            their.note("NPCMarkers\\Scripts\\config.lua is not a 2.3 settings file: the module keeps its default settings")


def convert_expmodifier(their):
    """EXPModifier.ini -> modules xp and general.
    The mod reads `Key=value` lines without sections, keys in any case, the last one counts; true / false also
    as yes / no, on / off, 1 / 0 (its scripts\\main.lua, readExisting and applyValues)."""
    ini = their.ini("EXPModifier.ini")
    ini.leave("UpdateIntervalMs", "the module xp has its own check interval")
    return {
        "xp": {
            "Multiplier": ini.number("ExpMultiplier"),
            "ShowMessage": ini.boolean("ShowBonusMessage"),
            "LogGains": ini.boolean("Debug"),
        },
        "general": {
            "NoteSeconds": ini.number("MessageDurationSeconds"),
        },
    }


def short_number(value):
    """A number as short as it can be written with three places: 35, 0.1, 2.778."""
    text = ("%.3f" % value).rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def convert_skillfullocks(their):
    """SkillfulLocks\\Scripts\\config.lua -> module locks.
    Their file: return { removeConnections = { untrained, skilled, master }, vanillaPrecision = { ... }, debug }.
        removeConnections.<level>      our <Level>Connections
            false                      "as the game has it"
            0 / 1 / 2                  "none" / "1" / "2"     (a negative number counts as 0 there)
            a number above 2           "safe"   (our module offers no fixed number above 2; their mod capped such a
                                                number per lock at what is proven solvable, which is what "safe" does)
            "auto"                     "safe"
            "all"                      "all"
        debug                          LogLocks (anything but false / nil counts as true there)
        vanillaPrecision.*             not carried over: the game's own numbers are built into our module
    Names are read as they are written (the mod is Lua: `Debug` is not `debug`). What the mod itself takes as "leave
    the lock alone" (a missing level, a value that is none of the above) is not carried over: our default is the same."""
    lua = their.lua("Scripts/config.lua", exact=True)
    if lua.problem:
        return {}                               # said in the plan; the module keeps its default settings
    out = {}
    table = lua.peek("removeConnections")
    lua.used("removeConnections")
    if not isinstance(table, dict):
        lua.tell("removeConnections" + ("" if table is None else "=%s" % show_value(table, True)),
                 "is not a table of the three skill levels in %s (a settings file of SkillfulLocks 1.0?): the mod itself then takes untrained "
                 "as the game has it, skilled \"auto\", master \"all\"; nothing of it is carried over" % lua.name)
        table = {}
        levels = ()
    else:
        levels = (("untrained", "UntrainedConnections"), ("skilled", "SkilledConnections"), ("master", "MasterConnections"))
    for level, key in levels:
        value = table.get(level)
        shown = "removeConnections.%s" % level + ("" if value is None else (" (a table)" if isinstance(value, dict) else "=%s" % show_value(value, True)))
        if value is False:
            out[key] = "as the game has it"
        elif value == "all":
            out[key] = "all"
        elif value == "auto":
            out[key] = "safe"
            their.remark("locks", key, "their \"auto\"")
        elif is_number(value):
            if value > 2:
                out[key] = "safe"
                their.remark("locks", key, "was %s: our module offers no fixed number above 2; their mod capped such a number per lock at "
                                           "what is proven solvable, which is what \"safe\" does" % show_value(value))
            elif value <= 0:
                out[key] = "none"
                if value < 0:
                    their.remark("locks", key, "was %s: their mod takes a negative number as 0" % show_value(value))
            elif value in (1, 2):
                out[key] = "%d" % value
            else:
                lua.tell(shown, "is not a whole number of connections: not carried over")
        elif value is None:
            lua.tell(shown, "is not in %s: their mod leaves such a level as the game has it, and so does our default" % lua.name)
        else:
            lua.tell(shown, "is none of false, a number, \"all\", \"auto\": their mod leaves such a level as the game has it, and so does our default")
    for name in table:                          # anything else in that table
        if name not in ("untrained", "skilled", "master"):
            lua.leave("removeConnections.%s" % name, "is not one of the three skill levels untrained, skilled, master")
    debug = lua.value("debug")
    if debug is not None:
        out["LogLocks"] = debug if isinstance(debug, bool) else True
        if not isinstance(debug, bool):
            their.remark("locks", "LogLocks", "was %s: anything but false counts as true there" % show_value(debug, True))
    lua.leave("vanillaPrecision", "the game's own numbers for the three skill levels are built into the module locks")
    return {"locks": out}


WAITONT_KNOWN = {"Key": "Y", "WAIT_HOURS": 0.5, "COOLDOWN_SECONDS": 2}      # G1R_WaitOnT 1.0.0 as it is installed on the PC
_WAITONT_KEYBIND = re.compile(r"RegisterKeyBind\s*[(,]\s*Key\.([A-Za-z0-9_]+)\s*,\s*(?:\{([^{}]*)\}\s*,)?")
_WAITONT_MODIFIER = re.compile(r"^\s*ModifierKey\.([A-Za-z_]+)\s*$")


def waitont_built_in(data):
    """What G1R_WaitOnT has built into its Scripts\\main.lua, read from the text without running it:
    ({"Key", "WAIT_HOURS", "COOLDOWN_SECONDS"} as far as they stand there in the known form, [names not found]).
    Known form: `local WAIT_HOURS = 0.5`, `local COOLDOWN_SECONDS = 2` (a plain number), and exactly one key
    registered with RegisterKeyBind(Key.Y, ...) / pcall(RegisterKeyBind, Key.Y, ...), with or without a list of
    ModifierKey names."""
    text = "\n".join(line.split("--", 1)[0].rstrip() for line in (data or b"").decode("latin-1").split("\n"))
    found = {}
    for name in ("WAIT_HOURS", "COOLDOWN_SECONDS"):
        hits = set(re.findall(r"(?m)^[ \t]*local[ \t]+%s[ \t]*=[ \t]*([0-9]+\.?[0-9]*|\.[0-9]+)[ \t]*$" % name, text))
        if len(hits) == 1:
            found[name] = lua_tonumber(hits.pop())
    keys = set()
    for key, modifiers in _WAITONT_KEYBIND.findall(text):
        held = [_WAITONT_MODIFIER.match(m) for m in modifiers.split(",") if m.strip()]
        keys.add("+".join([m.group(1) for m in held] + [key]) if all(held) else None)
    if len(keys) == 1 and None not in keys:
        found["Key"] = keys.pop()
    return found, [name for name in ("Key", "WAIT_HOURS", "COOLDOWN_SECONDS") if name not in found]


def convert_waitont(their):
    """G1R_WaitOnT -> module wait. The mod has no settings file; what it does is built into its Scripts\\main.lua:
    one key (Y) skips WAIT_HOURS (0.5) hours, at most every COOLDOWN_SECONDS (2), and shows a note.
        its key                        ShortKey
        WAIT_HOURS x 60                ShortMinutes
        COOLDOWN_SECONDS               Cooldown
        its note after a skip          ShowMessage = true
    The three values are taken from main.lua where they stand there in the known form (so a file somebody edited
    is read as it is); what is not found there is taken as version 1.0.0 has it, and the plan says so."""
    found, missing = waitont_built_in(their.read("Scripts/main.lua"))
    if missing:
        their.note("%s\\Scripts\\main.lua does not name %s in the form known from version 1.0.0: taken as that version has it (%s)"
                   % (their.name, _join(["its key" if name == "Key" else name for name in missing]),
                      ", ".join("%s = %s" % ("key" if name == "Key" else name, show_value(WAITONT_KNOWN[name])) for name in missing)))
    built = their.fixed(dict(WAITONT_KNOWN, **found), "Scripts\\main.lua")
    hours = built.number("WAIT_HOURS")
    if hours is not None:
        their.remark("wait", "ShortMinutes", "its WAIT_HOURS = %s" % show_value(hours))
    built.tell("the text and the place of its note (\"You waited 30 minutes\" in the game's top line)",
               "our module shows its own note: how long, and what time it is now; how notes look is set on the page General")
    built.tell("it skipped time whenever a game was loaded and not paused",
               "our module also refuses with a weapon drawn, in a conversation, in a cutscene and while the game's clock stands still "
               "(NotInFight, NotInConversation, NotInCutscene, NotWhenClockStopped: the shipped values; each can be switched off)")
    return {"wait": {
        "ShortKey": built.text("Key"),
        "ShortMinutes": None if hours is None else hours * 60,
        "Cooldown": built.number("COOLDOWN_SECONDS"),
        "ShowMessage": True,
    }}


def convert_bettermining(their):
    """BetterMining.ini -> module mining.
    Their file (in the mod's folder, or else in its scripts folder): Enabled, StrPerOre, AgiPerOre, PreventExhaustion
    (the mod reads the keys in any section).
    Its formula: floor(Strength / StrPerOre) + floor(Dexterity / AgiPerOre) ore per swing, for every state of the vein.
        Enabled=false                  Enabled = false, and nothing else
        StrPerOre, AgiPerOre           YieldEnabled = true, StrengthPerOre, DexterityPerOre, and the shape of its formula:
                                       BaseAmount = 0, MinAmount = 0, LowVeinRule = false
        PreventExhaustion              EndlessVeins
        (it showed no notes)           ShowMessage = false
    The formula is carried over as a whole or not at all: both numbers must be above 0 (the mod divides by them; in our
    module 0 means "does not count"). Half a formula would give amounts neither mod ever gave."""
    # the mod looks next to its scripts folder first, then inside it
    ini = their.ini("scripts/BetterMining.ini" if their.has("scripts/BetterMining.ini") and not their.has("BetterMining.ini") else "BetterMining.ini")
    if ini.problem:
        return {}
    enabled = ini.boolean("Enabled")
    if enabled is False:
        for name in ("StrPerOre", "AgiPerOre", "PreventExhaustion"):
            ini.leave(name, "BetterMining is switched off in its own file (Enabled=false): the module mining is switched off too, and nothing else is carried over")
        return {"mining": {"Enabled": False}}
    numbers = {}
    for name in ("StrPerOre", "AgiPerOre"):
        value = ini.number(name)
        if value is not None and not value > 0:
            ini.leave(name, "must be above 0: BetterMining divides by it (in our module 0 means that the attribute does not count)")
            value = None
        numbers[name] = value
    out = {"Enabled": enabled}
    if None not in numbers.values():
        out.update({"YieldEnabled": True, "BaseAmount": 0, "StrengthPerOre": numbers["StrPerOre"], "DexterityPerOre": numbers["AgiPerOre"],
                    "MinAmount": 0, "LowVeinRule": False})
        their.remark("mining", "YieldEnabled", "its formula: Strength / StrPerOre + Dexterity / AgiPerOre, each rounded down - no base amount, "
                                                "no least amount, the same for a nearly empty vein")
    else:
        for name, value in numbers.items():
            if value is not None:
                ini.leave(name, "not carried over without the other number of the formula")
        ini.tell("its formula for the ore of a swing", "it takes both StrPerOre and AgiPerOre as numbers above 0: the ore of a swing stays as the game has it (YieldEnabled = false)")
    out["EndlessVeins"] = ini.boolean("PreventExhaustion")
    out["ShowMessage"] = False
    their.remark("mining", "ShowMessage", "BetterMining showed no notes")
    return {"mining": out}


# The fifteen spells the module magic has settings for, as G1R_MageBalance names them, with the game's own numbers
# of the installed build - needed to say that mod's absolute numbers as our multipliers (source: the game's scripts,
# see dev/facts/magic.md; the simulation compares this table with dev/tests/magic/game.lua, the model of the module's
# own tests).
#   key      the start of our settings for the spell: <key>Damage, <key>Mana, <key>CastTime, ...
#   class    the name a block of their file gives for its definition; their mod also takes <class>_Lvl1 .. _Lvl4,
#            <class>_Base, <class>_WithParalysis and <class>_WithoutParalysis under that name
#   config   the name of its spell config (their `spellConfig`)
#   levels   per charge level: (mana to cast, mana for each further shot or second, casting time)
#   damage   its damage where it has one number: no charge levels, no steps by the caster's magic circle
#   steps    True: our module has numbers of its own for its damage by the caster's circle (<key>Step0 / 2 / 4 / 6)
#   stagger  its force against a foe's stance, where our module has a setting for that
#   freeze   the hit effect that holds its ice counter (their `freezeGE`)
MAGIC_SPELLS = (
    {"key": "FireBolt", "class": "FireBoltProjectileDefinition", "config": "ProjectileSpellConfig_FireBolt", "levels": ((1, 1, 0.1),), "steps": True},
    {"key": "FireBall", "class": "FireBallProjectileDefinition", "config": "ProjectileSpellConfig_FireBall", "levels": ((1, 0, 0.4), (2, 0, 0.6), (2, 2, 0.8))},
    {"key": "Pyrokinesis", "class": "PyrokinesisProjectileDefinition", "config": "PyrokinesisSpellConfig", "levels": ((5, 1, 0.5),)},
    {"key": "StormOfFire", "class": "StormOfFireDefinition", "config": "StormOfFireSpellConfig", "levels": ((30, 0, 0.5),)},
    {"key": "FireRain", "class": "FireRainDefinition", "config": "FireRainSpellConfig", "levels": ((20, 0, 0.1),), "damage": 50},
    {"key": "IceBolt", "class": "IceBoltProjectileDefinition", "config": "ProjectileSpellConfig_IceBolt", "levels": ((1, 1, 0.1),), "steps": True,
     "freeze": "GE_IceBolt_Damage"},
    {"key": "IceBlock", "class": "IceBlockProjectileDefinition", "config": "IceBlockSpellConfig", "levels": ((3, 0, 0.2),), "freeze": "GE_IceBlock_Freeze_Damage"},
    {"key": "IceWave", "class": "IceWaveProjectileDefinition", "config": "IceWaveSpellConfig", "levels": ((15, 0, 0.2),), "freeze": "GE_IceWave_Freeze_Damage"},
    {"key": "BallLightning", "class": "BallLightningDefinition", "config": "ProjectileSpellConfig_BallLightning",
     "levels": ((5, 0, 0.3), (1, 0, 1.03), (1, 0, 1.03), (2, 0, 1.03))},
    {"key": "ChainLightning", "class": "LightningRayDefinition", "config": "ChainLightningSpellConfig", "levels": ((5, 1, 0.5),)},
    {"key": "Uriziel", "class": "UrizielWaveOfDeathVisualDefinition", "config": "UrizielWaveOfDeathSpellConfig", "levels": ((40, 0, 0.3),), "damage": 90},
    {"key": "DeathToTheUndead", "class": "DeathToTheUndeadDefinition", "config": "DeathToTheUndeadSpellConfig", "levels": ((25, 0, 0.5),), "damage": 500},
    {"key": "WindFist", "class": "WindFistDefinition", "config": "FistOfWindSpellConfig", "levels": ((2, 0, 0),), "stagger": 200},
    {"key": "StormFist", "class": "StormFistDefinition", "config": "StormFistSpellConfig", "levels": ((10, 0, 0.5),)},
    {"key": "BreathOfDeath", "class": "BreathOfDeathDefinition", "config": "BreathOfDeathSpellConfig", "levels": ((15, 0, 0.5),), "damage": 150},
)
MAGIC_VARIANTS = ("_Lvl1", "_Lvl2", "_Lvl3", "_Lvl4", "_Base", "_WithParalysis", "_WithoutParalysis")
MAGIC_SNAP = 0.025          # the module magic takes a product this close to a whole number as that number (damage, mana)


def is_number(value):
    """A number a converter can calculate with: not true / false, not infinite (1e999), not beyond any setting."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and -1e12 <= value <= 1e12


def magic_multiplier(ratio):
    """A multiplier as our settings hold it: three places."""
    return float("%.3f" % ratio)


def magic_levels(spec, levels, column):
    """Their absolute numbers per charge level ({1: number, ...}) as ONE multiplier on the game's numbers.
    levels: the game's (mana, held, time) per level, none of them 0 in that column; column: 0 for mana, 2 for casting
    time. A level their table does not name keeps the game's number, as in their mod.
    Gives (multiplier, [their number or None per level]) - or (None, why one multiplier cannot say it)."""
    theirs = [spec.get(i + 1) if is_number(spec.get(i + 1)) else None for i in range(len(levels))]
    ratios = [1.0 if mine is None else float(mine) / level[column] for mine, level in zip(theirs, levels)]
    if max(ratios) - min(ratios) > 1e-9:
        return None, ("our module has one multiplier for a spell, not a number for each charge level (theirs are x%s of the game's %s)"
                      % (" / x".join(short_number(r) for r in ratios), " / ".join(short_number(level[column]) for level in levels)))
    return ratios[0], theirs


def convert_magebalance(their):
    """G1R_MageBalance\\Scripts\\config.lua (0.9.0) -> module magic.
    Their file: return { Enabled, Spells = { <any name> = { class, damage, fields, spellConfig, mana, cast,
    configFields, freezeGE, reliableFreeze, enabled } }, CircleCost, Verbose, DebugSteps }. A spell is known by
    `class` (its definition) and `spellConfig` (its config), not by the name of the block.
        Enabled                        Enabled (missing counts as true there)
        damage = number                <Spell>Damage (a multiplier there too)
        damage = { base, c2, c4, c6 }  fire bolt, ice bolt: <Spell>Steps = true, <Spell>Step0 / Step2 / Step4 / Step6
                                       a spell with one damage number: <Spell>Damage = base / the game's number
                                       other spells: not carried over (one multiplier is all our module has for them)
        fields.m_Speed                 ball lightning: BallLightningSpeed
        fields.m_SuperArmorDamageBase  fist of wind: WindFistStagger = their number / the game's 200
        mana = number                  <Spell>Mana;   mana = { per level }: <Spell>Mana = their number / the game's,
        cast = number                  <Spell>CastTime; cast = { per level } likewise - when one multiplier says it
        reliableFreeze + freezeGE      <Spell>Freeze of the ice spell whose hit effect is named
        CircleCost = number / { 1..6 } CircleCosts = true, CircleCost1 .. CircleCost6
        a mana cost that is changed    WholeMana = false (their mod writes the exact product, 2 x 1.25 = 2.5)
    Not carried over (each is said in the plan): any other of `fields` and `configFields`, blocks of other spells,
    Verbose / DebugSteps, and where our module does only a part of what theirs did."""
    lua = their.lua("Scripts/config.lua", exact=True)
    tree = lua.peek()               # a file that is missing or cannot be read gives an empty table: nothing below finds anything
    by_class = {spell["class"]: spell for spell in MAGIC_SPELLS}
    by_config = {spell["config"]: spell for spell in MAGIC_SPELLS}
    by_freeze = {spell["freeze"]: spell for spell in MAGIC_SPELLS if spell.get("freeze")}
    one_level = {spell["class"] + suffix: spell for spell in MAGIC_SPELLS for suffix in MAGIC_VARIANTS}
    out = {}
    mana_changed = []

    def put(key, value, remark=None):
        out[key] = value
        their.remarks.pop(("magic", key), None)        # a second block for the same spell: its value, its remark
        if remark:
            their.remark("magic", key, remark)

    def say(value, game, unit=""):
        return "their %s%s; the game has %s%s" % (short_number(value), unit, short_number(game), unit)

    def gives(game, times, theirs, whole):
        """Said when the module, with this multiplier, does not arrive at their number (three places are not always enough)."""
        got = game * times
        if whole and abs(got - math.floor(got + 0.5)) <= MAGIC_SNAP:
            got = math.floor(got + 0.5)
        return "" if short_number(got) == short_number(theirs) else "; x%s gives %s" % (short_number(times), short_number(got))

    lua.leave("ModName", "name and version of their mod: no settings")
    lua.leave("Version", "name and version of their mod: no settings")
    enabled = tree.get("Enabled")
    lua.used("Enabled")
    put("Enabled", None if enabled is None else enabled is not False)

    spells = tree.get("Spells")
    if spells is not None and not isinstance(spells, dict):
        lua.leave("Spells", "is not a table of spell blocks")
        spells = None
    for name, block in (spells or {}).items():
        path = "Spells.%s" % name
        if not isinstance(block, dict):
            lua.leave(path, "is not a table with the settings of a spell")
            continue
        if block.get("enabled") is False:
            lua.leave(path, "the block is switched off there (enabled = false)")
            continue
        lua.used(path + ".enabled")

        # ---- the definition: damage, fields
        cls = block.get("class")
        lua.used(path + ".class")
        spell = by_class.get(cls) if isinstance(cls, str) else None
        if spell is None:
            if cls is None:
                why = "the block names no class: their mod does not apply it either"
            elif isinstance(cls, str) and cls in one_level:
                why = "%s is one definition of a spell that has several: our settings hold for the whole spell" % cls
            else:
                why = "%s is not the definition of one of the fifteen spells the module magic has settings for" % show_value(cls, True)
            for part in ("damage", "fields"):
                lua.leave(path + "." + part, why)
        else:
            key = spell["key"]
            damage = block.get("damage")
            if is_number(damage):
                lua.used(path + ".damage")
                put(key + "Damage", damage)
            elif isinstance(damage, dict):
                given = {part: damage.get(part) for part in ("base", "c2", "c4", "c6") if damage.get(part) is not None}
                for part, value in list(given.items()):
                    if not is_number(value):
                        lua.leave("%s.damage.%s" % (path, part), "is not a number")
                        del given[part]
                if spell.get("steps"):
                    for part, step in (("base", "Step0"), ("c2", "Step2"), ("c4", "Step4"), ("c6", "Step6")):
                        if part in given:
                            lua.used("%s.damage.%s" % (path, part))
                            put(key + "Steps", True)
                            put(key + step, given[part])
                elif spell.get("damage"):
                    if "base" in given:
                        lua.used(path + ".damage.base")
                        times = magic_multiplier(float(given["base"]) / spell["damage"])
                        put(key + "Damage", times, say(given["base"], spell["damage"]) + gives(spell["damage"], times, given["base"], True))
                    for part in ("c2", "c4", "c6"):
                        if part in given:
                            lua.leave("%s.damage.%s" % (path, part), "the spell has one damage number in the game: their mod finds no step to write this to")
                else:
                    for part in given:
                        lua.leave("%s.damage.%s" % (path, part), "our module has numbers of its own for the damage by the caster's circle only for the fire bolt "
                                                                 "and the ice bolt; this spell has one multiplier (%sDamage), which absolute numbers do not give" % key)
            elif damage is not None:
                lua.leave(path + ".damage", "is neither a number (a multiplier) nor a table of absolute numbers")
            fields = block.get("fields")
            if isinstance(fields, dict):
                for field, value in fields.items():
                    place = "%s.fields.%s" % (path, field)
                    if field == "m_Speed" and key == "BallLightning":
                        if is_number(value) and value > 0:
                            lua.used(place)
                            put("BallLightningSpeed", value)
                            lua.tell("%s for BallLightningDefinition_Base" % place, "their mod also wrote the speed to that definition, which the rune does not use: "
                                                                                    "our module changes the four charge levels only")
                        else:
                            lua.leave(place, "our BallLightningSpeed takes a speed above 0 (0 there means the game's own speed)")
                    elif field == "m_SuperArmorDamageBase" and spell.get("stagger"):
                        if is_number(value) and value >= 0:
                            lua.used(place)
                            times = magic_multiplier(float(value) / spell["stagger"])
                            put(key + "Stagger", times, say(value, spell["stagger"]) + gives(spell["stagger"], times, value, False))
                        else:
                            lua.leave(place, "is not a number of 0 or more")
                    elif field == "m_Speed":
                        lua.leave(place, "our module has a flight speed of its own only for the ball lightning; for the other spells one multiplier for all (ProjectileSpeed)")
                    elif field == "m_SuperArmorDamageBase":
                        lua.leave(place, "our module has a setting of its own for the force against a foe's stance only for the fist of wind; "
                                         "for the other spells one multiplier for all (Stagger)")
                    elif field in ("m_XOffset", "m_YOffset") and key == "FireRain":
                        lua.leave(place, "no setting: the game's scripts do not read this number (the area of the rain of fire is held by other numbers); "
                                         "if the rain covered more ground with their mod, that is lost")
                    else:
                        lua.leave(place, "the module magic has no setting for this number")
            elif fields is not None:
                lua.leave(path + ".fields", "is not a table of numbers")

        # ---- the spell config: mana, casting time
        config = block.get("spellConfig")
        lua.used(path + ".spellConfig")
        parts = [part for part in ("mana", "cast", "configFields") if block.get(part) is not None]
        target = by_config.get(config) if isinstance(config, str) else None
        if parts and target is None:
            why = ("the block names no spellConfig: their mod does not apply it either" if not config else
                   "%s is not the spell config of one of the fifteen spells the module magic has settings for "
                   "(every other spell has only the multipliers for all spells)" % show_value(config, True))
            for part in parts:
                lua.leave(path + "." + part, why)
        elif parts:
            key, levels = target["key"], target["levels"]
            for part, column, ours, unit in (("mana", 0, key + "Mana", ""), ("cast", 2, key + "CastTime", " s")):
                value = block.get(part)
                place = "%s.%s" % (path, part)
                if value is None:
                    continue
                if column == 2 and not any(level[2] for level in levels):
                    lua.leave(place, "the game's casting time of this spell is 0: there is nothing to change, and our module has no setting for it")
                elif is_number(value):
                    lua.used(place)
                    put(ours, value)
                    if column == 0 and value != 1:
                        mana_changed.append(ours)
                elif isinstance(value, dict):
                    times, theirs = magic_levels(value, levels, column)             # or: None, why not
                    for index, number in value.items():
                        if not isinstance(index, int):
                            continue                                                # no level: listed as not looked at
                        if not 1 <= index <= len(levels):
                            lua.leave("%s.%s" % (place, index), "the spell has %d charge level(s) in the game" % len(levels))
                        elif not is_number(number):
                            lua.leave("%s.%s" % (place, index), "is not a number")
                        elif times is None:
                            lua.leave("%s.%s" % (place, index), theirs)
                        else:
                            lua.used("%s.%s" % (place, index))
                    if times is None or not any(number is not None for number in theirs):
                        continue
                    times = magic_multiplier(times)
                    remark = "their %s%s; the game has %s%s" % (" / ".join("-" if n is None else short_number(n) for n in theirs), unit,
                                                               " / ".join(short_number(level[column]) for level in levels), unit)
                    if column == 0 and times != 1:
                        mana_changed.append(ours)
                    more = []
                    for number, level in zip(theirs, levels):
                        if number is None:
                            continue
                        more.append(gives(level[column], times, number, column == 0))
                        if column == 0 and level[1] > 0 and short_number(level[1] * times) != short_number(number):
                            more.append("; their mod also set the cost of each further shot or second to %s, here it follows the multiplier: %s"
                                        % (short_number(number), short_number(level[1] * times)))
                    put(ours, times, remark + "".join(piece for i, piece in enumerate(more) if piece not in more[:i]))
                else:
                    lua.leave(place, "is neither a number (a multiplier) nor a table of absolute numbers")
            if block.get("configFields") is not None:
                lua.leave(path + ".configFields", "the module magic has no setting for this number")

        # ---- an ice spell that freezes with every hit
        effect, reliable = block.get("freezeGE"), block.get("reliableFreeze")
        if effect is not None or reliable is not None:
            frozen = by_freeze.get(effect) if isinstance(effect, str) else None
            if reliable is True and frozen is not None:
                lua.used(path + ".freezeGE")
                lua.used(path + ".reliableFreeze")
                put(frozen["key"] + "Freeze", True)
                lua.tell("%s.reliableFreeze for hits on a foe that is frozen already" % path,
                         "their mod set the flag in both lists of the hit effect; our module sets it in the ice counter only "
                         "(the other list counts hits on a frozen foe, and its overflow ends the freeze)")
            elif reliable is True:
                why = ("the block names no freezeGE: their mod does not apply it either" if effect is None else
                       "%s is not the hit effect of the ice bolt, the ice block or the ice wave" % show_value(effect, True))
                lua.leave(path + ".freezeGE", why)
                lua.leave(path + ".reliableFreeze", why)
            else:
                lua.leave(path + ".freezeGE", "without reliableFreeze = true their mod does nothing with it, and our switch stays off")
                lua.leave(path + ".reliableFreeze", "without reliableFreeze = true their mod does nothing with it, and our switch stays off")

    # ---- the price of the magic circles
    cost = tree.get("CircleCost")
    if is_number(cost):
        lua.used("CircleCost")
        put("CircleCosts", True)
        for circle in range(1, 7):
            put("CircleCost%d" % circle, cost)
    elif isinstance(cost, dict):
        for circle in range(1, 7):
            value = cost.get(circle)
            if is_number(value):
                lua.used("CircleCost.%d" % circle)
                put("CircleCosts", True)
                put("CircleCost%d" % circle, value)
            elif value is not None:
                lua.leave("CircleCost.%d" % circle, "is not a number")
    elif cost is not None:
        lua.leave("CircleCost", "is neither a number nor a table of six numbers")

    lua.leave("Verbose", "their line for each spell at its first cast has no counterpart (our LogChanges, one line for every value that is changed, stays off)")
    lua.leave("DebugSteps", "a development switch of their mod")
    if mana_changed:
        their.remark("magic", "WholeMana", "their mod writes the exact product: 2 x 1.25 = 2.5")
        out = dict([("Enabled", out.pop("Enabled")), ("WholeMana", False)] + list(out.items()))
    return {"magic": out}


def convert_regenmana(their):
    """G1R_RegenMana.ini -> module regen.
    Their file (no sections)           our key
        Enabled                        Enabled
        ManaEnabled                    ManaEnabled
        ManaSecondsPerTick             ManaSeconds
        ManaPerTick                    ManaFlat
        ManaPercentPerTick             ManaPercent
        ManaMaxRegenPercentage         ManaUpTo
        ManaCooldownAfterCast          ManaPause
        ManaCirclePercentEnabled       ManaByCircle
        CircleUnskilledPercent         ManaCircleNone
        CircleNovizePercent            ManaCircleNovice
        CircleOnePercent               ManaCircleFirst
        CircleTwoPercent .. Six        ManaCircleStep = (Six - One) / 5; where the table does not rise evenly, the
                                       nearest whole step, and the plan says that it was uneven
        HealthEnabled, HealthSecondsPerTick, HealthPerTick, HealthPercentPerTick, HealthMaxRegenPercentage,
        HealthCooldownAfterDamage      HealthEnabled, HealthSeconds, HealthFlat, HealthPercent, HealthUpTo, HealthPause
        ClearZeroManaGate              ManaClearBlock (a hidden setting, true by default: a line only for false)
        (it showed no notes)           ShowMessage = false
    Not carried over: RegenValueRounding, the marker on the bars (RecoveryIndicator...), the item requirements."""
    ini = their.ini("G1R_RegenMana.ini")
    if ini.problem:
        return {}
    out = {
        "Enabled": ini.boolean("Enabled"),
        "ManaEnabled": ini.boolean("ManaEnabled"),
        "ManaSeconds": ini.number("ManaSecondsPerTick"),
        "ManaFlat": ini.number("ManaPerTick"),
        "ManaPercent": ini.number("ManaPercentPerTick"),
        "ManaUpTo": ini.number("ManaMaxRegenPercentage"),
        "ManaPause": ini.number("ManaCooldownAfterCast"),
        "ManaByCircle": ini.boolean("ManaCirclePercentEnabled"),
        "ManaCircleNone": ini.number("CircleUnskilledPercent"),
        "ManaCircleNovice": ini.number("CircleNovizePercent"),
    }
    names = ("CircleOnePercent", "CircleTwoPercent", "CircleThreePercent", "CircleFourPercent", "CircleFivePercent", "CircleSixPercent")
    circles = [ini.number(name) for name in names]
    for i, name in enumerate(names):
        if circles[i] is not None and not is_number(circles[i]):
            ini.leave(name, "is no number to calculate with")
            circles[i] = None
    out["ManaCircleFirst"] = circles[0]
    if None not in circles:
        rises = [b - a for a, b in zip(circles, circles[1:])]
        step = (circles[5] - circles[0]) / 5.0
        if max(rises) - min(rises) > 1e-9:
            step = math.floor(step + 0.5)
            ini.tell("the uneven rise of %s .. %s (%s)" % (names[1], names[5], ", ".join(show_value(c) for c in circles[1:])),
                     "our module has one step for every further circle: ManaCircleStep = %s gives %s"
                     % (show_value(step), ", ".join(short_number(circles[0] + step * n) for n in range(1, 6))))
        out["ManaCircleStep"] = step
    else:
        for name, value in zip(names[1:], circles[1:]):
            if value is not None:
                ini.leave(name, "the step from circle to circle takes all six numbers of the table: not carried over")
    out.update({
        "HealthEnabled": ini.boolean("HealthEnabled"),
        "HealthSeconds": ini.number("HealthSecondsPerTick"),
        "HealthFlat": ini.number("HealthPerTick"),
        "HealthPercent": ini.number("HealthPercentPerTick"),
        "HealthUpTo": ini.number("HealthMaxRegenPercentage"),
        "HealthPause": ini.number("HealthCooldownAfterDamage"),
        "ManaClearBlock": ini.boolean("ClearZeroManaGate"),
        "ShowMessage": False,
    })
    ini.leave("RegenValueRounding", "the module regen restores whole points, as the game keeps them, and carries fractions over to the next step")
    for name in ("RecoveryIndicatorEnabled", "RecoveryIndicatorPrefix"):
        ini.leave(name, "the module regen has no marker on the bars for values that can regenerate")
    for what, keys in (("mana", ("ActivateManaRegenRequirements", "ManaRegenStacksPerItem", "ManaRegenStackPercentByItemCount", "ManaRegenItemWhitelist")),
                       ("health", ("ActivateHealthRegenRequirements", "HealthRegenStacksPerItem", "HealthRegenStackPercentByItemCount", "HealthRegenItemWhitelist"))):
        switch = ini.value(keys[0]) if ini.has(keys[0]) else None
        if isinstance(switch, str) and switch.strip().lower() in ("true", "yes", "on", "1"):
            their.note("G1R_RegenMana let %s regenerate only with certain items equipped (%s=%s): the module regen has NO item requirements - "
                       "%s will regenerate whatever the hero wears" % (what, keys[0], switch, what))
        for name in keys:
            ini.leave(name, "the module regen has no item requirements: regeneration does not depend on what the hero wears")
    return {"regen": out}


# THE take-over table: (folder of the mod in Mods, kind of mod, our module, converter). Read by the plan, the
# install, the rollback script, the audit (audit_megamod.py) and the simulation (sim_megamod.py) alike.
#   kind "lua": the folder holds Scripts\main.lua (or scripts\main.lua); "native": dlls\main.dll.
#   An entry acts only when its folder holds a mod and the package has modules/<our module>/Scripts/main.lua.
#   The package's Scripts/core/modules.lua must name the folder as `separate` of that module (checked).
TAKEOVERS = (
    ("G1R_Repopulate", "lua", "repopulate", carry_repopulate),
    ("NPCMarkers", "lua", "markers", carry_markers),
    ("EXPModifier", "lua", "xp", convert_expmodifier),
    ("SkillfulLocks", "lua", "locks", convert_skillfullocks),
    ("G1R_WaitOnT", "lua", "wait", convert_waitont),
    ("BetterMining", "lua", "mining", convert_bettermining),
    ("G1R_MageBalance", "lua", "magic", convert_magebalance),
    ("G1R_RegenMana", "native", "regen", convert_regenmana),
)
OWN_MODS = ("G1R_Repopulate", "NPCMarkers")         # our own former selves: their files are the module's files


# ---------------------------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------------------------
def is_session_file(rel):
    return any(rel.startswith(d) for d in SESSION_DIRS) and not rel.endswith("/README.txt")


def is_settings_file(rel):
    """The megamod's own config.lua or a module's: the player's own once it exists."""
    return re.match(r"^(?:Scripts|modules/[^/]+/Scripts)/config\.lua$", rel, re.I) is not None


def is_players(rel):
    """A file of the megamod folder that an update never removes."""
    return is_settings_file(rel) or rel in AS_INSTALLED or is_session_file(rel) or rel.lower() == SETTINGS_EXE_REL.lower()


def mods_txt_enables(text, name):
    """Whether UE4SS starts the mod `name` from this mods.txt (start_mods in UE4SSProgram.cpp): a line with a ';'
    anywhere or of four characters or fewer is skipped, spaces do not count, the name is the text before the first
    colon, on when the text after the last colon starts with 1. Names are compared without regard to case, as the
    loader of the mod does it (separateModRuns in Scripts/main.lua)."""
    if text.startswith("\xef\xbb\xbf"):
        text = text[3:]
    wanted = name.translate(_ASCII_LOWER)
    for line in text.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if ";" in line or len(line) <= 4:
            continue
        compact = line.replace(" ", "")
        m = re.match(r"^(.[^:]*):", compact, re.S)
        if m and m.group(1).translate(_ASCII_LOWER) == wanted and compact.rsplit(":", 1)[1][:1] == "1":
            return True
    return False


def find_mod(base_mods, name):
    """A mod of the table in the Mods folder: (folder name as on disk, {path inside it: sha256}, "lua" / "native" /
    None for what makes it a mod). The folder is found without regard to case; (None, {}, None) when it is not there."""
    folders = set(k.split("/", 1)[0] for k in base_mods if "/" in k)
    folder = name if name in folders else next((f for f in sorted(folders) if f.lower() == name.lower()), None)
    if folder is None:
        return None, {}, None
    inside = {k[len(folder) + 1:]: v for k, v in base_mods.items() if k.startswith(folder + "/")}
    lower = set(k.lower() for k in inside)
    # Scripts\main.lua and scripts\main.lua are the same file on Windows; both spellings count here too
    found = "lua" if "scripts/main.lua" in lower else ("native" if "dlls/main.dll" in lower else None)
    return folder, inside, found


def plan_install(files, installed, old_files=None):
    """What happens to each file: package files are add / replace / same / keep (player's own, left as it is);
    files in the folder that the package does not have are remove (the installed version brought them, the new one
    does not) or other (left alone)."""
    plan = {"add": [], "replace": [], "same": [], "keep": [], "remove": [], "other": []}
    lower = {k.lower(): k for k in installed}
    for rel in sorted(files):
        have = lower.get(rel.lower())
        if have is None:
            plan["keep" if rel in AS_INSTALLED and installed else "add"].append(rel)
        elif is_settings_file(rel) or rel in AS_INSTALLED:
            plan["keep"].append(rel)
        elif installed[have] == sha_of(files[rel]):
            plan["same"].append(rel)
        else:
            plan["replace"].append(rel)
    new = set(r.lower() for r in files)
    old = set(r.lower() for r in (old_files or ()))
    for rel in sorted(installed):
        if rel.lower() not in new:
            plan["remove" if rel.lower() in old and not is_players(rel) else "other"].append(rel)
    return plan


def earlier_runs():
    """The earlier runs of this installer, newest first: [(backup folder name, report, rolled back?)]."""
    out = []
    try:
        names = sorted((d for d in os.listdir(WS) if d.startswith(TAG + "-backup-")), reverse=True)
    except OSError:
        return out
    for d in names:
        try:
            with open(os.path.join(WS, d, "install-report.json"), encoding="utf-8") as f:
                report = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(report, dict):
            out.append((d, report, os.path.exists(os.path.join(WS, d, ROLLED_BACK_NAME))))
    return out


def put_back_mods():
    """{lower-case mod name: backup folder} of the mods the player put back with the rollback script's -Only."""
    out = {}
    try:
        names = sorted(d for d in os.listdir(WS) if d.startswith(TAG + "-backup-"))
    except OSError:
        return out
    for d in names:
        try:
            marks = os.listdir(os.path.join(WS, d))
        except OSError:
            continue
        for fn in marks:
            if fn.startswith(PUT_BACK_PREFIX) and fn.endswith(".txt"):
                out[fn[len(PUT_BACK_PREFIX):-4].lower()] = d
    return out


def installed_package(installed, version, runs, new_manifest_path):
    """The files the installed version was installed with: ({path: sha256 or None}, where that is known from), or
    (None, why it is not known). From the report of the last install / update of that version by this installer
    (not a rolled-back one); else from the manifest of that version in the package folder."""
    for name, report, rolled in runs:
        if rolled or report.get("mode") not in ("install", "update"):
            continue
        if (report.get("version") or version_from_name(report.get("package"))) != version:
            break                                       # the folder is not what that run left: do not guess from older ones
        listed = report.get("package_files")
        if isinstance(listed, dict) and listed:
            return dict(listed), "the report in %s" % name
        plan = report.get("plan") if isinstance(report.get("plan"), dict) else {}
        paths = [r for key in ("add", "replace", "same", "keep") for r in plan.get(key, []) if isinstance(r, str)]
        if paths:
            try:
                hashes = read_manifest(os.path.join(PKGDIR, manifest_name(str(report.get("package")))))
            except (OSError, ValueError):
                hashes = {}
            return {r: hashes.get(r) for r in paths}, "the report in %s" % name
        break
    have = set(k.lower() for k in installed)
    best = None
    for suffix in ("-dev", ""):
        path = os.path.join(PKGDIR, "%s-%s%s-manifest.sha256" % (NAME, version, suffix))
        if os.path.normcase(os.path.abspath(path)) == os.path.normcase(os.path.abspath(new_manifest_path)):
            continue
        try:
            listed = read_manifest(path)
        except (OSError, ValueError):
            continue
        if all(r.lower() in have for r in listed if not is_players(r)) and (best is None or len(listed) > len(best[0])):
            best = (listed, "the manifest %s" % os.path.basename(path))
    if best:
        return best
    return None, "no report of an earlier run and no manifest of version %s in %s" % (version, PKGDIR)


def plan_carry(todo, files, base_mods, pristine, take_values=True):
    """What comes along from the mods in `todo` (entries of the table that are installed, as dicts): whole files
    of our own former mods (`copies`) and the other mods' settings converted into our modules' config.lua
    (`texts`: path inside the megamod -> the new text). `pristine(path)` says whether that file may be written."""
    out = {"copies": [], "texts": {}, "conversions": [], "lost": [], "notes": [], "read": []}
    drafts, setters, schemas = {}, {}, {}
    for info in todo:
        mod, folder = info["mod"], info["folder"]
        their = TheirMod(mod, os.path.join(MODS, folder), list(info["inside"]))
        try:
            wanted = info["convert"](their) or {}
            if not isinstance(wanted, dict) or not all(isinstance(v, dict) for v in wanted.values()):
                raise TypeError("it must give back { module: { key: value } }")
        except Exception as e:                  # a mistake in a converter must not take the install down
            out["lost"].append({"mod": mod, "what": "everything", "why": "THE CONVERTER FAILED (%s: %s)" % (type(e).__name__, e)})
            continue
        out["copies"].extend((folder + "/" + src, dst) for src, dst in their.copies)
        out["notes"].extend(their.notes)
        copied = set(dst for _, dst in out["copies"])
        for module, values in wanted.items():
            if not take_values:
                break
            rel = "modules/%s/Scripts/config.lua" % module
            conv = {"mod": mod, "module": module, "config": rel, "state": "nothing", "set": {}, "same": {}, "remarks": {},
                    "from": dict(their.sources)}
            if module not in schemas:
                schemas[module] = module_schema(files, module) if (has_module(files, module) and rel in files) \
                    else (None, "the package has no module %s" % module)
            items, why_not = schemas[module]
            if items is not None and rel in copied:
                items, why_not = None, "%s comes as a whole file from our own former mod" % rel
            text = drafts.get(rel, files.get(rel, b""))
            for key, value in values.items():
                if value is None:
                    continue                    # the file it came from says why
                shown = "%s.%s = %s" % (module, key, show_value(value))
                if items is None:
                    out["lost"].append({"mod": mod, "what": shown, "why": why_not})
                    continue
                item = items.get(key)
                if item is None:
                    out["lost"].append({"mod": mod, "what": shown, "why": "the module %s has no setting %s" % (module, key)})
                    continue
                fitted, remark = fit_value(item, value)
                if fitted is None:
                    out["lost"].append({"mod": mod, "what": shown, "why": remark})
                    continue
                if setters.get((module, key), mod) != mod:
                    out["lost"].append({"mod": mod, "what": shown, "why": "%s.%s is set from %s already" % (module, key, setters[(module, key)])})
                    continue
                setters[(module, key)] = mod
                written = literal(item, fitted)
                remark = "; ".join(r for r in (their.remarks.get((module, key)), remark) if r)     # the converter's, then the schema's
                if remark:
                    conv["remarks"][key] = remark
                if not _key_line(key).search(text) and fitted == item.get("Default") and isinstance(fitted, bool) == isinstance(item.get("Default"), bool):
                    conv["same"][key] = written         # a setting without a line in the file that has its default
                    continue
                patched = patch_config(text, key, written.encode("utf-8", "surrogateescape"))
                if patched == text:
                    conv["same"][key] = written
                else:
                    conv["set"][key] = written
                    text = patched
            if conv["set"]:
                drafts[rel] = text
                ok, why = pristine(rel)
                conv["state"], conv["why"] = ("write" if ok else "player"), why
            if conv["set"] or conv["same"]:
                out["conversions"].append(conv)
        for handed in their.files:
            # what the converter was given and what of it it asked for: every value is asked for or listed below
            out["read"].append({"mod": mod, "file": handed.name, "values": len(handed._values),
                                "asked": [handed._values[i][0] for i in sorted(handed._taken)]})
            if handed.problem:
                out["lost"].append({"mod": mod, "what": handed.name, "why": handed.problem})
            for what, why in handed.complaints + handed.passed:
                out["lost"].append({"mod": mod, "what": what, "why": why})
            for name, value in handed.rest():
                out["lost"].append({"mod": mod, "what": "%s=%s" % (name, show_value(value, handed.typed)), "why": "not looked at by the converter"})
    for conv in out["conversions"]:
        if conv["state"] == "write":
            out["texts"][conv["config"]] = drafts[conv["config"]]
            conv["sha256"] = sha_of(drafts[conv["config"]])
    return out


# ---- the desktop shortcut of the settings app (Windows Script Host; values travel in the environment)
_PS_READ = ("[Console]::OutputEncoding = [Text.Encoding]::UTF8; "
            "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:G1R_LNK); "
            "[Console]::Out.Write($s.TargetPath + [char]10 + $s.WorkingDirectory + [char]10 + $s.IconLocation + [char]10 + $s.Arguments)")
_PS_WRITE = ("$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:G1R_LNK); "
             "$s.TargetPath = $env:G1R_TARGET; $s.WorkingDirectory = $env:G1R_WORKDIR; "
             "if ($env:G1R_ICON) { $s.IconLocation = $env:G1R_ICON }; $s.Save()")


def _powershell(script, **values):
    env = dict(os.environ)
    env.update(values)
    try:
        return subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except Exception:
        return None


def shortcut_read(lnk):
    """{'target', 'workdir', 'icon', 'args'} of a .lnk file, or None when it cannot be read."""
    r = _powershell(_PS_READ, G1R_LNK=lnk)
    if r is None or r.returncode != 0:
        return None
    parts = r.stdout.decode("utf-8", "replace").lstrip("\ufeff").split("\n")
    if len(parts) < 4:
        return None
    return {"target": parts[0].strip(), "workdir": parts[1].strip(), "icon": parts[2].strip(), "args": parts[3].strip()}


def shortcut_write(lnk, target, workdir, icon=""):
    """Points an existing .lnk file to another program. True when the call went through."""
    r = _powershell(_PS_WRITE, G1R_LNK=lnk, G1R_TARGET=target, G1R_WORKDIR=workdir, G1R_ICON=icon)
    return r is not None and r.returncode == 0


def same_path(a, b):
    def norm(p):
        return os.path.normcase(os.path.normpath(p)).lower()
    return bool(a) and bool(b) and norm(a) == norm(b)


def plan_shortcut(old_exe, new_exe, will_have_exe):
    """(what to write or None, note or None) for the desktop shortcut once G1R_Repopulate is retired."""
    if not os.path.isfile(SHORTCUT):
        return None, None
    info = shortcut_read(SHORTCUT)
    if info is None:
        return None, "the desktop shortcut %s cannot be read: left as it is" % os.path.basename(SHORTCUT)
    if not same_path(info["target"], old_exe):
        return None, "the desktop shortcut %s points to %s: left as it is" % (os.path.basename(SHORTCUT), info["target"] or "nothing")
    if not will_have_exe:
        return None, "the desktop shortcut %s will point to a retired file (the settings app is not taken over)" % os.path.basename(SHORTCUT)
    icon = ""
    m = re.match(r"^(.*),(-?\d+)$", info["icon"])
    if m and same_path(m.group(1), old_exe):            # an icon taken from the old file by its path
        icon = new_exe + "," + m.group(2)
    return {"lnk": SHORTCUT, "target": new_exe, "workdir": os.path.dirname(new_exe), "icon": icon, "before": info}, None


def ps_quote(text):
    return "'" + text.replace("'", "''") + "'"


def _ps_list(name, rels):
    """The lines that give a PowerShell variable a list of paths inside the megamod, one path per line."""
    if not rels:
        return ["    $%s = @()" % name]
    return ["    $%s = @(" % name] + ["        %s%s" % (ps_quote(r.replace("/", "\\")), "," if i + 1 < len(rels) else "") for i, r in enumerate(rels)] + ["    )"]


def rollback_script(stamp, fresh, replaced, retire, shortcut, removed=(), added=(), added_dirs=()):
    """The PowerShell script that undoes this run (Windows PowerShell 5.1 and later).
    replaced / removed: files of the megamod whose copies are in replaced\\ and removed\\ of the backup folder;
    added / added_dirs: files and folders the run adds to an installed megamod (folders deepest first)."""
    L = [
        "# Undoes the G1R_MegaMod %s of %s. Run with the game closed:" % ("install" if fresh else "update", stamp),
        "#   powershell -ExecutionPolicy Bypass -File \"%s\"" % ROLLBACK_NAME,
        "# Only one of the retired mods back, nothing else (G1R_MegaMod stays and leaves that job to the mod again):",
        "#   powershell -ExecutionPolicy Bypass -File \"%s\" -Only <ModName>" % ROLLBACK_NAME,
        "param([string]$ModsRoot = %s, [string]$Shortcut = %s, [string]$Only = '')" % (ps_quote(MODS), ps_quote(SHORTCUT)),
        "$ErrorActionPreference = 'Stop'",
        "$here = Split-Path -Parent $MyInvocation.MyCommand.Path",
        "$target = Join-Path $ModsRoot '%s'" % NAME,
        "if (Get-Process -Name 'G1R-Win64-Shipping','G1R' -ErrorAction SilentlyContinue) { throw 'Close the game first. Nothing changed.' }",
        "if (Get-Process -Name 'ISKLLauncher.App' -ErrorAction SilentlyContinue) { throw 'Close the mod manager first. Nothing changed.' }",
        "if (Get-Process -Name 'G1R_Repopulate_Settings' -ErrorAction SilentlyContinue) { throw 'Close the settings app first. Nothing changed.' }",
        "if (-not (Test-Path -LiteralPath $ModsRoot)) { throw \"Mods folder not found: $ModsRoot. Nothing changed.\" }",
        "$ModsRoot = (Get-Item -LiteralPath $ModsRoot).FullName",
        "# SHA-256 through .NET: Get-FileHash is not found in Windows PowerShell when it is started from PowerShell 7.",
        "function Get-Sha([string]$path) {",
        "    $sha = [System.Security.Cryptography.SHA256]::Create()",
        "    $stream = [System.IO.File]::OpenRead($path)",
        "    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }",
        "}",
        "function Get-Tree([string]$root) {",
        "    $base = (Get-Item -LiteralPath $root).FullName",
        "    $map = @{}",
        "    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {",
        "        $map[$f.FullName.Substring($base.Length).TrimStart('\\', '/')] = Get-Sha $f.FullName",
        "    }",
        "    return $map",
        "}",
        "# The mods this run set out to retire. A copy of each one that was retired is in retired\\ of this folder.",
        "$retired = @(%s)" % ", ".join(ps_quote(n) for n in retire),
        "$modsTxt = Join-Path $ModsRoot 'mods.txt'",
        "# Puts one retired mod back from its copy. $true when it is in Mods afterwards.",
        "function Restore-Mod([string]$name, [bool]$must) {",
        "    $copy = Join-Path (Join-Path $here 'retired') $name",
        "    $dst = Join-Path $ModsRoot $name",
        "    if (-not (Test-Path -LiteralPath $copy)) {",
        "        if ($must) { throw ($name + ': no copy in this backup folder (this run did not retire it). Nothing changed.') }",
        "        Write-Host ($name + ': no copy in this backup folder (it was not retired); skipped.')",
        "        return $false",
        "    }",
        "    if (Test-Path -LiteralPath $dst) { Write-Host ($name + ' is in ' + $ModsRoot + ' already; left as it is.'); return $true }",
        "    Copy-Item -LiteralPath $copy -Destination $dst -Recurse -Force",
        "    $a = Get-Tree $copy",
        "    $b = Get-Tree $dst",
        "    $bad = @($a.Keys | Where-Object { $b[$_] -ne $a[$_] })",
        "    if ($a.Count -ne $b.Count -or $bad.Count -gt 0) { throw ($name + ': the restored folder differs from the copy (' + $b.Count + ' of ' + $a.Count + ' files, ' + $bad.Count + ' different). Stopped here.') }",
        "    Write-Host ($name + ' restored (' + $b.Count + ' files).')",
        "    if (-not (Test-Path -LiteralPath (Join-Path $dst 'enabled.txt'))) {",
        "        $on = $false",
        "        if (Test-Path -LiteralPath $modsTxt) {",
        "            foreach ($line in @(Get-Content -LiteralPath $modsTxt)) {",
        "                if ($line.Contains(';') -or $line.Length -le 4) { continue }",
        "                $c = $line.Replace(' ', '')",
        "                if ($c.Length -lt 2) { continue }",
        "                $i = $c.IndexOf(':', 1)",
        "                if ($i -gt 0 -and [string]::Equals($c.Substring(0, $i), $name, [System.StringComparison]::OrdinalIgnoreCase) -and $c.Substring($c.LastIndexOf(':') + 1).StartsWith('1')) { $on = $true }",
        "            }",
        "        }",
        "        if (-not $on) { Write-Host ('NOTE: ' + $name + ' has no enabled.txt and mods.txt has no line \"' + $name + ' : 1\" any more: enable it in the mod manager.') }",
        "    }",
        "    return $true",
        "}",
        "",
        "if ($Only) {",
        "    # One retired mod back, nothing else. The megamod's module for that job stands down by itself while the mod is enabled.",
        "    $asked = @($retired | Where-Object { [string]::Equals($_, $Only, [System.StringComparison]::OrdinalIgnoreCase) })",
        "    if ($asked.Count -eq 0) { throw ($Only + ' is not one of the mods this run retired (' + ($retired -join ', ') + '). Nothing changed.') }",
        "    $one = [string]$asked[0]",
        "    $done = Restore-Mod $one $true",
        "    # so that a later run of the installer leaves this mod alone",
        "    Set-Content -LiteralPath (Join-Path $here ('%s' + $one + '.txt')) -Value ('put back with -Only on ' + (Get-Date -Format 's')) -Encoding ASCII" % PUT_BACK_PREFIX,
        "    Write-Host ('Only ' + $one + ' was put back; %s and everything else are as they were.')" % NAME,
        "    exit 0",
        "}",
        "",
        "# 1. The retired mods come back from the copies in this folder (a folder that is there is left as it is).",
        "foreach ($name in $retired) { $done = Restore-Mod $name $false }",
        "foreach ($left in @(Get-ChildItem -LiteralPath $ModsRoot -Directory | Where-Object { $_.Name -like '*.retired-*' })) {",
        "    Write-Host ('NOTE: left-over folder of an interrupted run: ' + $left.FullName + ' (not a mod any more; it can be deleted).')",
        "}",
        "",
        "# 2. G1R_MegaMod itself.",
        "if (-not (Test-Path -LiteralPath $target)) {",
        "    Write-Host 'G1R_MegaMod is not installed; nothing to remove.'",
        "} else {",
        "    $version = Join-Path $target 'Scripts\\core\\version.lua'",
        "    if (-not (Test-Path -LiteralPath $version) -or -not (Select-String -LiteralPath $version -SimpleMatch -Quiet -Pattern '\"%s\"')) {" % NAME,
        "        throw \"$target is not the mod %s. It was not touched.\"" % NAME,
        "    }",
    ]
    if fresh:
        L += [
            "    # First install: the whole folder goes away. A copy (with what game sessions and the settings app wrote) is kept here.",
            "    $kept = Join-Path $here 'removed-%s'" % NAME,
            "    if (Test-Path -LiteralPath $kept) { $kept = $kept + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }",
            "    Copy-Item -LiteralPath $target -Destination $kept -Recurse -Force",
            "    $a = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force).Count",
            "    $b = @(Get-ChildItem -LiteralPath $kept -Recurse -File -Force).Count",
            "    if ($a -ne $b) { throw \"The copy in $kept is incomplete ($b of $a files). G1R_MegaMod was not removed.\" }",
            "    Remove-Item -LiteralPath $target -Recurse -Force",
            "    Write-Host \"G1R_MegaMod removed from $ModsRoot (a copy is in $kept).\"",
        ]
    else:
        L += ["    # Update: what the update replaced or removed is put back; what it added is taken out (moved into taken-out\\ here).",
              ] + _ps_list("replaced", replaced) + _ps_list("removed", removed) + _ps_list("added", added) + _ps_list("addedFolders", added_dirs) + [
            "    foreach ($rel in $replaced) { if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $here 'replaced') $rel))) { throw ('The backup folder is incomplete (replaced\\' + $rel + '). G1R_MegaMod was not touched.') } }",
            "    foreach ($rel in $removed) { if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $here 'removed') $rel))) { throw ('The backup folder is incomplete (removed\\' + $rel + '). G1R_MegaMod was not touched.') } }",
            "    $out = 0",
            "    foreach ($rel in $added) {",
            "        $p = Join-Path $target $rel",
            "        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }",
            "        $keep = Join-Path (Join-Path $here 'taken-out') $rel",
            "        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $keep) | Out-Null",
            "        Copy-Item -LiteralPath $p -Destination $keep -Force",
            "        if ((Get-Sha (Get-Item -LiteralPath $keep -Force).FullName) -ne (Get-Sha (Get-Item -LiteralPath $p -Force).FullName)) { throw ('The copy of ' + $rel + ' in taken-out is not identical. Stopped here.') }",
            "        Remove-Item -LiteralPath $p -Force",
            "        $out++",
            "    }",
            "    foreach ($rel in $addedFolders) {",
            "        $d = Join-Path $target $rel",
            "        if ((Test-Path -LiteralPath $d -PathType Container) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) { Remove-Item -LiteralPath $d -Force }",
            "    }",
            "    foreach ($rel in $replaced) {",
            "        Copy-Item -LiteralPath (Join-Path (Join-Path $here 'replaced') $rel) -Destination (Join-Path $target $rel) -Force",
            "    }",
            "    foreach ($rel in $removed) {",
            "        $dst = Join-Path $target $rel",
            "        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null",
            "        Copy-Item -LiteralPath (Join-Path (Join-Path $here 'removed') $rel) -Destination $dst -Force",
            "    }",
            "    Write-Host ('G1R_MegaMod: %d replaced file(s) put back, %d removed file(s) put back, ' + $out + ' added file(s) taken out.')" % (len(replaced), len(removed)),
        ]
    L.append("}")
    if shortcut:
        L += [
            "",
            "# 3. The desktop shortcut of the settings app as it was.",
            "$lnk = Join-Path (Join-Path $here 'shortcut') %s" % ps_quote(os.path.basename(SHORTCUT)),
            "if ((Test-Path -LiteralPath $lnk) -and $Shortcut) {",
            "    Copy-Item -LiteralPath $lnk -Destination $Shortcut -Force",
            "    Write-Host \"Shortcut put back: $Shortcut\"",
            "}",
        ]
    L += [
        "# so that a later run of the installer does not take this run for what is installed",
        "Set-Content -LiteralPath (Join-Path $here '%s') -Value ('rolled back on ' + (Get-Date -Format 's')) -Encoding ASCII" % ROLLED_BACK_NAME,
        "Write-Host 'Rollback finished.'",
    ]
    text = "\r\n".join(L) + "\r\n"
    try:
        return text.encode("ascii")
    except UnicodeEncodeError:
        return text.encode("utf-8-sig")             # Windows PowerShell reads a file without a mark as ANSI


PLAN_ROW = 6        # a list in the plan with more entries than this is printed one entry per line


def lost_groups(lost):
    """The values of one mod that were not carried over, for the plan: neighbours with the same reason together."""
    groups = []
    for item in lost:
        if groups and groups[-1][0] == item["why"]:
            groups[-1][1].append(item["what"])
        else:
            groups.append((item["why"], [item["what"]]))
    parts = []
    for why, whats in groups:
        text = "; ".join(whats) if len(whats) <= 8 else "; ".join(whats[:6]) + "; ... and %d more" % (len(whats) - 6)
        parts.append("%s (%s%s)" % (text, ("all %d: " % len(whats)) if len(whats) > 1 else "", why))
    return parts


def conversion_lines(conv):
    """The plan's lines for the settings one mod gives to one of our modules."""
    def shown(values):                      # with what was done to a value on the way, or how it was worked out
        return ["%s = %s%s" % (k, v, (" (%s)" % conv["remarks"][k]) if k in conv["remarks"] else "") for k, v in values.items()]
    pairs = shown(conv["set"])
    same = ", ".join(shown(conv["same"]))
    where = "Mods\\%s -> %s\\%s" % (conv["mod"], NAME, conv["config"].replace("/", "\\"))
    if conv["state"] == "nothing":
        return ["  settings: %s: nothing to write (our default already: %s)" % (where, same)]
    if len(pairs) <= PLAN_ROW:
        if conv["state"] == "write":
            return ["  settings: %s: %s%s" % (where, ", ".join(pairs), (" (our default already: %s)" % same) if same else "")]
        return ["  settings: %s: NOT written, the file was %s (it would get: %s)" % (where, conv["why"], ", ".join(pairs))]
    head = ("  settings: %s: %d values" % (where, len(pairs)) if conv["state"] == "write" else
            "  settings: %s: NOT written, the file was %s; it would get %d values:" % (where, conv["why"], len(pairs)))
    return [head] + ["      " + pair for pair in pairs] + (["      (our default already: %s)" % same] if same and conv["state"] == "write" else [])


def settings_lines(carry, mods):
    """The plan's lines about the settings of the mods: what each of our modules gets, and per mod (in the order of
    `mods`) what is not carried over, with the reason."""
    lines = [line for conv in carry["conversions"] for line in conversion_lines(conv)]
    for mod in mods:
        groups = lost_groups([l for l in carry["lost"] if l["mod"] == mod])
        if len(groups) > 1:                 # several reasons: one per line
            lines.append("  settings: Mods\\%s: not carried over:" % mod)
            lines.extend("      " + group for group in groups)
        elif groups:
            lines.append("  settings: Mods\\%s: not carried over: %s" % (mod, "; ".join(groups)))
    return lines


def safe_output():
    """A character the console (or the file the output goes to) cannot show must not stop the run."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError, OSError):
            pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.exit("%s Nothing changed." % message)


def _join(names):
    return " and ".join(names) if len(names) < 3 else ", ".join(names)


def main(argv=None):
    ap = _Parser(description="Install or update G1R_MegaMod; its modules take over from the mods that did the same jobs.")
    ap.add_argument("--check", action="store_true", help="dry run: print the plan, change nothing")
    ap.add_argument("--package", metavar="ZIP", help="the package to install (default: %s in the package folder); its manifest lies next to it" % PACKAGE)
    ap.add_argument("--settings-app", metavar="EXE", help="install this program as modules\\repopulate\\%s" % SETTINGS_EXE)
    ap.add_argument("--keep", action="append", default=[], metavar="MOD", help="leave this mod of the take-over table alone (repeatable)")
    ap.add_argument("--retire", action="append", default=[], metavar="MOD",
                    help="retire this mod although the installer would leave it alone: put back with the rollback script's -Only, or its module is switched off (repeatable)")
    ap.add_argument("--keep-separate", action="store_true", help="leave every mod of the table in place (the megamod then leaves those jobs to them while they are enabled)")
    ap.add_argument("--sync-settings", action="store_true", help="only carry settings and progress of the mods over again")
    args = ap.parse_args(argv)
    safe_output()
    if not (GAME and SAVES and WS and SHORTCUT):
        refuse('deploy_settings.json next to this script is missing or incomplete (game, saves, project, shortcut): copy deploy_settings.example.json and fill it in.')
    target = os.path.join(MODS, NAME)
    table = {entry[0].lower(): entry[0] for entry in TAKEOVERS}
    for option, given in (("--keep", args.keep), ("--retire", args.retire)):
        for name in given:
            if name.lower() not in table:
                refuse("%s %s: not one of the mods this installer replaces (%s)." % (option, name, ", ".join(e[0] for e in TAKEOVERS)))
    keep_names = set(table[n.lower()] for n in args.keep)
    retire_names = set(table[n.lower()] for n in args.retire)
    if keep_names & retire_names:
        refuse("--keep and --retire name the same mod (%s)." % ", ".join(sorted(keep_names & retire_names)))

    # ---- before anything is touched
    names = running_images()
    if names is None:
        refuse("The list of running programs cannot be read, so it is not known whether the game runs.")
    if any(n in GAME_IMAGES or "gothic" in n for n in names):
        refuse("The game is running. Close it first.")
    for image, what in OTHER_IMAGES:
        if image in names:
            refuse("%s is running. Close it first." % what)
    dll = os.path.join(UE4SS, "UE4SS.dll")
    if not os.path.isfile(dll):
        refuse("UE4SS.dll not found in %s." % UE4SS)
    dll_hash = sha(dll)
    if dll_hash != EXPECTED_UE4SS:
        refuse("UE4SS.dll is not the expected build (sha256 %s...)." % dll_hash[:16])
    if not os.path.isdir(MODS):
        refuse("Mods folder not found: %s." % MODS)
    zip_path = os.path.abspath(args.package) if args.package else os.path.join(PKGDIR, PACKAGE)
    package = os.path.basename(zip_path)
    manifest_path = os.path.join(os.path.dirname(zip_path), manifest_name(package))
    for p in (zip_path, manifest_path):
        if not os.path.isfile(p):
            refuse("Package file missing: %s." % p)
    try:
        manifest = read_manifest(manifest_path)
        files = read_package(zip_path, manifest)
    except (ValueError, OSError, zipfile.BadZipFile) as e:
        refuse("The package is not usable: %s." % e)
    for needed in ("Scripts/main.lua", "Scripts/core/version.lua", "enabled.txt"):
        if needed not in files:
            refuse("The package has no %s." % needed)
    if ('"%s"' % NAME) not in files["Scripts/core/version.lua"].decode("latin-1"):
        refuse("The package is not %s." % NAME)
    version = version_in(files["Scripts/core/version.lua"])
    if not version:
        refuse("The package does not say which version it is (Scripts/core/version.lua).")
    try:
        listed = package_module_list(files)
    except LuaError as e:
        refuse("The module list of the package (Scripts/core/modules.lua) cannot be read: %s." % e)
    if listed is not None:
        # the loader must know the mod it stands down for; else two things would act on the game when a mod stays
        for mod, _, module, _ in TAKEOVERS:
            if has_module(files, module) and mod.lower() not in [s.lower() for s in listed.get(module, {}).get("separate", [])]:
                refuse("The package's module list (Scripts/core/modules.lua) does not name %s as a separate mod of the module %s: "
                       "this installer and the package do not belong together." % (mod, module))
    app = None
    if args.settings_app:
        app_path = os.path.abspath(args.settings_app)
        if not os.path.isfile(app_path):
            refuse("The settings app given with --settings-app is not a file: %s." % app_path)
        with open(app_path, "rb") as f:
            if f.read(2) != b"MZ":
                refuse("The settings app given with --settings-app is not a Windows program: %s." % app_path)
        app = {"source": app_path, "sha256": sha(app_path), "bytes": os.path.getsize(app_path)}

    fresh = not os.path.exists(target)
    installed_version = None
    if not fresh:
        try:
            with open(os.path.join(target, "Scripts", "core", "version.lua"), "rb") as f:
                version_file = f.read()
        except OSError:
            version_file = b""
        if ('"%s"' % NAME) not in version_file.decode("latin-1"):
            refuse("%s exists and is not this mod." % target)
        installed_version = version_in(version_file)
    if args.sync_settings and fresh:
        refuse("%s is not installed yet; --sync-settings has nothing to copy into." % NAME)
    if args.sync_settings and args.keep_separate:
        refuse("--sync-settings and --keep-separate do not go together (--sync-settings never retires anything).")
    if args.sync_settings and app:
        refuse("--sync-settings and --settings-app do not go together (--sync-settings only carries settings over).")

    base_mods = tree_hashes(MODS)
    base_saves = tree_hashes(SAVES) if os.path.isdir(SAVES) else None
    prefix = NAME + "/"
    installed = {k[len(prefix):]: v for k, v in base_mods.items() if k.startswith(prefix)}
    try:
        with open(os.path.join(MODS, "mods.txt"), "rb") as f:
            mods_txt = f.read().decode("latin-1")
    except OSError:
        mods_txt = ""

    # ---- the mods of the take-over table: what is there, what happens to each
    put_back = put_back_mods()
    megamod_on = fresh or any(k.lower() == "enabled.txt" for k in installed) or mods_txt_enables(mods_txt, NAME)
    try:
        with open(os.path.join(target, "Scripts", "config.lua"), "rb") as f:        # the player's own: it stays as it is
            megamod_config = f.read()
    except OSError:
        megamod_config = files.get("Scripts/config.lua", b"")
    off = modules_switched_off(listed, megamod_config)
    entries = []
    for mod, kind, module, convert in TAKEOVERS:
        folder, inside, found = find_mod(base_mods, mod)
        info = {"mod": mod, "kind": kind, "module": module, "convert": convert, "folder": folder, "inside": inside, "found": found,
                "files": len(inside), "enabled": False, "in_package": has_module(files, module), "action": "absent", "why": "",
                "hands_off": False}
        for name in set((mod, folder or mod)):
            if os.path.exists(os.path.join(MODS, name + ".retired-tmp")):
                refuse("%s exists (left over from an interrupted run). Look at it and remove it first." % os.path.join(MODS, name + ".retired-tmp"))
        if found:
            info["enabled"] = any(k.lower() == "enabled.txt" for k in inside) or mods_txt_enables(mods_txt, folder)
            if not info["in_package"]:
                info["action"], info["why"] = "left", "the package has no module %s" % module
            elif args.sync_settings:
                info["action"], info["why"] = "left", "--sync-settings retires nothing"
            elif args.keep_separate:
                info["action"], info["why"] = "left", "--keep-separate"
            elif mod in keep_names:
                info["action"], info["why"], info["hands_off"] = "left", "--keep %s" % mod, True
            elif mod.lower() in put_back and mod not in retire_names:
                info["action"], info["hands_off"] = "left", True
                info["why"] = "The player put it back with the rollback script of %s (-Only); --retire %s retires it again" % (put_back[mod.lower()], mod)
            elif not megamod_on and mod not in retire_names:
                info["action"] = "left"         # never leave a job to nobody
                info["why"] = "%s itself is switched off (no enabled.txt, no line in mods.txt): nothing would do the mod's job; --retire %s retires it all the same" % (NAME, mod)
            elif module in off and mod not in retire_names:
                info["action"] = "left"
                info["why"] = ("the module %s is switched off in %s\\Scripts\\config.lua (%s = false): nothing would do the mod's job; --retire %s retires it all the same"
                               % (module, NAME, off[module], mod))
            else:
                info["action"] = "retire"
        elif folder is not None:
            info["why"] = "the folder holds no mod (no Scripts\\main.lua, no dlls\\main.dll)"
        entries.append(info)
    present = [e for e in entries if e["found"]]
    retire = [e["folder"] for e in entries if e["action"] == "retire"]
    left_by_choice = [e for e in entries if e["action"] == "left" and e["in_package"] and not args.sync_settings]

    # ---- the files of the mod itself
    runs = earlier_runs()
    old_files, old_from = None, None
    if fresh or args.sync_settings:
        plan = plan_install(files, installed) if fresh else {"add": [], "replace": [], "same": [], "keep": [], "remove": [], "other": []}
    else:
        old_files, old_from = installed_package(installed, installed_version, runs, manifest_path)
        plan = plan_install(files, installed, old_files)

    def pristine(rel):
        """Whether a settings file of the megamod may be written: it is not there, or it is still as a package or
        this installer left it. (may it?, what it is)"""
        have = installed.get(rel)
        if have is None:
            return True, "not there yet"
        if have == manifest.get(rel):
            return True, "the package's default file"
        if old_files and old_files.get(rel) == have:
            return True, "the default file of the installed version"
        for _, report, rolled in runs:
            wrote = report.get("written") if isinstance(report.get("written"), dict) else {}
            if not rolled and rel in wrote:
                return (True, "as this installer wrote it") if wrote[rel] == have else (False, "changed by the player")
        return False, "changed by the player"

    # ---- what comes along from the mods
    notes = []
    known = set(entry[0].lower() for entry in TAKEOVERS)
    for module, entry in (listed or {}).items():
        for name in entry["separate"]:
            if name.lower() not in known and find_mod(base_mods, name)[2]:
                notes.append("%s is installed and the package's module %s stands down for it, but it is not in this installer's table: left as it is" % (name, module))
    todo = []
    for e in present:
        own = e["mod"] in OWN_MODS
        if not e["in_package"] or e["hands_off"]:
            continue
        if fresh or args.sync_settings:
            wanted = own or e["enabled"]
        else:
            wanted = e["action"] == "retire" and e["enabled"]           # their files are the ones in use
        if wanted:
            todo.append(e)
        elif not e["enabled"] and (e["action"] == "retire" or fresh or args.sync_settings):
            notes.append("%s is disabled: its settings are not %s" % (e["folder"], "copied (the module's own are the ones in use)" if own
                         else "carried over (its job was switched off; the module %s starts with its defaults)" % e["module"]))
    same_version = fresh or not args.sync_settings or sha_of(files["Scripts/core/version.lua"]) == installed.get("Scripts/core/version.lua")
    if args.sync_settings and not same_version:
        notes.append("the package is version %s, installed is %s: settings of other authors' mods are not converted (run an update first)" % (version, installed_version))
    carry = plan_carry(todo, files, base_mods, pristine, take_values=same_version)
    notes.extend(carry["notes"])
    copies = [(src, dst) for src, dst in carry["copies"] if not (app and dst == SETTINGS_EXE_REL)]
    copies = [(src, dst) for src, dst in copies if installed.get(dst) != base_mods[src]]       # what is the same already stays
    texts = {rel: text for rel, text in carry["texts"].items() if installed.get(rel) != sha_of(text)}
    if app:
        app["state"] = "same" if installed.get(SETTINGS_EXE_REL) == app["sha256"] else ("replace" if SETTINGS_EXE_REL in installed else "add")

    shortcut = None
    repop = next((e for e in entries if e["mod"] == "G1R_Repopulate"), None)
    if repop and repop["action"] == "retire":
        will_have_exe = any(dst == SETTINGS_EXE_REL for _, dst in carry["copies"]) or SETTINGS_EXE_REL in installed or bool(app)
        shortcut, note = plan_shortcut(os.path.join(MODS, repop["folder"], SETTINGS_EXE),
                                       os.path.join(target, SETTINGS_EXE_REL.replace("/", SEP)), will_have_exe)
        if note:
            notes.append(note)

    # ---- the plan
    mode = "sync-settings" if args.sync_settings else ("install" if fresh else "update")
    print("%s: %s" % (NAME, "settings and progress are copied again" if args.sync_settings else ("first install" if fresh else "update of the installed mod")))
    print("  target: %s" % target)
    if not args.sync_settings:
        print("  package: %s, version %s, %d files (sha256 %s...)" % (package, version, len(files), sha(zip_path)[:16]))
        if not fresh:
            print("  installed: version %s (%s)" % (installed_version or "unknown", ("its file list: " + old_from) if old_files else
                                                    "its file list is not known - %s: files that only the old version had stay where they are" % old_from))
        carried = set(dst for _, dst in copies) | set(texts)                # settings files that get the mods' settings: said below
        kept = [rel for rel in plan["keep"] if rel not in carried]
        print("  files: %d added, %d replaced, %d already the same, %d kept as installed%s%s" % (
            len(plan["add"]), len(plan["replace"]), len(plan["same"]), len(kept),
            (", %d of the old version removed" % len(plan["remove"])) if plan["remove"] else "",
            (", %d other files in the folder left alone" % len(plan["other"])) if plan["other"] else ""))
        for rel in kept:
            differs = rel in installed and installed[rel] != manifest[rel] and rel not in AS_INSTALLED
            print("    kept: %s%s" % (rel, " (The player's own; differs from the package's)" if differs else ""))
        for rel in plan["remove"][:12]:
            print("    removed: %s" % rel)
        if len(plan["remove"]) > 12:
            print("    removed: ... and %d more (all in the report)" % (len(plan["remove"]) - 12))
    for src, dst in copies:
        print("  copy: Mods\\%s -> %s\\%s" % (src.replace("/", "\\"), NAME, dst.replace("/", "\\")))
    for line in settings_lines(carry, [e["mod"] for e in entries]):
        print(line)
    if app:
        print("  settings app: %s -> %s\\%s (%d bytes, sha256 %s...; %s)" % (app["source"], NAME, SETTINGS_EXE_REL.replace("/", "\\"), app["bytes"], app["sha256"][:16],
              {"same": "the installed one is the same already", "replace": "the installed one goes to the backup folder", "add": "none is installed yet"}[app["state"]]))
    for e in entries:
        if e["action"] == "retire":
            print("  retire: Mods\\%s (%d files, %s) -> backup folder, then removed from Mods; the module %s takes over"
                  % (e["folder"], e["files"], "enabled" if e["enabled"] else "disabled", e["module"]))
    for e in entries:
        if e["action"] == "left" and not args.sync_settings:
            print("  left alone: Mods\\%s (%s)" % (e["folder"], e["why"]))
    absent = [e["mod"] for e in entries if e["action"] == "absent"]
    if absent:
        print("  not installed, nothing to do: %s" % ", ".join(absent))
    if shortcut:
        print("  shortcut: %s -> %s" % (os.path.basename(SHORTCUT), shortcut["target"]))
    for note in notes:
        print("  note: %s" % note)
    if left_by_choice:
        print("  note: %s installed as separate mod(s) and left in place: while enabled, %s leaves that job to them"
              % (_join([e["folder"] for e in left_by_choice]), NAME))
    print("  saves: %s" % ("%d files, only read" % len(base_saves) if base_saves is not None else "folder not found (nothing to compare)"))
    if args.check:
        print("CHECK ONLY: nothing was created or changed.")
        return 0
    app_write = bool(app) and app["state"] != "same"
    if not (plan["add"] or plan["replace"] or plan["remove"] or copies or texts or app_write or retire or shortcut):
        print("NOTHING TO DO: %s%s is in place as the package has it, and no mod of the table is waiting to be retired. Nothing was created or changed."
              % (NAME, "" if args.sync_settings else " " + version))
        return 0

    # ---- backup folder, rollback script
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(WS, "%s-backup-%s" % (TAG, stamp))
    count = 1
    while os.path.exists(backup):                   # two runs within one second
        count += 1
        backup = os.path.join(WS, "%s-backup-%s-%d" % (TAG, stamp, count))
    os.makedirs(backup)
    with open(os.path.join(backup, "baseline-hashes.json"), "w", encoding="utf-8") as f:
        json.dump({"stamp": stamp, "ue4ss_dll": dll_hash, "mods": base_mods, "saves": base_saves,
                   "shortcut": sha(SHORTCUT) if os.path.isfile(SHORTCUT) else None}, f, indent=1, sort_keys=True)
    writes = [dst for _, dst in copies] + sorted(texts) + ([SETTINGS_EXE_REL] if app_write else [])
    overwritten = list(plan["replace"])
    for dst in writes:
        if dst in installed and dst not in overwritten:
            overwritten.append(dst)
    added = [] if fresh else sorted(set(plan["add"]) | set(dst for dst in writes if dst not in installed))
    added_dirs = []
    for rel in added:                                   # folders the run makes inside the installed megamod
        parts = rel.split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            d = "/".join(parts[:depth])
            if d not in added_dirs and not os.path.isdir(os.path.join(target, d.replace("/", SEP))):
                added_dirs.append(d)
    added_dirs.sort(key=lambda d: (-d.count("/"), d))
    for rel in overwritten:
        copy_file(os.path.join(target, rel.replace("/", SEP)), os.path.join(backup, "replaced", rel.replace("/", SEP)))
    for rel in plan["remove"]:
        copy_file(os.path.join(target, rel.replace("/", SEP)), os.path.join(backup, "removed", rel.replace("/", SEP)))
    if shortcut:
        copy_file(SHORTCUT, os.path.join(backup, "shortcut", os.path.basename(SHORTCUT)))
    write_file(os.path.join(backup, ROLLBACK_NAME), rollback_script(stamp, fresh, overwritten, retire, shortcut, plan["remove"], added, added_dirs))

    # ---- install
    report = {"stamp": stamp, "mode": mode, "target": target, "package": package, "package_path": zip_path, "version": version, "package_sha256": sha(zip_path),
              "package_files": None if args.sync_settings else manifest, "installed_version": installed_version, "old_files_from": old_from,
              "plan": plan, "copies": copies, "notes": notes, "retire": retire, "retired": {}, "shortcut": shortcut,
              "replaced": overwritten, "removed": plan["remove"], "added": added, "added_dirs": added_dirs,
              "conversions": carry["conversions"], "not_carried": carry["lost"], "settings_read": carry["read"],
              "written": {rel: sha_of(text) for rel, text in carry["texts"].items()},
              "settings_app": app, "ok": False, "problems": []}
    report["takeovers"] = [{k: e[k] for k in ("mod", "kind", "module", "folder", "found", "files", "enabled", "in_package", "action", "why")} for e in entries]
    problems = report["problems"]
    try:
        for rel in plan["add"] + plan["replace"]:
            if rel not in texts:
                write_file(os.path.join(target, rel.replace("/", SEP)), files[rel])
        for rel in plan["remove"]:
            path = os.path.join(target, rel.replace("/", SEP))
            _retry(_remove_file, path)
            folder = os.path.dirname(path)
            while len(folder) > len(target) and not os.listdir(folder):     # folders the old version leaves empty
                os.rmdir(folder)
                folder = os.path.dirname(folder)
        for src, dst in copies:
            copy_file(os.path.join(MODS, src.replace("/", SEP)), os.path.join(target, dst.replace("/", SEP)))
        for rel in sorted(texts):
            write_file(os.path.join(target, rel.replace("/", SEP)), texts[rel])
        if app_write:
            copy_file(app["source"], os.path.join(target, SETTINGS_EXE_REL.replace("/", SEP)))
    except OSError as e:
        problems.append("writing failed: %s" % e)

    # ---- verify the mod itself
    after_mods = tree_hashes(MODS)
    after = {k[len(prefix):]: v for k, v in after_mods.items() if k.startswith(prefix)}
    copied = {dst: src for src, dst in copies}
    expected = {rel: sha_of(text) for rel, text in texts.items()}
    expected.update((dst, base_mods[src]) for dst, src in copied.items())
    if app_write:
        expected[SETTINGS_EXE_REL] = app["sha256"]
    for rel in sorted(files):
        if rel in expected:
            continue                            # checked below
        if args.sync_settings:
            want = installed.get(rel)           # nothing of the package is touched in this mode
        elif rel in plan["keep"]:
            want = installed.get(rel)           # the player's own: as before, present or not
        else:
            want = manifest[rel]
        if after.get(rel) != want:
            problems.append("%s is not what it should be after the %s" % (rel, "copy" if args.sync_settings else "install"))
    for rel, want in sorted(expected.items()):
        if after.get(rel) != want:
            problems.append("%s is not %s" % (rel, ("a copy of Mods\\%s" % copied[rel]) if rel in copied else
                                               ("the settings app given" if rel == SETTINGS_EXE_REL and rel not in texts else "the converted settings file")))
    for rel in plan["remove"]:
        if rel in after:
            problems.append("%s of the old version is still there" % rel)
    for rel in sorted(installed):
        if (rel in plan["other"] or is_session_file(rel)) and rel not in expected and after.get(rel) != installed[rel]:
            problems.append("%s was changed although it is left alone" % rel)
    if app:
        app["installed"] = after.get(SETTINGS_EXE_REL) == app["sha256"]
        app["previous_sha256"] = installed.get(SETTINGS_EXE_REL)

    # ---- retire the mods of the table (only when the megamod is in place without a problem)
    status = {m: "kept" for m in retire}        # kept (in place, untouched) / retired / partial (removing failed part-way)
    stayed = {}                                 # folder -> why it was not retired
    report["status"] = status
    if retire and problems:
        problems.append("the separate mods were NOT retired because of the problem(s) above")
        stayed = {m: "the megamod was not in place without a problem" for m in retire}
    elif retire:
        for m in retire:
            src = os.path.join(MODS, m)
            dst = os.path.join(backup, "retired", m)
            want = {k[len(m) + 1:]: v for k, v in base_mods.items() if k.startswith(m + "/")}
            try:
                copy_tree(src, dst)
                if tree_hashes(dst) != want or tree_hashes(src) != want:
                    stayed[m] = "the copy in the backup folder is not identical to the folder"
                    problems.append("%s: the copy in the backup folder is not identical to the folder; it was left in place" % m)
                    continue
            except OSError as e:
                stayed[m] = "copying to the backup folder failed"
                problems.append("%s: copying to the backup folder failed (%s); it was left in place" % (m, e))
                continue
            parked = src + ".retired-tmp"
            try:
                _retry(os.rename, src, parked)       # fails as a whole while a file in it is open
            except OSError as e:
                stayed[m] = "it is in use"
                problems.append("%s is in use (%s); it was left in place and keeps its job" % (m, e))
                continue
            try:
                remove_tree(parked)
            except OSError as e:
                status[m] = "partial"
                problems.append("%s: removing failed part-way (%s); the rest is in %s (not a mod any more)" % (m, e, parked))
                continue
            status[m] = "retired"
            report["retired"][m] = {"files": len(want), "copy": dst}
    for item in report["takeovers"]:
        if item["folder"] in status:
            item["state"] = status[item["folder"]]
            item["why"] = stayed.get(item["folder"], item["why"])
        else:
            item["state"] = "absent" if item["action"] == "absent" else "left"

    # ---- the shortcut (only when the file it pointed to is gone and the new one is there)
    if shortcut:
        if status.get(repop["folder"], "kept") == "kept":
            report["shortcut"] = None
        elif not os.path.isfile(shortcut["target"]):
            problems.append("the settings app is not in %s; the desktop shortcut was left as it is" % shortcut["target"])
        else:
            done = shortcut_write(shortcut["lnk"], shortcut["target"], shortcut["workdir"], shortcut["icon"])
            now = shortcut_read(shortcut["lnk"]) if done else None
            if not now or not same_path(now["target"], shortcut["target"]) or not same_path(now["workdir"], shortcut["workdir"]):
                problems.append("the desktop shortcut %s could not be pointed to %s" % (os.path.basename(SHORTCUT), shortcut["target"]))
            else:
                report["shortcut"]["after"] = now

    # ---- audit: nothing else changed
    after_mods = tree_hashes(MODS)
    own = set()
    for m in retire:
        own.update((m, m + ".retired-tmp"))
    for rel in sorted(set(base_mods) | set(after_mods)):
        if rel.startswith(prefix) or rel.split("/", 1)[0] in own:
            continue
        if base_mods.get(rel) != after_mods.get(rel):
            problems.append("CHANGED OUTSIDE THE MOD: Mods\\%s" % rel.replace("/", "\\"))
    for m in retire:
        base_m = {k: v for k, v in base_mods.items() if k.startswith(m + "/")}
        now_m = {k: v for k, v in after_mods.items() if k.startswith(m + "/")}
        if status[m] == "kept" and now_m != base_m:
            problems.append("%s was left in place but is not as it was (%d of %d files unchanged)"
                            % (m, sum(1 for k in base_m if now_m.get(k) == base_m[k]), len(base_m)))
        if status[m] != "kept" and (now_m or os.path.exists(os.path.join(MODS, m))):
            problems.append("%s is still in Mods" % m)
        if os.path.exists(os.path.join(MODS, m + ".retired-tmp")):
            problems.append("left-over folder in Mods: %s.retired-tmp" % m)
    if sha(dll) != dll_hash:
        problems.append("UE4SS.dll changed")
    if base_saves is not None and tree_hashes(SAVES) != base_saves:
        problems.append("the save folder changed while the install ran")
    report["ok"] = not problems
    with open(os.path.join(backup, "install-report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    def results():
        for m in retire:
            if status[m] == "retired":
                print("  retired: Mods\\%s (%d files) -> %s" % (m, report["retired"][m]["files"], report["retired"][m]["copy"]))
        for conv in carry["conversions"]:
            if conv["state"] == "write":
                print("  settings: %s\\%s holds %s (from Mods\\%s)" % (NAME, conv["config"].replace("/", "\\"),
                      ", ".join("%s = %s" % kv for kv in conv["set"].items()) if len(conv["set"]) <= PLAN_ROW else
                      "%d converted values, as listed in the plan above" % len(conv["set"]), conv["mod"]))
        if carry["lost"]:
            print("  settings: %d value(s) of the retired mods were not carried over (listed in the plan above and in the report)" % len(carry["lost"]))
        if plan["remove"]:
            print("  removed: %d file(s) that only the old version had (copies in the backup folder)" % len(plan["remove"]))
        if app:
            print("  settings app: %s (sha256 %s...)" % ("installed" if app_write else "was the same already", app["sha256"][:16]))
        if report["shortcut"]:
            print("  shortcut: %s now starts %s" % (os.path.basename(SHORTCUT), report["shortcut"]["target"]))

    if report["ok"]:
        print("DONE: %s is in place and verified (%d package files); nothing else changed." % (NAME if args.sync_settings else NAME + " " + version, len(files)))
        results()
        print("Backup and rollback script: %s" % backup)
        if left_by_choice:
            print("The separate mods are still in place: %s leaves that job to them while they are enabled." % NAME)
        return 0
    print("PROBLEMS:")
    for p in problems:
        print("  * " + p)
    results()
    print("The rollback script is in %s" % backup)
    return 1


if __name__ == "__main__":
    sys.exit(main())
