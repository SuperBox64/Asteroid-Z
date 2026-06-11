# Windows native exe - full Swift (single binary, no wasm, no webview).
# Runs on the windows CI runner: Swift toolchain via gha-setup-swift,
# SDL3 static via vcpkg. Embedded Swift on COFF can replace the stdlib
# build once proven; the output contract is identical either way.
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\.."
$FW = Resolve-Path "..\..\superbox64-spritekit"
$VCPKG = "$env:VCPKG_INSTALLATION_ROOT\installed\x64-windows-static"
$B = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid())

# CSDL3 module map over the vcpkg headers
New-Item -ItemType Directory -Path "$B\CSDL3" | Out-Null
Set-Content "$B\CSDL3\shim.h" '#include <SDL3/SDL.h>'
Set-Content "$B\CSDL3\module.modulemap" @"
module CSDL3 {
    header "shim.h"
    link "SDL3-static"
    export *
}
"@

# Box2D v3 (plain C)
New-Item -ItemType Directory -Path "$B\box2d" | Out-Null
Get-ChildItem "$FW\Sources\CBox2D\src\*.c" | ForEach-Object {
  clang -c -O2 -DNDEBUG -I "$FW\Sources\CBox2D\include" -I "$FW\Sources\CBox2D\src" $_.FullName -o "$B\box2d\$($_.BaseName).obj"
}

# strip @MainActor and compile everything as one module (stdlib build)
New-Item -ItemType Directory -Path "$B\src" | Out-Null
$sources = @()
foreach ($m in "SpriteKit","AppKit","GameplayKit","GameController") {
  Get-ChildItem "$FW\Sources\$m\*.swift" | ForEach-Object {
    $dst = "$B\src\$m-$($_.Name)"
    (Get-Content $_.FullName -Raw) -replace '@MainActor','' -replace '@preconcurrency','' | Set-Content $dst
    $sources += $dst
  }
}
foreach ($f in @("..\asteroidz-web\Sources\AsteroidZ\GameScene.swift", "$FW\native\sdl3-backend.swift", "main.swift")) {
  $name = Split-Path $f -Leaf
  (Get-Content $f -Raw) -replace '@MainActor','' | Set-Content "$B\src\game-$name"
  $sources += "$B\src\game-$name"
}

# stubs + baked assets, generated like the other platforms
python release\gen-stubs.py "$FW\Sources\KitABI\include\KitABI.h" "$B\stubs.c"
clang -c -O2 -I "$FW\Sources\KitABI\include" "$B\stubs.c" -o "$B\stubs.obj"
clang -c -O2 -I "$FW\Sources\KitABI\include" "$FW\Sources\KitABI\shim.c" -o "$B\shim.obj"
python release\gen-assets.py "..\asteroidz-web\web\assets\sfx" "$B\assets.c"
clang -c -O2 "$B\assets.c" -o "$B\assets.obj"

swiftc -O -wmo -parse-as-library `
  -Xcc -fmodule-map-file="$FW\Sources\KitABI\include\module.modulemap" `
  -Xcc -fmodule-map-file="$FW\Sources\CBox2D\include\module.modulemap" `
  -Xcc -fmodule-map-file="$B\CSDL3\module.modulemap" `
  -Xcc -I"$VCPKG\include" `
  -I "$FW\Sources\KitABI\include" -I "$FW\Sources\CBox2D\include" -I "$B\CSDL3" `
  -L "$VCPKG\lib" `
  -Xlinker "$B\stubs.obj" -Xlinker "$B\shim.obj" -Xlinker "$B\assets.obj" `
  $(Get-ChildItem "$B\box2d\*.obj" | ForEach-Object { "-Xlinker"; $_.FullName }) `
  -Xlinker user32.lib -Xlinker gdi32.lib -Xlinker winmm.lib -Xlinker ole32.lib `
  -Xlinker oleaut32.lib -Xlinker imm32.lib -Xlinker version.lib -Xlinker setupapi.lib -Xlinker advapi32.lib -Xlinker shell32.lib `
  $sources -o asteroidz-direct.exe
Write-Host "OK asteroidz-direct.exe"
