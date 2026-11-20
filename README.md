# projman.nvim

A project-oriented Neovim plugin for project discovery, scaffolding, build/run workflows and game-engine integration. It works with Neovim directly and does not depend on LazyVim, a plugin manager, a picker, a terminal emulator or a particular keybinding scheme.

## Requirements

- Neovim 0.10 or newer.
- The toolchain required by the project being managed.
- Git only when Git is selected during project creation.

Projman uses Neovim's native Lua APIs, including `vim.fs`, `vim.system`, `vim.ui.select` and `vim.ui.input`. Build commands are started with argument lists rather than shell-interpolated command strings.

## Installation

With lazy.nvim:

```lua
{
  "Hakynox/projman.nvim",
  event = { "VimEnter", "BufReadPre" },
  opts = {},
}
```

Other plugin managers can install the repository on `runtimepath`; call `require("projman").setup()` from your Neovim configuration.

## Configuration

All options are optional. The defaults are suitable for ordinary projects; configure only the tools or engine paths that cannot be discovered through `PATH`.

```lua
require("projman").setup({
  -- Use the bundled catalog by default.
  catalog = nil,

  scaffold = {
    directory = nil, -- defaults to Neovim's current working directory
    chdir = true,
    open_file = true,
  },

  cmake = {
    generator = nil, -- e.g. "Ninja" or "Unix Makefiles" for projects without presets
    executable = nil, -- run target path; defaults to build/<profile>/<project-name>
    run_args = {},
  },

  make = {
    executable = "make",
    run_target = "run",
  },

  engines = {
    unreal = {
      root = vim.env.UE_ROOT,
      target = nil, -- defaults to <Project>Editor
      executable = nil, -- defaults to the editor inside the engine installation
    },

    unity = {
      executable = "Unity",
      build_methods = {
        -- debug = "BuildScript.BuildDebug",
        -- release = "BuildScript.BuildRelease",
      },
    },

    godot = {
      executable = "godot",
      external_editor = true,
      export_presets = {
        -- debug = "Linux/X11",
        -- release = "Linux/X11",
      },
      export_paths = {},
    },
  },
})
```

Options left out, `nil` or `""` are unset. `setup()` raises an error that names any unknown option or any value of the wrong type, so typos do not go unnoticed.

The bundled `templates.toml` is used unless `catalog` is set to another path. The catalog is intentionally limited to the TOML syntax used by the bundled file: tables, quoted keys/values and multiline literal strings. This keeps project generation dependency-free.

## Commands

| Command | Action |
| --- | --- |
| `:ProjmanNew [spec]` | Create a project from the template catalog |
| `:ProjmanBuild [profile]` | Build the detected project |
| `:ProjmanRun [profile]` | Run the project or launch its engine editor |
| `:ProjmanRefresh [profile]` | Configure/import the project or generate its compilation database |
| `:ProjmanRoot` | Change Neovim's current directory to the project root |
| `:ProjmanInfo` | Show project kind, root and compilation-database information |
| `:ProjmanOpen` | Open an Unreal, Unity or Godot project in its editor |
| `:ProjmanRunFile` | Compile and run the current standalone C/C++ file |

Only one command runs per project directory at a time: while a build, or a program started with `:ProjmanRun`, is running, the next command reports that the directory is busy.

Build profiles are `debug`, `release` and `sanitize`. The default is `debug`. `sanitize` is limited to C/C++ CMake and Make projects whose build files explicitly enable both AddressSanitizer and UndefinedBehaviorSanitizer.

Project detection starts at the current buffer's path and walks upward to the nearest supported project marker. Unnamed buffers and special buffers (terminals, `oil://`, `fugitive://`, ...) use Neovim's current working directory. When marker types share a directory, engine projects take precedence over generated language/build files; this is important for Unity projects containing generated `.csproj` files.

## Project scaffolding

`:ProjmanNew` presents the available choices and creates a new directory under `scaffold.directory` or Neovim's current working directory. A single available choice is selected automatically. Tab completion lists the valid partial combinations that match what you typed.

Examples:

```vim
:ProjmanNew
:ProjmanNew cpp
:ProjmanNew cpp-cmake-ninja
:ProjmanNew cpp-git-cmake-ninja-vcpkg
:ProjmanNew python-git-uv
:ProjmanNew typescript-git-pnpm
```

Selection tokens follow this order: language, VCS, build system, CMake generator (when applicable), package manager.

| Language | Build pipeline | Package manager |
| --- | --- | --- |
| C, C++ | CMake or Make | None or vcpkg (automatic integration with CMake; Make requires manual include/link flags) |
| Rust | Cargo | Built-in (Cargo) |
| Zig | Zig compiler (`build.zig` or `main.zig`) | None |
| Odin | Odin compiler | None |
| C# | .NET | Built-in (NuGet) |
| Go | Go | Built-in (Go Modules) |
| Java | Gradle (uses `gradlew` when present) | Built-in (Gradle) |
| Python | Python | None or uv |
| JavaScript | Node.js | None or pnpm |
| TypeScript | TypeScript / Node.js | None or pnpm |

CMake projects select Ninja or Unix Makefiles. Other languages use their native build systems. Selecting Git writes `.gitignore` and `.gitattributes`, then runs `git init`; selecting None creates a local project without Git metadata. Project creation does not install dependencies.

The catalog creates language projects, not engine projects. Unreal, Unity and Godot projects should be created with their respective engine tools; Projman detects and manages those existing projects.

## Build workflows

### C and C++

The bundled templates provide three profiles:

