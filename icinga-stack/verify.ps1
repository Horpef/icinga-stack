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
  Check "API: >= 9 hosts" ($hosts.Count -ge 9) $hosts.Count
  curl.exe -sk -u "icingaweb:icingaweb123" -H "Accept: application/json" "$api/v1/objects/services" -o $js | Out-Null
  $services = @((Get-Content $js -Raw | ConvertFrom-Json).results)
  Check "API: >= 40 servicios" ($services.Count -ge 40) $services.Count

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

  # Los tres hosts y los cinco servicios del stack ajeno (Fase 2). Por
  # nombre, no solo por recuento: con mas hosts y servicios el recuento
  # seguiria cuadrando aunque desapareciera el indexer entero y entrara
  # otro servicio en su lugar. Mismo criterio que los "Backup - *".
  $wzEsperados = @('wazuh-dashboard', 'wazuh-indexer', 'wazuh-manager')
  $wzHay = @($hosts | ForEach-Object { $_.attrs.__name })
  $wzFaltan = @($wzEsperados | Where-Object { $_ -notin $wzHay })
  Check "API: 3 hosts del stack Wazuh dados de alta" `
        ($wzFaltan.Count -eq 0) `
        $(if ($wzFaltan.Count -eq 0) { 'wazuh-dashboard, wazuh-indexer, wazuh-manager' }
          else { "faltan: $($wzFaltan -join ', ')" })

  $wzServicios = @(
    'wazuh-manager!Wazuh Manager - API (HTTPS)',
    'wazuh-manager!Wazuh Manager - Agentes',
    'wazuh-manager!Wazuh Manager - Alta de agentes',
    'wazuh-indexer!Wazuh Indexer - Salud del cluster',
    'wazuh-dashboard!Wazuh Dashboard - Pagina de acceso'
  )
  $wzFS = @($wzServicios | Where-Object { $_ -notin $hay })
  Check "API: 5 servicios del stack Wazuh (API, agentes, alta, cluster, panel)" `
        ($wzFS.Count -eq 0) `
        $(if ($wzFS.Count -eq 0) { 'los 5 presentes' }
          else { "faltan: $($wzFS -join ', ')" })

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

# 4b. El mismo camino, pero sobre un objeto del stack AJENO. Es literalmente
# el criterio de hecho de la Fase 2 ("dispara una notificacion que acaba en
# Mailpit"): el bloque de arriba manda un aviso contra mariadb, que es del
# propio stack de monitorizacion, y eso probaria la cadena de correo pero no
# que las reglas de notificacion casen con los hosts nuevos. Aqui se manda un
# aviso custom contra un servicio de wazuh-manager y se espera verlo llegar.
try {
  $mzw = "$env:TEMP\verify_mail_wazuh.json"
  curl.exe -s "$mail/api/v1/messages" -o $mzw | Out-Null
  $bzw = (Get-Content $mzw -Raw | ConvertFrom-Json).total

  $pzw = '{"service":"wazuh-manager!Wazuh Manager - API (HTTPS)","type":"PROBLEM","severity":"CRITICAL",' +
         '"author":"verify","comment":"Verificacion Fase 2 ' + $tag + '",' +
         '"text":"Notificacion del stack Wazuh ' + $tag + '","force":true}'
  $pjz = "$env:TEMP\verify_payload_wazuh.json"
  [System.IO.File]::WriteAllText($pjz, $pzw, (New-Object System.Text.UTF8Encoding($false)))
  $rz = curl.exe -sk -u "icingaweb:icingaweb123" -H "Content-Type: application/json" -H "Accept: application/json" `
        -X POST "$api/v1/actions/send-custom-notification" --data-binary "@$pjz"
  Check "API: notificacion custom sobre un servicio de Wazuh aceptada" `
        ((@($rz) -join " ") -match '"code":\s*200') (@($rz) -join " ")

  Start-Sleep -Seconds 15
  curl.exe -s "$mail/api/v1/messages" -o $mzw | Out-Null
  $azw = (Get-Content $mzw -Raw | ConvertFrom-Json).total
  Check "Mailpit: mensaje nuevo del stack Wazuh ($bzw -> $azw)" ($azw -gt $bzw) "$bzw -> $azw"
  if ($azw -gt $bzw) {
    $szw = @(Get-Content $mzw -Raw | ConvertFrom-Json).messages[0].Subject
    Check "Mailpit: el aviso menciona el servicio de Wazuh" ($szw -match "Wazuh") $szw
  }
} catch { Check "Notificacion Wazuh/Mailpit" $false $_.Exception.Message }

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

  # La variable $host del dashboard se alimenta EXCLUSIVAMENTE de esta
  # etiqueta ("SHOW TAG VALUES FROM hostalive WITH KEY = hostname"): si un
  # host dejara de emitir ping4 desapareceria del desplegable aunque el
  # dashboard siguiera montado y los paneles respondieran. Se comprueba
  # sobre el stack ajeno, que es lo que se acaba de dar de alta.
  $tq = 'SHOW TAG VALUES FROM "hostalive" WITH KEY = "hostname"'
  $tj = @(docker exec $cInflux influx -database icinga2 -execute $tq 2>&1) -join "`n"
  $ts = ($tj -replace "`r?`n", " ")
  Check "InfluxDB: los 3 hosts de Wazuh salen en la variable Host de Grafana" `
        (($tj -match 'wazuh-manager') -and ($tj -match 'wazuh-indexer') -and ($tj -match 'wazuh-dashboard')) `
        $ts.Substring(0, [Math]::Min(200, $ts.Length))
} catch { Check "InfluxDB" $false $_.Exception.Message }

