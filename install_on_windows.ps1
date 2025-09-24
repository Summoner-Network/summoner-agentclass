# install_on_windows.ps1 — PowerShell-only manager (uses core\.venv exclusively)
# ==============================================================================
# How to use this script
# ==============================================================================
# > First, you may need to use the following command to allow the script to run:
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#
# > Then, you can run the script as follows:
# .\install_on_windows.ps1 setup
# .\install_on_windows.ps1 test_server_bg                # start in background
# .\install_on_windows.ps1 status                        # see PID + port status
# .\install_on_windows.ps1 stop_server                   # stop cleanly
#
# > or foreground run (Ctrl+C may not work reliably on Windows):
# .\install_on_windows.ps1 test_server
#
# > choose port or force-terminate listeners:
# .\install_on_windows.ps1 test_server_bg -Port 8890
# .\install_on_windows.ps1 stop_server -Port 8890
# ==============================================================================
[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('setup','delete','reset','deps','test_server','test_server_bg','stop_server','status','clean','use_core_venv')]
  [string]$Action = 'setup',

  # Options for server actions
  [int]$Port = 8888,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PythonSpec {
  $candidates = @(
    @{ Program='python';  Args=@()     },
    @{ Program='py';      Args=@('-3') },
    @{ Program='python3'; Args=@()     }
  )
  foreach ($c in $candidates) {
    $cmd = Get-Command $c.Program -ErrorAction SilentlyContinue
    if ($cmd) {
      & $c.Program @($c.Args) -c 'import sys; raise SystemExit(0 if sys.version_info[0]==3 else 1)' | Out-Null
      if ($LASTEXITCODE -eq 0) { return $c }
    }
  }
  throw "Python 3 not found on PATH. Install Python 3 and ensure 'python' or 'py' is available."
}

function Resolve-VenvPaths([string]$VenvDir) {
  $exe = Join-Path $VenvDir 'Scripts\python.exe'
  $nix = Join-Path $VenvDir 'bin\python'
  if (Test-Path $exe) { return @{ Py=$exe; Bin=(Join-Path $VenvDir 'Scripts') } }
  if (Test-Path $nix) { return @{ Py=$nix; Bin=(Join-Path $VenvDir 'bin') } }
  return @{ Py=$null; Bin=$null }
}

function Ensure-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "'git' not found on PATH."
  }
}

# ---------- Paths (Option A layout) ----------
$ROOT     = Split-Path -Parent $MyInvocation.MyCommand.Path
$SRC      = Join-Path $ROOT 'core'        # summoner-core repository path
$VENVDIR  = Join-Path $SRC  '.venv'       # venv lives inside repo
$DATA     = Join-Path $SRC  'desktop_data'
$PIDFILE  = Join-Path $ROOT '.server.pid' # background server PID

function Write-EnvFile {
  $envPath = Join-Path $SRC '.env'
@"
DATABASE_URL=postgres://user:pass@localhost:5432/mydb
SECRET_KEY=supersecret
"@ | Set-Content -Path $envPath -Encoding utf8
}

function Free-Port([int]$p) {
  $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
  if ($conns) {
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($pid in $pids) {
      try {
        Stop-Process -Id $pid -Force -ErrorAction Stop
      } catch {
        Write-Warning ("Failed to stop process {0} listening on port {1}: {2}" -f $pid, $p, $_.Exception.Message)
      }
    }
  }
}

