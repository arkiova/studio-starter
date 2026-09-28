# Set up a worker with Claude Code

Claude Code can run the whole setup for you on a new computer: it runs the starter, watches it, and checks the worker at the end. The sign-ins stay yours: it hands you each command to run in your own window, and it never sees a password or key.

## Before you start

1. **Install Claude Code** on the new computer (PowerShell): `irm https://claude.ai/install.ps1 | iex`. Then run `claude` and log in. This is also the Claude sign-in setup needs.
2. **Have the AWS access key** for the IAM user `arkiova-studio-worker` ready. The owner creates it: IAM > Users > arkiova-studio-worker > Security credentials > Create access key > Command Line Interface (CLI). An IAM user can have two keys, so each computer beyond the second needs the owner's help. See [The three logins](README.md#the-three-logins).
3. **Have your GitHub account** in the `arkiova` organization ready.
4. **Open Claude Code** in your home folder (not a OneDrive folder) and paste the prompt below.

If the computer shouldn't take work yet, change `-Yes` to `-Yes -NoAutostart` in step 2 of the prompt. On Linux or macOS, ask Claude Code to use `setup.sh` with the same steps instead (`curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash -s -- --yes`).

## The prompt

```text
Set up this computer as an Ibyto Studio worker, using the official starter script. The script does all the installing; you run it, watch it, and hand me the steps only a person can do.

Hard rules:
- Never read, print, copy or store any secret: AWS keys, ~/.aws/credentials, GitHub tokens, Claude credentials. Never run `aws sts get-caller-identity`, and if any output contains a 12-digit AWS account number, don't repeat it.
- The sign-ins are mine. When one is needed, stop and give me the exact command to run in my own PowerShell window. Never run an interactive sign-in yourself, and never ask me to paste a secret into this chat.
- Don't use a OneDrive folder as the work folder.
- Don't edit the starter script or change any system setting it doesn't change itself.

Step 1, preview. Run this and summarise for me what it will install and where it will put the work folder:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1))) -DryRun -Yes
If it proposes a OneDrive work folder, or a drive with less than 30 GB free, stop and ask me which drive to use. I'll give you a path to pass as -WorkDir.

Step 2, run setup:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1))) -Yes
- It can take 30 minutes or more (installs, Chromium, the voice models). Run it in the background, send its output to a log file, and check the log every few minutes instead of blocking on it.
- Windows may show admin (UAC) prompts for the installs. Tell me when one is probably waiting.
- When setup stops because a sign-in is missing, tell me exactly which one and give me the command to run myself:
  - GitHub: `gh auth login -s repo,project,read:org`. I approve it in the browser with my arkiova account. If gh isn't found, tell me to open a new PowerShell window first.
  - AWS: `aws configure --profile arkiova-studio`. I type the access key ID, the secret, the region `ap-south-1` and the output `json`.
  - Claude: I'm already logged in; if setup says otherwise, tell me to run `claude` in another window.
  After I say I'm done, run the same setup command again. Setup continues from where it stopped.
- If it stops for any other reason, show me its last lines and its suggested fix, and ask before trying anything else.

Step 3, check it's running. When setup finishes:
- Show me the workers page link it printed.
- Confirm the scheduled task: `Get-ScheduledTask -TaskName 'Ibyto Studio Worker' | Select-Object TaskName, State`
- Show the last 15 lines of the worker's log in the work folder. It should say it's serving the arkiova course repos, with no errors.

Finish with a short report:
- the work folder and the worker name
- whether a GPU is used for the voice
- the task state
- the workers page link
- anything that still needs me
```

## Check the AWS sign-in yourself

After `aws configure --profile arkiova-studio`, this should print the studio's settings (the bucket, the region and `https://ibyto.com`):

```powershell
aws ssm get-parameter --name /arkiova-studio/config --profile arkiova-studio --region ap-south-1 --query Parameter.Value --output text
```

- **`InvalidClientTokenId` or `SignatureDoesNotMatch`:** a value was mistyped, so run `aws configure` again.
- **`AccessDenied`:** the key belongs to another IAM user.

Type the secret only into that prompt, never into a chat. Delete a downloaded key `.csv` once the check passes.

When the worker is running, the computer appears under "Computers that make the videos" at the bottom of https://ibyto.com within about a minute.
