# Arkiova Studio starter

One command that turns a computer into an Arkiova Studio worker. The worker picks up
tasks from the studio boards (writing, visuals, voice, render) and runs them with the
engine, on this computer's CPU, GPU and Claude login.

This repository is public. It holds no keys, tokens, account ids or course content:
everything private comes from your own logins while setup runs.

## Set up a computer

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1 | iex
```

Linux (Debian or Ubuntu) and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash
```

Setup reads the hardware, proposes the settings (press Enter to keep each one), shows
exactly what it will install before it installs anything, walks you through the three
logins, and starts the worker. Every step prints one line, and a failure stops with
what to do next. Running it again is safe: it picks up where it stopped.

### Options

| Windows | Linux / macOS | What it does |
|---|---|---|
| `-DryRun` | `--dry-run` | Show what would happen. Installs, clones, writes and registers nothing. |
| `-Yes` | `--yes` | Accept every proposal without asking. The logins still need you. |
| `-WorkDir <dir>` | `--work-dir <dir>` | The work folder. OneDrive folders are refused. |
| `-Name <name>` | `--name <name>` | The worker name. |
| `-EnginePath <dir>` | `--engine-path <dir>` | Reuse a motion-agent checkout you already have. Setup installs its dependencies but never pulls it. |
| `-NoAutostart` | `--no-autostart` | Don't start the worker at log-on. |
| `-Uninstall` | `--uninstall` | Remove the autostart and, after you confirm, the work folder. |

To pass options to the one-liner:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1))) -DryRun
```

```bash
curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash -s -- --dry-run
```

### The settings it proposes

| Setting | Proposal |
|---|---|
| `workDir` | `<drive with the most free space>:\agentic-video-generation\_worker` (on Linux and macOS, `agentic-video-generation/_worker` on the disk with the most free space, in your home folder when that is the one) |
| `name` | this computer's hostname, lowercased |
| `capabilities` | `agent, render, tts`: every computer runs Claude, renders, and speaks (TTS uses the CPU when there is no free NVIDIA GPU) |
| `ttsDevice` | `auto` |
| `maxJobs` | the number of logical cores |
| `cacheBudgetGB` | `5` |
| `claudeAccount` | `main` |
| `repos` | `-`: every repo tagged `arkiova-studio` (new courses are picked up by themselves) |

They are saved in `<workDir>/studio.worker.json`. On a re-run, the proposals come from that file.

## What gets installed

Only what is missing:

| Tool | Windows | Linux (apt) | macOS (brew) |
|---|---|---|---|
| Git | winget `Git.Git` | `git` | `git` |
| Node.js 24 | winget `OpenJS.NodeJS.LTS`, pinned to 24.x | NodeSource `setup_24.x` | `node@24` |
| Python 3.11 (the engine's TTS needs exactly 3.11) | winget `Python.Python.3.11` | `python3.11`, `python3.11-venv` (deadsnakes PPA on Ubuntu if needed) | `python@3.11` |
| ffmpeg and ffprobe | winget `Gyan.FFmpeg` | `ffmpeg` | `ffmpeg` |
| GitHub CLI | winget `GitHub.cli` | GitHub's apt repository | `gh` |
| AWS CLI v2 | winget `Amazon.AWSCLI` | the official installer from awscli.amazonaws.com | `awscli` |
| Claude Code | the official installer (`claude.ai/install.ps1`) | the official installer (`claude.ai/install.sh`) | the official installer |

If the official Claude Code installer fails, setup falls back to `npm i -g @anthropic-ai/claude-code`.
On macOS, setup installs Homebrew first if it is missing.

Then, in the work folder:

- `studio/`: a clone of `arkiova/studio` (the worker) with its npm packages (`npm ci`).
- `motion-agent/`: a clone of `arkiova/motion-agent` (the engine) with its npm packages, unless you pass `-EnginePath`.
- Playwright Chromium, which the engine renders with (`npx playwright install chromium`).
- The engine's TTS environment in `motion-agent/tts/.venv`: Python 3.11 with PyTorch CUDA wheels
  when an NVIDIA GPU is present and CPU wheels otherwise, then `tts/requirements.txt`.
- The voice models, downloaded once: the Chatterbox weights, the whisper-tiny.en speech check
  and the MMS_FA word aligner.

## The three logins

Setup checks each one and skips it when you are already logged in.

1. **GitHub.** Setup runs `gh auth login -s repo,project,read:org` and you approve it in the
   browser. Use the GitHub account the owner added to the `arkiova` organization.
2. **AWS.** The worker uses the AWS profile `arkiova-studio`. **The key comes from the owner:**
   they create an access key for the IAM user `arkiova-studio-worker` (IAM > Users >
   arkiova-studio-worker > Security credentials > Create access key) and send you the access
   key ID, the secret access key and the region over a private channel. Setup runs
   `aws configure --profile arkiova-studio` and you type them in. The AWS CLI keeps them in its
   own files (`~/.aws`); setup never reads, prints or stores them.
3. **Claude Code.** If `claude auth status` says you are not logged in, setup asks you to open
   another terminal, run `claude` and log in with the Claude account for the `claudeAccount`
   label, and waits until you have.

## See your worker on the workers page

The page lives on the studio API. Its address, `apiUrl`, is in the discovery parameter
that setup reads with your AWS profile, and setup prints the workers link at the end.
To look it up yourself:

```bash
aws ssm get-parameter --name /arkiova-studio/config --profile arkiova-studio --query Parameter.Value --output text
```

It prints `{"bucket":"...","region":"...","apiUrl":"https://..."}`. Open
`<apiUrl>/workers?t=<token>`. The token for the workers page comes from the owner; without it
the page answers 403. Your worker shows up under its `name`, with its capabilities, tasks,
disk and CPU, once it is running. `studio workers` (see below) lists the same heartbeats in
the terminal, and prints the page link too when your AWS profile may read the link secret.

## Stop, update, uninstall

Windows:

```powershell
Stop-ScheduledTask -TaskName 'Arkiova Studio Worker'      # stop now; it starts again at the next log-on
Disable-ScheduledTask -TaskName 'Arkiova Studio Worker'   # keep it off (Enable-ScheduledTask to undo)
Start-ScheduledTask -TaskName 'Arkiova Studio Worker'     # start now
```

Stopping the task ends the worker and everything it started at once. Tasks it was running
are taken over by another computer after 10 minutes.

Linux:

```bash
systemctl --user stop arkiova-studio-worker      # stop now; it starts again at the next log-in
systemctl --user disable arkiova-studio-worker   # keep it off (enable --now to undo)
systemctl --user start arkiova-studio-worker     # start now
```

A stop works like Ctrl+C: the worker stops claiming and gets up to a minute to finish what
it is running.

macOS:

```bash
launchctl bootout gui/$(id -u)/com.arkiova.studio-worker                                    # stop until the next log-in
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arkiova.studio-worker.plist     # start now
```

**Update:** run the same one-liner again. It updates both clones and their dependencies,
stops the worker only while its files change, and changes nothing else.

**Uninstall:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1))) -Uninstall
```

