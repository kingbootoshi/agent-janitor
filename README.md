# agent-janitor

Orphan-process janitor with session attribution for AI-agent dev workstations. Watches every user process, remembers who spawned what before macOS reparents orphans to launchd, flags leftovers with evidence, and reaps only what is provably dead.

The problem: coding agents (Claude Code, Codex, and friends) spawn dev servers, shells, and helpers that outlive their sessions. macOS reparents them to launchd, their history evaporates, and RAM fills with week-old `python -m http.server` processes nobody remembers. Generic RAM cleaners solve the wrong problem - green memory pressure is healthy macOS behavior. The real fix is lineage: know who spawned what, prove nothing interacts with it, then reap with consent.

## components

| binary | role |
|---|---|
| `janitord` | LaunchAgent daemon. Scans every 5s via `proc_pid_rusage`/`libproc`, ranks by phys_footprint, persists lineage + time-series samples to SQLite, evaluates flag rules, listens for memory-pressure transitions, serves a unix socket API. ~5MB footprint. |
| `AgentJanitorMenu` | Menu bar app. Badge shows pending flag count. Per-flag submenu: Keep (instance / project 30d), Terminate, Force Kill, Dismiss. |
| `janitor` | CLI: `status`, `flags`, `keep`, `kill`, `dismiss`, `log`, `mode`. |
| `agent-session` | Exec wrapper: `agent-session --kind claude -- claude ...` registers the session root with the daemon, then execvp's the real CLI. Gives confidence-A attribution. |

## flag rules

- `httpServerOrphan` - python -m http.server, 4h+, parent dead, no tty
- `devToolStale` - vite / bun-watch / bun-dev / node / next orphaned 24h+
- `sshOneShot` - non-tunnel ssh alive 6h+ after parent death
- `staleAgent` - claude/codex 24h+ old and idle 1h+ (polite "still using?" only)
- `bigProc` - footprint >= 1GiB sustained 5min
- `rapidGrowth` - +512MiB in 15min

## safety

- Default mode is `audit`: auto-reap decisions are logged as `would_reap` / `would_hold` with per-gate results, nothing is touched.
- `enforce` mode auto-reaps exactly one class - http.server orphans - and only when every gate passes: loopback-only bind, zero established connections, idle CPU+disk 30min, no tty, no children, no pipe peer owned by a live agent/shell, no keep policy, identity revalidated at signal time.
- Every kill revalidates ProcessKey (pid + start time) immediately before SIGTERM. SIGKILL requires explicit user force.
- Never signals other uids, pid <= 1, or /System//usr/libexec executables.

## data

`~/Library/Application Support/AgentJanitor/`
- `state.sqlite` - process instances, lineage, 14d of per-process samples (footprint/cpu/disk), 30d system samples (pressure/swap/self-footprint), flags, keep policies, 60d decision log
- `events.jsonl` - wide events: flagged, reaped, would_reap, pressure transitions, luna verdicts
- `config.json` - thresholds and mode

## LLM triage (optional, off by default without a key)

The deterministic evidence layer is the product - the LLM is a garnish. When `OPENROUTER_API_KEY` is present in the environment (the bundled LaunchAgent injects it from a keychain-backed vault when available), every 15min `openai/gpt-5.6-luna` reads the pending flags and classifies each dead / active / ambiguous via forced function calling (~$0.001 per call). Its one value: reading command-line semantics the rules can't - distinguishing a forgotten scratch server from a deliberate long-running job with the same process shape. Verdicts are advisory labels in the menu; they never gate a kill. Without a key, everything runs unchanged.

## install

```sh
./install.sh
```

Builds release, copies binaries to `~/.local/bin`, installs both LaunchAgents (login-persistent), boots them, prints status.
