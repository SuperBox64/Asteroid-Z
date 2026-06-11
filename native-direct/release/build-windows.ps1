# Windows native build (EXPERIMENTAL).
# Attempts Embedded Swift first; Embedded COFF support is unproven, so on
# failure this falls back to full-stdlib Swift (still no wasm, no webview).
# Requires: Swift for Windows toolchain, vcpkg sdl3:x64-windows-static.
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\.."
Write-Host "Windows lane: see release/README.md - embedded COFF attempt, stdlib fallback"
# Full implementation lands once the embedded-COFF question is settled on a
# real runner; the stdlib fallback compiles GameScene + backend + main with
# swiftc -O and links SDL3 static from vcpkg.
exit 1
