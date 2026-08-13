$root = $PSScriptRoot
$port = 8080

$imagesDir = Join-Path $root "targets\images"
$videosDir = Join-Path $root "videos"
$modelsDir = Join-Path $root "models"
$targetsDir = Join-Path $root "targets"
New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null
New-Item -ItemType Directory -Force -Path $videosDir | Out-Null
New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

$handlerScript = {
  param($client, $root)

  $mime = @{
    ".html" = "text/html; charset=utf-8"; ".htm" = "text/html; charset=utf-8"
    ".js" = "application/javascript"; ".css" = "text/css"
    ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"; ".svg" = "image/svg+xml"; ".mind" = "application/octet-stream"
    ".mp4" = "video/mp4"; ".mov" = "video/quicktime"; ".webm" = "video/webm"
    ".glb" = "model/gltf-binary"; ".gltf" = "model/gltf+json"
    ".json" = "application/json; charset=utf-8"; ".ico" = "image/x-icon"
  }

  $imagesDir = Join-Path $root "targets\images"
  $videosDir = Join-Path $root "videos"
  $modelsDir = Join-Path $root "models"
  $targetsDir = Join-Path $root "targets"

  function Find-Sequence($haystack, $needle) {
    $hLen = $haystack.Length
    $nLen = $needle.Length
    if ($nLen -eq 0 -or $hLen -lt $nLen) { return -1 }
    for ($i = 0; $i -le $hLen - $nLen; $i++) {
      $match = $true
      for ($j = 0; $j -lt $nLen; $j++) {
        if ($haystack[$i + $j] -ne $needle[$j]) { $match = $false; break }
      }
      if ($match) { return $i }
    }
    return -1
  }

  function Receive-HttpRequest($stream) {
    $ms = New-Object System.IO.MemoryStream
    $chunk = New-Object byte[] 65536
    $headerEndIndex = -1
    $delim = [byte[]]@(13, 10, 13, 10)

    while ($true) {
      $n = $stream.Read($chunk, 0, $chunk.Length)
      if ($n -le 0) { break }
      $ms.Write($chunk, 0, $n)
      $arr = $ms.ToArray()
      $idx = Find-Sequence $arr $delim
      if ($idx -ge 0) { $headerEndIndex = $idx; break }
      if ($arr.Length -gt 2MB) { break }
    }
    if ($headerEndIndex -lt 0) { return $null }

    $all = $ms.ToArray()
    $headerBytes = New-Object byte[] $headerEndIndex
    [Array]::Copy($all, 0, $headerBytes, 0, $headerEndIndex)
    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes)

    $bodyStartIndex = $headerEndIndex + 4
    $alreadyBodyLen = $all.Length - $bodyStartIndex

    $contentLength = 0
    if ($headerText -match "(?im)^Content-Length:\s*(\d+)") { $contentLength = [int64]$matches[1] }

    $bodyBytes = New-Object byte[] $contentLength
    if ($alreadyBodyLen -gt 0) {
      $copyLen = [Math]::Min($alreadyBodyLen, $contentLength)
      [Array]::Copy($all, $bodyStartIndex, $bodyBytes, 0, $copyLen)
    }
    $haveBody = [Math]::Min($alreadyBodyLen, $contentLength)
    $remaining = $contentLength - $haveBody
    while ($remaining -gt 0) {
      $toRead = [Math]::Min($remaining, $chunk.Length)
      $n = $stream.Read($chunk, 0, $toRead)
      if ($n -le 0) { break }
      [Array]::Copy($chunk, 0, $bodyBytes, $haveBody, $n)
      $haveBody += $n
      $remaining -= $n
    }

    $firstLine = ($headerText -split "`r`n")[0]
    $parts = $firstLine -split " "
    $method = if ($parts.Length -ge 1) { $parts[0] } else { "GET" }
    $rawPath = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
    $path = ($rawPath -split "\?")[0]
    $queryString = ""
    if ($rawPath -match "\?(.*)$") { $queryString = $matches[1] }

    $query = @{}
    foreach ($pair in ($queryString -split "&")) {
      if ($pair -eq "") { continue }
      $kv = $pair -split "=", 2
      $k = [System.Uri]::UnescapeDataString($kv[0])
      $v = if ($kv.Length -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { "" }
      $query[$k] = $v
    }

    return @{
      Method = $method
      Path = [System.Uri]::UnescapeDataString($path)
      Query = $query
      Body = $bodyBytes
    }
  }

  function Send-Response($stream, $statusText, $contentType, [byte[]]$bodyBytes) {
    if ($null -eq $bodyBytes) { $bodyBytes = [byte[]]@() }
    $headerText = "HTTP/1.1 $statusText`r`nContent-Type: $contentType`r`nContent-Length: $($bodyBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerText)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $stream.Flush()
  }

  function Sanitize-Name($name) {
    if (-not $name) { return "" }
    return ($name -replace "[^a-zA-Z0-9_\-]", "")
  }

  try {
    $client.ReceiveTimeout = 20000
    $client.SendTimeout = 20000
    $stream = $client.GetStream()
    $req = Receive-HttpRequest $stream
    if ($null -eq $req) { $client.Close(); return }

    $status = "200 OK"
    $respType = "application/json; charset=utf-8"
    $respBody = [byte[]]@()

    if ($req.Method -eq "OPTIONS") {
      $status = "204 No Content"
    }
    elseif ($req.Path -eq "/api/list" -and $req.Method -eq "GET") {
      $imageParts = @()
      if (Test-Path $imagesDir) {
        Get-ChildItem $imagesDir -File | ForEach-Object {
          $nm = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
          $imageParts += ('{"name":"' + $nm + '","file":"' + $_.Name + '"}')
        }
      }
      $imagesJson = "[" + ($imageParts -join ",") + "]"
      $configPath = Join-Path $root "targets.config.json"
      $configJson = "null"
      if (Test-Path $configPath) { $configJson = Get-Content $configPath -Raw }
      $payload = "{`"images`":" + $imagesJson + ",`"config`":" + $configJson + "}"
      $respBody = [System.Text.Encoding]::UTF8.GetBytes($payload)
    }
    elseif ($req.Path -eq "/api/upload" -and $req.Method -eq "POST") {
      $type = $req.Query["type"]
      $name = Sanitize-Name $req.Query["name"]
      $ext = ($req.Query["ext"] -replace "[^a-zA-Z0-9]", "").ToLower()

      if ($type -eq "image" -and $name -and $ext) {
        $dest = Join-Path $imagesDir "$name.$ext"
        [System.IO.File]::WriteAllBytes($dest, $req.Body)
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"targets/images/$name.$ext`"}")
      }
      elseif ($type -eq "video" -and $name -and $ext) {
        $dest = Join-Path $videosDir "$name.$ext"
        [System.IO.File]::WriteAllBytes($dest, $req.Body)
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"videos/$name.$ext`"}")
      }
      elseif ($type -eq "model" -and $name -and $ext) {
        $dest = Join-Path $modelsDir "$name.$ext"
        [System.IO.File]::WriteAllBytes($dest, $req.Body)
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"models/$name.$ext`"}")
      }
      elseif ($type -eq "mind") {
        $dest = Join-Path $targetsDir "targets.mind"
        [System.IO.File]::WriteAllBytes($dest, $req.Body)
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"targets/targets.mind`"}")
      }
      else {
        $status = "400 Bad Request"
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":false,`"error`":`"invalid upload params`"}")
      }
    }
    elseif ($req.Path -eq "/api/config" -and $req.Method -eq "POST") {
      $dest = Join-Path $root "targets.config.json"
      [System.IO.File]::WriteAllBytes($dest, $req.Body)
      $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true}")
    }
    elseif ($req.Method -eq "GET") {
      $reqPath = $req.Path
      if ($reqPath -eq "/") { $reqPath = "/index.html" }
      $filePath = Join-Path $root ($reqPath.TrimStart("/") -replace "/", "\")
      $fullRoot = (Resolve-Path $root).Path

      if (Test-Path $filePath -PathType Leaf) {
        $resolvedFile = (Resolve-Path $filePath).Path
        if ($resolvedFile.StartsWith($fullRoot)) {
          $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
          $respType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
          $respBody = [System.IO.File]::ReadAllBytes($filePath)
        } else {
          $status = "403 Forbidden"
          $respType = "text/plain"
          $respBody = [System.Text.Encoding]::UTF8.GetBytes("403 Forbidden")
        }
      } else {
        $status = "404 Not Found"
        $respType = "text/plain"
        $respBody = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $reqPath")
      }
    }
    else {
      $status = "404 Not Found"
      $respBody = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":false,`"error`":`"not found`"}")
    }

    Send-Response $stream $status $respType $respBody
    Write-Output "$(Get-Date -Format 'HH:mm:ss') $($req.Method) $($req.Path) -> $status"
  } catch {
    Write-Output "$(Get-Date -Format 'HH:mm:ss') ERROR: $_"
  } finally {
    $client.Close()
  }
}

$initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(2, 16, $initialSessionState, $Host)
$runspacePool.Open()
$activeJobs = New-Object System.Collections.Generic.List[object]

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
$listener.Start()

$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1 -ExpandProperty IPAddress)
Write-Host "Serving $root (concurrent)"
Write-Host "  Admin panel: http://localhost:$port/admin.html"
Write-Host "  Local:       http://localhost:$port/"
if ($ip) { Write-Host "  Network:     http://$ip`:$port/" }
Write-Host "(Ctrl+C to stop)"

while ($true) {
  $client = $listener.AcceptTcpClient()

  $ps = [powershell]::Create()
  $ps.RunspacePool = $runspacePool
  [void]$ps.AddScript($handlerScript).AddArgument($client).AddArgument($root)
  $handle = $ps.BeginInvoke()
  $activeJobs.Add(@{ PS = $ps; Handle = $handle })

  $stillActive = New-Object System.Collections.Generic.List[object]
  foreach ($job in $activeJobs) {
    if ($job.Handle.IsCompleted) {
      try {
        $output = $job.PS.EndInvoke($job.Handle)
        foreach ($line in $output) { Write-Host $line }
      } catch {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') worker error: $_"
      }
      $job.PS.Dispose()
    } else {
      $stillActive.Add($job)
    }
  }
  $activeJobs = $stillActive
}
