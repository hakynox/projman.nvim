-- Dispatch build, run, refresh and open actions to the toolchain of the detected project.
local M = {}
local project = require("projman.project")
local process = require("projman.process")
local cmake = require("projman.cmake")
local make = require("projman.make")
local engines = require("projman.engines")

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
local PROFILES = { "debug", "release", "sanitize" }

local function job(ctx, title, argv, opts)
  return process.job(ctx.root, argv, vim.tbl_extend("force", { title = title }, opts or {}))
end

-- `argv` extended with `...` when `condition` holds.
local function when(condition, argv, ...)
  if condition then
    vim.list_extend(argv, { ... })
  end
  return argv
end

local function uses_uv(root)
  return project.has(root, "uv.lock") or project.grep(root, "pyproject.toml", "^%s*%[tool%.uv%]%s*$")
end

local function uses_pnpm(root)
  return project.has(root, "pnpm-workspace.yaml", "pnpm-lock.yaml")
    or project.grep(root, "package.json", '"packageManager"%s*:%s*"pnpm@')
end

local function package_scripts(root)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(root, "package.json")), "\n"))
  end)
  return ok and type(data) == "table" and type(data.scripts) == "table" and data.scripts or {}
end

-- The Node.js script to run, preferring pnpm's `name` script when the project defines one.
local function node_command(root, name, fallback)
  if uses_pnpm(root) and package_scripts(root)[name] then
    return { "pnpm", "run", name }
  end
  return fallback
end

