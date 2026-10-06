<#
 .SYNOPSIS
   Comprueba el stack de una sola pasada: login web, API, Director, una
   notificación de correo de extremo a extremo, las gráficas (InfluxDB +
   Grafana) y las copias de seguridad (volcado de MySQL + Duplicati,
   incluida una restauración real).

 .EXAMPLE
   .\verify.ps1                 # stack de produccion (8080 / 5665 / 8025 / 3000 / 8200)
   .\verify.ps1 -CleanTest      # proyecto clean-test (18080 / 15665 / 18025 / 13000 / 18200)

 Devuelve 0 si todo pasa, y el numero de fallos en caso contrario.
#>
param([switch]$CleanTest)

$ErrorActionPreference = "SilentlyContinue"

if ($CleanTest) {
  $web  = "http://localhost:18080"
  $api  = "https://localhost:15665"
  $mail = "http://localhost:18025"
  $graf = "http://localhost:13000"
  $dup  = "http://localhost:18200"
  $cWeb    = "ct-icinga-web"
  $cInflux = "ct-influxdb"
  $cDump   = "ct-icinga-mysql-dump"
  $cDup    = "ct-icinga-duplicati"
  $cDupIni = "ct-icinga-duplicati-init"
  $cMirror = "ct-icinga-project-mirror"
  $tag  = "CLEAN-TEST"
  # El proyecto que se esta verificando es _clean-test/, no la raiz: los
  # ficheros que se comparan con lo restaurado tienen que salir de ahi.
  $projRoot = Join-Path $PSScriptRoot "_clean-test"
} else {
  $web  = "http://localhost:8080"
  $api  = "https://localhost:5665"
  $mail = "http://localhost:8025"
  $graf = "http://localhost:3000"
  $dup  = "http://localhost:8200"
  $cWeb    = "icinga-web"
  $cInflux = "influxdb"
  $cDump   = "icinga-mysql-dump"
  $cDup    = "icinga-duplicati"
  $cDupIni = "icinga-duplicati-init"
  $cMirror = "icinga-project-mirror"
  $tag  = "PRODUCCION"
  $projRoot = $PSScriptRoot
}

$fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { "  [OK]   $name" }
  else { $script:fail++; "  [FAIL] $name :: $detail" }
}

"===== VERIFICACION $tag ====="

