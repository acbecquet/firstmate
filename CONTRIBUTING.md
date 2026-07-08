# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
Dependency bots are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (firstmate expects **no-mistakes v1.31.2+**; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, and `.agents/skills/`.
  Everything personal to one captain's fleet (`data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` uses it for routine backlog mutations.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `shellcheck bin/*.sh tests/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (launch templates in `bin/fm-spawn.sh`, facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, and agent skill files - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory instead.

Check and test the toolbelt before pushing:

```sh
bash -n bin/*.sh                          # syntax-check the toolbelt
shellcheck bin/*.sh tests/*.sh            # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do "$test_script"; done   # behavior tests, matching CI
tests/fm-wake-queue.test.sh               # durable wake queue losslessness, catch-up, double-drain, duplicate-collapse, and drain liveness guard tests
tests/fm-watcher-lock.test.sh             # watcher singleton, lock-race, watch-arm liveness, and guard-warning tests
tests/fm-lock.test.sh                     # per-home session lock liveness (mock ps shim, deterministic): zombie holder treated as stale, FM_LOCK_PID and session-id fallbacks when the harness is not in the tool shell's ancestry, live-holder refusal, and the no-identity honesty guard
tests/fm-watch-turnend-debounce.test.sh   # turn-end debounce against a busy crew pane: busy consumes the touch with no wake or queue record, idle wakes, status writes and kind=secondmate turn-ends always wake, missing meta falls back to waking
tests/fm-daemon.test.sh                   # sub-supervisor classifier, /afk presence-gating, max-defer, composer, and fm-send submit tests
tests/fm-send-settle.test.sh              # fm-send post-submit settle pause, tuning, disable, and --key bypass tests
tests/fm-send-popup-settle.test.sh        # fm-send pre-Enter popup-settle selection for slash commands and codex $skill invocations
tests/fm-send-secondmate-marker.test.sh   # fm-send from-firstmate marker for kind=secondmate targets: marked vs crewmate/explicit/--key, and the exact marker byte sequence
tests/fm-wake-daemon-lifecycle-e2e.test.sh # watcher + daemon lifecycle e2e: restart catch-up, batching, dedupe, stale-pane routing, and digest injection
tests/fm-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/fm-afk-inject-e2e.test.sh           # private-socket end-to-end test of the afk injection path (partial-input deferral, swallowed-Enter retry)
tests/fm-bootstrap.test.sh                # bootstrap dependency and feature-probe tests
tests/fm-tangle-guard.test.sh             # primary-checkout tangle detection and spawn/brief isolation tests
tests/fm-spawn-batch.test.sh              # batch dispatch and FM_HOME project-path scoping tests
tests/fm-spawn-worktree-meta.test.sh      # fm-spawn worktree resolution after treehouse get: a foreign-repo pane transient (e.g. the firstmate primary) is never latched, so meta worktree= and the turn-end hook stay in the project's isolated worktree
tests/fm-spawn-crew-model.test.sh         # config/crew-model claude model pin: absent file leaves the launch byte-for-byte unchanged, ship and scout spawns get --model, secondmate spawns and non-claude harnesses never do, whitespace-only trims to no flag
tests/fm-home-seed-crew-model.test.sh     # fm-home-seed propagation of the config/crew-model pin into a seeded secondmate home: a present pin is copied verbatim (byte-for-byte), absent and whitespace-only pins copy nothing and leave the home otherwise fully seeded
tests/fm-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/fm-secondmate-sync.test.sh          # local-HEAD secondmate sync, no-fetch, bootstrap nudge gating, and spawn hook tests
tests/fm-secondmate-lifecycle-e2e.test.sh # persistent secondmate routing, seeding, backlog handoff, spawn, recovery, teardown, and FM_HOME flow tests
tests/fm-secondmate-safety.test.sh        # secondmate home safety, idle charter, handoff validation, and teardown boundary tests
tests/fm-teardown.test.sh                 # fm-teardown.sh landed-work safety and reminder checks: fork-remote allow, squash/content landings, dirty and unlanded refusals, PR-head metadata, tasks-axi reminder, --force override
tests/fm-crew-state.test.sh               # fm-crew-state.sh current-state reconciliation: run-step authority including closed panes, stale needs-decision/blocked superseded by a resumed run, genuine-parked, cross-branch attribution, pane/status-log fallback, scout skip, torn-down/missing-meta graceful
tests/fm-machines.test.sh                 # multi-machine M1 foundation: fm-machines.sh registry parser (list/get/fields/validate), fm-project-mode.sh @machine tag and unchanged "<mode> <yolo>" default, and the secondmates.md machine: field parsed unchanged by fm-spawn.sh's existing regexes
tests/fm-transport.test.sh                # multi-machine M2 transport adapter: fm_tmux byte-for-byte-unchanged local path and remote ssh transport, fm_shquote quoting, fm-machines.sh ssh-prefix, fm-transport-lib.sh precedence and stranger-pane guard, and a mock (no real ssh/tmux) fm-peek/fm-send remote e2e
tests/fm-status-pull.test.sh              # multi-machine M2 status carry-back: fm-status-pull.sh mirrors a remote secondmate's status into local state (mock ssh), writes only on change, skips non-remote ids, exits 0 on an unreachable box, and arms a watcher check
tests/fm-spawn-remote-secondmate.test.sh  # multi-machine M3/M4/M5 remote secondmate spin-up (mock ssh/tmux): box-side Remote Control launch + routing meta + charter seed + status carry-back + round-trip, unchanged local path, M5 pre-launch sync over the wire, and M4 offline clean-fail (exit 3, awaiting-machine)
tests/fm-machine-ping.test.sh             # multi-machine M4 reachability probe: fm-machine-ping.sh flips status:/last-seen (mock ssh), skips local/hub machines, preserves reachability: and other fields, check exits 0/non-zero without writing, inserts missing fields, and fails cleanly on absent registry / unknown id
tests/fm-cross-machine-update.test.sh     # multi-machine M5 cross-machine self-update: fm-update.sh fast-forwards a machine:-tagged box clone over the transport (fetch + ff-only, mock ssh executes the box-side guarded ff), nudges on instruction change, skips a diverged/unreachable box cleanly, routes the registry backstop remotely, and a local secondmate makes no ssh call
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then "heartbeat")
```

CI runs the same checks on pushes to `main` and on pull requests targeting `main`.
It can also be triggered manually with `gh workflow run ci.yml --ref main` for ad-hoc verification.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
