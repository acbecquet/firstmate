# Onboarding a Windows box (WSL2) into the multi-machine fleet

This is the captain's guide for the per-box steps the hub cannot do remotely.
It brings up one Windows machine as a **remote secondmate**: stock firstmate running inside WSL2, supervising its own crewmates locally, reached from the hub over the tailnet, with the captain riding along from claude.ai/code.

See AGENTS.md section 14 for the model (a remote machine *is* a remote secondmate) and the registry/routing fields this runbook fills in.

## Why WSL2

The remote machines are Windows. Firstmate's supervision model needs a Unix toolchain — tmux panes, git worktrees, bash scripts, a file-polling watcher — which native Windows does not provide. The realistic path is **WSL2 (Ubuntu) + tmux** on each box. `claude remote-control` itself is cross-platform, but the firstmate-on-box machinery runs inside WSL2.

`claude remote-control` keeps the CLI session running locally in tmux (hub-driven) while letting the captain steer that **same live session** from claude.ai/code on a browser or phone. One session, no CLI/desktop split. The local CLI process must stay running for the web UI to attach.

## What is manual vs automated

| Step | Who does it | Why |
| --- | --- | --- |
| Install WSL2 + Ubuntu | **Manual (captain, on the box)** | Needs Windows admin + a reboot; not remotable. |
| Install the toolchain inside WSL2 (claude CLI, tmux, git, treehouse, no-mistakes) | **Manual first time** | First-run on a fresh box; the hub has no shell there yet. |
| `gh auth login` | **Manual, out-of-band** | Interactive browser/device auth; the hub cannot type the captain's credentials. |
| Harness first-run trust / permission dialog | **Manual, out-of-band** | A one-time security prompt that must be accepted by a human on the box. |
| Join the tailnet (`tailscale up`) | **Manual, out-of-band** | Interactive device authorization. |
| Install firstmate in its own `FM_HOME` | **Manual first time**, then automated | Clone once; thereafter `/updatefirstmate` and the spawn pre-launch sync keep it current. |
| Start the session under `claude remote-control` in tmux | **Manual first time**, then firstmate-managed | The hub takes over routing once the session exists. |
| Register the box + route work | **Hub (firstmate)** | `data/machines.md`, the `secondmates.md` `machine:` field, the `projects.md` `@machine` tag. |

The rule of thumb: anything that requires a human to accept a trust prompt or prove identity (gh auth, harness trust, tailnet join) is manual and out-of-band, once per box. Everything after the session exists is hub-driven.

## Steps (run on the Windows box, inside WSL2 unless noted)

### 1. Install WSL2 + Ubuntu — *manual, Windows side*

In an **administrator PowerShell**:

```powershell
wsl --install -d Ubuntu
```

Reboot if prompted, then launch **Ubuntu** from the Start menu and create your Unix user. Confirm you are on WSL2:

```powershell
wsl -l -v        # VERSION column must read 2
```

### 2. Install the toolchain — *manual, inside WSL2*

```sh
sudo apt-get update
sudo apt-get install -y tmux git curl
```

Install the Claude Code CLI (per the current install instructions at code.claude.com), then the firstmate dependencies:

```sh
# Claude Code CLI — follow code.claude.com/docs for the current installer.
claude --version          # confirm it runs inside WSL2

# treehouse (worktree pooling) and no-mistakes (the gate) — install per their docs.
treehouse --version
no-mistakes --version
```

Match the firstmate version floors in AGENTS.md section 3: `treehouse get` must support `--lease`, and `no-mistakes` must be recent enough for the version-matched crewmate validation guidance.

### 3. `gh auth login` — *manual, out-of-band*

```sh
gh auth login
```

Complete the interactive browser/device flow. This is per-home and per-box; the hub cannot do it for you. Bootstrap's `NEEDS_GH_AUTH` check will flag this if it is missing.

### 4. Join the tailnet — *manual, out-of-band*

