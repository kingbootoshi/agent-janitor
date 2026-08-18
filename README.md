# agent-janitor

![agent-janitor](assets/hero.jpeg)

Orphan-process janitor with session attribution for AI-agent dev workstations. Watches every user process, remembers who spawned what before macOS reparents orphans to launchd, flags leftovers with evidence, and reaps only what is provably dead.

Fully local. No network calls, no LLM, no telemetry - nothing leaves your machine. The daemon is a deterministic sensor and actuator; judgment stays with you (or the agent you already talk to, reading `janitor flags`).

The problem: coding agents (Claude Code, Codex, and friends) spawn dev servers, shells, and helpers that outlive their sessions. macOS reparents them to launchd, their history evaporates, and RAM fills with week-old `python -m http.server` processes nobody remembers. Generic RAM cleaners solve the wrong problem - green memory pressure is healthy macOS behavior. The real fix is lineage: know who spawned what, prove nothing interacts with it, then reap with consent.

## components

| binary | role |
|---|---|
| `janitord` | LaunchAgent daemon. Scans every 5s via `proc_pid_rusage`/`libproc`, ranks by phys_footprint, persists lineage + time-series samples to SQLite, evaluates flag rules, listens for memory-pressure transitions, serves a unix socket API. ~13MB footprint. |
| `AgentJanitorMenu` | Menu bar app (broom icon, dims when clean). Flags grouped by process type + project with bulk actions. Per-flag: Keep (instance / project 30d), Terminate, Force Kill, Dismiss. Memory Breakdown submenu reconciles Activity-Monitor-style totals. |
| `janitor` | CLI: `status`, `top`, `flags`, `keep`, `kill`, `dismiss`, `log`, `mode`. |
| `agent-session` | Optional exec wrapper: `agent-session --kind claude -- claude ...` registers the session root with the daemon before execvp'ing the real CLI, improving lineage attribution for that session tree. |

## flag rules

- `httpServerOrphan` - python -m http.server, 4h+, parent dead, no tty
- `devToolStale` - vite / bun-watch / bun-dev / node / next orphaned 24h+
- `sshOneShot` - non-tunnel ssh alive 6h+ after parent death
- `staleAgent` - claude/codex 24h+ old and idle 1h+ (polite "still using?" only)
- `runawayCpu` - >50% CPU for 30min with no tty
- `bigProc` - footprint >= 1GiB sustained 5min
- `rapidGrowth` - +512MiB in 15min

## safety

- Default mode is `audit`: auto-reap decisions are logged as `would_reap` / `would_hold` with per-gate results, nothing is touched.
- `enforce` mode auto-reaps exactly one class - http.server orphans - and only when every gate passes: loopback-only bind, zero established connections, idle CPU+disk 30min, no tty, no children, no pipe peer owned by a live agent/shell, no keep policy, identity revalidated at signal time.
- Every kill revalidates ProcessKey (pid + start time) immediately before SIGTERM. SIGKILL requires explicit user force.
- Never signals other uids, pid <= 1, or /System//usr/libexec executables.

## privacy

- Command lines are redacted at capture: `--api-key`-style flags, token-shaped values, and `user:pass@` URL credentials become `***` before anything is stored.
- Data dir is chmod 0700, database and config 0600, socket 0600.
- Everything stays in `~/Library/Application Support/AgentJanitor/`.

## data

`~/Library/Application Support/AgentJanitor/`
- `state.sqlite` - process instances, lineage, 14d of per-process samples (footprint/cpu/disk), 30d system samples (pressure/swap/self-footprint), flags, keep policies, 60d decision log
- `events.jsonl` - wide events: flagged, reaped, would_reap, pressure transitions (rotates at 5MB)
- `config.json` - thresholds and mode

## install

```sh
./install.sh
```

Builds release, copies binaries to `~/.local/bin`, installs both LaunchAgents (login-persistent), boots them, prints status.

## uninstall

```sh
launchctl bootout "gui/$(id -u)/com.bootoshi.agentjanitor.daemon"
launchctl bootout "gui/$(id -u)/com.bootoshi.agentjanitor.menu"
rm ~/Library/LaunchAgents/com.bootoshi.agentjanitor.{daemon,menu}.plist
rm ~/.local/bin/{janitord,janitor,AgentJanitorMenu,agent-session}
rm -rf ~/Library/Application\ Support/AgentJanitor
```
