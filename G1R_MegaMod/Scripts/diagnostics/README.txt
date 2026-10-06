Diagnostics of the mod - written while the game runs
====================================================

The mod keeps a small flight recorder here, so that a problem can be looked at
afterwards. Nothing in this folder is needed for playing; everything except
this README.txt can be deleted at any time (best while the game is closed).
If you report a problem, the files of the session in which it happened are
what helps most. They hold what the modules wrote to UE4SS.log, errors, and
numbers about how the modules use the game. Paths of the mod's own files are
written as <mod>/..., so the files do not show where the game is installed.

Files
-----
session-YYYYMMDD-HHMMSS.log
    One per game start, named after the start time. Lines look like
        HH:MM:SS [module] text
    [repopulate] and [markers] are the modules, [loader] and [diag] the mod's
    own parts. It holds every line a module printed, breadcrumbs, errors with
    their traceback (the lines below an ERROR line, indented), and notes when
    a module learns a fact or a fact changes ("note key = value (detail)").
    Normal lines are written every 20 seconds. A breadcrumb - a line whose
    text starts with ">" - is written before something that could take the
    game down, for example the first search for an object by its path
    ("> lookup /Script/..."), and the line after it is written at once too.
    So when a session log ENDS with a breadcrumb, the game most likely ended
    inside the step that the breadcrumb names.
    The newest 5 logs are kept (SessionFiles in Scripts/config.lua).

session-YYYYMMDD-HHMMSS.ops
    The last 256 "operations" of that game start: every step in which a
    module calls into the game for more than a moment (a search among all
    objects of the game, a round of looking at containers, a refresh of the
    map pins). One line of fixed length each:
        00000042 > 12:19:44 repopulate containers: look at new objects (25 waiting)
                 ^ ">" the step was begun, "=" it was finished
    The line is written, and has left the game's process, before the step
    runs - so it is still there when the game dies inside the step, which a
    session log line written every 20 seconds is not. The newest line is the
    one with the highest number (the file is a ring: after 256 lines the
    oldest are overwritten in place).
    If the game crashed: look at the files of the session in which it
    happened - after a restart that is NOT the newest session, but the one
    before. When the newest line of its .ops file says ">", the game went
    down inside that step. An older ">" is a step that ended with an error
    (the error is in the session log).
    Kept and deleted together with its session log.

session-YYYYMMDD-HHMMSS.report.txt
    The last report of that game start (see report-latest.txt): the same
    text, kept per session, so that the report of the session before the
    last one is still there after the game was started again.
    Kept and deleted together with its session log.

report-latest.txt
    Rewritten when the game starts, then every 5 minutes, and by the console
    command "g1r diag". In this order: header (mod, version, time, minutes
    since load), the modules (loaded or not, with the error), the status
    lines of the modules, notes as "key = value (detail) [first seen
    HH:MM:SS]", counters per module, errors (how often, first traceback), and
    the last 120 recorder lines.
    Counters: "lookups" are searches for an object by path (calls, first-time
    searches, not found, repeated after not found - each of those walks every
    object of the game -, total time, slowest path); "FindAllOf" /
    "FindFirstOf" calls and time; "callbacks" per kind (calls, errors, calls
    slower than SlowCallMs, longest call); "registered" per kind (ok, failed).

report-YYYYMMDD-HHMMSS.txt
    The same report, kept under its own name; written only by "g1r diag".

dump-YYYYMMDD-HHMMSS.lua
    Written only by the console command "g1r dump": what the modules know at
    that moment (tracked containers, map pins, ...), as a Lua table. "_meta"
    says which module was dumped; values that could not be written are
    replaced by a text "<refused: ...>" and listed in "_meta.refused".

sessions.txt
    The names of the session logs, oldest first. The mod uses it to delete old
    session logs (it cannot list a folder by itself). Only files named there
    and named like a session log are ever deleted, each together with the
    .ops and .report.txt file of the same name.

Console commands (UE4SS console)
--------------------------------
g1r          status of the modules and of the diagnostics
g1r diag     write a report now and show where it is
g1r dump     write a dump
g1r help     the list of commands

Settings
--------
Scripts/config.lua, section Config.Diagnostics. Level = "off" writes nothing
at all; "verbose" writes every line at once and records more (for hunting a
crash). If this folder cannot be written, the mod notes that once in UE4SS.log
and goes on without the files.