```bash
curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash -s -- --uninstall
```

This removes the scheduled task (or the systemd unit or launchd agent), then asks before it
deletes the work folder. The tools, the logins and the AWS profile stay. An engine checkout
given with `-EnginePath` is never touched.

## Autostart

- **Windows:** the scheduled task "Arkiova Studio Worker" runs at your log-on, hidden, and
  restarts on failure 3 times, 1 minute apart, with no time limit. It runs
  `<workDir>\run-worker.ps1`, which starts `studio worker` from the studio clone.
- **Linux:** the systemd user unit `arkiova-studio-worker` starts at log-in and restarts on
  failure 3 times, 1 minute apart. It runs `<workDir>/run-worker.sh`.
- **macOS:** the launchd agent `com.arkiova.studio-worker` starts at log-in and restarts after
  a failure, at most once a minute (launchd has no 3-attempt limit).

Logs are in `<workDir>/logs`, one file per run.

## Disk space

Plan for about 20 GB free. Measured sizes on a Windows worker:

| What | Where | Size |
|---|---|---|
| Tools (Git, Node.js, Python, ffmpeg, gh, AWS CLI, Claude Code) | their install folders | about 1 GB |
| `studio` and `motion-agent` clones with npm packages | the work folder | about 1 GB |
| Playwright Chromium | `%LOCALAPPDATA%\ms-playwright`, `~/.cache/ms-playwright`, `~/Library/Caches/ms-playwright` | 0.7 GB |
| TTS environment | `motion-agent/tts/.venv` | 5.7 GB with CUDA wheels, less with CPU wheels |
| Voice models | `~/.cache/huggingface` and `~/.cache/torch` | about 4.5 GB |
| Worker cache | the work folder | up to `cacheBudgetGB` (5 GB) |

**How scratch is cleaned:**

- Each task runs in a scratch folder inside the work folder, and the worker deletes that folder
  when the task ends, whatever happened. A task paused on Claude's usage limit keeps its
  folder until it resumes.
- The worker trims its local take cache to `cacheBudgetGB` after each voice task. `studio gc`
  does the same on demand, and also deletes scratch folders older than a day that belong
  to no running or paused task.
- The runner keeps the newest 30 worker logs in `<workDir>/logs` and deletes older ones.
- In storage, logs expire after 30 days and `tmp/` after 1 day, and render parts are deleted
  once the final video is assembled.

## Run studio commands

Setup doesn't put `studio` on your PATH. Run it with Node from the clone, from any folder
(`studio setup` left a pointer to the config in your home folder):

```bash
node <workDir>/studio/bin/studio.js doctor     # check this computer
node <workDir>/studio/bin/studio.js workers    # every worker's heartbeat
node <workDir>/studio/bin/studio.js gc         # trim the cache and old scratch folders
```

## What setup changes on this computer

- Installs the missing tools listed above. Their installers put them on PATH. On Linux this
  adds the NodeSource and GitHub CLI apt sources (and the deadsnakes PPA on Ubuntu when
  Python 3.11 needs it); on macOS it links `node@24` into Homebrew's bin folder.
- Creates the work folder, with the clones, the config, `run-worker.ps1` or `run-worker.sh`, and `logs`.
- Installs npm packages, and creates `tts/.venv` in the engine, including a checkout passed with `-EnginePath`.
- Downloads Playwright Chromium and the voice models into your user caches.
- Runs `gh auth setup-git`, so `git` uses your GitHub CLI login for github.com.
- Creates the AWS profile `arkiova-studio` when you type the key in.
- Registers the scheduled task (Windows), systemd user unit (Linux) or launchd agent (macOS).

Nothing else: setup never edits your shell profile.