function Is-ProcessRunning([int]$pid) {
  try { Get-Process -Id $pid -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Bootstrap {
  Write-Host "Bootstrapping environment (core\.venv)..."

  Ensure-Git
  $pySpec = Get-PythonSpec

  if (-not (Test-Path $SRC)) {
    Write-Host ("Cloning summoner-core into: {0}" -f $SRC)
    git clone --depth 1 https://github.com/Summoner-Network/summoner-core.git $SRC
  } else {
    Write-Host ("Repo exists at: {0}" -f $SRC)
  }

  if (-not (Test-Path $VENVDIR)) {
    Write-Host ("Creating virtual environment at: {0}" -f $VENVDIR)
    & $pySpec.Program @($pySpec.Args) -m venv $VENVDIR
  } else {
    Write-Host ("venv exists at: {0}" -f $VENVDIR)
  }

  $vp = Resolve-VenvPaths $VENVDIR
  if (-not $vp.Py) { throw ("Could not locate venv python inside {0}" -f $VENVDIR) }

  Write-Host "Upgrading pip and build tools..."
  & $vp.Py -m pip install --upgrade pip setuptools wheel maturin

  Write-Host "Installing summoner-core (editable) into core\.venv..."
  & $vp.Py -m pip install -e $SRC

  Write-Host "Writing .env..."
  Write-EnvFile
}

function Ensure-TestArtifacts([int]$p) {
  $defaultCfg = Join-Path $DATA 'default_config.json'
  if (-not (Test-Path $defaultCfg)) { throw ("Default config missing: {0}" -f $defaultCfg) }
  $script:TestCfg = Join-Path $ROOT 'test_server_config.json'
  Copy-Item $defaultCfg $script:TestCfg -Force
  # Patch the config's port on the fly
  (Get-Content $script:TestCfg -Raw) -replace '"port"\s*:\s*\d+', ('"port": {0}' -f $p) |
    Set-Content $script:TestCfg -Encoding utf8

  $script:TestPy = Join-Path $ROOT 'test_server.py'
@'
from summoner.server import SummonerServer
from tooling.your_package import hello_summoner

if __name__ == "__main__":
    hello_summoner()
    srv = SummonerServer(name="test_Server")
    srv.run(config_path="test_server_config.json")
'@ | Set-Content -Path $script:TestPy -Encoding utf8
}

function Usage {
  Write-Host "Usage: .\install_on_windows.ps1 {setup|delete|reset|deps|test_server|test_server_bg|stop_server|status|clean|use_core_venv} [-Port 8888] [-Force]"
}

switch ($Action) {
  'setup' {
    if (-not (Test-Path $VENVDIR)) {
      Write-Host "Environment not found; running setup..."
      Bootstrap
    } else {
      $vp = Resolve-VenvPaths $VENVDIR
      if (-not $vp.Py) { throw ("venv missing or broken: {0}" -f $VENVDIR) }
      & $vp.Py -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('summoner') else 1)"
      if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing summoner-core (editable) into existing venv..."
        & $vp.Py -m pip install -e $SRC
      }
    }
    Write-Host ("Environment ready at {0}" -f $ROOT)
    Write-Host ""
    Write-Host "Use background start + stop for reliable control on Windows:"
    Write-Host "  .\install_on_windows.ps1 test_server_bg   # start"
    Write-Host "  .\install_on_windows.ps1 stop_server      # stop"
  }

  'deps' {
    if (-not (Test-Path $VENVDIR)) { Bootstrap }
    $vp = Resolve-VenvPaths $VENVDIR
    if (-not $vp.Py) { throw ("venv missing: {0}" -f $VENVDIR) }
    Write-Host "Reinstalling summoner-core (editable)..."
    & $vp.Py -m pip install -e $SRC
    Write-Host "Dependencies reinstalled."
  }

  'test_server' {
    if (-not (Test-Path $VENVDIR)) { Bootstrap }
    $vp = Resolve-VenvPaths $VENVDIR
    if (-not $vp.Py) { throw ("venv missing: {0}" -f $VENVDIR) }

    Ensure-TestArtifacts -p $Port

    # If port is occupied, either stop listeners (with -Force) or abort
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
      if ($Force) {
        Write-Host ("Port {0} is in use; forcing termination of listeners..." -f $Port)
        Free-Port -p $Port
      } else {
        throw ("Port {0} is already in use. Re-run with -Force or choose -Port <free-port>." -f $Port)
      }
    }

    Write-Host ("Starting test server (foreground) on 127.0.0.1:{0} ..." -f $Port)
    & $vp.Py $script:TestPy --config $script:TestCfg
  }

  'test_server_bg' {
    if (-not (Test-Path $VENVDIR)) { Bootstrap }
    $vp = Resolve-VenvPaths $VENVDIR
    if (-not $vp.Py) { throw ("venv missing: {0}" -f $VENVDIR) }

    Ensure-TestArtifacts -p $Port

    # Stop an existing background server on the same port
    if (Test-Path $PIDFILE) {
      $oldPid = 0 + (Get-Content $PIDFILE)
      if (Is-ProcessRunning $oldPid) {
        Write-Host ("Found existing background server PID {0}. Stopping it..." -f $oldPid)
        try { Stop-Process -Id $oldPid -Force -ErrorAction Stop } catch {}
      }
      Remove-Item $PIDFILE -Force -ErrorAction SilentlyContinue
    }

    # Ensure port is free
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
      Write-Host ("Port {0} is in use; terminating listeners before start..." -f $Port)
      Free-Port -p $Port
    }

    Write-Host ("Starting test server in background on 127.0.0.1:{0} ..." -f $Port)
    $args = @($script:TestPy, '--config', $script:TestCfg)
    $proc = Start-Process -FilePath $vp.Py -ArgumentList $args -WorkingDirectory $ROOT -PassThru -WindowStyle Normal
    Set-Content -Path $PIDFILE -Value $proc.Id -Encoding ascii
    Write-Host ("Background PID: {0}. Use '.\install_on_windows.ps1 status' or 'stop_server'." -f $proc.Id)
  }

  'stop_server' {
    # Prefer PID file; fall back to killing listeners on the port
    if (Test-Path $PIDFILE) {
      $pid = 0 + (Get-Content $PIDFILE)
      if (Is-ProcessRunning $pid) {
        Write-Host ("Stopping background server PID {0} ..." -f $pid)
        try { Stop-Process -Id $pid -Force -ErrorAction Stop } catch {
          Write-Warning ("Failed to stop PID {0}: {1}" -f $pid, $_.Exception.Message)
        }
      } else {
        Write-Host ("PID {0} from .server.pid is not running." -f $pid)
      }
      Remove-Item $PIDFILE -Force -ErrorAction SilentlyContinue
    } else {
      Write-Host "No PID file found; stopping any process listening on the chosen port..."
      Free-Port -p $Port
    }
    Write-Host "Stop complete."
  }

  'status' {
    $runningByPID = $false
    if (Test-Path $PIDFILE) {
      $pid = 0 + (Get-Content $PIDFILE)
      $runningByPID = Is-ProcessRunning $pid
      Write-Host ("PID file: {0} (running: {1})" -f $pid, $runningByPID)
    } else {
      Write-Host "PID file: (none)"
    }

    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
      $pids = $conn | Select-Object -ExpandProperty OwningProcess -Unique
      Write-Host ("Port {0} listeners: {1}" -f $Port, ($pids -join ', '))
    } else {
      Write-Host ("Port {0} listeners: none" -f $Port)
    }
  }

  'clean' {
    Write-Host "Cleaning test artifacts..."
    if (Test-Path "$ROOT\logs") {
      Get-ChildItem "$ROOT\logs" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $ROOT -Filter 'test_*.py'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ROOT -Filter 'test_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Clean complete."
  }

  'reset' {
    Write-Host "Resetting environment..."
    if (Test-Path $SRC)         { Remove-Item $SRC -Recurse -Force }
    if (Test-Path "$ROOT\logs") { Remove-Item "$ROOT\logs" -Recurse -Force }
    if (Test-Path $PIDFILE)     { Remove-Item $PIDFILE -Force }
    Get-ChildItem $ROOT -Filter 'test_*.py'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ROOT -Filter 'test_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Bootstrap
    Write-Host "Reset complete."
  }

  'delete' {
    Write-Host "Deleting environment..."
    if (Test-Path $PIDFILE)     { Remove-Item $PIDFILE -Force }
    if (Test-Path $SRC)         { Remove-Item $SRC -Recurse -Force }
    if (Test-Path "$ROOT\logs") { Remove-Item "$ROOT\logs" -Recurse -Force }
    Get-ChildItem $ROOT -Filter 'test_*.py'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ROOT -Filter 'test_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Deletion complete."
  }

  'use_core_venv' {
    $vp = Resolve-VenvPaths $VENVDIR
    if (-not $vp.Bin) { throw ("venv not found at {0}. Run .\install_on_windows.ps1 setup first." -f $VENVDIR) }
    # Prepend this session's PATH so python/pip resolve to core\.venv
    $env:Path = "$($vp.Bin);$env:Path"
    & "$($vp.Py)" -c 'import sys; print(sys.executable)'
    Write-Host "This PowerShell session now uses core\.venv's python/pip."
    Write-Host "To revert, start a new PowerShell session."
  }

  default { Usage }
}
