# twikit-hotfix

A one-command bash script to apply a defensive hotfix across every Twikit install on a server. It patches `twikit/user.py` and `twikit/guest/user.py` to use safe `.get()` access against the upstream API, and replaces `twikit/x_client_transaction/transaction.py` with a known-good copy.

The fix exists because Twikit pulls fields like `followers_count`, `verified`, etc. via direct dict access against `legacy`, which crashes the moment X/Twitter drops a field from the response. Same story with the transaction signing module — easier to swap the file than monkeypatch.

## Quickstart

```bash
# Interactive menu (default when run from a terminal)
bash twikit.sh

# Preview without changing anything
bash twikit.sh --dry-run

# Patch a specific project, skip the menu
bash twikit.sh --non-interactive --roots /home/ubuntu/discord/follows-tracker

# Patch multiple roots
bash twikit.sh --roots /home/ubuntu /root /opt/apps

# Use a specific transaction.py source
bash twikit.sh --source /path/to/good/transaction.py
```

## Flags

| Flag | What it does |
| --- | --- |
| `--source FILE` | Path to a known-good `transaction.py` to copy onto every target. If omitted, the script auto-discovers one from the roots. |
| `--roots DIR [DIR ...]` | Root directories to scan for Twikit installs. Default: `/home/ubuntu /root`. |
| `--non-interactive` | Skip the menu. Use the supplied `--roots` and `--source` directly. Good for cron and CI. |
| `--dry-run` | Show what would be patched / replaced. No files are modified. |
| `-h, --help` | Print usage. |

## Interactive menu

When run from a terminal without `--non-interactive`, the script shows a 4-option menu:

1. **Scan default roots** — Walk `/home/ubuntu` and `/root` for any `venv/.../twikit/`.
2. **Pick 1 project** — List every detected Twikit project, pick one by number.
3. **Pick multiple projects** — Same list, accept comma-separated numbers (e.g. `1,3,5`).
4. **Manual roots** — Type space-separated paths yourself. Fastest if you already know exactly where things live.

After the project pick, you're asked for a `transaction.py` source path (Enter = auto-discover).

## How it works

1. **Banner & arg parse.** Prints the ASCII banner, parses `--source`, `--roots`, `--non-interactive`, `--dry-run`.
2. **Interactive mode.** If TTY-attached and the user didn't pass `--roots`, show the menu. Same for `--source`.
3. **Validate / auto-discover source.** If `--source` was passed but doesn't exist, fall back to auto-discovery. If no source can be found anywhere under the roots, the script exits.
4. **Find targets.** Globs every venv under the roots for:
   - `*/venv/lib/python*/site-packages/twikit/user.py`
   - `*/venv/lib/python*/site-packages/twikit/guest/user.py`
   - `*/venv/lib/python*/site-packages/twikit/x_client_transaction/transaction.py`
5. **Progress bar.** Renders an ANSI progress bar `[████████ ] 60%` based on total target count. Falls back to `#` if the locale isn't UTF-8.
6. **Patch each `user.py`.** A Python heredoc finds the block of direct-access lines (`self.followers_count: int = legacy['followers_count']`, etc.) and rewrites it to use `legacy.get('followers_count', 0)` style with sane defaults. Already-patched files report `NOCHANGE` and are skipped.
7. **Patch each `guest/user.py`.** Same idea, smaller block (no DM / can_media_tag / want_retweets fields).
8. **Replace each `transaction.py`.** Copies the source file over the target. Skips if source and target resolve to the same path.
9. **Backups.** Every modified file gets a sibling backup `<file>.bak_<YYYYMMDD_HHMMSS>` before being touched. Easy revert: `mv file.bak_TIMESTAMP file`.
10. **Summary.** Prints mode (`APPLY` vs `DRY-RUN`), roots, source path, and counts of patched/copied files. In apply mode, also shows the backup suffix used for this run.

## Safety / behavior notes

- **Idempotent.** Running it twice on the same install is a no-op for the user.py patches; they detect "already patched" via the regex match count and skip.
- **Backups always.** Every write makes a `.bak_<timestamp>` next to the original. The script never destroys the previous version. Multiple runs make multiple backups.
- **Dry-run is fully safe.** It walks every target and reports `WOULD_PATCH` / `would replace` without writing.
- **No network.** The script doesn't `pip install`, doesn't reach out to GitHub, doesn't talk to the X API. Pure local filesystem work.
- **Restart your services.** Patched files only take effect on next process start. Restart your bot / worker after a successful run.

## Reverting

Each touched file has a backup at `<file>.bak_<TIMESTAMP>`. To roll back a single file:

```bash
mv twikit/user.py.bak_20260516_021500 twikit/user.py
```

Or roll back all files from one run across a venv:

```bash
find /path/to/venv -name '*.bak_20260516_021500' | while read bak; do
  mv "$bak" "${bak%.bak_20260516_021500}"
done
```

## Requirements

- bash 4+
- `python3` on PATH (used for the regex patches)
- `find`, `cp`, `awk`, `sed` (standard GNU userland)
- Twikit installed inside a `venv/` under one of the roots
