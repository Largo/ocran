@echo off
setlocal enabledelayedexpansion

echo == Installing dependencies ==

:: Check if Bundler is installed (warn if not)
where bundler >nul 2>nul
if errorlevel 1 (
  echo Bundler is not installed. Please run 'gem install bundler' first.
  exit /b 1
)

:: Run bundle install
call bundle install
if errorlevel 1 (
  echo bundle install failed
  exit /b 1
)

echo == Building stub executables ==

call bundle exec rake build
if errorlevel 1 (
  echo Failed to build stubs.
  exit /b 1
)

echo == Setup completed ==

endlocal