try {
  $gh = Invoke-WebRequest "$graf/api/health" -UseBasicParsing -TimeoutSec 30
  Check "Grafana: /api/health OK" ($gh.StatusCode -eq 200 -and $gh.Content -match '"database":\s*"ok"') $gh.Content

  $ga = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:icingaadmin123")) }
  $ds = Invoke-WebRequest "$graf/api/datasources" -Headers $ga -UseBasicParsing -TimeoutSec 30
  Check "Grafana: datasource InfluxDB provisionado" ($ds.Content -match '"uid":"icinga-influx"') $ds.Content

  $db = Invoke-WebRequest "$graf/api/search?type=dash-db" -Headers $ga -UseBasicParsing -TimeoutSec 30
  Check "Grafana: dashboard provisionado" ($db.Content -match '"uid":"icinga-stack"') $db.Content

  # El dashboard trae 22 paneles (los 19 de la Fase 1 y los 3 del stack
  # Wazuh). Se comprueba por id, no solo el recuento: con un panel menos y
  # otro de mas el recuento seguira cuadrando. Se lee de la API (lo que
  # Grafana sirve), no del JSON.
  $dbf = Invoke-WebRequest "$graf/api/dashboards/uid/icinga-stack" -Headers $ga -UseBasicParsing -TimeoutSec 30
  $dp  = @(($dbf.Content | ConvertFrom-Json).dashboard.panels)
  $hbp = @($dp | Where-Object { $_.id -eq 19 -and $_.title -like "*Icinga DB*" })
  Check "Grafana: 22 paneles y el de Icinga DB presente" `
        ($dp.Count -ge 22 -and $hbp.Count -eq 1) `
        "$($dp.Count) paneles; panel 19 de Icinga DB: $($hbp.Count)"

  # La tercera pata del criterio de hecho de la Fase 2: "tiene su panel en
  # Grafana". Ademas se mira la consulta, no solo que el panel exista: si
  # fuera con la variable $host dejaria de verse en cuanto el selector estuviera
  # puesto en otro stack, y el panel dejaria de ser "suyo".
  $wzp = @($dp | Where-Object { $_.id -eq 20 -and $_.title -like "Wazuh*" })
  $wzq = ''
  if ($wzp.Count -gt 0) { $wzq = @($wzp[0].targets)[0].query }
  Check "Grafana: panel del stack Wazuh (id 20) con filtro propio hostname =~ /wazuh/" `
        (($wzp.Count -eq 1) -and ($wzq -match 'hostname"\s*=~\s*/wazuh/')) `
        "$($wzp.Count) panel(es) :: $wzq"
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

    # La copia del otro stack (Fase 2). Se guarda la entrada porque su ID es
    # el que usa la restauracion de mas abajo. El recuento generico de
    # "declaradas" de mas abajo ya fallaria si faltara, pero por nombre da un
    # mensaje mucho mas claro.
    $wzEntry = $null
    try { $wzEntry = @($all) | Where-Object { $_.Backup.Name -eq "wazuh-stack" } | Select-Object -First 1 } catch {}
    Check "Duplicati: copia 'wazuh-stack' dada de alta (Fase 2)" `
          ($null -ne $wzEntry) "no encontrada"

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

      # 6.6b y en concreto en el subdirectorio propio de la copia nueva.
      # El de arriba es recursivo, asi que pasaria aunque wazuh-stack no
      # hubiera dejado ni un byte (o al reves). Cada copia tiene su destino.
      $dst2 = (docker exec $cDup sh -c "find /dest/wazuh-stack -type f -name duplicati-*.zip" 2>&1) -join "`n"
      Check "Duplicati: ficheros .zip de wazuh-stack en su destino" ($dst2 -match '\.zip') $dst2

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

      # 6.7b RESTAURACION de la copia del stack ajeno (Fase 2). La de arriba
      # solo restaura de la copia icinga-stack; wazuh-stack tiene origenes
      # distintos y podria estar roto sin que nada lo dijera. Dos rutas bajo
      # el mismo prefijo, para que Duplicati fije la base en
      # /sources/otros/wazuh-stack y los ficheros caigan donde toca.
      #
      # La ruta del origen en el HOST se lee del compose, igual que hace el
      # apartado 6.8 con el destino: asi no queda escrita a mano en dos
      # sitios, y si un dia se mueve el proyecto verify lo sigue.
      if ($wzEntry) {
        $wzRoot = ''
        foreach ($l in [IO.File]::ReadAllLines((Join-Path $projRoot 'docker-compose.yml'))) {
          if ($l -match '^\s*-\s*(?<src>[A-Za-z]:/[^:]+)/docker-compose\.yml:/sources/otros/wazuh-stack/docker-compose\.yml\s*(?::ro)?\s*$') {
            $wzRoot = $Matches['src']; break
          }
        }
        Check "Duplicati: origen del stack Wazuh leido del compose" ($wzRoot -ne '') $wzRoot

        if ($wzRoot -ne '') {
          $wzb = $wzEntry.Backup.ID
          # Forzar una copia de wazuh-stack ANTES del restore, igual que el
          # apartado 6.5 hace con la de icinga. Sin esto el restore compara
          # el archivo actual en disco contra la ULTIMA COPIA PROGRAMADA, que
          # queda desfasada en cuanto se toca un fichero de wazuh-stack (un
          # proyecto vivo): el SHA256 no cuadra y el check falla por un
          # desfase del backup, no por un problema real. Forzar la copia
          # hace que el check pruebe lo que dice: actuales -> backup ->
          # restore -> identico.
          $wrf2 = Join-Path $env:TEMP "verify_dup_run_wazuh.json"
          [System.IO.File]::WriteAllText($wrf2, "{}", (New-Object System.Text.UTF8Encoding($false)))
          curl.exe -s -X POST "$dup/api/v1/backup/$wzb/run" -H $hf `
                   -H "Content-Type: application/json" --data-binary "@$wrf2" -o $wrf2 | Out-Null
          $wact = ""; $wt = 0
          while ($wt -lt 180) {
            $wact = (curl.exe -s -X GET "$dup/api/v1/backup/$wzb/isactive" -H $hf) -join ""
            if (($wt -ge 15) -and ($wact -match '"Active":false')) { break }
            Start-Sleep -Seconds 3; $wt += 3
          }
          Check "Duplicati: ejecucion wazuh-stack terminada" ($wact -match '"Active":false') $wact
          # Precrear TAMBIEN la subcarpeta destino, no solo la raiz: es lo que
          # hace el bloque 6.7 de arriba, y sin esto Duplicati emite
          # CreateMissingFolder, deja la ejecucion en Warning en la UI y
          # hace parecer fallida una comprobacion que ha salido bien.
          docker exec $cDup sh -c "rm -rf /tmp/rtest2; mkdir -p /tmp/rtest2/config/wazuh_dashboard" | Out-Null
          $wrf = Join-Path $env:TEMP "verify_dup_restore_wazuh.json"
          $wbody = '{"paths":["/sources/otros/wazuh-stack/docker-compose.yml",' +
                   '"/sources/otros/wazuh-stack/config/wazuh_dashboard/wazuh.yml"],' +
                   '"time":"","restore_path":"/tmp/rtest2","overwrite":true,"skip_metadata":true}'
          [System.IO.File]::WriteAllText($wrf, $wbody, (New-Object System.Text.UTF8Encoding($false)))
          curl.exe -s -X POST "$dup/api/v1/backup/$wzb/restore" -H $hf `
                   -H "Content-Type: application/json" --data-binary "@$wrf" `
                   -o (Join-Path $env:TEMP "verify_dup_restore_wazuh_out.json") | Out-Null
          Start-Sleep -Seconds 8

          $tree2 = (docker exec $cDup sh -c "find /tmp/rtest2 -type f" 2>&1) -join "`n"
          Check "Duplicati: restauracion de wazuh-stack (compose + wazuh.yml)" `
                (($tree2 -match 'docker-compose\.yml') -and ($tree2 -match 'wazuh\.yml')) $tree2

          # Bit a bit contra el original. sha256sum dentro del contenedor
          # para las DOS mitades, en vez de Get-FileHash de PowerShell: el
          # original vive fuera de $projRoot y asi ambos lados de la
          # comparacion pasan por el mismo camino que en la prueba 6.7.
          $wp1 = ($wzRoot -replace '/', '\') + '\docker-compose.yml'
          $wp2 = ($wzRoot -replace '/', '\') + '\config\wazuh_dashboard\wazuh.yml'
          $h1 = ''; $h2 = ''
          try { $h1 = (Get-FileHash -LiteralPath $wp1 -Algorithm SHA256).Hash } catch {}
          try { $h2 = (Get-FileHash -LiteralPath $wp2 -Algorithm SHA256).Hash } catch {}
          $r1 = (docker exec $cDup sh -c "sha256sum /tmp/rtest2/docker-compose.yml" 2>&1) -join " "
          $r2 = (docker exec $cDup sh -c "sha256sum /tmp/rtest2/config/wazuh_dashboard/wazuh.yml" 2>&1) -join " "
          Check "Duplicati: docker-compose.yml de Wazuh restaurado identico (SHA256)" `
                (($h1.Length -eq 64) -and ($r1 -match $h1)) "$h1 :: $r1"
          Check "Duplicati: wazuh.yml del panel restaurado identico (SHA256)" `
                (($h2.Length -eq 64) -and ($r2 -match $h2)) "$h2 :: $r2"

          docker exec $cDup sh -c "rm -rf /tmp/rtest2" | Out-Null
        }
      }
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

# --- 8. Wazuh: el agente de logs de los contenedores --------------------------
# wazuh-stack es un stack aparte (mk-clean-test no lo clona), asi que, igual
# que la red de seguridad del 6.8, esto solo corre en produccion. Copia del
# criterio de hecho del feature de logs: los dos agentes activos, la regla
# propia cargada, el logcollector siguiendo los json del daemon y una sonda
# E2E real (una linea con "error" que tiene que volver como alerta).
#
# La sonda 8d protege de la regresion del 2026-10-09: el patron de la regla
# 100100 tenia unos parentesis que el regex de Wazuh NO interpreta como
# agrupacion (los exige como literales), de modo que el contenido "error"
# caia en la regla 1002; y 1002 (level 2) no escribe alerta porque el
# manager tiene <log_alert_level>3</log_alert_level>. El transporte estaba
# sano todo el rato: silenciaban dos piezas de configuracion.
if (-not $CleanTest) {
  try {
    # 8a. La API exige JWT: se tokeniza con user/pass y el token se
    # reutiliza en los GET siguientes.
    $za0 = docker exec wazuh-manager curl -s -u wazuh-wui:icingaweb123 -k -X POST "https://localhost:55000/security/user/authenticate"
    $ztok = ((@($za0) -join '') | ConvertFrom-Json).data.token
    Check "Wazuh: API JWT obtenida" ($ztok -is [string] -and $ztok.Length -gt 20) "token vacio"

    $za1 = docker exec wazuh-manager curl -s -k -H ("Authorization: Bearer " + $ztok) "https://localhost:55000/agents?limit=50"
    $zitems = ((@($za1) -join '') | ConvertFrom-Json).data.affected_items
    $znames = @($zitems | ForEach-Object { "$($_.name)=$($_.status)" })
    $zdock = @($zitems | Where-Object { $_.name -eq 'docker-stacks' -and $_.status -eq 'active' }).Count
    $zice  = @($zitems | Where-Object { $_.name -eq 'icinga-stacks' -and $_.status -eq 'active' }).Count
    Check "Wazuh: agentes docker-stacks e icinga-stacks active" `
          (($zdock -eq 1) -and ($zice -eq 1)) ($znames -join ', ')

    # 8b. La regla propia cargada. OJO: la API de /rules usa
    # total_affected_items, no "total" como la de /agents.
    $za2 = docker exec wazuh-manager curl -s -k -H ("Authorization: Bearer " + $ztok) "https://localhost:55000/rules?rule_ids=100100"
    $zrc = ((@($za2) -join '') | ConvertFrom-Json).data.total_affected_items
    Check "Wazuh: regla 100100 cargada" ([int]$zrc -ge 1) "total_affected_items=$zrc"

    # 8c. El logcollector analiza tantos json como ficheros hay en el
    # daemon. "Analyzing file" se emite a nivel INFO (no depende del debug
    # que se activo durante la investigacion) y se acumula por arranque, de
    # modo que sirve de cota inferior del seguimiento.
    $zjf = (docker exec wazuh-agent-icinga sh -c "ls /var/lib/docker/containers/*/*-json.log | wc -l") -join ''
    $zaf = (docker exec wazuh-agent-icinga sh -c "grep 'Analyzing file' /var/ossec/logs/ossec.log | grep -c json.log") -join ''
    Check "Wazuh: logcollector analiza todos los json de contenedores" `
          (([int]$zaf -ge [int]$zjf) -and ([int]$zjf -ge 1)) "analizados=$zaf json=$zjf"

    # 8d. Sonda E2E: se inyecta una linea con "ERROR" en la salida
    # estandard de un contenedor json-file (via /proc/1/fd/1, que si entra
    # en el log del daemon; el stdout de `docker exec` no) y se espera ver
    # la alerta en alerts.log. Unicidad por marca de tiempo para no cazar
    # alertas de ejecuciones anteriores.
    $zmark = "verify-e2e-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    docker exec icinga2 sh -c "echo 'ERROR $zmark sonda de verificacion' > /proc/1/fd/1" | Out-Null
    $zhits = 0
    for ($zt = 0; $zt -lt 120 -and $zhits -eq 0; $zt += 10) {
      Start-Sleep -Seconds 10
      $zhits = [int]((docker exec wazuh-manager sh -c "grep -c $zmark /var/ossec/logs/alerts/alerts.log" 2>$null) -join '')
    }
    Check "Wazuh: sonda E2E con 'error' vuelve como alerta 100100" ($zhits -ge 1) "marcador=$zmark en $zt s"
  } catch { Check "Wazuh" $false $_.Exception.Message }
}

"===== TOTAL FALLOS: $fail ====="
exit $fail
