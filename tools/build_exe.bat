@echo off
REM CakeGame -> build\CakeGame.exe
REM
REM Locates the Godot editor across the usual install locations instead of
REM trusting PATH: a bare `godot` on this machine resolves to a Microsoft Store
REM redirector that exits without doing anything, which looks exactly like a
REM failed export.
setlocal

set "GODOT="
for %%P in (
  "E:\godot_toolchain\godot\Godot_v4.5.1-stable_win64_console.exe"
  "E:\godot_toolchain\godot\Godot_v4.5.1-stable_win64.exe"
  "D:\1\gotot\Godot_v4.5.1-stable_win64_console.exe"
  "D:\1\gotot\Godot_v4.5.1-stable_win64.exe"
  "%LOCALAPPDATA%\Programs\Godot\Godot.exe"
) do (
  if exist %%P if not defined GODOT set "GODOT=%%~P"
)

if not defined GODOT (
  echo [cakegame] Godot not found. Edit GODOT in tools\build_exe.bat.
  exit /b 1
)

echo [cakegame] godot: %GODOT%

if not exist build mkdir build

"%GODOT%" --headless --path . --export-release "Windows Desktop" "build\CakeGame.exe"
if errorlevel 1 (
  echo [cakegame] export failed.
  exit /b 1
)

for %%F in ("build\CakeGame.exe") do echo [cakegame] build\CakeGame.exe  %%~zF bytes
echo [cakegame] done.
endlocal