# --- 1. Login ---------------------------------------------------------------
# Icinga Web 2 redirige dos veces (set-cookie) y el campo CSRF se llama
# literalmente `CSRFToken`, no `_csrf_token`.
try {
  $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $r0 = Invoke-WebRequest "$web/authentication/login" -WebSession $s -UseBasicParsing -TimeoutSec 60
  $m = [regex]::Match($r0.Content, 'value="([^"]+)"\s+name="CSRFToken"')
  Check "login: token CSRF presente" ($m.Success -and $m.Groups[1].Value.Length -gt 10) "pagina=$($r0.StatusCode)"
  $body = "CSRFToken=" + [uri]::EscapeDataString($m.Groups[1].Value) +
          "&uid=form_login&username=admin&password=icingaadmin123&rememberme=n" +
          "&submit_login=Login&redirect=dashboard"
  Invoke-WebRequest "$web/authentication/login?redirect=dashboard" -Method POST -Body $body `
    -ContentType "application/x-www-form-urlencoded" -WebSession $s -UseBasicParsing -TimeoutSec 60 |
    Out-Null
  $r2 = Invoke-WebRequest "$web/dashboard" -WebSession $s -UseBasicParsing -TimeoutSec 60
  $title = [regex]::Match($r2.Content, '<title>([^<]+)</title>').Groups[1].Value
  Check "login admin/icingaadmin123 -> dashboard" ($r2.StatusCode -eq 200 -and $title -match "Dashboard") $title
} catch { Check "login web" $false $_.Exception.Message }

# --- 2. API -----------------------------------------------------------------
try {
  $jh = "$env:TEMP\verify_hosts.json"; $js = "$env:TEMP\verify_svc.json"
  curl.exe -sk -u "icingaweb:icingaweb123" -H "Accept: application/json" "$api/v1/objects/hosts" -o $jh | Out-Null
  $hosts = @((Get-Content $jh -Raw | ConvertFrom-Json).results)
  Check "API: >= 6 hosts" ($hosts.Count -ge 6) $hosts.Count
  curl.exe -sk -u "icingaweb:icingaweb123" -H "Accept: application/json" "$api/v1/objects/services" -o $js | Out-Null
  $services = @((Get-Content $js -Raw | ConvertFrom-Json).results)
  Check "API: >= 31 servicios" ($services.Count -ge 31) $services.Count

  # Los cinco servicios que vigilan las copias (seccion 6 y
  # icinga2-conf/conf.d/stack-monitoring.conf). Se comprueban por nombre y
  # no solo por el recuento: el recuento seguiria cuadrando si desapareciera
  # uno de ellos y apareciera otro.
  $esperados = @(
    'icinga2!Backup - Last upload',
    'icinga2!Backup - Free space',
    'icinga2!Backup - Project mirror',
    'icinga2!Backup - MySQL dump',
    'icinga2!Backup - Scheduled run'
  )
  $hay = @($services | ForEach-Object { $_.attrs.__name })
  $bak = @($services | Where-Object { $_.attrs.__name -like '*Backup - *' })
  $faltan = @($esperados | Where-Object { $_ -notin $hay })
  Check "API: 5 servicios 'Backup - *' vigilando las copias" `
       ($bak.Count -ge 5 -and $faltan.Count -eq 0) `
       "$($bak.Count) en total; faltan: $(if ($faltan.Count) { $faltan -join ', ' } else { 'ninguno' })"

  # El heartbeat de Icinga DB: el daemon no publica puerto y su imagen no
  # admite healthcheck, asi que este servicio es lo unico que lo vigila.
  # Tambien por nombre: el recuento cuadraria aunque desapareciera.
  $hb = @($services | Where-Object { $_.attrs.__name -eq 'icingadb!Icinga DB - Heartbeat' })
  Check "API: servicio 'Icinga DB - Heartbeat' presente" ($hb.Count -eq 1) "$($hb.Count) encontrado(s)"

  $bad = @($services | Where-Object { $_.attrs.state -ne 0 })

  # Tras un reinicio del stack los checks tardan en asentarse: los que se
  # apoyan en `Uptime` necesitan mas de 60 s de vida del contenedor Y un
  # ciclo de chequeo posterior, y hasta entonces Icinga reporta WARNING
  # aunque todo este bien. Se reconsulta con tope de 3 min. Si aun asi hay
  # servicios fuera de OK, el chequeo de abajo lo dice con los motivos
  # reales (el `services.Count -gt 0` evita quedarse esperando si la
  # consulta a la API ha fallado).
  $deadline = (Get-Date).AddMinutes(3)
  while ($bad.Count -gt 0 -and $services.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    curl.exe -sk -u "icingaweb:icingaweb123" -H "Accept: application/json" "$api/v1/objects/services" -o $js | Out-Null
    $services = @((Get-Content $js -Raw | ConvertFrom-Json).results)
    $bad = @($services | Where-Object { $_.attrs.state -ne 0 })
  }

  Check "API: todos los servicios en OK" ($bad.Count -eq 0) `
        (($bad | ForEach-Object { $_.attrs.__name }) -join ", ")
} catch { Check "API Icinga" $false $_.Exception.Message }

# --- 3. Director ------------------------------------------------------------
try {
  $h = @(docker exec $cWeb icingacli director health 2>&1) -join "`n"
  Check "Director health: everything is fine"  ($h -match "everything is fine")   $h.Substring(0, [Math]::Min(240, $h.Length))
  Check "Director: 0 cambios sin desplegar"    ($h -match "There are 0 un-deployed changes") ""
  Check "Director: sin migraciones pendientes" ($h -match "no pending schema migrations") ""
  Check "Director: ultimo deployment OK"       ($h -match "last Deployment was successful") ""
} catch { Check "Director" $false $_.Exception.Message }

