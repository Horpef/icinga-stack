<#
 .SYNOPSIS
   Copia plana y legible de TODOS los volumenes del stack en
   C:\docker-backups\safety-net\. Para el stack unos minutos, para que el
   volcado sea consistente.

   -SoloCatalogo   refresca SOLO duplicati_config.tar. Para unicamente el
                   contenedor Duplicati (~15 s en vez de 2-3 min), para
                   mantener el catalogo cuadrado con el destino sin parar
                   el stack.

 .DESCRIPTION
   Duplicati guarda los datos en su propio formato (.zip + dlist + dblock),
   que solo el sabe leer. Este script guarda los mismos volumenes como .tar
   crudos: se restauran con cualquier `docker run ... tar -xf`, sin
   Duplicati, sin red y sin necesidad del proyecto.

   Es la RED DE SEGURIDAD que permite ensayar una restauracion real
   (`docker compose down -v`) sin quedarte sin vuelta atras. Se usa antes
   de cualquier operacion destructiva, no sustituye a la copia diaria de
   Duplicati.

   Durante el volcado el stack esta parado (2-3 min).

   UN VOLUMEN ENVEJECE: duplicati_config. Cada copia nueva anade ficheros
   al destino, y si el catalogo guardado aqui no los conoce, al restaurarlo
   Duplicati se quejara de "unknown files" y se negara a hacer copias
   (ver README, *Recuperar desde cero*). Con -SoloCatalogo refrescarlo es
   tan barato que no hay excusa: tras cada verify.ps1 o cada pocos dias.

 .EXAMPLE
   .\safety-net.ps1                  # todo el stack (2-3 min, stack parado)
   .\safety-net.ps1 -SoloCatalogo    # solo el catalogo (~15 s)
#>
param([switch]$SoloCatalogo)

$ErrorActionPreference = 'Stop'

$dest    = 'C:\docker-backups\safety-net'
$prefix  = 'icinga-stack_'

Write-Output "=== RED DE SEGURIDAD: volcado de volumenes ==="

New-Item -ItemType Directory -Path $dest -Force | Out-Null

# Vuelca un volumen con el contenedor propietario ya parado. `:ro` para que
# nada pueda tocar el origen mientras se copia, y alpine ya en local.
function Copy-Volume($name) {
    docker run --rm -v "${prefix}${name}:/vol:ro" -v "${dest}:/out" alpine:3.19 `
        sh -c "tar -C /vol -cf /out/$name.tar ." | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fallo al volcar $name" }
    Write-Output "    $name.tar"
}

if ($SoloCatalogo) {
    # SQLite quieto = copia consistente. `stop duplicati` no toca al resto
    # del stack y `start` respeta el orden; el volcado dura ~1 s.
    Write-Output "  parando unicamente Duplicati (~15 s)..."
    docker compose stop duplicati | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker compose stop duplicati fallo" }
    try   { Copy-Volume 'duplicati_config' }
    finally { docker compose start duplicati | Out-Null }
    $sz = [math]::Round((Get-Item "$dest\duplicati_config.tar").Length / 1MB, 1)
    Write-Output ""
    Write-Output "  catalogo refrescado ($sz MB), el resto del stack sin parar"
    Write-Output "=== RED DE SEGURIDAD LISTA ==="
    return
}

# Lista los volumenes ANTES de parar: `docker compose down` los dejaria
# igual (no lleva -v) pero asi se documenta exactamente que se copio.
$vols = @(docker volume ls --format '{{.Name}}' |
          Where-Object { $_.StartsWith($prefix) })
if ($vols.Count -eq 0) { throw "no se encontraron volumenes '$prefix*'" }
Write-Output "  volumenes: $($vols.Count)"

# Se limpia el destino: si el volcado se interrumpe a medias no queremos
# mezclar trozos del run anterior con los de este.
Get-ChildItem -Path $dest -Filter '*.tar' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force

Write-Output "  parando el stack (2-3 min)..."
docker compose stop | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker compose stop fallo" }

$ok = 0
try {
    foreach ($v in $vols) {
        Copy-Volume $v.Substring($prefix.Length)
        $ok++
        Write-Output "    [$ok/$($vols.Count)] hecho"
    }
}
finally {
    Write-Output "  arrancando el stack..."
    docker compose up -d --wait | Out-Null
}

$files = @(Get-ChildItem -Path $dest -Filter '*.tar' -File)
$size  = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Output ""
Write-Output "  $dest"
Write-Output "  $($files.Count) .tar  ·  $size MB"
Write-Output "  para restaurar un volumen suelto:"
Write-Output "    docker run --rm -v icinga-stack_DB_DATA:/vol -v <carpeta>:/out alpine:3.19 tar -xf /out/DB_DATA.tar -C /vol"
Write-Output "=== RED DE SEGURIDAD LISTA ==="
