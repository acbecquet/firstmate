# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain and version problems, optional capability facts, and primary-checkout `TANGLE:` problems; locally sync live secondmate homes; refresh clones best-effort; install tools only after consent |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                 |
| `fm-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate` |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing watcher needs a prominent banner |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, copy a non-empty `config/crew-model` pin from the seeding firstmate, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`; ship/scout spawns require an isolated treehouse worktree and, on claude, append `--model` from the local `config/crew-model` pin (never a secondmate launch); a local secondmate spawn syncs the home before launch, while a `machine:`-tagged secondmate spawns ON its box over the transport under `claude remote-control`, seeding the box's `data/charter.md` and arming status carry-back |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`, plus its optional `@machine` tag (`machine` subcommand) |
| `fm-machines.sh`         | Parse the `data/machines.md` multi-machine registry: list machine ids, get a field, dump all fields, validate an id, or resolve a machine's `ssh-prefix` transport command words |
| `fm-transport-lib.sh`    | Resolve a remote-machine target into the `FM_TMUX_SSH` prefix consumed by `fm_tmux` (override > `FM_TARGET_MACHINE` > meta `machine=`), enforcing the stranger-pane guard; sourced by `fm-send.sh` and `fm-peek.sh` so a local target stays unchanged |
| `fm-status-pull.sh`      | Status carry-back for a remote secondmate: mirror the box's `state/<id>.status` into the hub's local state over ssh, writing only on real change; `arm <id>` wires the pull to the watcher's check cadence |
| `fm-machine-ping.sh`     | Reachability probe (M4): `ssh <host> true` over a machine's transport, recording `status:`/`last-seen` into `data/machines.md` (cheap, bounded, non-fatal); no-arg probes every remote box, `<id>...` named ones, `check <id>` probes without writing for a clean yes/no. Wired into bootstrap and the heartbeat; offline boxes route work to an `awaiting-machine` blocker |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-marker-lib.sh`       | Shared from-firstmate request marker and detector sourced by `fm-send.sh`, `fm-brief.sh`, and tests                 |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-crew-state.sh`       | Print one stable current-state line for a crew by reconciling its matching no-mistakes run-step, even when the pane has closed, with pane and status-log fallback |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls, no-fetch local secondmate syncs, and the box-side cross-machine fast-forward (`remote_ff_command`/`ff_remote_secondmate`) advancing a `machine:`-tagged home over the transport |
| `fm-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and teardown                                            |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work, then run the watcher-liveness guard         |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `fm-send.sh`             | Send one verified literal line (or `--key Escape`) to a direct-report window; exits non-zero on confirmed swallowed Enter; bare `kind=secondmate` targets are marked as from-firstmate; slash commands and codex `$...` skill invocations get popup-settle before Enter; text sends pause `FM_SEND_SETTLE` seconds after success |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry; `fm_tmux` runs tmux locally or, when `FM_TMUX_SSH` is set, transports each call to a remote machine's tmux over ssh with `fm_shquote`-safe argument quoting |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record `pr=` and a verified `pr_head=` when available for a PR-ready task, then arm the watcher's merge poll        |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return a clean, landed ship worktree or retire/release a secondmate home; requires scout reports, checks child work, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate harness                                                  |
| `fm-lock.sh`             | Per-home firstmate session lock with zombie-aware holder liveness; records the session's harness PID resolved via `FM_LOCK_PID` override, then the ancestry walk, then a unique session-id match for background sessions whose tool shells run under a pty-host daemon |