# --- 4. Notificacion -> Mailpit --------------------------------------------
try {
  $mj = "$env:TEMP\verify_mail.json"
  curl.exe -s "$mail/api/v1/messages" -o $mj | Out-Null
  $before = (Get-Content $mj -Raw | ConvertFrom-Json).total

  $payload = '{"service":"mariadb!ping4","type":"PROBLEM","severity":"CRITICAL",' +
             '"author":"verify","comment":"Verificacion ' + $tag + '",' +
             '"text":"Verificacion end-to-end ' + $tag + '","force":true}'
  $pj = "$env:TEMP\verify_payload.json"
  [System.IO.File]::WriteAllText($pj, $payload, (New-Object System.Text.UTF8Encoding($false)))
  $res = curl.exe -sk -u "icingaweb:icingaweb123" -H "Content-Type: application/json" -H "Accept: application/json" `
         -X POST "$api/v1/actions/send-custom-notification" --data-binary "@$pj"
  Check "API: send-custom-notification aceptada" ((@($res) -join " ") -match '"code":\s*200') (@($res) -join " ")

  Start-Sleep -Seconds 15
  curl.exe -s "$mail/api/v1/messages" -o $mj | Out-Null
  $after = (Get-Content $mj -Raw | ConvertFrom-Json).total
  Check "Mailpit: mensaje nuevo ($before -> $after)" ($after -gt $before) "$before -> $after"
  if ($after -gt $before) {
    $subj = @(Get-Content $mj -Raw | ConvertFrom-Json).messages[0].Subject
    Check "Mailpit: asunto del aviso" ($subj -match "ping4") $subj
  }
} catch { Check "Notificacion/Mailpit" $false $_.Exception.Message }

# --- 5. InfluxDB + Grafana ---------------------------------------------------
# El performance data de cada check viaja Icinga 2 -> InfluxdbWriter ->
# InfluxDB, y Grafana lo grafica. Sin esto los paneles salen vacios.
try {
  $m = @(docker exec $cInflux influx -database icinga2 -execute "SHOW MEASUREMENTS" 2>&1) -join "`n"
  Check "InfluxDB: mediciones 'ping4' y 'load'" (($m -match "ping4") -and ($m -match "load")) `
        ($m -replace "`r?`n", " ").Substring(0, [Math]::Min(160, $m.Length))

  # Los servicios de copias emiten perfdata (age_s / free_gb) y sin ella sus
  # paneles de Grafana saldrian vacios aunque el check este en OK. Se comprueba
  # la medicion aparte para que un fallo apunte a esto y no a ping4/load.
  Check "InfluxDB: medicion 'backup_health' (metricas de copias)" ($m -match "backup_health") `
        ($m -replace "`r?`n", " ").Substring(0, [Math]::Min(200, $m.Length))

  # Datos frescos: si el writer se cayera, las mediciones seguirian ahí pero
  # dejarian de crecer, y eso es exactamente lo que hay que detectar.
  $fq = 'SELECT count("value") FROM "ping4" WHERE "metric" = ''rta'' AND time > now() - 5m'
  $fj = @(docker exec $cInflux influx -database icinga2 -format json -execute $fq 2>&1) -join "`n"
  $n = 0
  try {
    $series = @((($fj | ConvertFrom-Json).results[0].series))
    if ($series.Count -gt 0) { $n = [int]$series[0].values[0][1] }
  } catch { $n = 0 }
  Check "InfluxDB: puntos nuevos en los ultimos 5 min" ($n -gt 0) "$n puntos :: $($fj.Substring(0,[Math]::Min(160,$fj.Length)))"
} catch { Check "InfluxDB" $false $_.Exception.Message }

