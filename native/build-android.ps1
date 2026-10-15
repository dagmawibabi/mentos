$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Root
$Out = Join-Path $Repo "android\app\src\main\jniLibs"
$Ndk = $env:ANDROID_NDK_HOME
if (-not $Ndk) {
  $Ndk = "C:\Users\1babi\AppData\Local\Android\Sdk\ndk\28.2.13676358"
}
$env:ANDROID_NDK_HOME = $Ndk
$env:CARGO_TARGET_DIR = Join-Path (Split-Path -Parent $Repo) ".cargo-target"

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Set-Location $Root

function Invoke-CargoNdk {
  cargo ndk -t arm64-v8a -P 26 -o $Out build --release
}

try {
  Invoke-CargoNdk
} catch {
  Write-Host "cargo-ndk missing or failed, installing..."
  cargo install cargo-ndk --locked
  Invoke-CargoNdk
}

# cargo-ndk can drop dependency cdylibs next to libmentos_net.so. Android would
# package those too, and they are not a loadable iroh runtime.
Get-ChildItem $Out -Recurse -Filter *.so |
  Where-Object { $_.Name -ne "libmentos_net.so" } |
  Remove-Item -Force
