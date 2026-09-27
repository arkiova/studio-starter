<#
.SYNOPSIS
    Turns this computer into an Arkiova Studio worker.

.DESCRIPTION
    Sets up (or updates) an Arkiova Studio worker on Windows, in seven steps:
      1. reads the hardware: cores, memory, free disk per drive, NVIDIA GPU and VRAM;
      2. proposes the worker settings and lets you confirm or change each one;
      3. installs only the missing tools: Git, Node.js 24, Python 3.11, ffmpeg,
         GitHub CLI and AWS CLI v2 with winget, and Claude Code with its official installer;
      4. checks the three logins (GitHub, the AWS profile arkiova-studio, Claude Code);
      5. clones or updates arkiova/studio and arkiova/motion-agent in the work folder, installs
         their npm packages, Playwright Chromium, the engine's TTS Python environment and the
         voice models;
      6. writes <workDir>\studio.worker.json, then runs `studio doctor` and `studio worker --once --dry`;
      7. registers the "Arkiova Studio Worker" scheduled task (at log-on, hidden, restarts on failure).
    Running it again updates the clones and dependencies and changes nothing else.
    It never prints, logs or copies a key or token.

.PARAMETER DryRun
    Show what would happen. Installs, clones, writes and registers nothing.

.PARAMETER Yes
    Accept every proposal without asking (the logins still need you).

.PARAMETER WorkDir
    The work folder. Default: <drive with the most free space>:\agentic-video-generation\_worker.
    OneDrive folders are refused.

.PARAMETER Name
    The worker name. Default: this computer's hostname, lowercased.

.PARAMETER EnginePath
    Reuse an existing motion-agent checkout instead of cloning one into the work folder.
    Setup installs its dependencies but never pulls it.

.PARAMETER NoAutostart
    Don't register the scheduled task.

.PARAMETER Uninstall
    Remove the scheduled task and, after you confirm, the work folder. Tools and logins stay.

.EXAMPLE
    irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.ps1))) -Yes

.EXAMPLE
    .\setup.ps1 -DryRun -Yes -EnginePath D:\agentic-video-generation\motion-agent
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'An interactive installer: every line is for the person at the console, and Write-Host keeps it out of the output stream when the script runs through irm | iex.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Every parameter is read inside the & { } block below; the rule does not look into nested script blocks.')]
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$WorkDir = '',
    [string]$Name = '',
    [string]$EnginePath = '',
    [switch]$NoAutostart,
    [switch]$Uninstall
)

# Everything runs inside this script block, so that under `irm | iex` none of its
# functions or preferences leak into the caller's session, and `exit` (which would
# close that window) is only used when the script runs as a file.
$ArkiovaSetupFailed = $false
& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 1

    $TaskName = 'Arkiova Studio Worker'
    $StudioRepo = 'arkiova/studio'
    $EngineRepo = 'arkiova/motion-agent'
    $DefaultRepos = @('-')   # '-': every repo tagged arkiova-studio, which the workers discover (new courses included)
    $AwsProfile = 'arkiova-studio'
    $AwsIamUser = 'arkiova-studio-worker'
    $SsmParameter = '/arkiova-studio/config'
    $GhScopes = @('repo', 'project', 'read:org')
    $AllCapabilities = @('agent', 'render', 'tts')
    $MinClaudeVersion = [version]'2.1.41'
    $ConfigName = 'studio.worker.json'
    $RunnerName = 'run-worker.ps1'
    $StampName = '.studio-starter'
    $RawBase = 'https://raw.githubusercontent.com/arkiova/studio-starter/main'
    $State = @{ WorkerStopped = $false; ApiUrl = '' }

    # The script the scheduled task runs. Written to <workDir>\run-worker.ps1.
    $RunnerScript = @'
