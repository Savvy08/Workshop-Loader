[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Show-Banner {
    param([string]$RootDir)
    Clear-Host
    $defaultOutDir = Join-Path $RootDir "Downloads"
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "             STEAM WORKSHOP DOWNLOADER                     " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Куда сохраняются моды:" -ForegroundColor DarkYellow
    Write-Host "  $defaultOutDir\<Название_Коллекции или Мода>" -ForegroundColor Gray
    Write-Host "  (Каждая коллекция скачивается в свою отдельную папку)" -ForegroundColor DarkGray
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1] Скачать коллекцию модов по ссылке" -ForegroundColor White
    Write-Host "  [2] Скачать отдельный мод по ссылке" -ForegroundColor White
    Write-Host "  [0] Выход" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor DarkGray
}

function Get-CleanFileName {
    param([string]$Name)
    $clean = $Name -replace '[\\/:*?"<>|]', '_'
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function Fetch-SteamPage {
    param([string]$TargetId)
    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    try {
        return $webClient.DownloadString("https://steamcommunity.com/sharedfiles/filedetails/?id=$TargetId")
    } catch {
        throw "Не удалось загрузить страницу Steam: $_"
    }
}

function Parse-AppId {
    param([string]$Html)
    if ($Html -match 'steamcommunity\.com/app/(\d+)') {
        return $matches[1]
    } elseif ($Html -match 'appid["'':\s=]+(\d+)') {
        return $matches[1]
    }
    return $null
}

function Ensure-SteamCMD {
    param([string]$RootDir)
    $steamCmdDir = Join-Path $RootDir "steamcmd"
    $steamCmdExe = Join-Path $steamCmdDir "steamcmd.exe"
    $isFirstInstall = $false

    if (-not (Test-Path $steamCmdExe)) {
        Write-Host "[-] SteamCMD не обнаружен. Загрузка базового архива (~2.5 МБ)..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $steamCmdDir -Force | Out-Null
        $zipPath = Join-Path $steamCmdDir "steamcmd.zip"

        $client = New-Object System.Net.WebClient
        $client.DownloadFile("https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip", $zipPath)

        Write-Host "[+] Распаковка архива..." -ForegroundColor Cyan
        Expand-Archive -Path $zipPath -DestinationPath $steamCmdDir -Force
        Remove-Item $zipPath -Force
        $isFirstInstall = $true
    }

    $steamClientDll = Join-Path $steamCmdDir "steamclient.dll"
    if ($isFirstInstall -or (-not (Test-Path $steamClientDll))) {
        Write-Host "[+] Первичная инициализация SteamCMD (загрузка компонентов Valve ~43 МБ)..." -ForegroundColor Cyan
        Write-Host "    Пожалуйста, подождите 20-40 секунд..." -ForegroundColor DarkGray
        Start-Process -FilePath $steamCmdExe -ArgumentList "+quit" -Wait -NoNewWindow
    }

    return $steamCmdDir
}

function Download-WorkshopItems {
    param(
        [string]$SteamCmdDir,
        [string]$AppId,
        [array]$Items,
        [string]$TargetFolder,
        [string]$CollectionTitle
    )

    Write-Host ""
    Write-Host "[*] Подготовка скрипта загрузки..." -ForegroundColor Yellow

    $scriptFile = Join-Path $SteamCmdDir "download_script.txt"
    $scriptContent = @(
        "@ShutdownOnFailedCommand 0",
        "@NoPromptForPassword 1",
        "login anonymous"
    )

    foreach ($item in $Items) {
        $scriptContent += "workshop_download_item $AppId $($item.Id)"
    }
    $scriptContent += "quit"

    # Запись файла строго без BOM для корректной работы SteamCMD
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($scriptFile, $scriptContent, $utf8NoBom)

    $steamCmdExe = Join-Path $SteamCmdDir "steamcmd.exe"
    Write-Host "[+] Запуск загрузки $($Items.Count) модов через SteamCMD..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    # Создаем карту ID -> Название и порядковый номер для чистого вывода
    $itemMap = @{}
    $itemIdx = @{}
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        $itemMap[$it.Id] = $it.Title
        $itemIdx[$it.Id] = $i + 1
    }
    $totalCount = $Items.Count

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $steamCmdExe
    $psi.Arguments = "+runscript download_script.txt"
    $psi.WorkingDirectory = $SteamCmdDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    $reader = $proc.StandardOutput
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line) { continue }

        # Начало скачивания
        if ($line -match 'Downloading item (\d+)') {
            $id = $matches[1]
            $title = if ($itemMap.ContainsKey($id)) { $itemMap[$id] } else { "Мод $id" }
            $num = if ($itemIdx.ContainsKey($id)) { $itemIdx[$id] } else { "?" }
            Write-Host ("[{0}/{1}]  [..] Скачивается: {2}..." -f $num, $totalCount, $title) -ForegroundColor Cyan
        }
        # Успешное завершение скачивания мода
        elseif ($line -match 'Downloaded item (\d+).*?\((\d+)\s*bytes\)') {
            $id = $matches[1]
            $bytes = [int64]$matches[2]
            $size = if ($bytes -ge 1048576) { "{0:N1} MB" -f ($bytes / 1MB) } else { "{0:N0} KB" -f ($bytes / 1KB) }
            $title = if ($itemMap.ContainsKey($id)) { $itemMap[$id] } else { "Мод $id" }
            $num = if ($itemIdx.ContainsKey($id)) { $itemIdx[$id] } else { "?" }
            Write-Host ("[{0}/{1}]  [OK] Скачан: {2} ({3})" -f $num, $totalCount, $title, $size) -ForegroundColor Green
        }
        # Мод удален или недоступен
        elseif ($line -match 'ERROR!\s*Download item (\d+)\s*failed') {
            $id = $matches[1]
            $title = if ($itemMap.ContainsKey($id)) { $itemMap[$id] } else { "Мод $id" }
            $num = if ($itemIdx.ContainsKey($id)) { $itemIdx[$id] } else { "?" }
            Write-Host ("[{0}/{1}]  [FAIL] Пропущен (недоступен в Steam): {2} ({3})" -f $num, $totalCount, $title, $id) -ForegroundColor DarkYellow
        }
    }
    $proc.WaitForExit()

    # Перемещение/организация файлов в целевую папку коллекции
    Write-Host ""
    Write-Host "[*] Организация папок модов..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null

    $srcBase = Join-Path $SteamCmdDir "steamapps\workshop\content\$AppId"
    $successCount = 0

    foreach ($item in $Items) {
        $modSrc = Join-Path $srcBase $item.Id
        if (Test-Path $modSrc) {
            # Формируем имя папки мода: "ID (Название)"
            $safeModTitle = Get-CleanFileName $item.Title
            $destName = "$($item.Id) ($safeModTitle)"
            $destPath = Join-Path $TargetFolder $destName

            if (Test-Path $destPath) {
                Remove-Item -Path $destPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            # Перемещаем (Move-Item), чтобы не дублировать файлы и не забивать диск
            Move-Item -Path $modSrc -Destination $destPath -Force
            $successCount++
        }
    }

    # Очистка остатков во временном каталоге SteamCMD
    if (Test-Path $srcBase) {
        Remove-Item -Path "$srcBase\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Сохраняем список ссылок прямо в папку с коллекцией
    $linksList = @()
    $linksList += "Коллекция: $CollectionTitle"
    $linksList += "App ID игры: $AppId"
    $linksList += "Всего модов: $($Items.Count)"
    $linksList += "------------------------------------------------------------"
    foreach ($item in $Items) {
        $linksList += "https://steamcommunity.com/sharedfiles/filedetails/?id=$($item.Id) | $($item.Title)"
    }
    $linksPath = Join-Path $TargetFolder "mods_links.txt"
    [System.IO.File]::WriteAllLines($linksPath, $linksList, $utf8NoBom)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "[OK] Загрузка и сортировка завершена!" -ForegroundColor Green
    Write-Host "Успешно собрано модов: $successCount из $($Items.Count)" -ForegroundColor White
    Write-Host "Папка с модами коллекции:" -ForegroundColor Yellow
    Write-Host "  $TargetFolder" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ""

    $open = Read-Host "Открыть папку со скачанными модами? (y/n)"
    if ($open -eq 'y' -or $open -eq 'д' -or $open -eq '') {
        Start-Process "explorer.exe" $TargetFolder
    }
}

function Process-Collection {
    param([string]$RootDir, [string]$SteamCmdDir)

    Write-Host ""
    Write-Host "--- Скачивание коллекции ---" -ForegroundColor Cyan
    $url = Read-Host "Вставьте ссылку на коллекцию Steam Workshop"

    if ($url -match 'id=(\d+)') {
        $targetId = $matches[1]
    } else {
        Write-Host "[-] Ошибка: В ссылке не найден ID коллекции." -ForegroundColor Red
        return
    }

    Write-Host "[*] Получение данных о коллекции..." -ForegroundColor Gray
    $html = Fetch-SteamPage -TargetId $targetId

    $collTitle = "Collection_$targetId"
    if ($html -match '<div class="workshopItemTitle">([^<]+)</div>') {
        $collTitle = $matches[1].Trim()
    }

    $appId = Parse-AppId -Html $html
    if (-not $appId) {
        $appId = Read-Host "Не удалось определить App ID. Введите вручную (RimWorld = 294100)"
    }

    $itemRegex = [regex]'id="sharedfile_(\d+)"[\s\S]*?<div class="workshopItemTitle">([^<]+)</div>'
    $matchList = $itemRegex.Matches($html)

    if ($matchList.Count -eq 0) {
        Write-Host "[-] В этой коллекции не найдено элементов или это страница одиночного мода." -ForegroundColor Yellow
        return
    }

    $items = @()
    foreach ($m in $matchList) {
        $items += [PSCustomObject]@{
            Id    = $m.Groups[1].Value
            Title = $m.Groups[2].Value.Trim()
        }
    }

    Write-Host ""
    Write-Host "[+] Название: $collTitle" -ForegroundColor Green
    Write-Host "[+] App ID игры: $appId" -ForegroundColor Green
    Write-Host "[+] Найдено модов: $($items.Count)" -ForegroundColor Green

    $safeTitle = Get-CleanFileName $collTitle
    $targetDir = Join-Path (Join-Path $RootDir "Downloads") $safeTitle

    Download-WorkshopItems -SteamCmdDir $SteamCmdDir -AppId $appId -Items $items -TargetFolder $targetDir -CollectionTitle $collTitle
}

function Process-SingleMod {
    param([string]$RootDir, [string]$SteamCmdDir)

    Write-Host ""
    Write-Host "--- Скачивание отдельного мода ---" -ForegroundColor Cyan
    $url = Read-Host "Вставьте ссылку на мод Steam Workshop"

    if ($url -match 'id=(\d+)') {
        $targetId = $matches[1]
    } else {
        Write-Host "[-] Ошибка: В ссылке не найден ID мода." -ForegroundColor Red
        return
    }

    Write-Host "[*] Получение данных о моде..." -ForegroundColor Gray
    $html = Fetch-SteamPage -TargetId $targetId

    $modTitle = "Mod_$targetId"
    if ($html -match '<div class="workshopItemTitle">([^<]+)</div>') {
        $modTitle = $matches[1].Trim()
    }

    $appId = Parse-AppId -Html $html
    if (-not $appId) {
        $appId = Read-Host "Не удалось определить App ID. Введите вручную (RimWorld = 294100)"
    }

    Write-Host ""
    Write-Host "[+] Название: $modTitle" -ForegroundColor Green
    Write-Host "[+] App ID игры: $appId" -ForegroundColor Green

    $items = @(
        [PSCustomObject]@{
            Id    = $targetId
            Title = $modTitle
        }
    )

    $safeTitle = Get-CleanFileName $modTitle
    $targetDir = Join-Path (Join-Path $RootDir "Downloads") "Single_Mods\$($targetId) ($safeTitle)"

    Download-WorkshopItems -SteamCmdDir $SteamCmdDir -AppId $appId -Items $items -TargetFolder $targetDir -CollectionTitle $modTitle
}

# --- Главный цикл программы с меню ---
$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $rootDir) { $rootDir = Get-Location }

try {
    $steamDir = Ensure-SteamCMD -RootDir $rootDir
} catch {
    Write-Host "Ошибка инициализации SteamCMD: $_" -ForegroundColor Red
    pause
    exit
}

while ($true) {
    Show-Banner -RootDir $rootDir
    $choice = Read-Host "Выберите действие (1, 2 или 0)"

    switch ($choice) {
        "1" {
            try {
                Process-Collection -RootDir $rootDir -SteamCmdDir $steamDir
            } catch {
                Write-Host "Ошибка: $_" -ForegroundColor Red
            }
            Write-Host ""
            Read-Host "Нажмите Enter для возврата в меню..."
        }
        "2" {
            try {
                Process-SingleMod -RootDir $rootDir -SteamCmdDir $steamDir
            } catch {
                Write-Host "Ошибка: $_" -ForegroundColor Red
            }
            Write-Host ""
            Read-Host "Нажмите Enter для возврата в меню..."
        }
        "0" {
            Write-Host "Выход из программы..." -ForegroundColor Gray
            break
        }
        default {
            Write-Host "Неверный ввод. Введите 1, 2 или 0." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