| Profile | CMake | Make |
| --- | --- | --- |
| `debug` | Debug | `-O0 -g3` |
| `release` | Release | `-O2 -DNDEBUG` |
| `sanitize` | ASan + UBSan | ASan + UBSan |

Projman uses matching configure/build presets when available, including presets in `CMakeUserPresets.json` and included preset files. Preset inheritance is resolved for the fields Projman needs. A configure preset without `binaryDir` uses CMake’s source-directory default. Without presets, Projman configures into `build/<profile>`, exports `compile_commands.json`, and uses the configured generator if supplied. Run targets are resolved in both single- and multi-configuration build directories. Set `cmake.executable` when the run target cannot be inferred or has a different path or name. `cmake.run_args` are passed to it.

Make workflows pass `BUILD=<profile>`. `make.run_target` defaults to `run`. `:ProjmanRefresh` derives a best-effort `compile_commands.json` from `make -nB`; the parser supports conventional compiler commands and basic quoting, not arbitrary shell syntax. Recursive Make and makefile remaking can still execute commands during dry runs, so refresh only trusted Makefiles.

### Native toolchains

| Project | Build | Run |
| --- | --- | --- |
| Rust | `cargo build` | `cargo run` |
| Go | `go build ./...` | `go run .` |
| C# | `dotnet build` | `dotnet run` for one root-level project |
| Java | `gradle build` | `gradle run` |
| Python | `compileall` | `python3` or `uv run` |
| JavaScript | pnpm build script when present, otherwise `node --check` | pnpm start script when present, otherwise Node.js |
| TypeScript | pnpm build script or `tsc` | Build, then pnpm start script or Node.js |
| Zig | `zig build` when `build.zig` exists, otherwise `zig build-exe` | `zig build run` when `build.zig` exists, otherwise build then run |
| Odin | `odin build` | Build then run |

Native profiles map to the toolchain's ordinary debug/release options where available. Plain JavaScript has no separate compilation profile, so debug and release are identical. These workflows do not claim to provide ASan+UBSan. For Zig projects with `build.zig`, `:ProjmanRun` expects a `run` build step.

Python projects with `uv.lock` or a `[tool.uv]` section use `uv`; JavaScript/TypeScript projects with a pnpm lockfile, workspace file or `packageManager` declaration use pnpm. Gradle projects use the local wrapper when present (it must be executable on Unix; Windows wrappers run through `cmd.exe`), otherwise the `gradle` executable on `PATH`. For .NET, one root-level solution is preferred for building; without a solution, exactly one root-level project is required. Running requires exactly one root-level project. Projects with multiple executable targets need an explicit project selection outside the current automatic workflow.

## Engine integrations

### Unreal Engine

Set `engines.unreal.root` or `$UE_ROOT` to the engine directory containing `Engine/Build/BatchFiles`. Projman detects one `.uproject` file at the project root, builds its `<Project>Editor` target by default, and supports a configured target override. Debug maps to UBT `Development`; release maps to `Shipping` for non-editor targets. The default `<Project>Editor` target remains `Development`, because Unreal Editor targets are not Shipping builds.

`:ProjmanRefresh` invokes UBT's `GenerateClangDatabase` mode and writes `.clangd` and `.clang-format` only when those files do not already exist. The templates come from `templates.toml`. `:ProjmanRun` and `:ProjmanOpen` launch Unreal Editor with the project. ASan+UBSan is not provided for Unreal projects.

### Unity

A Unity project is detected from `Assets/` and `ProjectSettings/ProjectVersion.txt`. Set `engines.unity.executable` when `Unity` is not on `PATH`.

`:ProjmanOpen` and `:ProjmanRun` open the project in Unity Editor. `:ProjmanBuild` runs Unity in batch mode to import assets and compile scripts. To perform an actual player build, configure the project's own static build methods in `engines.unity.build_methods.debug` and/or `.release`; Projman passes the selected method through `-executeMethod`. This deliberately avoids inventing a universal Unity build method, since player-build settings and output paths belong to the project.

`:ProjmanRefresh` runs a batch import/compile pass. Unity does not expose the Projman ASan+UBSan profile.

### Godot

A Godot project is detected by `project.godot`. Set `engines.godot.executable` when the executable is not named `godot` on `PATH`.

- `:ProjmanRun` launches the project.
- `:ProjmanOpen` opens the editor.
- `:ProjmanRefresh` performs a headless editor import/validation pass.
- `:ProjmanBuild` exports the configured profile when `export_presets.debug` or `.release` is set; otherwise it performs the same headless import/validation pass.

Export preset names must match those in the project's `export_presets.cfg`. Optional `export_paths.debug` and `.release` values override the export destination.

When `external_editor` is enabled, Projman serves a Neovim RPC socket when you enter a Godot project. Its path depends only on the project root, so it is the same in every session and needs to be configured in Godot only once. If another Neovim already serves it, that instance is used; a stale socket left behind by a crash is replaced. `:ProjmanInfo` displays the path. Use it in Godot's External Editor **Exec Flags**:

```text
--server <socket-path> --remote-send "<C-\\><C-N>:e {file}<CR>:call cursor({line},{col})<CR>"
```

Godot's editor must be running for its language server. For Godot .NET projects, configure the executable to the corresponding Godot .NET build.

## Lua API

```lua
local projman = require("projman")

projman.setup({})
local context = projman.context() -- { kind = "cmake", root = "/path/to/project" }
projman.build("debug")
projman.run("release")
projman.refresh()
projman.open()
projman.new("cpp-cmake-ninja")
projman.info()
```

`projman.find(path)` detects a project from a file or directory path. `projman.get_config()` returns a copy of the active configuration. The plugin does not set keymaps; users can map commands or Lua API calls however they prefer.