try {
  $gh = Invoke-WebRequest "$graf/api/health" -UseBasicParsing -TimeoutSec 30
  Check "Grafana: /api/health OK" ($gh.StatusCode -eq 200 -and $gh.Content -match '"database":\s*"ok"') $gh.Content

  $ga = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:icingaadmin123")) }
  $ds = Invoke-WebRequest "$graf/api/datasources" -Headers $ga -UseBasicParsing -TimeoutSec 30
  Check "Grafana: datasource InfluxDB provisionado" ($ds.Content -match '"uid":"icinga-influx"') $ds.Content

  $db = Invoke-WebRequest "$graf/api/search?type=dash-db" -Headers $ga -UseBasicParsing -TimeoutSec 30
  Check "Grafana: dashboard provisionado" ($db.Content -match '"uid":"icinga-stack"') $db.Content

  # El dashboard trae 19 paneles. Se comprueba por id el de Icinga DB, no
  # solo el recuento: con un panel menos y otro de mas el recuento seguira
  # cuadrando. Se lee de la API (lo que Grafana sirve), no del JSON.
  $dbf = Invoke-WebRequest "$graf/api/dashboards/uid/icinga-stack" -Headers $ga -UseBasicParsing -TimeoutSec 30
  $dp  = @(($dbf.Content | ConvertFrom-Json).dashboard.panels)
  $hbp = @($dp | Where-Object { $_.id -eq 19 -and $_.title -like "*Icinga DB*" })
  Check "Grafana: 19 paneles y el de Icinga DB presente" `
        ($dp.Count -ge 19 -and $hbp.Count -eq 1) `
        "$($dp.Count) paneles; panel 19 de Icinga DB: $($hbp.Count)"
} catch { Check "Grafana" $false $_.Exception.Message }