local function python_command(root, profile)
  local argv = uses_uv(root) and { "uv", "run", "python" }
    or { vim.fn.executable("python3") == 1 and "python3" or "python" }
  if profile == "release" then
    argv[#argv + 1] = "-O"
  end
  return argv
end

local function gradle_command(root, args)
  local windows = vim.fn.has("win32") == 1
  local wrapper = vim.fs.joinpath(root, windows and "gradlew.bat" or "gradlew")
  if vim.fn.filereadable(wrapper) == 0 then
    return vim.list_extend({ "gradle" }, args)
  elseif not windows and vim.fn.executable(wrapper) == 0 then
    return vim.notify("Gradle wrapper is not executable: " .. wrapper, ERROR)
  end
  return vim.list_extend(windows and { "cmd.exe", "/c", wrapper } or { wrapper }, args)
end

local function typescript_build(root, profile)
  local pnpm, scripts = uses_pnpm(root), package_scripts(root)
  local name = profile == "release" and scripts["build:release"] and "build:release" or scripts.build and "build"
  if pnpm and name then
    return { "pnpm", "run", name }
  end
  local argv = vim.list_extend(pnpm and { "pnpm", "exec", "tsc" } or { "tsc" }, { "--project", "tsconfig.json" })
  return when(profile == "release", argv, "--removeComments")
end

local DOTNET_EFM = "%E%f(%l\\,%c): %trror %m,%W%f(%l\\,%c): %tarning %m,%-G%.%#"

local function dotnet_configuration(profile)
  return profile == "release" and "Release" or "Debug"
end

-- Compiler-driven projects build to build/<profile>/<name>. Returns build and run functions for
-- `compiler(profile, output)`, which gives the compiler command; run builds, then starts the result.
local function standalone(title, compiler)
  local function build(ctx, profile, run)
    local output = vim.fs.joinpath(ctx.root, "build", profile, project.binary(ctx.root))
    vim.fn.mkdir(vim.fs.dirname(output), "p")
    job(ctx, title, compiler(profile, output), {
      on_ok = run and function()
        process.launch({ output }, ctx.root)
      end or nil,
    })
  end
  return function(ctx, profile)
    build(ctx, profile, false)
  end, function(ctx, profile)
    build(ctx, profile, true)
  end
end

local zig_exe_build, zig_exe_run = standalone("zig build-exe", function(profile, output)
  local optimize = profile == "release" and "ReleaseFast" or "Debug"
  return { "zig", "build-exe", "main.zig", "-O", optimize, "-femit-bin=" .. output }
end)

local odin_build, odin_run = standalone("odin build", function(profile, output)
  return { "odin", "build", ".", "-out:" .. output, profile == "release" and "-o:speed" or "-debug" }
end)

local function zig_argv(profile, ...)
  return when(profile == "release", { "zig", "build", ... }, "-Doptimize=ReleaseFast")
end

local function go_argv(profile, verb, target)
  local argv = when(profile == "debug", { "go", verb }, "-gcflags=all=-N -l")
  argv[#argv + 1] = target
  return argv
end

local native = {
  rust = {
    build = function(ctx, profile)
      job(ctx, "cargo build", when(profile == "release", { "cargo", "build" }, "--release"))
    end,
    run = function(ctx, profile)
      process.launch(when(profile == "release", { "cargo", "run" }, "--release"), ctx.root)
    end,
  },
  go = {
    build = function(ctx, profile)
      job(ctx, "go build", go_argv(profile, "build", "./..."))
    end,
    run = function(ctx, profile)
      process.launch(go_argv(profile, "run", "."), ctx.root)
    end,
  },
  dotnet = {
    build = function(ctx, profile)
      local solutions, projects = project.files(ctx.root, "sln", "slnx"), project.files(ctx.root, "csproj")
      local target = #solutions == 1 and solutions[1] or (#solutions == 0 and #projects == 1 and projects[1])
      if not target then
        local message = "%s holds %d solutions and %d projects; select one solution or one project."
        return vim.notify(message:format(ctx.root, #solutions, #projects), WARN)
      end
      local argv = { "dotnet", "build", "-c", dotnet_configuration(profile), "-nologo" }
      vim.list_extend(argv, { "-consoleloggerparameters:NoSummary", target })
      job(ctx, "dotnet build", argv, { efm = DOTNET_EFM })
    end,
    run = function(ctx, profile)
      local projects = project.files(ctx.root, "csproj")
      if #projects ~= 1 then
        return vim.notify(("dotnet run needs exactly one root-level project (found %d)"):format(#projects), WARN)
      end
      local argv = { "dotnet", "run", "--configuration", dotnet_configuration(profile), "--project", projects[1] }
      process.launch(argv, ctx.root)
    end,
  },
  java = {
    build = function(ctx, profile)
      local argv = gradle_command(ctx.root, { "build", "-Pprofile=" .. profile })
      if argv then
        job(ctx, "gradle build", argv)
      end
    end,
    run = function(ctx, profile)
      local argv = gradle_command(ctx.root, { "run", "-Pprofile=" .. profile })
      if argv then
        process.launch(argv, ctx.root)
      end
    end,
  },
  python = {
    build = function(ctx, profile)
      local argv = vim.list_extend(python_command(ctx.root, profile), { "-m", "compileall", "-q" })
      if profile == "release" then
        vim.list_extend(argv, { "-o", "1" })
      end
      job(ctx, "Python compile", vim.list_extend(argv, { "src" }))
    end,
    run = function(ctx, profile)
      process.launch(vim.list_extend(python_command(ctx.root, profile), { "src/main.py" }), ctx.root)
    end,
  },
  javascript = {
    build = function(ctx)
      local argv = node_command(ctx.root, "build", { "node", "--check", "src/main.js" })
      job(ctx, argv[1] == "pnpm" and "pnpm build" or "node --check", argv)
    end,
    run = function(ctx)
      process.launch(node_command(ctx.root, "start", { "node", "src/main.js" }), ctx.root)
    end,
  },
  typescript = {
    build = function(ctx, profile)
      job(ctx, "TypeScript build", typescript_build(ctx.root, profile))
    end,
    run = function(ctx, profile)
      job(ctx, "TypeScript build", typescript_build(ctx.root, profile), {
        on_ok = function()
          process.launch(node_command(ctx.root, "start", { "node", "build/main.js" }), ctx.root)
        end,
      })
    end,
  },
  zig = {
    build = function(ctx, profile)
      if project.has(ctx.root, "build.zig") then
        job(ctx, "zig build", zig_argv(profile))
      else
        zig_exe_build(ctx, profile)
      end
    end,
    run = function(ctx, profile)
      if project.has(ctx.root, "build.zig") then
        process.launch(zig_argv(profile, "run"), ctx.root)
      else
        zig_exe_run(ctx, profile)
      end
    end,
  },
  odin = { build = odin_build, run = odin_run },
}

-- Every kind of project, with its build, run, refresh and open handlers as far as it has them.
local handlers = vim.tbl_extend("error", native, engines.handlers, { cmake = cmake, make = make })

-- Why `profile` cannot be used for the project, or nil when it can.
local function problem(ctx, profile)
  local handler = handlers[ctx.kind]
  if not vim.list_contains(PROFILES, profile) then
    return "Profile must be debug, release or sanitize"
  elseif profile == "sanitize" and not handler.sanitizer then
    return "ASan + UBSan is supported by C/C++ CMake and Make projects only"
  elseif profile == "sanitize" and not handler.sanitizer(ctx.root) then
    return (ctx.kind == "make" and "The Makefile" or "The CMake project")
      .. " does not enable both AddressSanitizer and UBSan"
  end
end

local function available(ctx)
  return vim.tbl_filter(function(profile)
    return not problem(ctx, profile)
  end, PROFILES)
end

local active = {} -- project root -> profile chosen in this session

local function current(ctx)
  return vim.list_contains(available(ctx), active[ctx.root]) and active[ctx.root] or "debug"
end

local function detect()
  local ctx = project.context()
  if not ctx then
    vim.notify("No supported project found around this buffer", WARN)
  end
  return ctx
end

-- Profiles the detected project offers; `sanitize` only when its build files enable it.
function M.profiles()
  local ctx = project.context()
  return ctx and available(ctx) or {}
end

-- The active profile of the detected project, or select `name` as the active one.
function M.profile(name)
  local ctx = detect()
  if not ctx or name == nil or name == "" then
    return ctx and current(ctx)
  end
  local reason = problem(ctx, name)
  if reason then
    return vim.notify(reason, WARN)
  end
  active[ctx.root] = name
  vim.notify("Active profile: " .. name)
  return name
end

-- The actions ("build", "run", "refresh", "open") the detected project supports.
function M.actions()
  local ctx = project.context()
  local handler = ctx and handlers[ctx.kind] or {}
  return vim.tbl_filter(function(action)
    return handler[action] ~= nil
  end, { "build", "run", "refresh", "open" })
end

-- Run `action` ("build", "run", "refresh" or "open") on the project around the current buffer. Without a
-- `profile`, the project's active one is used.
function M.run(action, profile, config)
  local ctx = detect()
  if not ctx then
    return
  end

  profile = profile ~= nil and profile ~= "" and profile or current(ctx)
  local reason = problem(ctx, profile)
  if reason then
    return vim.notify(reason, WARN)
  elseif not handlers[ctx.kind][action] then
    return vim.notify(ctx.kind .. " projects do not support " .. action, WARN)
  end

  if action ~= "open" then
    vim.cmd("silent! wall")
  end
  handlers[ctx.kind][action](ctx, profile, config)
end

local COMPILERS = {
  c = { env = "CC", default = "cc", standard = "-std=c17" },
  cpp = { env = "CXX", default = "c++", standard = "-std=c++17" },
}

-- Compile the current C or C++ buffer on its own and run the result.
function M.run_file()
  local compiler = COMPILERS[vim.bo.filetype]
  local source = vim.api.nvim_buf_get_name(0)
  if not compiler or source == "" then
    return vim.notify("RunFile needs a saved C or C++ buffer", WARN)
  end
  local cc = vim.env[compiler.env]
  cc = cc and cc ~= "" and cc or compiler.default
  if vim.fn.executable(cc) ~= 1 then
    return vim.notify("Compiler not found: " .. cc, ERROR)
  end

  vim.cmd("write")
  local output = vim.fn.tempname() .. (vim.fn.has("win32") == 1 and ".exe" or "")
  local dir = vim.fs.dirname(vim.fs.normalize(source))
  local function cleanup()
    vim.fn.delete(output)
  end
  local argv = { cc, compiler.standard, "-g", "-Wall", "-Wextra", source, "-o", output }
  local started = process.job(dir, argv, {
    title = vim.fs.basename(source),
    on_error = cleanup,
    on_ok = function()
      if not process.launch({ output }, dir, cleanup) then
        cleanup()
      end
    end,
  })
  if not started then
    cleanup()
  end
end

function M.info(config)
  local ctx = detect()
  if not ctx then
    return
  end
  local lines = {
    "kind: " .. ctx.kind,
    "root: " .. ctx.root,
    "profile: " .. current(ctx),
    "compile_commands.json: " .. (cmake.database(ctx.root) or "none"),
  }
  if ctx.kind == "godot" and config.engines.godot.external_editor then
    lines[#lines + 1] = "Godot RPC socket: " .. (engines.socket(ctx.root) or "not started")
  end
  vim.notify(table.concat(lines, "\n"))
end

return M
