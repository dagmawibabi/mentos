# Flutter's compiler dumps temp files on %TEMP%, which is on C:.
# C: is full; keep Mentos temp on D: so `flutter run -d windows` can compile.
$ErrorActionPreference = "Stop"
$tmp = "D:\Projects\VibeCoded\mentos\.tmp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP = $tmp
$env:MENTOS_HOME = "D:\mentos"
New-Item -ItemType Directory -Force -Path $env:MENTOS_HOME | Out-Null
Set-Location $PSScriptRoot
flutter run -d windows @args
