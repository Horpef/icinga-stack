<#
 .SYNOPSIS
   Copia plana y legible de TODOS los volumenes de LOS DOS stacks
   (icinga-stack + wazuh-stack) en C:\docker-backups\safety-net\.
   Para ambos stacks unos minutos, en UNA sola ventana, para que el
   volcado sea consistente.

   -SoloCatalogo   refresca SOLO duplicati_config.tar (de icinga-stack).
                   Para unicamente el contenedor Duplicati (~15 s en vez de
                   ~8 min), para mantener el catalogo cuadrado con el destino
                   sin parar nada mas.

 .DESCRIPTION
   Duplicati guarda los datos en su propio formato (.zip + dlist + dblock),
   que solo el sabe leer. Este script guarda los mismos volumenes como .tar
   crudos: se restauran con cualquier `docker run ... tar -xf`, sin
   Duplicati, sin red y sin necesidad del proyecto.

   Es la RED DE SEGURIDAD que permite ensayar una restauracion real
   (`docker compose down -v`) sin quedarte sin vuelta atras. Se usa antes
   de cualquier operacion destructiva, no sustituye a la copia diaria de
   Duplicati.

   Durante el volcado AMBOS stacks estan parados (~8-10 min: el volcado en
   si es ~1-2 min, pero el arranque espera a que el indexer de Wazuh (JVM)
   se ponga healthy, unos 3-4 min).

   UN VOLUMEN ENVEJECE: duplicati_config. Cada copia nueva anade ficheros
   al destino, y si el catalogo guardado aqui no los conoce, al restaurarlo
   Duplicati se quejara de "unknown files" y se negara a hacer copias
   (ver README, *Recuperar desde cero*). Con -SoloCatalogo refrescarlo es
   tan barato que no hay excusa: tras cada verify.ps1 o cada pocos dias.

 .EXAMPLE
   .\safety-net.ps1                  # ambos stacks (~8-10 min, parados)
   .\safety-net.ps1 -SoloCatalogo    # solo el catalogo de Duplicati (~15 s)
#>
param([switch]$SoloCatalogo)

$ErrorActionPreference = 'Stop'

$dest = 'C:\docker-backups\safety-net'

# Los DOS stacks que hoy tiene el proyecto. Cada uno es un proyecto compose
# proprio con su propio prefijo de volumenes (nombre <proyecto>_<volumen>).
# El script vive dentro de icinga-stack; wazuh-stack es un hermano.
$icingaDir = $PSScriptRoot
$wazuhDir  = (Resolve-Path (Join-Path $PSScriptRoot '..\wazuh-stack')).Path
$stacks = @(
    @{ name = 'icinga-stack'; dir = $icingaDir; prefix = 'icinga-stack_' },
    @{ name = 'wazuh-stack';  dir = $wazuhDir;  prefix = 'wazuh-stack_'  }
)

Write-Output "=== RED DE SEGURIDAD: volcado de volumenes (icinga + wazuh) ==="

New-Item -ItemType Directory -Path $dest -Force | Out-Null

