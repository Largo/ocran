@echo off
rem Builds the static pieces of the mswin (MSVC) ocran runtime: Ruby with
rem every extension compiled to a static library, against the static CRT
rem (-MT) and vcpkg's x64-windows-static dependencies.
rem
rem   build-ruby.cmd ROOT PATCHDIR...
rem
rem ROOT\src       Ruby source checkout (patches in PATCHDIRs are applied)
rem ROOT\baseruby  a Ruby of the same revision (the official mswin zip)
rem ROOT\deps\installed\x64-windows-static   vcpkg (see vcpkg.json)
setlocal
set ROOT=%~1
if "%ROOT%" == "" (echo usage: build-ruby.cmd ROOT PATCHDIR... & exit /b 2)
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set "PATH=%ROOT%\baseruby\bin;%PATH%"
set DEPS=%ROOT%\deps\installed\x64-windows-static

cd /d "%ROOT%\src" || exit /b 1
git checkout -q -- . || exit /b 1
:patches
shift
if "%~1" == "" goto :patched
for %%p in ("%~1\ruby-*.patch") do (git apply "%%p" || exit /b 1)
goto :patches
:patched

rem vcpkg names its static zlib zs.lib; Ruby's zlib extconf looks for zlib.lib.
if not exist "%ROOT%\deps\compat\lib" mkdir "%ROOT%\deps\compat\lib"
copy /y "%DEPS%\lib\zs.lib" "%ROOT%\deps\compat\lib\zlib.lib" >nul || exit /b 1

if exist "%ROOT%\build" rmdir /s /q "%ROOT%\build"
mkdir "%ROOT%\build" && cd /d "%ROOT%\build" || exit /b 1
rem The baseruby path must use backslashes: nmake silently skips a command
rem whose program path is written C:/... (every generator step would do
rem nothing, and the build fails much later on a missing header).
rem --with-ldflags: rbconfig's LIBS is only user32.lib, but the static
rem OpenSSL also needs advapi32 for extconf's link checks to pass.
call "%ROOT%\src\win32\configure.bat" --prefix=%ROOT:\=/%/stage ^
  --with-baseruby=%ROOT%\baseruby\bin\ruby.exe ^
  --with-static-linked-ext --disable-install-doc ^
  "--with-opt-dir=%DEPS:\=/%;%ROOT:\=/%/deps/compat" ^
  "--with-ldflags=-incremental:no -debug -opt:ref -opt:icf -manifest:embed,ID=2 advapi32.lib" || exit /b 1
rem -MT: the static CRT, so the runtime needs no VC++ redistributable
rem (needs patches\ruby-win32-static-crt.patch).
nmake RUNTIMEFLAG=-MT || exit /b 1
nmake RUNTIMEFLAG=-MT install-nodoc || exit /b 1