Install Tailscale on Windows (or inside WSL2 per Tailscale's WSL guidance) and bring the box onto the captain's tailnet:

```sh
tailscale up
tailscale status          # note this box's 100.x.y.z address and its tailnet name
```

Authorize the device when prompted. Confirm from the **hub** that the box is reachable:

```sh
# on the hub
tailscale status | grep <box-name>      # should show the box online
ssh <box-tailnet-name> 'echo reachable' # tailscale-ssh, once ACLs allow it
```

The box's tailnet hostname is what goes in the registry `host:` field. `transport:` is `tailscale-ssh`; `auth:` is the reference `tailnet-acl` — the hub holds only the reference, never a key copied off the box.

### 5. Install firstmate in its own `FM_HOME` — *manual first time*

Clone firstmate into a home of its own on the box and run bootstrap there:

```sh
git clone <firstmate-repo-url> ~/firstmate
cd ~/firstmate
FM_HOME=~/firstmate bin/fm-bootstrap.sh
```

Resolve any `MISSING:` / `NEEDS_GH_AUTH` lines bootstrap prints (that is what steps 2–3 cover). This home keeps its own `state/`, `data/`, `projects/`, and session lock — fully isolated from the hub and from any other box.

### 6. Accept the harness first-run trust dialog — *manual, out-of-band*

Launch the harness once by hand in this home and accept its trust / permission prompt. This one-time dialog cannot be auto-accepted; a human on the box must approve it before unattended dispatch works.

### 7. Start the session under `claude remote-control` in tmux — *manual first time*

```sh
tmux new-session -s firstmate
# inside the tmux session:
claude remote-control
```

The tmux session name (`firstmate` here) is what goes in the registry `tmux-session:` field and is authoritative for any remote peek. From claude.ai/code (browser or phone) attach to this same session to ride along.

### 8. Register the box on the hub — *hub (firstmate)*

Add the box to the hub's private registry `data/machines.md` (gitignored; one line per machine):

```markdown
- cabin-desktop - cabin Windows box, WSL2 (host: cabin-desktop.tailnet.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
```

Seed examples for the three known boxes (`data/machines.md` is firstmate-private, so these are copy-paste starting points, not tracked data):

```markdown
- cabin-desktop - cabin Windows box, WSL2 (host: cabin-desktop.tailnet.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
- desktop-bgiv1ph - Charlie's Workstation, Windows/WSL2 (host: desktop-bgiv1ph.tailnet.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-06-29)
- s102000028774 - SDR Windows box, WSL2 (host: s102000028774.tailnet.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-06-27)
```

Verify the registry parses:

```sh
bin/fm-machines.sh list
bin/fm-machines.sh validate cabin-desktop
bin/fm-machines.sh get cabin-desktop host
```

### 9. Route work to the box — *hub (firstmate)*

- Tag the box's projects in `data/projects.md` so intake resolves them to the box without a network hop:

  ```markdown
  - roybot @cabin-desktop [direct-PR] - RoyBot robot controller (added 2026-06-29)
  ```

- When a remote secondmate exists for that domain, mark its `data/secondmates.md` line with the box (the `machine:` field goes at the **end**, after `added`):

  ```markdown
  - roybot-dev - RoyBot development (home: /home/cap/firstmate; scope: RoyBot robot control; projects: roybot; added 2026-06-29; machine: cabin-desktop)
  ```

Absent tags mean local (hub) behavior, unchanged.

## Transport: making `ssh <box> tmux` reach the WSL2 session

The hub reaches a remote box's tmux by running `ssh <host> "tmux …"` — the prefix comes from `bin/fm-machines.sh ssh-prefix <id>` (transport + `host:`), which `bin/fm-transport-lib.sh` exports as `FM_TMUX_SSH` so `fm-send`/`fm-peek` transport every tmux call (AGENTS.md section 14, *Transport adapter*). For this to work, an ssh login to the box **must land in the WSL2 Ubuntu environment** where tmux, the firstmate tmux session, and the right `PATH` live — not a Windows `cmd`/PowerShell shell.

**Where the login lands depends on where Tailscale runs:**

- **Recommended — Tailscale inside WSL2.** If `tailscaled` runs inside WSL2 (step 4 already points at Tailscale's WSL guidance), a tailnet ssh to the box terminates directly in WSL2 and `tmux` is on `PATH` with no extra setup. This is the path this runbook assumes; prefer it.
- **Alternative — Tailscale on the Windows host.** Then tailscale-ssh (or Windows OpenSSH) lands in the Windows default shell, where `tmux` does not exist. Make the remote command run under WSL2 — set the Windows OpenSSH `DefaultShell` to `wsl.exe` (so `tmux …` runs as `wsl.exe tmux …`), or front the box with a small wrapper that re-enters WSL2. This indirection is exactly what the WSL2-resident Tailscale path avoids, so use it only if you cannot move Tailscale into WSL2.

The hub never passes a socket flag or PATH shim: the transport invokes the default `tmux`, which must resolve on the box's **non-interactive** login PATH. `ssh <host> tmux` runs a non-login, non-interactive shell, so an `apt`-installed tmux (in `/usr/bin`) is fine, but a tmux/treehouse/no-mistakes installed outside the default PATH must be added ahead of the interactive guard in the WSL2 user's `~/.bashrc` (or the system PATH), or the remote `tmux` call will fail with "command not found".

The ssh-prefix bakes in `-o BatchMode=yes -o ConnectTimeout=8` (override with `FM_SSH_OPTS`), so the box must accept **non-interactive key-based auth**: tailscale-ssh satisfies this through tailnet ACLs; a plain `ssh` transport needs an ssh-agent identity the hub can use unattended. A box that would prompt for a password fails fast and cleanly instead of hanging a supervision call.

**Verify from the hub** (after step 7's session exists):

```sh
ssh <box-tailnet-name> tmux -V                        # prints tmux's version from WSL2
ssh <box-tailnet-name> tmux has-session -t firstmate  # exit 0 once the session is up
```

If `tmux -V` errors with "command not found" or returns a Windows shell banner, ssh is not landing in WSL2 — fix the landing shell before registering the box. Keep the registry `tmux-session:` field equal to the session name from step 7: the transport's **stranger-pane guard** refuses any remote target whose session does not match the registry, so a mismatch blocks all remote peeks.

### Status carry-back for a remote secondmate

A remote secondmate escalates by appending to its **own** home's `state/<id>.status` on the box. The hub mirrors that file into its local `state/<id>.status` with `bin/fm-status-pull.sh` (it resolves the box from the `<id>.meta` `machine=` field, pulls over the same ssh transport, and writes only on a real change), so the hub watcher wakes on it through the ordinary local signal path. Arm it on the watcher's slow cadence so the network stays off the tight loop:

```sh
# on the hub, once per remote secondmate id
bin/fm-status-pull.sh arm <id>
```

This keeps the high-frequency watcher local and puts the wire only on the heartbeat-cadence pull (AGENTS.md section 14, *Status carry-back*). An asleep or off-tailnet box simply yields no new status until it returns.

## Offline and asleep boxes

A personal box may sleep, suspend, reboot, or drop off the tailnet. The accepted behavior is to **fail cleanly**: firstmate reports plainly that the machine is asleep or unreachable rather than hanging. A remote crewmate that is already running keeps working and can still land its PR through GitHub during a hub-link outage; anything that needs a captain decision, a relayed status, or a hub-side merge waits until the box is reachable again. The reachability probe and the `awaiting-machine` backlog blocker that automate this queue-and-resume are a later milestone (AGENTS.md section 14, forward references).

## What this milestone does and does not include

This runbook, the registry/routing fields, the transport that carries `fm-send`/`fm-peek` to a remote tmux, and the status carry-back that surfaces a remote escalation into the hub's watcher are all in place (AGENTS.md section 14). The remaining cross-machine pieces — the reachability probe with its `awaiting-machine` backlog blocker, and routing `machine:`-tagged homes through `origin` fast-forward for cross-machine self-update — are later milestones. Everything stays additive: with no machine registry and no routing tags, firstmate behaves exactly as it does on the hub alone.
