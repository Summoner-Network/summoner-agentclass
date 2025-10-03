# install_on_windows.ps1 — PowerShell-only manager (uses venv exclusively)
# ==============================================================================
# How to use this script
# ==============================================================================
# > First, you may need to use the following command to allow the script to run:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#
# > Then, you can run the script as follows:
#   .\install_on_windows.ps1 setup
#   .\install_on_windows.ps1 test_server                # run server in foreground
#   . .\install_on_windows.ps1 use_venv                  # dot-source to activate the repo venv in THIS session (recommended for full activation)
#
# > Notes:
# - Running the script normally (.\install_on_windows.ps1 setup) will set the environment variables so python/pip resolve to the repo venv.
# - If you also want prompt/function changes from Activate.ps1 to persist in your interactive shell, dot-source:
#     . .\install_on_windows.ps1 use_venv
#
# > or foreground run (Ctrl+C may not work reliably on Windows):
#   .\install_on_windows.ps1 test_server
#
# > choose port or force-terminate listeners:
#   .\install_on_windows.ps1 test_server -Port 8890
#   .\install_on_windows.ps1 test_server -Port 8890 -Force
# ==============================================================================
[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('setup','delete','reset','deps','test_server','clean','use_venv')]
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
  $nix = Join-Path (Join-Path $VenvDir 'bin') 'python'
  if (Test-Path $exe) { return @{ Py=$exe; Bin=(Join-Path $VenvDir 'Scripts') } }
  if (Test-Path $nix) { return @{ Py=$nix; Bin=(Join-Path $VenvDir 'bin') } }
  return @{ Py=$null; Bin=$null }
}

function Ensure-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "'git' not found on PATH."
  }
}

# ---------- Paths ----------
$ScriptFile = $MyInvocation.MyCommand.Definition
$ROOT = (Resolve-Path (Split-Path -Parent $ScriptFile)).ProviderPath
$SRC      = Join-Path $ROOT 'core'        # summoner-core repository path
$VENVDIR  = Join-Path $ROOT 'venv'       # venv lives inside the root repo
$DATA     = Join-Path $SRC  'desktop_data'

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

# Activate the repo venv in the current PowerShell process.
# Note: environment variables (PATH, VIRTUAL_ENV) set here will persist in the session.
#       prompt/function modifications inside Activate.ps1 will only persist if the activate script is dot-sourced in the current session.
function Activate-Venv {
  param([string]$VenvDir)

  $vp = Resolve-VenvPaths $VenvDir
  if (-not $vp.Py) { throw ("venv not found at {0}. Run .\install_on_windows.ps1 setup first." -f $VenvDir) }

  # If Activate.ps1 is present, dot-source it here — that tries to set functions and state.
  # If the manager script itself is not dot-sourced, dot-sourcing inside this function affects the manager script scope,
  # but environment variable modifications will still persist at the process level.
  $activatePS = Join-Path $VenvDir 'Scripts\Activate.ps1'
  if (Test-Path $activatePS) {
    try {
      . $activatePS
    } catch {
      Write-Warning ("Activation script failed: {0}" -f $_.Exception.Message)
      # fallback to manual env setup below
    }
  }

  # Ensure environment variables and PATH are set so python/pip resolve to venv
  Remove-Item Function:\python -ErrorAction SilentlyContinue
  Remove-Item Function:\pip   -ErrorAction SilentlyContinue

  $env:VIRTUAL_ENV = (Resolve-Path $VenvDir).ProviderPath
  $env:Path = "$($vp.Bin);$env:Path"

  # Verification
  & $vp.Py -c "import sys, os; print('python executable:', sys.executable); print('sys.prefix:', os.path.abspath(sys.prefix))"
  Write-Host ("Activated venv at: {0}" -f $VenvDir)
  Write-Host "If you want prompt/function changes to persist in this interactive shell, run:"
  Write-Host "  . .\install_on_windows.ps1 use_venv"
  Write-Host "or dot-source the venv's activate directly:"
  Write-Host "  . $VENVDIR\Scripts\Activate.ps1"
}

