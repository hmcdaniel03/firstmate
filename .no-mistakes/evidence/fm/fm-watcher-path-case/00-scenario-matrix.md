# Live validation - fm/fm-watcher-path-case (watcher health compares filesystem identity)

Every row below was driven against the real executables (`bin/fm-guard.sh`,
`bin/fm-turnend-guard.sh`, `bin/fm-watch-arm.sh --restart`) with real
`bin/fm-watch.sh` watcher processes in throwaway homes under `$TMPDIR`.
"BEFORE" rows re-ran the same operator command against the base-commit
`bin/fm-wake-lib.sh` (269f8fe) to show the false negative that was fixed.

| # | Scenario | Result | Transcript |
|---|----------|--------|------------|
| 1 | Watcher armed with a lowercase spelling of the home; pull guard invoked with the on-disk mixed-case spelling | BEFORE: `WATCHER DOWN` / AFTER: silent | 01 |
| 2 | Watcher armed through a symlinked install dir; guard run from the canonical checkout | BEFORE: `WATCHER DOWN` / AFTER: silent | 02 |
| 3 | That same install spelling repointed at a *different* watcher script | `WATCHER DOWN` | 02 |
| 4 | Genuinely different home directory (both exist) | `WATCHER DOWN` | 03 |
| 5 | Recorded home / recorded watcher script no longer exist | `WATCHER DOWN` | 03 |
| 6 | Relative home spelling recorded by the watcher, guard run from the cwd where it names the real home | BEFORE: `WATCHER DOWN` / AFTER: silent | 04 |
| 7 | Same relative spelling, guard run from a cwd where it names a different real directory | `WATCHER DOWN` | 04 |
| 8 | Stale beacon, dead pid, and pid reused by an unrelated live process - all under an equivalent (mixed-case) home spelling | `WATCHER DOWN` in all three; the unrelated process is never signalled | 05 |
| 9 | `fm-watch-arm.sh --restart` against a reused-pid lock recorded under a symlinked home spelling | lock cleared, `check: rearm-resurface`, unrelated pid untouched | 06 |
| 10 | Claude Stop turn-end hook on a home reached by a mixed-case spelling of both the home and `bin/fm-watch.sh` | BEFORE: `TURN WOULD END BLIND` exit 2 / AFTER: exit 0 | 07 |
| 11 | Turn-end hook, same live watcher, `bin/fm-watch.sh` missing from the install (partial install) | exit 2, `TURN WOULD END BLIND` | 08 |
| 12 | Turn-end hook, same live watcher, lock records a foreign home | exit 2; restoring the equivalent spelling returns exit 0 | 08 |
| 13 | Replacement at a byte-identical recorded spelling (delete + recreate, new inode) | accepted on the type gate - the documented contract; deleting it outright is `WATCHER DOWN` | 09 |

Not driveable on this host: rejection of case-distinct *real* objects requires a
case-sensitive filesystem. This machine's `/` and `$TMPDIR` are case-insensitive
APFS, so `tests/fm-watcher-lock.test.sh` reports the intended explicit skip:
`ok - case-distinct real-object rejection skipped on a case-insensitive filesystem`.
