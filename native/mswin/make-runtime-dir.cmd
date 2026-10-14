@echo off
rem Assembles the runtime directory `ocran --native` takes, from the pieces
rem built by build-ruby.cmd, build-gemexts.rb, make-sdk.rb (ROOT\sdk) and
rem link-runtime.rb:
rem
rem   make-runtime-dir.cmd ROOT RUNTIME.exe OUTDIR
rem
rem OUTDIR gets ocran-runtime.exe, lib\ruby (the installed standard library
rem and bundled gems) and runtime.json.
setlocal
set ROOT=%~1
set EXE=%~2
set OUT=%~3
if "%OUT%" == "" (echo usage: make-runtime-dir.cmd ROOT RUNTIME.exe OUTDIR & exit /b 2)
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%" || exit /b 1
copy /y "%EXE%" "%OUT%\ocran-runtime.exe" >nul || exit /b 1
if exist "%ROOT%\sdk" robocopy "%ROOT%\sdk" "%OUT%\sdk" /e /nfl /ndl /njh /njs /nc /ns >nul
if errorlevel 8 exit /b 1
robocopy "%ROOT%\stage\lib" "%OUT%\lib" /e /nfl /ndl /njh /njs /nc /ns >nul
if errorlevel 8 exit /b 1
rem License texts of what is linked in (vcpkg keeps each port's in
rem share\<port>\copyright); ocran packs them into every executable.
mkdir "%OUT%\LICENSES\ruby"
for %%f in (BSDL COPYING LEGAL) do copy /y "%ROOT%\src\%%f" "%OUT%\LICENSES\ruby\" >nul
for /d %%p in ("%ROOT%\deps\installed\x64-windows-static\share\*") do (
  if exist "%%p\copyright" (
    mkdir "%OUT%\LICENSES\%%~nxp" 2>nul
    copy /y "%%p\copyright" "%OUT%\LICENSES\%%~nxp\" >nul
  )
)
"%ROOT%\stage\bin\ruby.exe" "%~dp0..\write-runtime-info.rb" "%ROOT%\build" "%OUT%" "%ROOT%\exts\fiddle.line" "%ROOT%\exts\bigdecimal.line" "%ROOT%\exts\racc_cparse.line" "%ROOT%\exts\win32ole.line"