# Arkiova Studio worker runner.
# Written by setup.ps1 (arkiova/studio-starter) and started at log-on by the
# "Arkiova Studio Worker" scheduled task. Setup rewrites it, so don't edit it.
# It runs `studio worker` from the studio clone next to it, with this folder as
# the working directory, and logs to .\logs (the newest 30 runs are kept). The
# worker's whole process tree is tied to this process through a job object, so
# stopping the task stops the worker and everything it started.
$ErrorActionPreference = 'Stop'
$work = $PSScriptRoot
$logs = Join-Path $work 'logs'
$null = New-Item -ItemType Directory -Force -Path $logs
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jobType = '
using System;
using System.Runtime.InteropServices;
public static class ArkiovaStudioJob {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong R; public ulong W; public ulong O; public ulong RB; public ulong WB; public ulong OB; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits Basic; public IoCounters Io;
        public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    static IntPtr job = IntPtr.Zero;
    public static bool Adopt(IntPtr process) {
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { return false; }
        ExtendedLimits info = new ExtendedLimits();
        info.Basic.LimitFlags = 0x2000;
        int size = Marshal.SizeOf(typeof(ExtendedLimits));
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(job, 9, ptr, (uint)size)) { return false; }
        } finally { Marshal.FreeHGlobal(ptr); }
        return AssignProcessToJobObject(job, process);
    }
}
'
try {
    Get-ChildItem -LiteralPath $logs -Filter 'worker-*.log' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 60 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $studio = Join-Path $work 'studio'
    $pkg = Get-Content -Raw -LiteralPath (Join-Path $studio 'package.json') | ConvertFrom-Json
    $bin = $pkg.bin
    if ($bin -isnot [string]) { $bin = $bin.studio }
    $node = (Get-Command -Name node.exe -CommandType Application | Select-Object -First 1).Source
    Add-Type -TypeDefinition $jobType
    $start = @{
        FilePath               = $node
        ArgumentList           = ('"{0}" worker --config "{1}"' -f (Join-Path $studio $bin), (Join-Path $work 'studio.worker.json'))
        WorkingDirectory       = $work
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = (Join-Path $logs "worker-$stamp.log")
        RedirectStandardError  = (Join-Path $logs "worker-$stamp.err.log")
    }
    $p = Start-Process @start
    $null = [ArkiovaStudioJob]::Adopt($p.Handle)
    $p.WaitForExit()
    exit $p.ExitCode
} catch {
    Add-Content -LiteralPath (Join-Path $logs 'runner.log') -Value ('{0}  {1}' -f (Get-Date -Format s), $_.Exception.Message)
    exit 1
}
'@

    # ------------------------------------------------------------------ output

    function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
    function Write-Info([string]$Text) { Write-Host "    $Text" }
    function Write-Tagged([string]$Tag, [ConsoleColor]$Color, [string]$Text) {
        Write-Host ('    {0,-6}' -f $Tag) -ForegroundColor $Color -NoNewline
        Write-Host $Text
    }
    function Write-Ok([string]$Text) { Write-Tagged 'ok' Green $Text }
    function Write-Dry([string]$Text) { Write-Tagged 'dry' Magenta $Text }
    function Write-Run([string]$Text) { Write-Tagged 'run' DarkCyan $Text }
    function Write-Warn([string]$Text) { Write-Tagged 'warn' Yellow $Text }
    function Write-Todo([string]$Text) { Write-Tagged 'todo' Yellow $Text }

    # Stops setup: $Message says what failed, $Next says what to do about it.
    function Exit-Setup {
        param([Parameter(Mandatory = $true)][string]$Message, [string]$Next = '')
        $err = New-Object System.Exception $Message
        if ($Next) { $err.Data['Next'] = $Next }
        throw $err
    }

    # ------------------------------------------------------------------ small helpers

    function ConvertTo-ArgumentString([string[]]$ArgumentList) {
        # Quotes each argument the way CommandLineToArgvW reads it back.
        $parts = foreach ($a in $ArgumentList) {
            if ($null -eq $a -or $a -eq '') { '""' }
            elseif ($a -notmatch '[\s"]') { $a }
            else {
                $escaped = $a -replace '(\\*)"', '$1$1\"'
                $escaped = $escaped -replace '(\\+)$', '$1$1'
                '"' + $escaped + '"'
            }
        }
        return (@($parts) -join ' ')
    }

    # Runs a program in this console (its output shows as it runs; prompts work) and
    # returns its exit code.
    function Invoke-Tool {
        param(
            [Parameter(Mandatory = $true)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [string]$WorkingDirectory = ''
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ConvertTo-ArgumentString $ArgumentList
        $psi.UseShellExecute = $false
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        return $proc.ExitCode
    }

    # Runs a program with no console input and returns its exit code and output. Callers
    # only parse the text; it is never printed, because some tools echo masked keys.
    function Invoke-Capture {
        param(
            [Parameter(Mandatory = $true)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [string]$WorkingDirectory = '',
            [int]$TimeoutSeconds = 120
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ConvertTo-ArgumentString $ArgumentList
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch { return [pscustomobject]@{ Code = -1; Text = $_.Exception.Message } }
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { Write-Verbose 'the process had already exited' }
            return [pscustomobject]@{ Code = -1; Text = 'timed out' }
        }
        $proc.WaitForExit()
        return [pscustomobject]@{ Code = $proc.ExitCode; Text = ($out.Result + "`n" + $err.Result).Trim() }
    }

    function Find-Command([string]$Name, [string[]]$Fallback = @()) {
        $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
        foreach ($p in $Fallback) {
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
        }
        return $null
    }

    function Find-Git { Find-Command 'git.exe' @("$env:ProgramFiles\Git\cmd\git.exe") }
    function Find-Node { Find-Command 'node.exe' @("$env:ProgramFiles\nodejs\node.exe") }
    function Find-Npm { Find-Command 'npm.cmd' @("$env:ProgramFiles\nodejs\npm.cmd") }
    function Find-Npx { Find-Command 'npx.cmd' @("$env:ProgramFiles\nodejs\npx.cmd") }
    function Find-Gh { Find-Command 'gh.exe' @("$env:ProgramFiles\GitHub CLI\gh.exe") }
    function Find-AwsCli { Find-Command 'aws.exe' @("$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe") }
    function Find-Claude { Find-Command 'claude' @("$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd") }
    function Find-Winget { Find-Command 'winget.exe' @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe") }

    function Find-Python311 {
        $py = Find-Command 'py.exe' @("$env:SystemRoot\py.exe", "$env:LOCALAPPDATA\Programs\Python\Launcher\py.exe")
        if ($py) {
            $r = Invoke-Capture -FilePath $py -ArgumentList '-3.11', '-c', 'import sys; print(sys.executable)'
            if ($r.Code -eq 0) {
                $exe = @($r.Text -split "`r?`n")[-1].Trim()
                if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) { return $exe }
            }
        }
        foreach ($p in @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe", "$env:ProgramFiles\Python311\python.exe")) {
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
        return $null
    }

    function Get-VersionText([string]$FilePath, [string[]]$ArgumentList = @('--version')) {
        $r = Invoke-Capture -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds 60
        if ($r.Code -eq 0 -and $r.Text -match '(\d+\.\d+(\.\d+)?)') { return $Matches[1] }
        return ''
    }

    function ConvertTo-Int([string]$Text, [int]$Default = 0) {
        $n = 0
        if ([int]::TryParse(($Text -replace '[^\d-]', ''), [ref]$n)) { return $n }
        return $Default
    }

    function Write-TextFile([string]$Path, [string]$Text) {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
    }

    # Puts tools installed a moment ago on this session's PATH, keeping what was already there.
    function Sync-SessionPath {
        $seen = New-Object System.Collections.Generic.List[string]
        $sources = @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User'),
            $env:Path,
            (Join-Path $env:USERPROFILE '.local\bin'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
            (Join-Path $env:APPDATA 'npm')
        )
        foreach ($source in $sources) {
            if (-not $source) { continue }
            foreach ($entry in ($source -split ';')) {
                $item = [Environment]::ExpandEnvironmentVariables($entry.Trim())
                if ($item -and -not ($seen -contains $item) -and (Test-Path -LiteralPath $item)) { $seen.Add($item) }
            }
        }
        $env:Path = $seen -join ';'
    }

    function Read-Console([string]$Prompt) {
        try { return (Read-Host -Prompt $Prompt) }
        catch {
            Exit-Setup 'This step needs an answer, but there is no console to ask in.' 'Run setup in an interactive PowerShell window, or pass -Yes to accept the proposals.'
        }
    }

    function Read-YesNo([string]$Question, [bool]$Default = $true) {
        if ($Yes) { return $true }
        $hint = '[y/N]'
        if ($Default) { $hint = '[Y/n]' }
        while ($true) {
            $answer = Read-Console "    $Question $hint"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
            if ($answer.Trim() -match '^(y|yes)$') { return $true }
            if ($answer.Trim() -match '^(n|no)$') { return $false }
            Write-Warn 'Please answer y or n.'
        }
    }

    # Asks for one setting, showing the proposal; Enter keeps it. $Check returns a problem or nothing.
    function Read-Setting([string]$Label, [string]$Default, [scriptblock]$Check) {
        if ($Yes) {
            $problem = & $Check $Default
            if ($problem) { Exit-Setup "The proposed $Label '$Default' can't be used: $problem" "Pass a valid value as a parameter, or run without -Yes and type one." }
            Write-Info ('{0,-14} {1}' -f $Label, $Default)
            return $Default
        }
        while ($true) {
            $answer = Read-Console ('    {0,-14} [{1}]' -f $Label, $Default)
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default } else { $answer = $answer.Trim() }
            $problem = & $Check $answer
            if (-not $problem) { return $answer }
            Write-Warn $problem
        }
    }

    function Test-OneDrivePath([string]$Path) {
        $full = $Path.TrimEnd('\') + '\'
        foreach ($root in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
            if ($root) {
                $r = $root.TrimEnd('\') + '\'
                if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
        return ($full -match '\\OneDrive( - [^\\]*)?\\')
    }

    function Test-WorkDirValue([string]$Path) {
        if ($Path -notmatch '^[A-Za-z]:\\') { return 'use a full path, such as D:\agentic-video-generation\_worker' }
        if ($Path -match '["*?<>|;]') { return 'the path has a character that is not allowed here' }
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if ($full.Length -le 3) { return 'pick a folder, not the root of a drive' }
        if (Test-OneDrivePath $full) { return 'OneDrive folders are refused: syncing gigabytes of scratch would fight the worker. Pick a folder outside OneDrive' }
        if (-not (Test-Path -LiteralPath $full.Substring(0, 3))) { return "drive $($full.Substring(0, 2)) does not exist" }
        return $null
    }

    function Test-EngineCheckout([string]$Path) {
        return ((Test-Path -LiteralPath (Join-Path $Path 'package.json')) -and
            (Test-Path -LiteralPath (Join-Path $Path 'tts\requirements.txt')))
    }

    function Get-ConfigValue($Config, [string]$Key, $Default) {
        if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains $Key) -and $null -ne $Config.$Key) { return $Config.$Key }
        return $Default
    }

    function Get-TaskWorkDir {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and @($task.Actions).Count -gt 0 -and $task.Actions[0].WorkingDirectory) { return $task.Actions[0].WorkingDirectory }
        return $null
    }

    function Find-ExistingWorkDir($Hardware) {
        $fromTask = Get-TaskWorkDir
        if ($fromTask) { return $fromTask }
        foreach ($d in $Hardware.Disks) {
            $p = "$($d.Drive)\agentic-video-generation\_worker"
            if (Test-Path -LiteralPath (Join-Path $p $ConfigName)) { return $p }
        }
        return $null
    }

    # ------------------------------------------------------------------ 1. hardware

    function Get-NvidiaGpu {
        $smi = Find-Command 'nvidia-smi.exe' @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:SystemRoot\System32\nvidia-smi.exe")
        if (-not $smi) { return }
        $r = Invoke-Capture -FilePath $smi -ArgumentList '--query-gpu=name,memory.total,memory.free', '--format=csv,noheader,nounits' -TimeoutSeconds 30
        if ($r.Code -ne 0) { return }
        foreach ($line in ($r.Text -split "`r?`n")) {
            $f = $line -split ','
            if ($f.Count -ge 3 -and $f[0].Trim()) {
                [pscustomobject]@{ Name = $f[0].Trim(); TotalMB = (ConvertTo-Int $f[1]); FreeMB = (ConvertTo-Int $f[2]) }
            }
        }
    }

    function Get-Hardware {
        $ramGB = 0
        $disks = @()
        try {
            $ramGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID | ForEach-Object {
                    [pscustomobject]@{ Drive = $_.DeviceID; FreeGB = [math]::Round($_.FreeSpace / 1GB, 1); SizeGB = [math]::Round($_.Size / 1GB, 1) }
                })
        } catch { Write-Warn "could not read memory or disks: $($_.Exception.Message)" }
        return [pscustomobject]@{
            Cores    = [Environment]::ProcessorCount
            RamGB    = $ramGB
            Disks    = $disks
            Gpus     = @(Get-NvidiaGpu)
            HostName = [System.Net.Dns]::GetHostName()
        }
    }

    function Show-Hardware($Hardware) {
        Write-Step '1/7 Hardware'
        Write-Info ('{0,-10} {1} logical' -f 'cores', $Hardware.Cores)
        Write-Info ('{0,-10} {1} GB' -f 'memory', $Hardware.RamGB)
        foreach ($d in $Hardware.Disks) { Write-Info ('{0,-10} {1} GB free of {2} GB' -f "disk $($d.Drive)", $d.FreeGB, $d.SizeGB) }
        if ($Hardware.Gpus.Count -eq 0) { Write-Info ('{0,-10} no NVIDIA GPU found (TTS will use the CPU)' -f 'gpu') }
        foreach ($g in $Hardware.Gpus) {
            Write-Info ('{0,-10} {1}, {2:N1} GB VRAM, {3:N1} GB free' -f 'gpu', $g.Name, ($g.TotalMB / 1024), ($g.FreeMB / 1024))
        }
    }

    # ------------------------------------------------------------------ 2. settings

    function Get-ProposedName($Hardware) {
        $n = $Hardware.HostName.ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
        $n = $n.Trim('-')
        if ($n.Length -gt 63) { $n = $n.Substring(0, 63).Trim('-') }
        if (-not $n) { $n = 'worker' }
        return $n
    }

    function Get-ProposedWorkDir($Hardware) {
        if ($WorkDir) { return $WorkDir }
        $existing = Find-ExistingWorkDir $Hardware
        if ($existing) { return $existing }
        $best = $Hardware.Disks | Sort-Object FreeGB -Descending | Select-Object -First 1
        if ($best) { return "$($best.Drive)\agentic-video-generation\_worker" }
        return "$env:SystemDrive\agentic-video-generation\_worker"
    }

    function Read-ExistingConfig([string]$Dir) {
        $path = Join-Path $Dir $ConfigName
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
        catch { Exit-Setup "$path is not valid JSON." "Fix or delete it, then re-run setup." }
    }

    function Split-List([string]$Text) { return @($Text -split '[,\s]+' | Where-Object { $_ }) }

    function Read-WorkerSetting($Hardware) {
        Write-Step '2/7 Settings'
        if (-not $Yes) { Write-Info 'Press Enter to keep the value in brackets, or type a new one.' }

        # workDir comes first: the other proposals may come from a config already in it.
        $dir = Read-Setting 'workDir' (Get-ProposedWorkDir $Hardware) { param($v) Test-WorkDirValue $v }
        $dir = [IO.Path]::GetFullPath($dir).TrimEnd('\')
        $old = Read-ExistingConfig $dir
        if ($old) { Write-Info "(the other proposals come from the existing $ConfigName)" }

        $nameDefault = $Name
        if (-not $nameDefault) { $nameDefault = Get-ConfigValue $old 'name' (Get-ProposedName $Hardware) }
        $workerName = Read-Setting 'name' $nameDefault {
            param($v)
            if ($v -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') { 'use lowercase letters, digits and hyphens (at most 63)' }
        }

        $capsDefault = @(Get-ConfigValue $old 'capabilities' $AllCapabilities) -join ','
        $capsText = Read-Setting 'capabilities' $capsDefault {
            param($v)
            $items = @(Split-List $v)
            if ($items.Count -eq 0) { 'list at least one of agent, render, tts' }
            elseif (@($items | Where-Object { $_ -notin $AllCapabilities }).Count -gt 0) { 'only agent, render and tts are allowed' }
        }
        $caps = @($AllCapabilities | Where-Object { $_ -in (Split-List $capsText) })

        $device = Read-Setting 'ttsDevice' ([string](Get-ConfigValue $old 'ttsDevice' 'auto')) {
            param($v)
            if ($v -notin @('auto', 'cuda', 'cpu')) { 'use auto, cuda or cpu' }
        }

        $jobs = Read-Setting 'maxJobs' ([string](Get-ConfigValue $old 'maxJobs' $Hardware.Cores)) {
            param($v)
            if ($v -notmatch '^\d+$' -or [int]$v -lt 1 -or [int]$v -gt 256) { 'use a whole number from 1 up' }
        }

        $cache = Read-Setting 'cacheBudgetGB' ([string](Get-ConfigValue $old 'cacheBudgetGB' 5)) {
            param($v)
            if ($v -notmatch '^\d+$' -or [int]$v -lt 1) { 'use a whole number of GB, 1 or more' }
        }

        $account = Read-Setting 'claudeAccount' ([string](Get-ConfigValue $old 'claudeAccount' 'main')) {
            param($v)
            if ($v -notmatch '^[A-Za-z0-9._-]{1,64}$') { 'use letters, digits, dots, hyphens or underscores' }
        }

        $reposDefault = @(Get-ConfigValue $old 'repos' $DefaultRepos) -join ','
        if (-not $reposDefault) { $reposDefault = '-' }
        $reposText = Read-Setting 'repos' $reposDefault {
            param($v)
            $items = @(Split-List $v | Where-Object { $_ -ne '-' })
            if (@($items | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' }).Count -gt 0) { 'use owner/repo, separated by commas, or - for every repo tagged arkiova-studio' }
        }

        # The engine: -EnginePath, else the one the existing config names, else a clone in the work folder.
        $managedEngine = Join-Path $dir 'motion-agent'
        $engine = $managedEngine
        if ($EnginePath) {
            $engine = [IO.Path]::GetFullPath($EnginePath).TrimEnd('\')
            if (-not (Test-EngineCheckout $engine)) {
                Exit-Setup "-EnginePath $engine is not a motion-agent checkout (no package.json or tts\requirements.txt)." 'Point -EnginePath at a motion-agent clone, or leave it out to clone one into the work folder.'
            }
        } else {
            $oldEngine = [string](Get-ConfigValue $old 'enginePath' '')
            if ($oldEngine -and $oldEngine -ne $managedEngine) {
                if (Test-EngineCheckout $oldEngine) { $engine = $oldEngine }
                else { Write-Warn "the configured engine $oldEngine is gone; using a clone in the work folder instead" }
            }
        }
        $engineNote = 'cloned and updated by setup'
        if ($engine -ne $managedEngine) { $engineNote = 'existing checkout: setup installs its dependencies but never pulls it' }
        Write-Info ('{0,-14} {1} ({2})' -f 'enginePath', $engine, $engineNote)

        $config = [ordered]@{
            name          = $workerName
            capabilities  = [string[]]$caps
            ttsDevice     = $device
            maxJobs       = [int]$jobs
            workDir       = $dir
            enginePath    = $engine
            awsProfile    = $AwsProfile
            claudeAccount = $account
            repos         = [string[]]@(Split-List $reposText | Where-Object { $_ -ne '-' })
            cacheBudgetGB = [int]$cache
            pollSeconds   = [int](Get-ConfigValue $old 'pollSeconds' 45)
        }
        $extra = [ordered]@{}
        if ($old) {
            foreach ($prop in $old.PSObject.Properties) {
                if (-not $config.Contains($prop.Name)) { $extra[$prop.Name] = $prop.Value }
            }
        }
        return [pscustomobject]@{ Config = $config; Old = $old; Extra = $extra; EngineManaged = ($engine -eq $managedEngine) }
    }

    # ------------------------------------------------------------------ 3. tools

    function Get-Node24Version {
        $winget = Find-Winget
        if (-not $winget) { return '' }
        $r = Invoke-Capture -FilePath $winget -ArgumentList 'show', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--versions', '--accept-source-agreements', '--disable-interactivity' -TimeoutSeconds 120
        if ($r.Code -ne 0) { return '' }
        $versions = @($r.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^24\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending)
        if ($versions.Count -gt 0) { return $versions[0] }
        return ''
    }

    function Get-InstallPlan {
        $plan = New-Object System.Collections.Generic.List[object]

        $git = Find-Git
        if ($git) { Write-Ok ('{0,-12} {1}' -f 'Git', (Get-VersionText $git)) }
        else { $plan.Add([pscustomobject]@{ Label = 'Git'; Kind = 'winget'; Id = 'Git.Git'; Version = ''; Why = 'missing' }) }

        $node = Find-Node
        $nodeVersion = ''
        if ($node) { $nodeVersion = Get-VersionText $node }
        if ($node -and $nodeVersion -and ([version]$nodeVersion).Major -ge 24) { Write-Ok ('{0,-12} {1}' -f 'Node.js', $nodeVersion) }
        else {
            $why = 'missing'
            if ($node) { $why = "found $nodeVersion, the studio needs 24" }
            $plan.Add([pscustomobject]@{ Label = 'Node.js 24 LTS'; Kind = 'winget'; Id = 'OpenJS.NodeJS.LTS'; Version = (Get-Node24Version); Why = $why })
        }

        $py = Find-Python311
        if ($py) { Write-Ok ('{0,-12} {1}' -f 'Python 3.11', $py) }
        else { $plan.Add([pscustomobject]@{ Label = 'Python 3.11'; Kind = 'winget'; Id = 'Python.Python.3.11'; Version = ''; Why = 'missing (the engine TTS needs 3.11 exactly)' }) }

        $ffmpeg = Find-Command 'ffmpeg.exe'
        $ffprobe = Find-Command 'ffprobe.exe'
        if ($ffmpeg -and $ffprobe) { Write-Ok ('{0,-12} {1}' -f 'ffmpeg', (Get-VersionText $ffmpeg @('-version'))) }
        else { $plan.Add([pscustomobject]@{ Label = 'ffmpeg + ffprobe'; Kind = 'winget'; Id = 'Gyan.FFmpeg'; Version = ''; Why = 'missing' }) }

        $gh = Find-Gh
        if ($gh) { Write-Ok ('{0,-12} {1}' -f 'GitHub CLI', (Get-VersionText $gh)) }
        else { $plan.Add([pscustomobject]@{ Label = 'GitHub CLI'; Kind = 'winget'; Id = 'GitHub.cli'; Version = ''; Why = 'missing' }) }

        $aws = Find-AwsCli
        $awsVersion = ''
        if ($aws) { $awsVersion = Get-VersionText $aws }
        if ($aws -and $awsVersion -match '^2\.') { Write-Ok ('{0,-12} {1}' -f 'AWS CLI', $awsVersion) }
        else {
            $why = 'missing'
            if ($aws) { $why = "found $awsVersion, need v2" }
            $plan.Add([pscustomobject]@{ Label = 'AWS CLI v2'; Kind = 'winget'; Id = 'Amazon.AWSCLI'; Version = ''; Why = $why })
        }

        $claude = Find-Claude
        $claudeVersion = ''
        if ($claude) { $claudeVersion = Get-VersionText $claude }
        if ($claude -and $claudeVersion -and ([version]$claudeVersion) -ge $MinClaudeVersion) { Write-Ok ('{0,-12} {1}' -f 'Claude Code', $claudeVersion) }
        else {
            $why = 'missing'
            if ($claude) { $why = "found $claudeVersion, need $MinClaudeVersion or newer" }
            $plan.Add([pscustomobject]@{ Label = 'Claude Code'; Kind = 'claude'; Id = ''; Version = ''; Why = $why })
        }
        return $plan.ToArray()
    }

    function Get-PlanLine($Item) {
        if ($Item.Kind -eq 'claude') { return 'Claude Code: official installer (irm https://claude.ai/install.ps1 | iex), npm i -g @anthropic-ai/claude-code if that fails' }
        $line = "$($Item.Label): winget install --id $($Item.Id) --exact"
        if ($Item.Version) { $line += " --version $($Item.Version)" }
        return $line
    }

    function Install-PlannedTool($Item) {
        Write-Run (Get-PlanLine $Item)
        if ($Item.Kind -eq 'winget') {
            $wingetArgs = @('install', '--id', $Item.Id, '--exact', '--source', 'winget', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
            if ($Item.Version) { $wingetArgs += @('--version', $Item.Version) }
            $code = Invoke-Tool -FilePath (Find-Winget) -ArgumentList $wingetArgs
            # 0x8A15002B: nothing newer to install; 0x8A150061: already installed.
            if ($code -notin @(0, -1978335189, -1978335135)) {
                Exit-Setup "winget could not install $($Item.Label) (exit code $code)." "Run 'winget install --id $($Item.Id) --exact' yourself to see why, fix that, then re-run setup."
            }
            return
        }
        $shell = (Get-Process -Id $PID).Path
        $code = Invoke-Tool -FilePath $shell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex'
        Sync-SessionPath
        if ($code -eq 0 -and (Find-Claude)) { return }
        Write-Warn 'the official Claude Code installer did not finish; trying npm i -g @anthropic-ai/claude-code'
        $npm = Find-Npm
        if (-not $npm) { Exit-Setup 'Could not install Claude Code.' 'Install it yourself with: irm https://claude.ai/install.ps1 | iex   then re-run setup.' }
        $code = Invoke-Tool -FilePath $npm -ArgumentList 'install', '-g', '@anthropic-ai/claude-code'
        if ($code -ne 0) { Exit-Setup 'Could not install Claude Code with npm either.' 'Install it yourself with: irm https://claude.ai/install.ps1 | iex   then re-run setup.' }
    }

    function Test-PlannedToolPresent($Item) {
        switch ($Item.Id) {
            'Git.Git' { return [bool](Find-Git) }
            'OpenJS.NodeJS.LTS' { return [bool](Find-Node) -and [bool](Find-Npm) }
            'Python.Python.3.11' { return [bool](Find-Python311) }
            'Gyan.FFmpeg' { return [bool](Find-Command 'ffmpeg.exe') -and [bool](Find-Command 'ffprobe.exe') }
            'GitHub.cli' { return [bool](Find-Gh) }
            'Amazon.AWSCLI' { return [bool](Find-AwsCli) }
            default { return [bool](Find-Claude) }
        }
    }

    function Install-Tool {
        Write-Step '3/7 Tools'
        $plan = @(Get-InstallPlan)
        if ($plan.Count -eq 0) { Write-Ok 'no tools to install' }
        else {
            Write-Info 'Setup will install:'
            foreach ($item in $plan) { Write-Info "  - $(Get-PlanLine $item)   [$($item.Why)]" }
        }
        Write-Info 'Step 5 also installs, inside the work folder and the engine: npm packages (npm ci),'
        Write-Info 'Playwright Chromium, the TTS Python env (PyTorch CUDA or CPU wheels) and the voice models (once).'
        if ($plan.Count -eq 0) { return }
        if ($DryRun) { Write-Dry 'nothing installed (dry run)'; return }
        if (@($plan | Where-Object { $_.Kind -eq 'winget' }).Count -gt 0 -and -not (Find-Winget)) {
            Exit-Setup 'winget is not available on this computer.' "Install 'App Installer' from the Microsoft Store (it provides winget), then re-run setup."
        }
        if (-not (Read-YesNo 'Install these now?')) { Exit-Setup 'Nothing was installed.' 'Install the tools listed above yourself, or re-run setup and answer y.' }

        foreach ($item in $plan) { Install-PlannedTool $item; Sync-SessionPath }
        foreach ($item in $plan) {
            if (-not (Test-PlannedToolPresent $item)) {
                Exit-Setup "$($item.Label) was installed, but this window can't see it yet." 'Open a new PowerShell window and run setup again.'
            }
            Write-Ok "$($item.Label) installed"
        }
    }

    # ------------------------------------------------------------------ 4. logins

    function Confirm-GitHubLogin {
        $gh = Find-Gh
        if (-not $gh) { Write-Dry 'GitHub: would log in with gh auth login -s repo,project,read:org (gh is not installed yet)'; return }
        $status = Invoke-Capture -FilePath $gh -ArgumentList 'auth', 'status', '--hostname', 'github.com' -TimeoutSeconds 60
        if ($status.Code -eq 0) {
            $missing = @()
            if ($status.Text -match 'Token scopes:\s*(.*)') {
                $have = @([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
                $missing = @($GhScopes | Where-Object { $_ -notin $have })
            }
            $status = $null
            if ($missing.Count -eq 0) { Write-Ok 'GitHub: logged in' }
            elseif ($DryRun) { Write-Dry "GitHub: would add the missing scopes $($missing -join ', ') (gh auth refresh)" }
            else {
                Write-Todo "GitHub: the login lacks the scopes $($missing -join ', '); approving them in the browser"
                $code = Invoke-Tool -FilePath $gh -ArgumentList 'auth', 'refresh', '--hostname', 'github.com', '--scopes', ($GhScopes -join ',')
                if ($code -ne 0) { Exit-Setup 'GitHub: could not add the scopes.' "Run 'gh auth refresh -h github.com -s repo,project,read:org' yourself, then re-run setup." }
                Write-Ok 'GitHub: scopes added'
            }
        } elseif ($DryRun) {
            Write-Dry 'GitHub: not logged in; would run gh auth login -s repo,project,read:org'
            return
        } else {
            Write-Todo 'GitHub: not logged in. Log in with the GitHub account the owner added to the arkiova org.'
            $code = Invoke-Tool -FilePath $gh -ArgumentList 'auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web', '--scopes', ($GhScopes -join ',')
            if ($code -ne 0) { Exit-Setup 'GitHub: the login did not finish.' "Run 'gh auth login -s repo,project,read:org' yourself, then re-run setup." }
            Write-Ok 'GitHub: logged in'
        }
        if (-not $DryRun) {
            # Lets plain git (pull, fetch) use the gh login for github.com.
            $null = Invoke-Capture -FilePath $gh -ArgumentList 'auth', 'setup-git', '--hostname', 'github.com' -TimeoutSeconds 60
        }
    }

    function Test-AwsProfile([string]$Aws) {
        # The output holds masked keys, so it is only matched here and never printed.
        $r = Invoke-Capture -FilePath $Aws -ArgumentList 'configure', 'list', '--profile', $AwsProfile -TimeoutSeconds 60
        $ok = ($r.Code -eq 0) -and ($r.Text -notmatch 'access_key\s+<not set>') -and ($r.Text -notmatch 'secret_key\s+<not set>') -and ($r.Text -notmatch 'region\s+<not set>')
        $r = $null
        return $ok
    }

    function Read-StudioDiscovery([string]$Aws) {
        $r = Invoke-Capture -FilePath $Aws -ArgumentList 'ssm', 'get-parameter', '--name', $SsmParameter, '--profile', $AwsProfile, '--query', 'Parameter.Value', '--output', 'text' -TimeoutSeconds 60
        if ($r.Code -eq 0) {
            try {
                $cfg = $r.Text | ConvertFrom-Json
                return [pscustomobject]@{ Ok = $true; ApiUrl = [string]$cfg.apiUrl; Why = '' }
            } catch { return [pscustomobject]@{ Ok = $false; ApiUrl = ''; Why = 'the parameter is not JSON' } }
        }
        # Only a short reason is shown: AWS error text can include the account id.
        $why = "exit code $($r.Code)"
        if ($r.Text -match 'Unable to locate credentials') { $why = 'no credentials' }
        elseif ($r.Text -match 'specify a region') { $why = 'no region set' }
        elseif ($r.Text -match 'Could not connect|Connect timeout|getaddrinfo') { $why = 'no connection to AWS' }
        elseif ($r.Text -match '\((\w+)\) when calling') { $why = $Matches[1] }
        return [pscustomobject]@{ Ok = $false; ApiUrl = ''; Why = $why }
    }

    function Confirm-AwsProfile {
        $aws = Find-AwsCli
        if (-not $aws) { Write-Dry "AWS: would set up the profile $AwsProfile (the AWS CLI is not installed yet)"; return }
        if (-not (Test-AwsProfile $aws)) {
            if ($DryRun) { Write-Dry "AWS: profile $AwsProfile is missing or incomplete; would run aws configure --profile $AwsProfile"; return }
            Write-Todo "AWS: the profile $AwsProfile is missing or incomplete."
            Write-Info "The key comes from the owner: they create an access key for the IAM user $AwsIamUser"
            Write-Info '(IAM > Users > arkiova-studio-worker > Security credentials > Create access key) and'
            Write-Info 'send you the access key ID, the secret access key and the region, over a private channel.'
            Write-Info 'Type them into the prompts below; press Enter for the output format. The AWS CLI keeps'
            Write-Info 'them in its own files (~\.aws); this script never reads, prints or stores them.'
            $code = Invoke-Tool -FilePath $aws -ArgumentList 'configure', '--profile', $AwsProfile
            if ($code -ne 0 -or -not (Test-AwsProfile $aws)) {
                Exit-Setup "AWS: the profile $AwsProfile is still incomplete." "Run 'aws configure --profile $AwsProfile' with the key and region the owner sent, then re-run setup."
            }
        }
        $found = Read-StudioDiscovery $aws
        if ($found.Ok) {
            $State.ApiUrl = $found.ApiUrl
            Write-Ok "AWS: profile $AwsProfile reads $SsmParameter"
        } elseif ($DryRun) {
            Write-Warn "AWS: profile $AwsProfile is set but can't read $SsmParameter ($($found.Why))"
        } else {
            Exit-Setup "AWS: profile $AwsProfile can't read $SsmParameter ($($found.Why))." "Check the key and region with the owner, run 'aws configure --profile $AwsProfile' again, then re-run setup."
        }
    }

    function Test-ClaudeLogin([string]$Claude) {
        $r = Invoke-Capture -FilePath $Claude -ArgumentList 'auth', 'status' -TimeoutSeconds 60
        return ($r.Code -eq 0)
    }

    function Confirm-ClaudeLogin([string]$Account) {
        $claude = Find-Claude
        if (-not $claude) { Write-Dry 'Claude Code: would ask you to log in (claude is not installed yet)'; return }
        if (Test-ClaudeLogin $claude) { Write-Ok 'Claude Code: logged in'; return }
        if ($DryRun) { Write-Dry 'Claude Code: not logged in; would ask you to run claude and log in, then wait'; return }
        Write-Todo 'Claude Code: not logged in.'
        Write-Info "Open another terminal, run:  claude   and log in with the Claude account for the label '$Account'."
        Write-Info 'Then come back here.'
        while (-not (Test-ClaudeLogin $claude)) {
            $answer = Read-Console '    Press Enter once you have logged in (or type q to stop)'
            if ($answer -match '^\s*q') { Exit-Setup 'Claude Code is not logged in.' 'Run claude, log in, then re-run setup.' }
            if (-not (Test-ClaudeLogin $claude)) { Write-Warn 'still not logged in' }
        }
        Write-Ok 'Claude Code: logged in'
    }

    # ------------------------------------------------------------------ 5. code and dependencies

    function Close-WorkerProcess([string]$Dir) {
        $studioDir = Join-Path $Dir 'studio'
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($studioDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        foreach ($p in $procs) {
            $null = Invoke-Capture -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList '/PID', "$($p.ProcessId)", '/T', '/F' -TimeoutSeconds 30
        }
    }

    # The worker holds files open in node_modules and the TTS env, so it stops before they change.
    function Suspend-RunningWorker([string]$Dir) {
        if ($State.WorkerStopped) { return }
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task -or [string]$task.State -ne 'Running') { return }
        $State.WorkerStopped = $true
        if ($DryRun) { Write-Dry 'would stop the running worker first and start it again at the end'; return }
        Write-Run 'stopping the running worker while its files change (it starts again at the end)'
        Stop-ScheduledTask -TaskName $TaskName
        Close-WorkerProcess $Dir
    }

    function Sync-Repository([string]$Repo, [string]$Dir) {
        $git = Find-Git
        if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
            if ($DryRun) { Write-Dry "would update $Dir from $Repo (git pull --ff-only)"; return }
            $before = (Invoke-Capture -FilePath $git -ArgumentList '-C', $Dir, 'rev-parse', 'HEAD').Text
            $branch = Invoke-Capture -FilePath $git -ArgumentList '-C', $Dir, 'symbolic-ref', '--short', '-q', 'HEAD'
            if ($branch.Code -ne 0) {
                $null = Invoke-Tool -FilePath $git -ArgumentList '-C', $Dir, 'fetch', '--quiet'
                Write-Ok "$Repo is at a pinned commit; fetched, not moved"
                return
            }
            $code = Invoke-Tool -FilePath $git -ArgumentList '-C', $Dir, 'pull', '--ff-only', '--quiet'
            if ($code -ne 0) {
                Exit-Setup "Could not update $Dir." "Look at it with 'git -C `"$Dir`" status', commit, stash or discard the local changes (or delete the folder), then re-run setup."
            }
            $after = (Invoke-Capture -FilePath $git -ArgumentList '-C', $Dir, 'rev-parse', '--short', 'HEAD').Text
            $before = (Invoke-Capture -FilePath $git -ArgumentList '-C', $Dir, 'rev-parse', '--short', $before).Text
            if ($before -eq $after) { Write-Ok "$Repo is up to date ($after)" }
            else { Write-Ok "$Repo updated $before -> $after" }
            return
        }
        if ((Test-Path -LiteralPath $Dir) -and @(Get-ChildItem -LiteralPath $Dir -Force).Count -gt 0) {
            Exit-Setup "$Dir exists but is not a git clone." 'Move or delete that folder, then re-run setup.'
        }
        if ($DryRun) { Write-Dry "would clone $Repo into $Dir"; return }
        Write-Run "cloning $Repo into $Dir"
        $code = Invoke-Tool -FilePath (Find-Gh) -ArgumentList 'repo', 'clone', $Repo, $Dir, '--', '--quiet'
        if ($code -ne 0) { Exit-Setup "Could not clone $Repo." "Check that your GitHub account can see $Repo (ask the owner for access), then re-run setup." }
        Write-Ok "cloned $Repo"
    }

    function Test-NodeDependencyCurrent([string]$Dir) {
        $lock = Join-Path $Dir 'package-lock.json'
        $stamp = Join-Path $Dir "node_modules\$StampName"
        if (-not (Test-Path -LiteralPath $lock) -or -not (Test-Path -LiteralPath $stamp)) { return $false }
        return ((Get-Content -Raw -LiteralPath $stamp).Trim() -eq (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash)
    }

    function Install-NodeDependency([string]$Dir, [string]$Label, [string]$WorkerDir) {
        if (Test-NodeDependencyCurrent $Dir) { Write-Ok "$Label npm packages are current"; return }
        if ($DryRun) { Write-Dry "would run npm ci in $Dir"; return }
        $lock = Join-Path $Dir 'package-lock.json'
        if (-not (Test-Path -LiteralPath $lock)) { Exit-Setup "$Dir has no package-lock.json, so npm ci can't run." "Tell the owner that $Label needs a committed package-lock.json." }
        Suspend-RunningWorker $WorkerDir
        Write-Run "npm ci in $Dir"
        $code = Invoke-Tool -FilePath (Find-Npm) -ArgumentList 'ci', '--no-audit', '--no-fund' -WorkingDirectory $Dir
        if ($code -ne 0) { Exit-Setup "npm ci failed in $Dir." 'Read the npm error above; a network hiccup just needs a re-run. Then re-run setup.' }
        Write-TextFile (Join-Path $Dir "node_modules\$StampName") (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
        Write-Ok "$Label npm packages installed"
    }

    function Install-PlaywrightChromium([string]$Engine) {
        if ($DryRun) { Write-Dry "would run npx playwright install chromium in $Engine (a no-op when it is already there)"; return }
        Write-Run 'npx playwright install chromium'
        $code = Invoke-Tool -FilePath (Find-Npx) -ArgumentList 'playwright', 'install', 'chromium' -WorkingDirectory $Engine
        if ($code -ne 0) { Exit-Setup 'Playwright could not install Chromium.' "Run 'npx playwright install chromium' in $Engine to see why, then re-run setup." }
        Write-Ok 'Playwright Chromium is installed'
    }

    function Get-RequirementPin([string[]]$Lines, [string]$Package) {
        foreach ($line in $Lines) {
            if ($line -match ('^\s*' + [regex]::Escape($Package) + '\s*==\s*([A-Za-z0-9.+]+)')) { return $Matches[1] }
        }
        return ''
    }

    function Read-TtsStamp([string]$Venv) {
        $path = Join-Path $Venv $StampName
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) } catch { return $null }
    }

    function Install-VoiceModel([string]$Engine, [string]$Python) {
        # Downloads what the engine's first TTS run would, with the engine's own code: the
        # Chatterbox weights (its from_pretrained, stopped before the model loads), the
        # whisper-tiny.en speech check and torchaudio's MMS_FA word aligner.
        $code = @'
import os, sys
engine = sys.argv[1]
sys.path.insert(0, os.path.join(engine, "tts", "src"))
from chatterbox import mtl_tts
cls = mtl_tts.ChatterboxMultilingualTTS
cls.from_local = classmethod(lambda c, ckpt_dir, device: ckpt_dir)
print("voice model:", cls.from_pretrained("cpu"), flush=True)
from transformers import pipeline
pipeline("automatic-speech-recognition", model="openai/whisper-tiny.en", device=-1)
print("speech check: openai/whisper-tiny.en", flush=True)
import torchaudio
torchaudio.pipelines.MMS_FA.get_model(with_star=False)
print("word aligner: torchaudio MMS_FA", flush=True)
'@
        $file = Join-Path ([IO.Path]::GetTempPath()) ('arkiova-voice-models-{0}.py' -f [guid]::NewGuid().ToString('N'))
        Write-TextFile $file $code
        $saved = $env:PYTHONUTF8
        try {
            $env:PYTHONUTF8 = '1'
            $exit = Invoke-Tool -FilePath $Python -ArgumentList $file, $Engine -WorkingDirectory $Engine
        } finally {
            $env:PYTHONUTF8 = $saved
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        if ($exit -ne 0) { Exit-Setup 'Could not download the voice models.' 'Check the network (Hugging Face and download.pytorch.org must be reachable), then re-run setup.' }
    }

    function Install-TtsEnvironment([string]$Engine, [bool]$HasGpu, [string[]]$Capabilities, [string]$WorkerDir) {
        if ('tts' -notin $Capabilities) { Write-Ok 'TTS env skipped: this worker has no tts capability'; return }
        $variant = 'cpu'
        if ($HasGpu) { $variant = 'cuda' }
        $venv = Join-Path $Engine 'tts\.venv'
        $req = Join-Path $Engine 'tts\requirements.txt'
        if (-not (Test-Path -LiteralPath $req)) {
            if ($DryRun) { Write-Dry "would create $venv with Python 3.11 and install tts\requirements.txt (PyTorch $variant wheels)"; Write-Dry 'would download the voice models once (about 4.5 GB)'; return }
            Exit-Setup "The engine has no tts\requirements.txt ($req)." 'Update the engine (re-run setup) or ask the owner.'
        }
        $lines = @(Get-Content -LiteralPath $req)
        $torch = Get-RequirementPin $lines 'torch'
        $torchaudio = Get-RequirementPin $lines 'torchaudio'
        $cudaIndex = 'https://download.pytorch.org/whl/cu126'
        foreach ($line in $lines) {
            if ($line -match '^\s*--(extra-)?index-url\s+(https://download\.pytorch\.org/whl/cu\d+)') { $cudaIndex = $Matches[2] }
        }
        $index = 'https://download.pytorch.org/whl/cpu'
        if ($HasGpu) { $index = $cudaIndex }
        $reqHash = (Get-FileHash -LiteralPath $req -Algorithm SHA256).Hash
        $python = Join-Path $venv 'Scripts\python.exe'
        $stamp = Read-TtsStamp $venv
        $venvExists = Test-Path -LiteralPath $python
        $depsCurrent = $venvExists -and $stamp -and $stamp.requirements -eq $reqHash -and $stamp.torch -eq $variant
        $modelsDone = $venvExists -and $stamp -and $stamp.models -eq $true
        $wheelNote = "PyTorch $torch CPU wheels (no NVIDIA GPU)"
        if ($HasGpu) { $wheelNote = "PyTorch $torch CUDA wheels from $index (NVIDIA GPU found)" }

        if ($depsCurrent) { Write-Ok "TTS env is current ($venv, $variant)" }
        elseif ($DryRun) {
            if ($venvExists) { Write-Dry "would update $venv`: $wheelNote, then tts\requirements.txt" }
            else { Write-Dry "would create $venv with Python 3.11: $wheelNote, then tts\requirements.txt" }
        } else {
            Suspend-RunningWorker $WorkerDir
            if (-not $venvExists) {
                $py311 = Find-Python311
                if (-not $py311) { Exit-Setup 'Python 3.11 is not installed.' 'Re-run setup so it installs Python 3.11 (winget Python.Python.3.11).' }
                Write-Run "creating $venv with Python 3.11"
                if ((Invoke-Tool -FilePath $py311 -ArgumentList '-m', 'venv', $venv) -ne 0) { Exit-Setup "Could not create $venv." "Delete $venv if it is half made, then re-run setup." }
            }
            $pip = @('-m', 'pip', '--disable-pip-version-check', '--no-input')
            $null = Invoke-Tool -FilePath $python -ArgumentList ($pip + @('install', '--upgrade', 'pip'))
            if ($torch) {
                $torchArgs = $pip + @('install', "torch==$torch")
                if ($torchaudio) { $torchArgs += "torchaudio==$torchaudio" }
                $torchArgs += @('--index-url', $index, '--extra-index-url', 'https://pypi.org/simple')
                # A venv built before (or for the other device) is switched in place.
                if ($venvExists -and (-not $stamp -or $stamp.torch -ne $variant)) { $torchArgs += @('--force-reinstall', '--no-deps') }
                Write-Run "installing $wheelNote"
                if ((Invoke-Tool -FilePath $python -ArgumentList $torchArgs) -ne 0) { Exit-Setup 'Could not install PyTorch.' 'Read the pip error above (often the network), then re-run setup.' }
            }
            Write-Run 'installing tts\requirements.txt'
            if ((Invoke-Tool -FilePath $python -ArgumentList ($pip + @('install', '-r', $req)) -WorkingDirectory $Engine) -ne 0) {
                Exit-Setup 'Could not install the TTS requirements.' 'Read the pip error above, then re-run setup.'
            }
            Write-TextFile (Join-Path $venv $StampName) (@{ requirements = $reqHash; torch = $variant; models = $modelsDone } | ConvertTo-Json -Compress)
            Write-Ok "TTS env ready ($variant)"
        }

        if ($modelsDone) { Write-Ok 'voice models already downloaded' }
        elseif ($DryRun) { Write-Dry 'would download the voice models once: Chatterbox, whisper-tiny.en and the MMS_FA aligner (about 4.5 GB, in your user cache)' }
        else {
            Write-Run 'downloading the voice models once (about 4.5 GB; this takes a while)'
            Install-VoiceModel $Engine $python
            Write-TextFile (Join-Path $venv $StampName) (@{ requirements = $reqHash; torch = $variant; models = $true } | ConvertTo-Json -Compress)
            Write-Ok 'voice models downloaded'
        }
    }

    # ------------------------------------------------------------------ 6. config, doctor, dry pass

    function ConvertTo-JsonText([string]$Text) { return '"' + $Text.Replace('\', '\\').Replace('"', '\"') + '"' }

    function Format-WorkerConfig($Config, $Extra) {
        $list = { param($items) '[' + ((@($items) | ForEach-Object { ConvertTo-JsonText $_ }) -join ', ') + ']' }
        # Each element is parenthesized: the comma operator binds tighter than +.
        $lines = @(
            ('  "name": ' + (ConvertTo-JsonText $Config.name)),
            ('  "capabilities": ' + (& $list $Config.capabilities)),
            ('  "ttsDevice": ' + (ConvertTo-JsonText $Config.ttsDevice)),
            ('  "maxJobs": ' + [int]$Config.maxJobs),
            ('  "workDir": ' + (ConvertTo-JsonText $Config.workDir)),
            ('  "enginePath": ' + (ConvertTo-JsonText $Config.enginePath)),
            ('  "awsProfile": ' + (ConvertTo-JsonText $Config.awsProfile)),
            ('  "claudeAccount": ' + (ConvertTo-JsonText $Config.claudeAccount)),
            ('  "repos": ' + (& $list $Config.repos)),
            ('  "cacheBudgetGB": ' + [int]$Config.cacheBudgetGB),
            ('  "pollSeconds": ' + [int]$Config.pollSeconds)
        )
        if ($Extra) {
            foreach ($key in $Extra.Keys) { $lines += ('  ' + (ConvertTo-JsonText $key) + ': ' + (ConvertTo-Json -InputObject $Extra[$key] -Compress -Depth 20)) }
        }
        return "{`n" + ($lines -join ",`n") + "`n}`n"
    }

    function Get-StudioEntry([string]$StudioDir) {
        $pkgPath = Join-Path $StudioDir 'package.json'
        if (-not (Test-Path -LiteralPath $pkgPath)) { return $null }
        $pkg = Get-Content -Raw -LiteralPath $pkgPath | ConvertFrom-Json
        if (-not ($pkg.PSObject.Properties.Name -contains 'bin')) { return $null }
        $bin = $null
        if ($pkg.bin -is [string]) { $bin = $pkg.bin }
        elseif ($pkg.bin.PSObject.Properties.Name -contains 'studio') { $bin = $pkg.bin.studio }
        if (-not $bin) { return $null }
        return (Join-Path $StudioDir $bin)
    }

    function Get-StudioCommand([string]$Dir) {
        $entry = Get-StudioEntry (Join-Path $Dir 'studio')
        if (-not $entry) {
            Exit-Setup "The studio clone has no 'studio' command (package.json bin)." 'Re-run setup to update the clone, or ask the owner whether the worker CLI is published yet.'
        }
        return $entry
    }

    # `studio setup` writes the config itself when it takes every setting as a flag; the help
    # is read with no console input, so a version without those flags can't stop to ask.
    function Test-StudioSetupFlag([string]$Entry, [string]$Dir) {
        $r = Invoke-Capture -FilePath (Find-Node) -ArgumentList $Entry, 'setup', '--help' -WorkingDirectory $Dir -TimeoutSeconds 30
        if ($r.Code -ne 0) { return $false }
        foreach ($flag in @('--name', '--capabilities', '--tts-device', '--max-jobs', '--work-dir', '--engine-path', '--aws-profile', '--claude-account', '--repos', '--cache-budget-gb', '--poll-seconds')) {
            if ($r.Text -notmatch ([regex]::Escape($flag) + '\b')) { return $false }
        }
        return $true
    }

    function Write-WorkerConfig($Settings) {
        $config = $Settings.Config
        $path = Join-Path $config.workDir $ConfigName
        $text = Format-WorkerConfig $config $Settings.Extra
        if ($Settings.Old) {
            $oldConfig = [ordered]@{}
            foreach ($key in @($config.Keys)) { $oldConfig[$key] = Get-ConfigValue $Settings.Old $key $null }
            $same = $true
            try { $same = (Format-WorkerConfig $oldConfig $Settings.Extra) -eq $text } catch { $same = $false }
            if ($same) { Write-Ok "$path is unchanged"; return }
        }
        if ($DryRun) {
            Write-Dry "would write $path"
            foreach ($line in ($text.TrimEnd() -split "`n")) { Write-Info "        $line" }
            return
        }
        $entry = Get-StudioEntry (Join-Path $config.workDir 'studio')
        if ($entry -and (Test-StudioSetupFlag $entry $config.workDir)) {
            # --yes: take the flags instead of asking again. studio setup also writes a pointer
            # in the home folder, so `studio` finds this config from any folder.
            $flags = @($entry, 'setup', '--yes',
                '--name', $config.name, '--capabilities', ($config.capabilities -join ','), '--tts-device', $config.ttsDevice,
                '--max-jobs', "$($config.maxJobs)", '--work-dir', $config.workDir, '--engine-path', $config.enginePath,
                '--aws-profile', $config.awsProfile, '--claude-account', $config.claudeAccount,
                # --repos= (empty): every repo tagged arkiova-studio, and an old list is cleared. One
                # argument, because Windows PowerShell drops an empty one.
                ('--repos=' + ($config.repos -join ',')),
                '--cache-budget-gb', "$($config.cacheBudgetGB)", '--poll-seconds', "$($config.pollSeconds)")
            Write-Run 'studio setup (writes the config)'
            if ((Invoke-Tool -FilePath (Find-Node) -ArgumentList $flags -WorkingDirectory $config.workDir) -ne 0) {
                Exit-Setup 'studio setup failed.' 'Read its error above, fix it, then re-run setup.'
            }
        } else {
            Write-TextFile $path $text
        }
        Write-Ok "wrote $path"
    }

    function Invoke-StudioCheck($Config) {
        if ($DryRun) {
            Write-Dry 'would run: studio doctor'
            Write-Dry 'would run: studio worker --once --dry'
            return
        }
        $entry = Get-StudioCommand $Config.workDir
        $node = Find-Node
        $configPath = Join-Path $Config.workDir $ConfigName
        Write-Run 'studio doctor'
        if ((Invoke-Tool -FilePath $node -ArgumentList $entry, 'doctor', '--config', $configPath -WorkingDirectory $Config.workDir) -ne 0) {
            Exit-Setup 'studio doctor found a problem (see above).' 'Fix what it reports, then re-run setup.'
        }
        Write-Ok 'studio doctor passed'
        Write-Run 'studio worker --once --dry'
        if ((Invoke-Tool -FilePath $node -ArgumentList $entry, 'worker', '--once', '--dry', '--config', $configPath -WorkingDirectory $Config.workDir) -ne 0) {
            Exit-Setup 'The dry worker pass failed (see above).' 'Fix what it reports, then re-run setup.'
        }
        Write-Ok 'dry worker pass finished'
    }

    # ------------------------------------------------------------------ 7. autostart

    function Get-TaskCommand([string]$Dir) {
        return [pscustomobject]@{
            Execute   = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            Arguments = ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Dir $RunnerName))
        }
    }

    function Register-WorkerTask($Config) {
        $dir = $Config.workDir
        $runner = Join-Path $dir $RunnerName
        $cmd = Get-TaskCommand $dir
        $runnerCurrent = (Test-Path -LiteralPath $runner) -and
            (((Get-Content -Raw -LiteralPath $runner) -replace "`r`n", "`n") -eq ($RunnerScript -replace "`r`n", "`n"))
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskCurrent = $task -and @($task.Actions).Count -eq 1 -and $task.Actions[0].Execute -eq $cmd.Execute -and
            $task.Actions[0].Arguments -eq $cmd.Arguments -and $task.Actions[0].WorkingDirectory -eq $dir
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

        if ($runnerCurrent -and $taskCurrent) { Write-Ok "scheduled task '$TaskName' is already set up"; return }
        if ($DryRun) {
            Write-Dry "would write $runner"
            Write-Dry "would register the scheduled task '$TaskName': at log-on of $user, hidden,"
            Write-Dry "restarts on failure 3 times 1 minute apart, no time limit, logs in $dir\logs"
            return
        }
        if (-not $runnerCurrent) { Write-TextFile $runner $RunnerScript }
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'logs')
        if (-not $taskCurrent) {
            $timing = @{
                RestartCount               = 3
                RestartInterval            = (New-TimeSpan -Minutes 1)
                ExecutionTimeLimit         = [TimeSpan]::Zero
                AllowStartIfOnBatteries    = $true
                DontStopIfGoingOnBatteries = $true
                StartWhenAvailable         = $true
                MultipleInstances          = 'IgnoreNew'
            }
            $register = @{
                TaskName    = $TaskName
                Action      = (New-ScheduledTaskAction -Execute $cmd.Execute -Argument $cmd.Arguments -WorkingDirectory $dir)
                Trigger     = (New-ScheduledTaskTrigger -AtLogOn -User $user)
                Settings    = (New-ScheduledTaskSettingsSet @timing)
                Principal   = (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited)
                Description = 'Runs the Arkiova Studio worker (studio worker) at log-on. Set up by arkiova/studio-starter.'
                Force       = $true
            }
            try { $null = Register-ScheduledTask @register }
            catch {
                Exit-Setup "Could not register the scheduled task: $($_.Exception.Message)" 'Run setup again from PowerShell opened with "Run as administrator", or pass -NoAutostart and start the worker yourself.'
            }
        }
        Write-Ok "scheduled task '$TaskName' registered: at log-on, hidden, restarts on failure 3 times 1 minute apart"
        # A new or changed task starts now rather than at the next log-on (unless setup stopped
        # the worker earlier; it is started again at the end).
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and [string]$task.State -eq 'Ready' -and -not $State.WorkerStopped) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Ok 'worker started'
        }
    }

    # ------------------------------------------------------------------ uninstall

    function Test-WorkerFolder([string]$Dir) {
        if ($Dir.TrimEnd('\').Length -le 3) { return $false }
        if (@(Get-ChildItem -LiteralPath $Dir -Force).Count -eq 0) { return $true }
        foreach ($marker in @($ConfigName, $RunnerName, 'studio', 'motion-agent', 'logs')) {
            if (Test-Path -LiteralPath (Join-Path $Dir $marker)) { return $true }
        }
        return $false
    }

    function Invoke-Uninstall {
        Write-Step 'Uninstall'
        $hw = [pscustomobject]@{ Disks = @() }
        try {
            $hw.Disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{ Drive = $_.DeviceID } })
        } catch { Write-Warn 'could not list the drives' }
        $dir = $WorkDir
        if (-not $dir) { $dir = Find-ExistingWorkDir $hw }
        if ($dir) { $dir = [IO.Path]::GetFullPath($dir).TrimEnd('\') }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Ok "no scheduled task '$TaskName'" }
        elseif ($DryRun) { Write-Dry "would stop and remove the scheduled task '$TaskName'" }
        else {
            if ([string]$task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName }
            if ($dir) { Close-WorkerProcess $dir }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Ok "removed the scheduled task '$TaskName'"
        }

        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { Write-Ok 'no work folder found' }
        elseif (-not (Test-WorkerFolder $dir)) {
            Exit-Setup "$dir does not look like a worker folder, so setup won't delete it." 'Delete it yourself if you are sure, or pass the right -WorkDir.'
        } elseif ($DryRun) { Write-Dry "would ask, then delete $dir (clones, cache, logs, config)" }
        elseif (Read-YesNo "Delete $dir and everything in it (clones, cache, logs, config)?" $false) {
            Close-WorkerProcess $dir
            $null = Invoke-Capture -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList '/d', '/c', 'rd', '/s', '/q', $dir -TimeoutSeconds 600
            if (Test-Path -LiteralPath $dir) { Exit-Setup "Could not delete all of $dir." 'Close anything using it (editors, terminals), then delete it yourself.' }
            Write-Ok "deleted $dir"
        } else { Write-Ok "kept $dir" }
        Write-Info 'The tools, the logins and the AWS profile stay installed. An engine checkout given with -EnginePath is never touched.'
    }

    # ------------------------------------------------------------------ main

    function Invoke-Setup {
        $hw = Get-Hardware
        Show-Hardware $hw
        $settings = Read-WorkerSetting $hw
        $config = $settings.Config

        Install-Tool

        Write-Step '4/7 Logins'
        Confirm-GitHubLogin
        Confirm-AwsProfile
        Confirm-ClaudeLogin $config.claudeAccount

        Write-Step '5/7 Code and dependencies'
        if (-not $DryRun -and -not (Test-Path -LiteralPath $config.workDir)) { $null = New-Item -ItemType Directory -Force -Path $config.workDir }
        $studioDir = Join-Path $config.workDir 'studio'
        Sync-Repository $StudioRepo $studioDir
        if ($settings.EngineManaged) { Sync-Repository $EngineRepo $config.enginePath }
        else { Write-Ok "engine: using $($config.enginePath) as it is (not pulled)" }
        Install-NodeDependency $studioDir 'studio' $config.workDir
        Install-NodeDependency $config.enginePath 'engine' $config.workDir
        Install-PlaywrightChromium $config.enginePath
        Install-TtsEnvironment $config.enginePath ($hw.Gpus.Count -gt 0) $config.capabilities $config.workDir

        Write-Step '6/7 Worker config'
        Write-WorkerConfig $settings
        Invoke-StudioCheck $config

        Write-Step '7/7 Autostart'
        if ($NoAutostart) { Write-Ok 'skipped (-NoAutostart)' }
        else { Register-WorkerTask $config }
        if ($State.WorkerStopped -and -not $DryRun -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Ok 'worker started again'
        }

        Write-Step 'Done'
        if ($DryRun) { Write-Info 'Dry run: nothing was installed, cloned, written or registered.' }
        Write-Info ('{0,-10} {1} ({2}), up to {3} jobs' -f 'worker', $config.name, ($config.capabilities -join ', '), $config.maxJobs)
        Write-Info ('{0,-10} {1}' -f 'config', (Join-Path $config.workDir $ConfigName))
        Write-Info ('{0,-10} {1}' -f 'logs', (Join-Path $config.workDir 'logs'))
        if ($State.ApiUrl) { Write-Info ('{0,-10} {1}/workers?t=<the workers link token from the owner>' -f 'workers', $State.ApiUrl.TrimEnd('/')) }
        Write-Info ('{0,-10} {1}' -f 'stop', "Stop-ScheduledTask -TaskName '$TaskName'")
        Write-Info ('{0,-10} {1}' -f 'update', 'run the same one-liner again')
        Write-Info ('{0,-10} {1}' -f 'uninstall', "& ([scriptblock]::Create((irm $RawBase/setup.ps1))) -Uninstall")
    }

    try {
        $onCore = $PSVersionTable.PSEdition -eq 'Core'
        $isWin = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        if ($onCore -and -not $isWin) {
            Exit-Setup 'setup.ps1 is for Windows.' "On Linux or macOS run: curl -fsSL $RawBase/setup.sh | bash"
        }
        Write-Host ''
        Write-Host 'Arkiova Studio worker setup' -ForegroundColor White
        if ($DryRun) { Write-Host 'DRY RUN: nothing will be installed, cloned, written or registered.' -ForegroundColor Magenta }
        if ($Uninstall) { Invoke-Uninstall } else { Invoke-Setup }
    } catch {
        $ex = $_.Exception
        Write-Host ''
        Write-Host "FAILED  $($ex.Message)" -ForegroundColor Red
        if ($ex.Data.Contains('Next')) { Write-Host "Next:   $($ex.Data['Next'])" -ForegroundColor Yellow }
        else {
            Write-Host "        at $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
            Write-Host 'Next:   fix the error above, then re-run setup (it picks up where it stopped).' -ForegroundColor Yellow
        }
        Set-Variable -Name ArkiovaSetupFailed -Value $true -Scope 1
    }
}
if ($ArkiovaSetupFailed -and $PSCommandPath) { exit 1 }
