# ocran

home   :: https://github.com/largo/ocran/

issues :: http://github.com/largo/ocran/issues

## Description

OCRAN (One-Click Ruby Application Next) packages Ruby applications for
distribution. It bundles your script, the Ruby interpreter, gems, and native
libraries into a single self-contained artifact that runs without requiring
Ruby to be installed on the target machine.

OCRAN supports four output formats, all cross-platform:

* **Self-extracting executable** — bundles everything into a single binary that unpacks and runs transparently, with no Ruby installation required. Produces a `.exe` on Windows, and a native executable on Linux and macOS.
* **macOS app bundle** (`--macosx-bundle`) — wraps the executable in a `.app` bundle for Finder integration, Dock icons, and code signing.
* **Directory** (`--output-dir`) — copies all files into a folder with a ready-to-run launch script (`.sh` on Linux/macOS, `.bat` on Windows).
* **Zip archive** (`--output-zip`) — same as directory output, packed into a `.zip`.

OCRAN is a fork of [OCRA](https://github.com/larsch/ocra) maintained for
Ruby 3.2+ compatibility.

## Recommended usage

The most common use-case is shipping a program to Windows servers or users
who do not have Ruby installed. By default, each time the `.exe` is opened it
extracts the Ruby interpreter and your code to a temporary directory and runs
them from there.

Because extraction takes time on each launch, consider using the Inno Setup
option (`--innosetup`) to produce a proper installer that extracts once to a
permanent directory.

For cross-platform packaging or CI artifacts, use `--output-dir` or
`--output-zip` to produce a portable directory/archive that runs with the
bundled Ruby on Linux, macOS, or Windows.

## Features

* **Windows/Linux/macOS executable** — self-extracting, self-running executable (primary output)
* **macOS app bundle** — `.app` bundle with `Info.plist` for Finder/Dock/code-signing (`--macosx-bundle`)
* **Directory output** — portable directory with a launch script (`--output-dir`)
* **Zip archive output** — portable zip with a launch script (`--output-zip`)
* LZMA compression (optional, default on, for `.exe` only)
* Both windowed and console mode supported (Windows)
* Gems included based on actual usage, or from a Bundler Gemfile
* Code-signing compatible
* Multibyte (UTF-8) path support on Windows 10 1903+

## Problems & Bug Reporting

If you experience problems with OCRAN or have found a bug, please use the
issue tracker on GitHub (http://github.com/largo/ocran/issues).

## Safety

As this gem ships with binary blobs, releases are securely built on GitHub
Actions. Feel free to verify that the published gem matches the source.

This repository includes `lzma.exe` from the
[official ip7z/7zip release](https://github.com/ip7z/7zip/releases)
(version 22.01, from `lzma2201.7z`), used to compress Windows executables.

`stub.exe`, `stubw.exe`, and `edicon.exe` are compiled from source in this
repository.

## Installation

    gem install ocran

Alternatively, download from http://rubygems.org/gems/ocran or
https://github.com/largo/ocran/releases/.

## Synopsis

### Building a Windows executable:

    ocran script.rb

Packages `script.rb`, the Ruby interpreter, and all dependencies (gems and
DLLs) into `script.exe`.

### Building a portable directory (Linux / macOS / Windows):

    ocran --output-dir myapp/ script.rb

Copies all files into `myapp/` and writes a `script.sh` (or `script.bat` on
Windows) launch script.

### Building a macOS app bundle:

    ocran --macosx-bundle script.rb

Produces `script.app/` — a standard macOS `.app` bundle containing the
self-extracting executable at `Contents/MacOS/script` and an `Info.plist`.
Open it with `open script.app` or double-click it in Finder.

    ocran --macosx-bundle --output MyApp --bundle-id com.example.myapp --icon icon.icns script.rb

Custom name, bundle identifier and icon (must be `.icns` format). The icon is
placed at `Contents/Resources/AppIcon.icns` and referenced in `Info.plist`.

### Building a zip archive:

    ocran --output-zip myapp.zip script.rb

Same as `--output-dir`, but packages the result into a zip file. Requires
`zip` on Linux/macOS or PowerShell on Windows.

### Command line:

    ocran [options] script.rb [<other files> ...] [-- <script arguments> ...]

### Options:

    ocran --help
    ocran -h

#### General options:

* `--help`, `-h`: Display available command-line options.
* `--quiet`: Suppress all output during the build process.
* `--verbose`: Provide detailed output during the build process.
* `--version`: Display the OCRAN version number and exit.

#### Packaging options:

* `--dll <dllname>`: Include additional DLLs from the Ruby `bin` directory.
* `--add-all-core`: Add all standard Ruby core libraries to the executable.
* `--gemfile <file>`: Include all gems and dependencies listed in a Bundler `Gemfile`.
* `--no-enc`: Exclude encoding support files to reduce output size.

#### Gem content detection modes:

These options control which files from included gems are added to the output.

* `--gem-minimal[=gem1,..]`: Include only scripts actually loaded during the dependency run.
* `--gem-guess[=gem1,..]`: Include loaded scripts and a best guess of other needed files (DEFAULT).
* `--gem-all[=gem1,..]`: Include all scripts and important files from the gem.
* `--gem-full[=gem1,..]`: Include every file in the gem directory.
* `--gem-spec[=gem1,..]`: Include files listed in the gemspec (not compatible with newer RubyGems).

Fine-tuning flags:

* `--[no-]gem-scripts[=..]`: Include/exclude non-loaded script files (`.rb`, `.rbw`).
* `--[no-]gem-files[=..]`: Include/exclude data files.
* `--[no-]gem-extras[=..]`: Include/exclude extras (READMEs, tests, C sources).

#### Auto-detection options:

* `--no-dep-run`: Skip running the script to detect dependencies. Use this if your script has side effects during load or if you are manually specifying all dependencies. Requires `--add-all-core` and `--gem-full`.
* `--no-autoload`: Do not attempt to load `autoload`ed constants.
* `--no-autodll`: Disable automatic detection of runtime DLL dependencies.

#### Output options:

* `--output <file>`: Name the generated executable. Defaults to `./<scriptname>.exe` on Windows and `./<scriptname>` on Linux/macOS.
* `--output-dir <dir>`: Output all files to a directory with a launch script instead of building an executable. Works on Linux, macOS, and Windows.
* `--output-zip <file>`: Output a zip archive containing all files and a launch script. Requires `zip` (Linux/macOS) or PowerShell (Windows).
* `--macosx-bundle`: Build a macOS `.app` bundle. Use `--output` to set the bundle name (default: `<scriptname>.app`). (macOS)
* `--bundle-id <id>`: Set the `CFBundleIdentifier` in `Info.plist` (default: `com.example.<appname>`). Used with `--macosx-bundle`.
* `--no-lzma`: Disable LZMA compression (faster build, larger executable).
* `--innosetup <file>`: Use an Inno Setup script (`.iss`) to create a Windows installer.

#### Executable options:

* `--windows`: Force a Windows GUI application (uses `rubyw.exe`). (Windows only)
* `--console`: Force a console application (uses `ruby.exe`). (Windows only)
* `--chdir-first`: Change working directory to the app's extraction directory before the script starts.
* `--icon <ico>`: Replace the default icon with a custom `.ico` file.
* `--rubyopt <str>`: Set `RUBYOPT` when the executable runs.
* `--debug`: Enable verbose output when the generated executable runs.
* `--debug-extract`: Unpack to a local directory and do not delete after execution (useful for troubleshooting).

### Compilation:

* OCRAN runs your script (using `Kernel#load`) and builds the output when it exits.
* Your program should `require` all necessary files when invoked without arguments so OCRAN can detect all dependencies.
* DLLs are detected automatically; only those within your Ruby installation are included.
* `.rb` files become console applications; `.rbw` files become windowed applications (without a console window popping up on Windows). Use `--console` or `--windows` to override.

### Running your application:

* The working directory is not changed by OCRAN unless you use `--chdir-first`. You must change to the installation or temporary
  directory yourself. See also below.
* When a `.exe` is running, `OCRAN_EXECUTABLE` points to the `.exe` with its full path.
* The temporary location of the script is available via `$0`.
* OCRAN does not set up the include path. Add `$:.unshift File.dirname($0)` at the start of your script if you need to `require` additional files from the same directory as your main script.

### Directory and zip output (Linux / macOS / Windows):

When using `--output-dir` or `--output-zip`, OCRAN produces the same file
layout as a `.exe` would extract to:

    bin/          # Ruby interpreter and shared libraries
    lib/          # Ruby standard library
    gems/         # Bundled gems
    src/          # Your application source files
    script.sh     # Launch script (Linux/macOS) — or script.bat on Windows

The launch script sets `RUBYLIB`, `GEM_HOME`, `GEM_PATH`, and any other
environment variables, then runs your script with the bundled Ruby.

On Linux/macOS, make the script executable and run it:

    chmod +x myapp/script.sh
    ./myapp/script.sh

On Windows, run the batch file:

    myapp\script.bat

### Pitfalls:

* Avoid modifying load paths at runtime. Use `-I` or `RUBYLIB` if needed, but don't expect OCRAN to preserve them for runtime. OCRAN may pack sources into other directories than you
  expect
* If you use `.rbw` files or `--windows`, verify your application works with `rubyw.exe` before building.
* Avoid absolute paths in your code and when invoking OCRAN.

### Multibyte path and filename support:

* OCRAN-built executables correctly handle multibyte paths (e.g. Japanese, emoji) on Windows 10 1903+.
* When using the executable from the console, run `chcp 65001` first to switch to UTF-8 on windows.

## Limitations

### No cross-platform building

OCRAN is not a cross-compiler. The executable or directory it produces bundles
the Ruby interpreter from the machine where OCRAN is run, so you must **run
OCRAN on the same platform (and architecture) as the intended target**:

* To produce a Windows `.exe`, run OCRAN on Windows.
* To produce a Linux binary, run OCRAN on Linux.
* To produce a macOS app bundle, run OCRAN on macOS.

There is no support for building a Windows `.exe` from a Linux or macOS host,
or vice versa. If you need builds for multiple platforms, run OCRAN in CI on
each target platform separately (e.g., a Windows runner for `.exe` builds and
a Linux runner for Linux builds).

## Requirements

* Ruby 3.2+
* For building Windows `.exe`: Windows with RubyInstaller DevKit (mingw-w64), or Wine on Linux/macOS
* For `--output-dir` / `--output-zip`: any platform with Ruby 3.2+
* For `--output-zip` on Linux/macOS: the `zip` command must be available
* For `--output-zip` on Windows: PowerShell (included in Windows 8+)

### Output architecture

The architecture of the generated executable matches the Ruby interpreter used to run OCRAN:

* **macOS (Intel / Apple Silicon)** — The output binary targets the same CPU as your Ruby installation. If you build with an ARM64 Ruby (Apple Silicon), the result is an ARM64 executable and will not run on Intel Macs. Build on Intel (or with an Intel Ruby under Rosetta) to produce a universally compatible x86-64 binary.

* **Windows on ARM (Windows 11 ARM)** — RubyInstaller recently started shipping ARM64 builds; Installing the ARM64 RubyInstaller on a Windows ARM machine and running OCRAN from it will produce an ARM64 `.exe`. These run on ARM Windows natively. Installing the standard x86-64 RubyInstaller on a Windows ARM machine and running OCRAN from it will (probably?) produce an x86-64 `.exe`. These run on ARM Windows via the built-in x86-64 emulation layer, so the executables work on both ARM and x86-64 Windows targets. If you use `--no-lzma`, note that `lzma.exe` (the bundled compressor) is also x86-64 and relies on the same emulation.

## Development

### Quick start

    git clone https://github.com/largo/ocran.git
    cd ocran
    bin/setup          # install Bundler & all dev gems, build stubs
    bundle exec rake   # run the full Minitest suite
    exe/ocran filename.rb # build filename.rb as an executable

### Developer utilities (`bin/` scripts)

| Script        | Purpose                                                                  |
|---------------|--------------------------------------------------------------------------|
| `bin/setup`   | Installs Bundler and all required development gems, then builds stub.exe |
| `bin/console` | Launches an IRB console with OCRAN preloaded                             |

### Rake tasks

| Task         | Purpose                                                                |
|--------------|------------------------------------------------------------------------|
| `rake build` | Compile stub(.exe) (requires MSVC or mingw-w64 + DevKit or Unix build tools)                |
| `rake clean` | Remove generated binaries                                              |
| `rake test`  | Execute all unit & integration tests                                   |

## Technical details

OCRAN first runs the target script to detect files loaded at runtime (via
`Kernel#require` and `Kernel#load`).

For `.exe` output, OCRAN embeds everything into a single executable: a C stub,
and a custom opcode stream containing instructions to create directories,
extract files, set environment variables, and launch the script. The stub
extracts everything to a temporary directory at runtime and runs the script.

For `--output-dir` / `--output-zip`, OCRAN performs the same file collection
but writes directly to the filesystem and generates a shell/batch launch
script instead of an opcode stream.

### Libraries

Any code loaded through `Kernel#require` when your script runs is included.
Conditionally loaded code is only included if it is actually executed during
the OCRAN build run.
Otherwise, OCRAN won't know about it and will not include
the source files.
You can use `defined?(OCRAN)` to check if the script is running while OCRAN is building it and exit the script after dependencies are loaded but before the main logic runs.

RubyGems are handled specially: when a file from a gem is detected, OCRAN
includes the required files from that gem. It does not automatically include all the files of the Gem, which could be required at runtime. This behavior is controlled with
the `--gem-*` options.

Libraries found in non-standard path (for example, if you invoke OCRAN
with "ruby -I some/path") will be placed into the site dir
(lib/ruby/site_ruby). Avoid changing `$LOAD_PATH` or
`$:` from your script to include paths outside your source
tree, since OCRAN may place the files elsewhere when extracted into the
temporary directory.

If your script uses `Kernel#autoload`, OCRAN will attempt to load those
constants so they are included in the output. Missing modules are ignored
with a warning.

Dynamic link libraries (.dll files, for example WxWidgets, or other
source files) will be detected and included by OCRAN.

### Including libraries non-automatically

If automatic dependency resolution is insufficient, use `--no-dep-run` to
skip running your script. This requires `--gem-full` and typically
`--add-all-core`.

You can specify gems via a Bundler Gemfile with `--gemfile`. OCRAN includes
all listed gems and their dependencies (they must be installed, not vendored
via `bundle package`).

Example — packaging a Rails app without running it:

    ocran someapp/script/rails someapp --output someapp.exe --add-all-core \
    --gemfile someapp/Gemfile --no-dep-run --gem-full --chdir-first -- server

Note the space between `--` and `server`! It's important; `server` is
an argument to be passed to rails when the script is ran.
### Gem handling

By default, OCRAN includes all scripts loaded by your script plus important
non-script files from those gems, excluding C/C++ sources, object files,
READMEs, tests, and specs.

Four modes:

* *minimal*: Loaded scripts only
* *guess*: Loaded scripts and important files (DEFAULT)
* *all*: All scripts and important files
* *full*: All files in the gem directory

If files are missing from the output, try `--gem-all=gemname` first, then
`--gem-full=gemname`. Use `--gem-full` to include everything for all gems.

### Code-signing a macOS app bundle

After building with `--macosx-bundle`, sign the bundle with your Developer ID:

    codesign --deep --force --verify --verbose \
      --sign "Developer ID Application: Your Name (TEAMID)" \
      MyApp.app

Verify the signature:

    codesign --verify --deep --strict --verbose=2 MyApp.app
    spctl --assess --type execute --verbose MyApp.app

For distribution outside the Mac App Store, notarize with Apple:

    # Submit for notarization (requires app-specific password or API key)
    xcrun notarytool submit MyApp.app \
      --apple-id you@example.com \
      --team-id TEAMID \
      --password APP_SPECIFIC_PASSWORD \
      --wait

    # Staple the notarization ticket so it works offline
    xcrun stapler staple MyApp.app

Requirements:
* Xcode Command Line Tools (`xcode-select --install`)
* An Apple Developer account with a "Developer ID Application" certificate in Keychain

### Creating a Windows installer

To make your application start faster or keep files between runs, use
`--innosetup` to generate an Inno Setup installer.

Install Inno Setup 5+ and add it to your `PATH`, then supply an `.iss` script:

Make sure that iss is in the PATH environment variable by running the command `iss` in your terminal.

Do not add any [Files] or [Dirs] sections
to the script; Ocran will figure those out itself.
To continue the Rails example above, let's package the Rails application
into an installer. Save the following as `someapp.iss`:

    [Setup]
    AppName=SomeApp
    AppVersion=0.1
    DefaultDirName={pf}\SomeApp
    DefaultGroupName=SomeApp
    OutputBaseFilename=SomeAppInstaller

    [Icons]
    Name: "{group}\SomeApp"; Filename: "{app}\someapp.bat"; IconFilename: "{app}\someapp.ico"; Flags: runminimized;
    Name: "{group}\Uninstall SomeApp"; Filename: "{uninstallexe}"

    ocran someapp/script/rails someapp --output someapp.exe --add-all-core \
    --gemfile someapp/Gemfile --no-dep-run --gem-full --chdir-first --no-lzma \
    --icon someapp.ico --innosetup someapp.iss -- server

If all goes well, a file named "SomeAppInstaller.exe" will be placed
into the Output directory.

### Environment variables

OCRAN clears the `RUBYLIB` environment variable before running your script so it does not pick up load
paths from the end user's Ruby installation.

OCRAN sets the `RUBYOPT` environment variable to the value it had when you invoked OCRAN. For `.exe`
output, `OCRAN_EXECUTABLE` is set to the full path of the running executable:

    ENV["OCRAN_EXECUTABLE"] # => C:\Program Files\MyApp\MyApp.exe

### Working directory

The OCRAN executable does not change the working directory when it starts. It only changes the working directory when you use
`--chdir-first`.

You should not assume that the current working directory when invoking
an executable built with .exe is the location of the source script. It
can be the directory where the executable is placed (when invoked
through the Windows Explorer), the users' current working directory
(when invoking from the Command Prompt), or even
`C:\\WINDOWS\\SYSTEM32` when the executable is invoked through
a file association.

With `--chdir-first`, the working directory is always the common parent
directory of your source files. Do not use this if your application takes
filenames as command-line arguments.

To `require` additional files from the source directory while keeping the
user's working directory:

    $LOAD_PATH.unshift File.dirname($0)

### Detecting OCRAN at build time

Check for the `Ocran` constant to detect whether OCRAN is currently building
your script:

    app = MyApp.new
    app.main_loop unless defined?(Ocran)

### Additional files and resources

Append extra files, directories, or glob patterns to the command line:

    ocran mainscript.rb someimage.jpeg docs/document.txt
    ocran script.rb assets/**/*.png

This produces the following layout in the output (temp dir for `.exe`,
or the output directory for `--output-dir`):

    src/mainscript.rb
    src/someimage.jpeg
    src/docs/document.txt

Both files, directoriess and glob patterns can be specified on the
command line. Files will be added as-is. If a directory is specified,
OCRAN will include all files found below that directory. Glob patterns
(See Dir.glob) can be used to specify a specific set of files, for
example:

    ocran script.rb assets/**/*.png

### Command Line Arguments

Pass arguments to your script (both during the build run and at runtime)
after a `--` marker:

    ocran script.rb -- --some-option=value

Extra arguments supplied by the user at runtime are appended after the
compile-time arguments.

### Load path mangling

Adding paths to `$LOAD_PATH` or `$:` at runtime is not recommended. Adding
relative load paths depends on the working directory being the same as where
the script is located (see above). If you have additional library files in
directories below the directory containing your source script, use this idiom:

    $LOAD_PATH.unshift File.join(File.dirname($0), 'path/to/script')

### Window/Console

By default, OCRAN builds console applications from `.rb` files and windowed
applications (without a console window) from `.rbw` files.

Ruby on Windows provides two executables: `ruby.exe` is a console mode
application and `rubyw.exe` is a windowed application that does not bring up
a console window when launched from Windows Explorer. By default, or if
`--console` is used, OCRAN uses the console runtime. OCRAN automatically
selects the windowed runtime when your script has the `.rbw` extension, or
when you pass `--windows`.

If your application works in console mode but not in windowed mode, first
check that your script works without OCRAN using `rubyw.exe`. A script that
prints to standard output (`puts`, `print`, etc.) will eventually raise an
exception under `rubyw.exe` once the IO buffers fill up.

You can also wrap your script in an exception handler that logs errors to a
file:

    begin
      # your script here
    rescue Exception => e
      File.open("except.log", "w") do |f|
        f.puts e.inspect
        f.puts e.backtrace
      end
    end

## Credits

Lars Christensen and contributors for the OCRA project which this is forked from.

Kevin Walzer of codebykevin, Maxim Samsonov for ocra2, John Mair for
codesigning support.

Igor Pavlov for the LZMA compressor and decompressor (Public Domain).

Erik Veenstra for rubyscript2exe, which provided inspiration.

Dice for the default `.exe` icon (vit-ruby.ico,
http://ruby.morphball.net/vit-ruby-ico_en.html).

## License

(The MIT License)

Copyright (c) 2009-2020 Lars Christensen
Copyright (c) 2020-2025 The OCRAN Committers Team

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