# --- 6. Copias de seguridad -------------------------------------------------
# Flujo completo: mysqldump -> backup_staging -> Duplicati -> ./backups
# Se comprueban las cuatro piezas y, sobre todo, una RESTAURACION real: un
# backup que no se puede restaurar no es un backup.
try {
  # 6.1 volcado de MySQL: presente y fresco (se renueva cada 10 min)
  $dsz = (docker exec $cDump sh -c "wc -c < /staging/dump.sql" 2>&1) -join " "
  Check "mysqldump: volcado en /staging" ($dsz -match '\d{5,}') $dsz
  $fr = (docker exec $cDump sh -c "find /staging/dump.sql -mmin -15" 2>&1) -join " "
  Check "mysqldump: volcado con menos de 15 min" ($fr -match 'dump\.sql') $fr

  # 6.2 servidor Duplicati vivo
  $dupCode = 0
  try { $dupCode = (Invoke-WebRequest "$dup/" -UseBasicParsing -TimeoutSec 30).StatusCode } catch {}
  Check "Duplicati: interfaz responde" ($dupCode -eq 200) "HTTP $dupCode"

  # 6.3 el alta declarativa se ejecuto sin errores
  $initCode = (docker inspect $cDupIni --format '{{.State.ExitCode}}' 2>&1) -join ""
  Check "duplicati-init: copia dada de alta (exit 0)" ($initCode.Trim() -eq "0") $initCode

  # 6.4 login contra la API
  $lf = Join-Path $env:TEMP "verify_dup_login.json"
  $tf = Join-Path $env:TEMP "verify_dup_tok.json"
  [System.IO.File]::WriteAllText($lf, '{"Username":"admin","Password":"icingaadmin123"}',
                                 (New-Object System.Text.UTF8Encoding($false)))
  curl.exe -s -X POST "$dup/api/v1/auth/login" -H "Content-Type: application/json" `
           --data-binary "@$lf" -o $tf | Out-Null
  $dupTok = $null
  try { $dupTok = (Get-Content $tf -Raw | ConvertFrom-Json).AccessToken } catch {}
  Check "Duplicati: login API" ($null -ne $dupTok) "sin token"

  $bid = ""
  if ($dupTok) {
    $hf = "Authorization: Bearer $dupTok"
    $bf = Join-Path $env:TEMP "verify_dup_backups.json"
    curl.exe -s -X GET "$dup/api/v1/backups" -H $hf -o $bf | Out-Null
    $entry = $null
    try {
      # Ojo con `@(...)` aqui: en PowerShell 5.1 envuelve el array que devuelve
      # ConvertFrom-Json como UN solo elemento, de modo que Where-Object
      # recibira la lista entera en vez de una entrada y Select-Object -First 1
      # devolveria otra vez la lista. Con una unica copia en el servidor pasa
      # por accidente (todo se reduce a un array de un elemento); con dos, el
      # ID resultante seria "1 2" y la URL siguiente se romperia. Se asigna
      # primero y se envuelve despues.
      $all = Get-Content $bf -Raw | ConvertFrom-Json
      $entry = @($all) |
                 Where-Object { $_.Backup.Name -eq "icinga-stack" } | Select-Object -First 1
    } catch {}
    Check "Duplicati: copia 'icinga-stack' dada de alta" ($null -ne $entry) "no encontrada"

    # Cada JSON declarativo de backup/*.json tiene que aparecer en el
    # servidor: es la prueba de que lo declarado y lo real estan
    # sincronizados (duplicati-init da de alta todos los que encuentra).
    # Ojo con @() en PS 5.1: aqui se envuelve el resultado de
    # Get-ChildItem, nunca un `ConvertFrom-Json` (que envolveria el array
    # entero como UN solo elemento).
    $declared = @()
    $bdir = Join-Path $projRoot 'backup'
    foreach ($f in @(Get-ChildItem -LiteralPath $bdir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $t = [IO.File]::ReadAllText($f.FullName)
      if ($t -match '"Name"\s*:\s*"([^"]+)"') { $declared += $Matches[1] }
    }
    $missing = @()
    foreach ($n in $declared) {
      $hit = @($all) | Where-Object { $_.Backup.Name -eq $n } | Select-Object -First 1
      if ($null -eq $hit) { $missing += $n }
    }
    $detail = "declaradas: $($declared -join ', ')"
    if ($declared.Count -eq 0)      { $detail = "sin ningun *.json en $bdir" }
    elseif ($missing.Count -gt 0)   { $detail = "faltan: $($missing -join ', ')" }
    Check "Duplicati: $($declared.Count) copia(s) declarada(s) en backup/ dadas de alta" `
          ($declared.Count -ge 1 -and $missing.Count -eq 0) $detail

    if ($entry) {
      $bid = $entry.Backup.ID
      $df = Join-Path $env:TEMP "verify_dup_detail.json"
      curl.exe -s -X GET "$dup/api/v1/backup/$bid" -H $hf -o $df | Out-Null
      $d = $null
      try { $d = Get-Content $df -Raw | ConvertFrom-Json } catch {}
      if ($d) {
        $src = @($d.Backup.Sources)
        $set = @($d.Backup.Settings | ForEach-Object { "$($_.Name)=$($_.Value)" })

        Check "Duplicati: 19 origenes (volcado + volumenes + proyecto)" ($src.Count -ge 19) $src.Count
        Check "Duplicati: el volcado de MySQL es origen" `
              ($src -contains "/sources/volumes/mysql-dump") ($src -join ", ")
        Check "Duplicati: safety-net.ps1 es origen (la red de seguridad se copia)" `
              ($src -contains "/sources/project/safety-net.ps1") ($src -join ", ")
        Check "Duplicati: docker-compose.yml es origen" `
              ($src -contains "/sources/project/docker-compose.yml") ($src -join ", ")
        Check "Duplicati: db_data NO es origen (se respalda el volcado)" `
              (-not ($src -contains "/sources/volumes/db_data")) ($src -join ", ")
        Check "Duplicati: cifrado desactivado (--no-encryption)" `
              ($set -contains "--no-encryption=true") ($set -join " | ")
        Check "Duplicati: retencion 14D:0s,8W:7D,1Y:30D" `
              ($set -contains "retention-policy=14D:0s,8W:7D,1Y:30D") ($set -join " | ")
        Check "Duplicati: planificacion diaria" ($d.Schedule.Repeat -eq "1D") `
              ($d.Schedule | ConvertTo-Json -Compress)
      }

      # 6.5 ejecutar una copia real y comprobar el resultado
      $rf = Join-Path $env:TEMP "verify_dup_run.json"
      [System.IO.File]::WriteAllText($rf, "{}", (New-Object System.Text.UTF8Encoding($false)))
      curl.exe -s -X POST "$dup/api/v1/backup/$bid/run" -H $hf `
               -H "Content-Type: application/json" --data-binary "@$rf" -o $rf | Out-Null
      $act = ""; $t = 0
      while ($t -lt 180) {
        $act = (curl.exe -s -X GET "$dup/api/v1/backup/$bid/isactive" -H $hf) -join ""
        if (($t -ge 15) -and ($act -match '"Active":false')) { break }
        Start-Sleep -Seconds 3; $t += 3
      }
      Check "Duplicati: ejecucion terminada" ($act -match '"Active":false') $act

      # El resultado real de la ultima operacion Backup. Se busca la entrada
      # Backup del log porque las restauraciones de mas abajo se apilan
      # delante.
      #
      # OJO con Metadata.LastErrorMessage: era lo que usaba el chequeo de
      # "sin errores" y no sirve. Duplicati lo deja fijado hasta el siguiente
      # error de CUALQUIER operacion y no lo borra al volver a tener exito, de
      # modo que un unico Restore fallido (una restauracion de prueba a ciegas
      # de un fichero que aun no esta en el fileset, por ejemplo) dejaria este
      # check en rojo para siempre. Los dos chequeos salen del mismo log.
      #
      # Ojo con `@($lr | ConvertFrom-Json)`: en PowerShell 5.1 ese array se
      # envuelve como UN solo elemento, asi que el bucle recorre una unica vez
      # la lista entera, `$e` deja de ser una entrada y los [int] caen sobre un
      # Object[] -> excepcion, que el catch se traga en silencio y no queda ni
      # OK ni FAIL. Se asigna primero (la asignacion si desempaqueta) y el
      # Check se deja fuera del bucle.
      $mm = $null
      try {
        $lr = (curl.exe -s -X GET "$dup/api/v1/backup/$bid/log?limit=10" -H $hf) -join ""
        $entries = $lr | ConvertFrom-Json
        foreach ($e in $entries) {
          $m1 = $null
          try { $m1 = $e.Message | ConvertFrom-Json } catch {}
          if ($m1 -and $m1.MainOperation -eq "Backup") { $mm = $m1; break }
        }
      } catch {}

      curl.exe -s -X GET "$dup/api/v1/backup/$bid" -H $hf -o $df | Out-Null
      $d2 = $null
      try { $d2 = Get-Content $df -Raw | ConvertFrom-Json } catch {}
      $meta = if ($d2) { $d2.Backup.Metadata } else { $null }

      if ($mm) {
        Check "Duplicati: ultima copia sin errores" `
              ([int]$mm.ErrorsActualLength -eq 0) `
              "ParsedResult=$($mm.ParsedResult) Errors=$($mm.ErrorsActualLength)"
      } else {
        Check "Duplicati: ultima copia sin errores" $false "sin entrada Backup en el log"
      }

      $nfs = 0
      if ($meta -and $meta.TargetFilesetsCount) { $nfs = [int]$meta.TargetFilesetsCount }
      Check "Duplicati: fileset creado" ($nfs -ge 1) $nfs
      $ssz = 0
      if ($meta -and $meta.SourceFilesSize) { $ssz = [int64]$meta.SourceFilesSize }
      # Backstop grosero: si desapareciera uno de los volumenes grandes, el
      # total se desploma. El valor depende del entorno (produccion ~128 MiB,
      # un stack recien creado ~72 MiB porque InfluxDB aun no ha acumulado),
      # por eso se fija en 30 MiB y no en algo ajustado a produccion.
      Check "Duplicati: origen > 30 MiB (nada omitido)" ($ssz -gt 31457280) "$ssz bytes"

      if ($mm) {
        $worst = "ParsedResult=$($mm.ParsedResult) Warnings=$($mm.WarningsActualLength) Errors=$($mm.ErrorsActualLength)"
        Check "Duplicati: ultima copia sin avisos" `
              ($mm.ParsedResult -eq "Success" -and
               [int]$mm.WarningsActualLength -eq 0 -and
               [int]$mm.ErrorsActualLength -eq 0) $worst
      } else {
        Check "Duplicati: ultima copia sin avisos" $false "sin entrada Backup en el log"
      }

      # 6.6 destino local con ficheros
      $dst = (docker exec $cDup sh -c "find /dest -type f -name duplicati-*.zip" 2>&1) -join "`n"
      Check "Duplicati: ficheros .zip en el destino" ($dst -match '\.zip') $dst

      # 6.7 RESTAURACION: recuperar tres ficheros y compararlos con el original
      # Los directorios destino se crean antes a proposito: si no, Duplicati
      # emite dos "CreateMissingFolder" y deja la copia con estado Warning en
      # la UI, cuando lo que ha fallado es nuestra propia comprobacion.
      # OJO con cuantas rutas se pasan: Duplicati usa el ancestro comun de la
      # seleccion como base, de modo que con UNA sola ruta /sources/project/x
      # el fichero caeria en la raiz (restore_path/x) y no en
      # restore_path/project/x. Al pedir rutas de /sources/project y de
      # /sources/volumes a la vez la base es /sources y todo cae donde toca.
      docker exec $cDup sh -c "rm -rf /tmp/rtest; mkdir -p /tmp/rtest/volumes/mysql-dump /tmp/rtest/project" | Out-Null
      $pf = Join-Path $env:TEMP "verify_dup_restore.json"
      $body = '{"paths":["/sources/project/README.md","/sources/project/safety-net.ps1",' +
              '"/sources/volumes/mysql-dump/dump.sql"],' +
              '"time":"","restore_path":"/tmp/rtest","overwrite":true,"skip_metadata":true}'
      [System.IO.File]::WriteAllText($pf, $body, (New-Object System.Text.UTF8Encoding($false)))
      curl.exe -s -X POST "$dup/api/v1/backup/$bid/restore" -H $hf `
               -H "Content-Type: application/json" --data-binary "@$pf" `
               -o (Join-Path $env:TEMP "verify_dup_restore_out.json") | Out-Null
      Start-Sleep -Seconds 10
      $tree = (docker exec $cDup sh -c "find /tmp/rtest -type f" 2>&1) -join "`n"
      Check "Duplicati: restauracion con README.md, safety-net.ps1 y dump.sql" `
            (($tree -match 'README\.md') -and ($tree -match 'safety-net\.ps1') -and
             ($tree -match 'dump\.sql')) $tree

      # bit a bit contra el original local
      $hashLocal = (Get-FileHash (Join-Path $projRoot "README.md") -Algorithm SHA256).Hash
      $hashBack = (docker exec $cDup sh -c "sha256sum /tmp/rtest/project/README.md" 2>&1) -join " "
      Check "Duplicati: README.md restaurado identico (SHA256)" `
            (($hashLocal.Length -eq 64) -and ($hashBack -match $hashLocal)) "$hashBack"

      # y la red de seguridad, que es el fichero que protege el catalogo
      $hashLocalSn = (Get-FileHash (Join-Path $projRoot "safety-net.ps1") -Algorithm SHA256).Hash
      $hashBackSn = (docker exec $cDup sh -c "sha256sum /tmp/rtest/project/safety-net.ps1" 2>&1) -join " "
      Check "Duplicati: safety-net.ps1 restaurado identico (SHA256)" `
            (($hashLocalSn.Length -eq 64) -and ($hashBackSn -match $hashLocalSn)) "$hashBackSn"

      # el dump restaurado tiene que ser un volcado de verdad
      $rsz = (docker exec $cDup sh -c "wc -c < /tmp/rtest/volumes/mysql-dump/dump.sql" 2>&1) -join " "
      Check "Duplicati: dump.sql restaurado > 1 MB" ($rsz -match '\d{7,}') $rsz
      $cdb = (docker exec $cDup sh -c "grep -c CREATE DATABASE /tmp/rtest/volumes/mysql-dump/dump.sql" 2>&1) -join " "
      Check "Duplicati: dump.sql restaurado crea bases" ($cdb -match '\d+') $cdb

      docker exec $cDup sh -c "rm -rf /tmp/rtest" | Out-Null
    }
  }

  # 6.8 Red de seguridad: los .tar que saca safety-net.ps1 con el stack
  # parado. Es la pieza que reconstruye el catalogo de Duplicati si se pierde
  # duplicati_config (el caso RemoteListVerificationException del apartado de
  # problemas), asi que si se queda obsoeta no sale a la luz hasta el
  # desastre. Solo en produccion: safety-net.ps1 es una herramienta del host
  # y una copia limpia no la tiene, de modo que comprobarla aqui acoplaria
  # el clean-test al estado de produccion. Si sale este FAIL, la vuelta es
  # `.\safety-net.ps1 -SoloCatalogo` (~15 s, solo para de Duplicati).
  if (-not $CleanTest) {
    $snDir = ''
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $projRoot 'docker-compose.yml'))) {
      # La unica linea cuyo destino montado en /dest tiene UN solo tramo es
      # la de `duplicati`; la de `project-mirror` lleva ademas /project y no
      # encaja. Asi el directorio se lee del compose en vez de quedar escrito
      # a mano en dos sitios (y si un dia se mueve el destino, verify lo sigue).
      if ($l -match '^\s*-\s*(?<dst>[A-Za-z]:/[\w.-]+):/dest\s*$') { $snDir = $Matches['dst']; break }
    }
    Check "safety-net: destino de copias leido del compose" ($snDir -ne '') $snDir

    if ($snDir -ne '') {
      $sn = Join-Path ($snDir -replace '/', '\') 'safety-net'
      $tars = @(Get-ChildItem -LiteralPath $sn -Filter '*.tar' -File -ErrorAction SilentlyContinue)
      Check "safety-net: al menos 12 .tar (volumenes del stack)" ($tars.Count -ge 12) "$($tars.Count) en $sn"

      $cat = Join-Path $sn 'duplicati_config.tar'
      $h = -1.0
      if (Test-Path -LiteralPath $cat) {
        $h = ((Get-Date) - (Get-Item -LiteralPath $cat).LastWriteTime).TotalHours
      }
      Check "safety-net: duplicati_config.tar con menos de 7 dias" ($h -ge 0 -and $h -lt 168) `
            $(if ($h -lt 0) { 'no existe' } else { "hace $([int]$h) h" })
    }
  }
} catch { Check "Duplicati" $false $_.Exception.Message }

# --- 7. Espejo del proyecto --------------------------------------------------
# Copia en plano del proyecto en el otro disco fisico (ver
# backup/project-mirror.sh). Es lo que permite volver a arrancar sin tocar
# Duplicati si se pierde el disco que lleva los datos: el compose y la
# configuracion quedan en texto legible.
try {
  $mh = (docker inspect $cMirror --format '{{.State.Health.Status}}' 2>&1) -join " "
  Check "project-mirror: contenedor healthy" ($mh.Trim() -eq "healthy") $mh

  $mt = (docker exec $cMirror sh -c "find /dest/.last-sync -mmin -30" 2>&1) -join " "
  Check "project-mirror: sincronizado hace menos de 30 min" ($mt -match 'last-sync') $mt

  $mc = (docker exec $cMirror sh -c "test -f /dest/docker-compose.yml && find /dest -type f | wc -l" 2>&1) -join " "
  Check "project-mirror: compose copiado en el espejo" ($mc -match '\d+') $mc
} catch { Check "project-mirror" $false $_.Exception.Message }

"===== TOTAL FALLOS: $fail ====="
exit $fail
