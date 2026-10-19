# Creates an isolated copy of the stack used to prove that a *clean volume*
# deployment works end-to-end (MySQL init scripts, Icinga DB auto-import,
# Icinga Web schema, ICINGA_CN endpoint naming, Director migration + kickstart
# + deploy, msmtp) without touching the running production stack.
#
# The copy gets a distinct compose project name, container names and host
# ports, so it runs side by side with `icinga-stack` and its volumes are
# separate (`clean-test_*`).
$ErrorActionPreference = 'Stop'

$src = 'D:\docker\icinga-stack'
$dst = Join-Path $src '_clean-test'

if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
New-Item -ItemType Directory -Path $dst | Out-Null

# Lo que se copia NO se mantiene a mano: se deriva del propio compose. Cada
# bind-mount relativo (`./algo/...`) tiene que existir en la copia; si falta,
# Docker crea en su lugar un *directorio* vacio y el contenedor no arranca con
# "not a directory" (paso con ./influxdb/influxdb.conf, que la lista fija no
# tenia). Derivandolo, anadir un montaje nuevo al compose ya no puede dejar
# este script desactualizado en silencio.
$composeSrc = Join-Path $src 'docker-compose.yml'
$mounted = [regex]::Matches((Get-Content -Raw $composeSrc), '(?m)^\s*-\s*\./([^:/]+)') |
           ForEach-Object { $_.Groups[1].Value }
$items = (@('docker-compose.yml') + $mounted) | Sort-Object -Unique
foreach ($item in $items) {
    $from = Join-Path $src $item
    if (-not (Test-Path -LiteralPath $from)) {
        throw "el compose monta './$item' y no existe en $src"
    }
    Copy-Item -Recurse -Force -LiteralPath $from (Join-Path $dst $item)
}

$compose = Join-Path $dst 'docker-compose.yml'
$content = Get-Content -Raw $compose

# 1) unique container names, otherwise they clash with the running stack
$content = $content -replace '(?m)^(\s*)container_name:\s*(\S+)\s*$', '$1container_name: ct-$2'

# 2) distinct published host ports (container-internal ports stay untouched,
#    the apply rules in stack-monitoring.conf only use those).
#    OJO: la clave tiene que ser el texto EXACTO del compose. Las UIs se
#    publican como `127.0.0.1:<puerto>:<puerto>` (endurecimiento: UIs solo en
#    loopback) y el API de Icinga 2 como `"5665:5665"` (0.0.0.0, puerto de
#    servicio). Si algun dia cambia una linea, la guarda del final revienta:
#    primero se comprueba, no se confia en que el Replace casara.
$portMap = @{
    '127.0.0.1:8080:8080' = '127.0.0.1:18080:8080'
    '127.0.0.1:8443:8443' = '127.0.0.1:18443:8443'
    '"5665:5665"'         = '"15665:5665"'
    '127.0.0.1:8025:8025' = '127.0.0.1:18025:8025'
    '127.0.0.1:1025:1025' = '127.0.0.1:11025:1025'
    '127.0.0.1:3000:3000' = '127.0.0.1:13000:3000'
    '127.0.0.1:8200:8200' = '127.0.0.1:18200:8200'
}
foreach ($k in $portMap.Keys) { $content = $content.Replace($k, $portMap[$k]) }

# 3) own image tag, otherwise `--build` in the copy would silently retag
#    `icinga-stack-web:latest` and swap the image under the running
#    production stack.
$content = $content -replace '(?m)^(\s*)image:\s*icinga-stack-web:latest\s*$', '$1image: ct-icinga-stack-web:latest'

# 4) la red de monitorizacion (`monitoring-net`) es externa y compartida: en
#    la copia tiene que ser propia, o el clean-test se colgaria de la red de
#    produccion y `down -v` no la podria borrar. Quitando `external` y `name`
#    compose vuelve a generar una por proyecto (clean-test_icinga-net), que
#    crea y elimina solo.
$content = $content -replace '(?m)^[ \t]*external:[ \t]*true[ \t]*\r?\n', ''
$content = $content -replace '(?m)^[ \t]*name:[ \t]*monitoring-net[ \t]*\r?\n', ''

# 5) el destino de las copias y el espejo del proyecto viven en
#    C:\docker-backups, en el disco fisico de ENTRADA (separado de los datos,
#    que estan en D:). En la copia tienen que volver a ser relativos
#    (./backups) para que el clean-test escriba dentro de _clean-test y no
#    contamine el destino de produccion.
$content = $content -replace 'C:/docker-backups', './backups'

Set-Content -Path $compose -Value $content -NoNewline

# Guarda: si algun rewrite fallara, el clean-test estaria escribiendo en el
# destino real de produccion. Se comprueba el resultado, no la intencion.
# Se ignoran los comentarios: el bloque de documentacion de la red reproduce
# a proposito `external: true` y `name: monitoring-net` como ejemplo.
$final  = Get-Content -Raw $compose
$code   = (($final -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
$leak   = @('C:/docker-backups', 'container_name: icinga-',
            'name: monitoring-net', 'external: true') |
          Where-Object { $code.Contains($_) }
# Cada cadena de puerto original tiene que haber desaparecido. Se recorre el
# MISMO mapa que se aplico arriba, asi que ampliarlo no deja la guarda ciega
# (fue justo lo que paso cuando las UIs pasaron a 127.0.0.1: la guarda seguia
# buscando '"8200:8200"' y no vio que el Replace ya no casaba).
$leak  += @($portMap.Keys | Where-Object { $code.Contains($_) })
if ($leak) {
    throw "la copia conserva '$($leak -join ''', ''')': el clean-test chocaria con produccion"
}

Write-Host "clean test copy prepared at $dst"
