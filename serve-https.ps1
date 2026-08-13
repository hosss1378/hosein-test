$root = $PSScriptRoot
$port = 8443

$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $ip) { $ip = "127.0.0.1" }

$certSubject = "CN=$ip"
$existing = Get-ChildItem "Cert:\CurrentUser\My" | Where-Object { $_.Subject -eq $certSubject } | Select-Object -First 1
if ($existing) {
  $cert = $existing
} else {
  $cert = New-SelfSignedCertificate -Subject $certSubject -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddYears(2) `
    -TextExtension @("2.5.29.17={text}IPAddress=$ip") -FriendlyName "ARTestLocalCert"
}

$handlerScript = {
  param($client, $cert, $root)

  $mime = @{
    ".html" = "text/html; charset=utf-8"; ".htm" = "text/html; charset=utf-8"
    ".js" = "application/javascript"; ".css" = "text/css"
    ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"; ".svg" = "image/svg+xml"; ".mind" = "application/octet-stream"
    ".mp4" = "video/mp4"; ".mov" = "video/quicktime"; ".webm" = "video/webm"
    ".glb" = "model/gltf-binary"; ".gltf" = "model/gltf+json"
    ".json" = "application/json; charset=utf-8"; ".ico" = "image/x-icon"
  }

  try {
    $client.ReceiveTimeout = 20000
    $client.SendTimeout = 20000
    $rawStream = $client.GetStream()
    $sslStream = New-Object System.Net.Security.SslStream($rawStream, $false)
    $sslStream.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13, $false)

    $buffer = New-Object byte[] 8192
    $read = $sslStream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { $client.Close(); return }
    $requestText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    $firstLine = ($requestText -split "`r`n")[0]
    $parts = $firstLine -split " "
    $reqPath = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
    $reqPath = $reqPath -split "\?" | Select-Object -First 1
    if ($reqPath -eq "/") { $reqPath = "/index.html" }

    $decodedPath = [System.Uri]::UnescapeDataString($reqPath)
    $filePath = Join-Path $root ($decodedPath.TrimStart("/") -replace "/", "\")
    $fullRoot = (Resolve-Path $root).Path

    $bodyBytes = $null
    $status = "200 OK"
    $contentType = "application/octet-stream"

    if ((Test-Path $filePath -PathType Leaf)) {
      $resolvedFile = (Resolve-Path $filePath).Path
      if ($resolvedFile.StartsWith($fullRoot)) {
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        if ($mime.ContainsKey($ext)) { $contentType = $mime[$ext] }
        $bodyBytes = [System.IO.File]::ReadAllBytes($filePath)
      } else {
        $status = "403 Forbidden"
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes("403 Forbidden")
      }
    } else {
      $status = "404 Not Found"
      $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $decodedPath")
    }

    $headerText = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($bodyBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerText)
    $sslStream.Write($headerBytes, 0, $headerBytes.Length)
    $sslStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $sslStream.Flush()
    $remoteIp = $client.Client.RemoteEndPoint
    Write-Output "$(Get-Date -Format 'HH:mm:ss') $remoteIp -> $decodedPath -> $status"
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

Write-Host "Serving $root over HTTPS (self-signed cert, concurrent)"
Write-Host "  Network: https://$ip`:$port/  <- open this on your phone"
Write-Host "  On first visit you'll see an untrusted-certificate warning -> tap Advanced -> Proceed"
Write-Host "(Ctrl+C to stop)"

while ($true) {
  $client = $listener.AcceptTcpClient()

  $ps = [powershell]::Create()
  $ps.RunspacePool = $runspacePool
  [void]$ps.AddScript($handlerScript).AddArgument($client).AddArgument($cert).AddArgument($root)
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
