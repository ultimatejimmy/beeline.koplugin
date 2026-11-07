param (
    [switch]$Watch,
    [switch]$NoRestart
)

# Ensure WSL passes software rendering and X11 driver flags to fix graphics crashes in Copy Mode
$env:LIBGL_ALWAYS_SOFTWARE = "1"
$env:SDL_VIDEO_DRIVER = "x11"
$env:SDL_VIDEODRIVER = "x11"

$EnvList = @("LIBGL_ALWAYS_SOFTWARE/u", "SDL_VIDEO_DRIVER/u", "SDL_VIDEODRIVER/u")
foreach ($item in $EnvList) {
    $varName = $item.Split('/')[0]
    if ($env:WSLENV) {
        if ($env:WSLENV -notlike "*$varName*") {
            $env:WSLENV = "$env:WSLENV:$item"
        }
    } else {
        $env:WSLENV = $item
    }
}

# Determine plugin directory
if (Test-Path "beeline.koplugin/plugin/beeline.koplugin") {
    $PluginDir = "beeline.koplugin/plugin/beeline.koplugin"
    $RepoRoot = "beeline.koplugin"
} elseif (Test-Path "beeline/plugin/beeline.koplugin") {
    $PluginDir = "beeline/plugin/beeline.koplugin"
    $RepoRoot = "beeline"
} elseif (Test-Path "plugin/beeline.koplugin") {
    $PluginDir = "plugin/beeline.koplugin"
    $RepoRoot = "."
} elseif (Test-Path "_meta.lua") {
    $PluginDir = "."
    $RepoRoot = "../.."
} else {
    $PluginDir = "plugin/beeline.koplugin"
    $RepoRoot = "."
}

$WSLDest = "~/.config/koreader/plugins/beeline.koplugin"
$SyntaxScript = Join-Path $PSScriptRoot "check_syntax.py"
if (-not (Test-Path $SyntaxScript)) {
    $SyntaxScript = "tools/check_syntax.py"
}

# Probe for the squashfs-root location in WSL
$SquashPath = ""
$UserNameLower = $env:USERNAME.ToLower()
$ProbedPaths = @(
    "/home/jimmy/squashfs-root",
    "/home/$env:USERNAME/squashfs-root",
    "/home/$UserNameLower/squashfs-root",
    "/mnt/c/Users/$env:USERNAME/squashfs-root",
    "/mnt/c/Users/$UserNameLower/squashfs-root"
)
foreach ($path in $ProbedPaths) {
    $null = wsl test -d $path
    if ($LASTEXITCODE -eq 0) {
        $SquashPath = $path
        break
    }
}
if (-not $SquashPath) {
    $SquashPath = "/home/jimmy/squashfs-root"
}

