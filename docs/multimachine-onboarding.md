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

## Offline and asleep boxes

A personal box may sleep, suspend, reboot, or drop off the tailnet. The accepted behavior is to **fail cleanly**: firstmate reports plainly that the machine is asleep or unreachable rather than hanging. A remote crewmate that is already running keeps working and can still land its PR through GitHub during a hub-link outage; anything that needs a captain decision, a relayed status, or a hub-side merge waits until the box is reachable again. The reachability probe and the `awaiting-machine` backlog blocker that automate this queue-and-resume are a later milestone (AGENTS.md section 14, forward references).

## What this milestone does and does not include

This runbook and the registry/routing fields are the additive hub-side foundation. The transport that actually carries `fm-send`/`fm-peek` to a remote tmux, the status carry-back that surfaces a remote escalation into the hub's watcher, the reachability automation, and cross-machine self-update are later milestones. Until they land, registering a box and tagging its projects changes nothing about how firstmate supervises local crewmates — the fields are inert metadata.