# Vuelca un volumen (nombre COMPLETO) como $tarname.tar. `:ro` para que nada
# pueda tocar el origen mientras se copia, y alpine ya en local.
# $extraTarArgs permite excluir subrutas (ver Volume-TarArgs).
function Copy-Volume($vol, $tarname, $extraTarArgs = '') {
    docker run --rm -v "${vol}:/vol:ro" -v "${dest}:/out" alpine:3.19 `
        sh -c "tar $extraTarArgs -C /vol -cf /out/$tarname.tar ." | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fallo al volcar $vol" }
    Write-Output "    $tarname.tar"
}

# Exclusiones de volcado por volumen. Por defecto, volcado COMPLETO.
function Volume-TarArgs($vol) {
    # wazuh_queue contiene los feeds CVE de Vulnerability Detector en sus
    # subdirs vd/ y vd_updater/ (~12,5 GB). El updater los VUELVE A BAJAR
    # solos cada 60 min (vulnerability-detection/feed-update-interval=60m),
    # asi que son datos regenerables: volcarlos inflaria la red de seguridad
    # en 12,5 GB sin aportar nada. Si se restaura con `down -v`, el manager
    # los re-descarga en la primera hora. El RESTO del volumen (colas,
    # queue/db, inventarios) si se vuelca. Verificado 2026-10-16.
    if ($vol -eq 'wazuh-stack_wazuh_queue') { return '--exclude=vd --exclude=vd_updater' }
    return ''
}

if ($SoloCatalogo) {
    # SQLite quieto = copia consistente. `stop duplicati` no toca al resto
    # del stack y `start` respeta el orden; el volcado dura ~1 s. Push-Location
    # para que funcione desde cualquier cwd.
    Write-Output "  parando unicamente Duplicati de icinga-stack (~15 s)..."
    Push-Location $icingaDir
    try {
        docker compose stop duplicati | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker compose stop duplicati fallo" }
        try   { Copy-Volume 'icinga-stack_duplicati_config' 'duplicati_config' }
        finally { docker compose start duplicati | Out-Null }
    }
    finally { Pop-Location }
    $sz = [math]::Round((Get-Item "$dest\duplicati_config.tar").Length / 1MB, 1)
    Write-Output ""
    Write-Output "  catalogo refrescado ($sz MB), el resto sin parar"
    Write-Output "=== RED DE SEGURIDAD LISTA ==="
    return
}

# Lista los volumenes de LOS DOS stacks ANTES de parar: `docker compose stop`
# los dejaria igual (no lleva -v) pero asi se documenta exactamente que se copio.
$allVols = @()
foreach ($s in $stacks) {
    $found = @(docker volume ls --format '{{.Name}}' |
               Where-Object { $_.StartsWith($s.prefix) })
    if ($found.Count -eq 0) { throw "no se encontraron volumenes '$($s.prefix)*'" }
    Write-Output "  $($s.name): $($found.Count) volumenes"
    $allVols += $found
}
Write-Output "  total: $($allVols.Count) volumenes"

# Se limpia el destino: si el volcado se interrumpe a medias no queremos
# mezclar trozos del run anterior con los de este.
Get-ChildItem -Path $dest -Filter '*.tar' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force

# Se paran AMBOS stacks (ventana unica de mantenimiento; sin -v, los
# volumenes quedan). Asi el snapshot es consistente y no hay cruces de
# alertas (si solo se parara Wazuh, Icinga estaria vivo y lo alertaria).
Write-Output "  parando ambos stacks..."
foreach ($s in $stacks) {
    Push-Location $s.dir
    try {
        docker compose stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker compose stop fallo en $($s.name)" }
    }
    finally { Pop-Location }
}

$ok = 0
try {
    foreach ($v in $allVols) {
        # El .tar se nombra por el volumen SIN el prefijo de proyecto (igual
        # que siempre hizo icinga: db_data.tar, duplicati_config.tar, ...).
        # Los dos stacks no comparten nombres logicos, asi que no hay colision.
        $tarname = $v
        foreach ($s in $stacks) { if ($v.StartsWith($s.prefix)) { $tarname = $v.Substring($s.prefix.Length) } }
        Copy-Volume $v $tarname (Volume-TarArgs $v)
        $ok++
        Write-Output "    [$ok/$($allVols.Count)] hecho"
    }
}
finally {
    Write-Output "  arrancando ambos stacks (wazuh tarda ~3-4 min en healthy)..."
    foreach ($s in $stacks) {
        Push-Location $s.dir
        try { docker compose up -d --wait | Out-Null }
        finally { Pop-Location }
    }
}

$files = @(Get-ChildItem -Path $dest -Filter '*.tar' -File)
$size  = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Output ""
Write-Output "  $dest"
Write-Output "  $($files.Count) .tar  ·  $size MB"
Write-Output "  para restaurar un volumen suelto (ej. icinga-stack_db_data):"
Write-Output "    docker run --rm -v icinga-stack_db_data:/vol -v <carpeta>:/out alpine:3.19 tar -xf /out/db_data.tar -C /vol"
Write-Output "  (los .tar de wazuh-stack se restauran igual, cambiando el nombre del volumen,"
Write-Output "   p. ej. wazuh-stack_wazuh_etc <- wazuh_etc.tar)"
Write-Output "=== RED DE SEGURIDAD LISTA ==="