function Run-Workflow {
    Write-Host "`n--- Starting Beeline Verification Workflow ---" -ForegroundColor Cyan
    
    # 1. Syntax Check
    if (Test-Path $SyntaxScript) {
        Write-Host "Checking Lua syntax..." -NoNewline
        $syntaxResult = python -X utf8 $SyntaxScript $PluginDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $syntaxResult
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    # 2. Automated Tests
    Write-Host "Running Worker & Pairing tests (Node.js)..." -NoNewline
    $specDir = Join-Path $RepoRoot "spec"
    if (Test-Path (Join-Path $specDir "test_worker_e2e.js")) {
        $nodeResult = node (Join-Path $specDir "test_worker_e2e.js") 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $nodeResult
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running OpenSSL EVP crypto tests in WSL LuaJIT..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_crypto_roundtrip.js")) {
        node (Join-Path $specDir "test_crypto_roundtrip.js") > $null 2>&1
        $winRepoPath = (Get-Item $RepoRoot).FullName -replace '\\', '/'
        $wslRepoDir = (wsl wslpath -u $winRepoPath).Trim()
        $luaTest = wsl bash -c "cd '$wslRepoDir' && /home/jimmy/squashfs-root/usr/lib/koreader/luajit spec/test_beeline_crypto.lua" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $luaTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running Beeline DRM & Autoclean tests in WSL LuaJIT..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_beeline_drm.lua")) {
        $winRepoPath = (Get-Item $RepoRoot).FullName -replace '\\', '/'
        $wslRepoDir = (wsl wslpath -u $winRepoPath).Trim()
        $drmTest = wsl bash -c "cd '$wslRepoDir' && /home/jimmy/squashfs-root/usr/lib/koreader/luajit spec/test_beeline_drm.lua" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $drmTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running Beeline Ephemeral ADEPT tests in WSL LuaJIT..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_beeline_ephemeral.lua")) {
        $winRepoPath = (Get-Item $RepoRoot).FullName -replace '\\', '/'
        $wslRepoDir = (wsl wslpath -u $winRepoPath).Trim()
        $ephTest = wsl bash -c "cd '$wslRepoDir' && /home/jimmy/squashfs-root/usr/lib/koreader/luajit spec/test_beeline_ephemeral.lua" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $ephTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running Beeline UI Toast & Refresh tests in WSL LuaJIT..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_beeline_ui_toast.lua")) {
        $winRepoPath = (Get-Item $RepoRoot).FullName -replace '\\', '/'
        $wslRepoDir = (wsl wslpath -u $winRepoPath).Trim()
        $uiToastTest = wsl bash -c "cd '$wslRepoDir' && /home/jimmy/squashfs-root/usr/lib/koreader/luajit spec/test_beeline_ui_toast.lua" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $uiToastTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running Translation unit tests (Python)..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_sync_translations.py")) {
        $pyTest = python (Join-Path $specDir "test_sync_translations.py") 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $pyTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    Write-Host "Running Beeline Localization tests in WSL Lua..." -NoNewline
    if (Test-Path (Join-Path $specDir "test_beeline_localization.lua")) {
        $winRepoPath = (Get-Item $RepoRoot).FullName -replace '\\', '/'
        $wslRepoDir = (wsl wslpath -u $winRepoPath).Trim()
        $locTest = wsl bash -c "cd '$wslRepoDir' && /usr/bin/lua spec/test_beeline_localization.lua" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $locTest
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    # 3. Sync to WSL
    Write-Host "Syncing plugin to WSL KOReader..." -NoNewline
    $winPluginPath = (Get-Item $PluginDir).FullName -replace '\\', '/'
    $WslPluginDir = (wsl wslpath -u $winPluginPath).Trim()

    wsl bash -c "mkdir -p $WSLDest"
    wsl rsync -rv --delete --exclude=".git/" --exclude="*.log" "$WslPluginDir/" "$WSLDest/"

    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 4. Restart KOReader in WSL
    if (-not $NoRestart) {
        Write-Host "Restarting KOReader in WSL..." -ForegroundColor Cyan
        wsl bash -c "killall -9 luajit reader.lua koreader 2>/dev/null; pkill -9 -f 'reader.lua|luajit|koreader' 2>/dev/null"
        Start-Sleep -Seconds 1

        $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"/usr/bin/koreader`""
        $StartCmd = if ($env:KOREADER_START_CMD) { $env:KOREADER_START_CMD } else { $DefaultCmd }

        Write-Host "Starting KOReader: $StartCmd"
        $cmdLine = "/c start `"`" $StartCmd"
        Start-Process cmd.exe -ArgumentList $cmdLine -WindowStyle Hidden
    }

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes in $PluginDir..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = (Get-Item $PluginDir).FullName
    $watcher.Filter = "*.lua"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    $action = {
        Run-Workflow
    }

    Register-ObjectEvent $watcher "Changed" -Action $action
    Register-ObjectEvent $watcher "Created" -Action $action
    Register-ObjectEvent $watcher "Deleted" -Action $action
    Register-ObjectEvent $watcher "Renamed" -Action $action

    while ($true) { Start-Sleep -Seconds 1 }
} else {
    Run-Workflow
}