function Bootstrap {
  Write-Host ("Bootstrapping environment at: {0}" -f $VENVDIR)

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

  Write-Host ("Installing summoner-core (non-editable) into: {0}" -f $VENVDIR)
  & $vp.Py -m pip install $SRC

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
  Write-Host "Usage: .\install_on_windows.ps1 {setup|delete|reset|deps|test_server|clean|use_venv} [-Port 8888] [-Force]"
}

# Detect if script was dot-sourced into current session (used only for messaging).
$IsDotSourced = ($MyInvocation.InvocationName -eq '.')

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
        Write-Host ("Installing summoner-core (non-editable) into: {0}" -f $VENVDIR)
        & $vp.Py -m pip install $SRC
      }
    }
    Write-Host ("Environment ready at {0}" -f $ROOT)

    # Activate venv in this session (sets PATH and VIRTUAL_ENV). These env changes will persist.
    try {
      Activate-Venv -VenvDir $VENVDIR
    } catch {
      Write-Warning ("Failed to auto-activate venv in this process: {0}" -f $_.Exception.Message)
      Write-Host "You can activate manually with: . $VENVDIR\Scripts\Activate.ps1  (dot-source into current shell)"
    }

    if ($IsDotSourced) {
      Write-Host "Note: you ran this script via dot-sourcing; activation (including functions/prompt) persists in your current shell."
    } else {
      Write-Host "Note: if you want prompt/function changes to persist, dot-source the activation now:"
      Write-Host "  . .\install_on_windows.ps1 use_venv"
    }

    Write-Host ""
    Write-Host "To run the test server in foreground (Ctrl+C to stop):"
    Write-Host "  .\install_on_windows.ps1 test_server -Port 8888"
  }

  'delete' {
    Write-Host "Deleting environment..."
    if (Test-Path $SRC)         { Remove-Item $SRC -Recurse -Force }
    if (Test-Path $VENVDIR)     { Remove-Item $VENVDIR -Recurse -Force }
    if (Test-Path "$ROOT\logs") { Remove-Item "$ROOT\logs" -Recurse -Force }
    Get-ChildItem $ROOT -Filter 'test_*.py'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ROOT -Filter 'test_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Deletion complete."
  }

  'deps' {
    if (-not (Test-Path $VENVDIR)) { Bootstrap }
    $vp = Resolve-VenvPaths $VENVDIR
    if (-not $vp.Py) { throw ("venv missing: {0}" -f $VENVDIR) }
    Write-Host "Reinstalling summoner-core (non-editable)..."
    & $vp.Py -m pip install $SRC
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

  'reset' {
    Write-Host "Resetting environment..."
    if (Test-Path $SRC)         { Remove-Item $SRC -Recurse -Force }
    if (Test-Path "$ROOT\logs") { Remove-Item "$ROOT\logs" -Recurse -Force }
    if (Test-Path $VENVDIR)     { Remove-Item $VENVDIR -Recurse -Force }
    Get-ChildItem $ROOT -Filter 'test_*.py'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ROOT -Filter 'test_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Bootstrap

    # Activate the freshly created venv in this session (sets PATH/VIRTUAL_ENV)
    try {
      Activate-Venv -VenvDir $VENVDIR
    } catch {
      Write-Warning ("Failed to auto-activate venv after reset in this process: {0}" -f $_.Exception.Message)
      Write-Host "You can activate manually with: . $VENVDIR\Scripts\Activate.ps1  (dot-source into current shell)"
    }

    if ($IsDotSourced) {
      Write-Host "Note: you ran this script via dot-sourcing; activation (including functions/prompt) persists in your current shell."
    } else {
      Write-Host "Note: if you want prompt/function changes to persist, dot-source the activation now:"
      Write-Host "  . .\install_on_windows.ps1 use_venv"
    }

    Write-Host "Reset complete."
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

  'use_venv' {
    Activate-Venv -VenvDir $VENVDIR
  }

  default { Usage }
}
