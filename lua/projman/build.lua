-- Build, run and refresh detected projects with their native toolchains.
local M = {}
local project = require("projman.project")
local template = require("projman.template")

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
local busy, godot_servers = {}, {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function extension(path)
  return vim.fn.fnamemodify(path, ":e")
end

local function absolute(path)
  return path:match("^[/\\]") ~= nil or path:match("^%a:[/\\]") ~= nil
end

local function executable(name)
  return type(name) == "string" and name ~= "" and vim.fn.executable(name) == 1
end

local function launch(argv, cwd, on_exit, lock_root)
  if lock_root and busy[lock_root] then
    return notify("Already running in " .. lock_root, WARN)
  end

  if lock_root then
    busy[lock_root] = true
  end
  vim.cmd("botright 15split")
  local id = vim.fn.jobstart(argv, {
    term = true,
    cwd = cwd,
    on_exit = function(...)
      if lock_root then
        busy[lock_root] = nil
      end
      if on_exit then
        on_exit(...)
      end
    end,
  })
  if id <= 0 then
    if lock_root then
      busy[lock_root] = nil
    end
    vim.cmd("close")
    notify("Cannot start " .. argv[1], ERROR)
    return
  end
  vim.cmd("startinsert")
  return id
end

local function detached(argv, cwd)
  local id = vim.fn.jobstart(argv, { cwd = cwd, detach = true })
  if id <= 0 then
    return notify("Cannot start " .. argv[1], ERROR)
  end
end

-- Run one asynchronous job per project root. Failed output is sent to quickfix.
local function job(root, argv, opts)
  opts = opts or {}
  local title = opts.title or argv[1]
  if busy[root] then
    return notify("Already running in " .. root, WARN)
  end

  local output = {}
  local function collect(_, data)
    if data then
      output[#output + 1] = data
    end
  end

  busy[root] = true
  local ok, process = pcall(vim.system, argv, {
    cwd = root,
    text = true,
    stdout = collect,
    stderr = collect,
  }, function(result)
    vim.schedule(function()
      busy[root] = nil
      if result.code == 0 then
        notify(title .. ": done")
        if opts.on_ok then
          opts.on_ok(table.concat(output))
        end
        return
      end

      if opts.on_error then
        opts.on_error(result)
      end
      local lines = vim.split(table.concat(output), "\n", { trimempty = true })
      vim.fn.setqflist({}, " ", { title = title, lines = lines, efm = opts.efm })
      vim.cmd("botright copen 12")
      notify(("%s: failed (exit %d)"):format(title, result.code or 1), ERROR)
    end)
  end)

  if not ok then
    busy[root] = nil
    return notify(("Cannot run %s: %s"):format(argv[1], process), ERROR)
  end
  notify(title .. "…")
  return process
end

local function has_text(root, file, pattern)
  local path = vim.fs.joinpath(root, file)
  return vim.fn.filereadable(path) == 1
    and vim.iter(vim.fn.readfile(path)):any(function(line)
      return line:match(pattern) ~= nil
    end)
end

local function uses_uv(root)
  return exists(vim.fs.joinpath(root, "uv.lock")) or has_text(root, "pyproject.toml", "^%s*%[tool%.uv%]%s*$")
end

local function uses_pnpm(root)
  return exists(vim.fs.joinpath(root, "pnpm-workspace.yaml"))
    or exists(vim.fs.joinpath(root, "pnpm-lock.yaml"))
    or has_text(root, "package.json", '"packageManager"%s*:%s*"pnpm@')
end

local function package_scripts(root)
  local path = vim.fs.joinpath(root, "package.json")
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(data) == "table" and type(data.scripts) == "table" and data.scripts or {}
end

local function python_command(root)
  return uses_uv(root) and { "uv", "run", "python" } or { executable("python3") and "python3" or "python" }
end

local function gradle_command(root, args)
  local windows = vim.fn.has("win32") == 1
  local wrapper = vim.fs.joinpath(root, windows and "gradlew.bat" or "gradlew")
  if vim.fn.filereadable(wrapper) == 1 then
    if not windows and not executable(wrapper) then
      notify("Gradle wrapper is not executable: " .. wrapper, ERROR)
      return
    end
    return vim.list_extend(windows and { "cmd.exe", "/c", wrapper } or { wrapper }, args)
  end
  return vim.list_extend({ "gradle" }, args)
end

local function make_executable(config)
  local name = config.make.executable
  return name and name ~= "" and name or "make"
end

local function makefile(root)
  for _, name in ipairs({ "GNUmakefile", "makefile", "Makefile" }) do
    local path = vim.fs.joinpath(root, name)
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
end

local function make_sanitizer(root)
  local path = makefile(root)
  return path ~= nil and has_text(root, vim.fs.basename(path), "%-fsanitize=address,undefined")
end

-- Parse conventional compiler commands printed by `make -nB`.
local compilers = {
  gcc = true,
  ["g++"] = true,
  cc = true,
  ["c++"] = true,
  clang = true,
  ["clang++"] = true,
  ["clang-cl"] = true,
  nvcc = true,
}
local sources = {
  c = true,
  C = true,
  cc = true,
  cpp = true,
  cxx = true,
  ["c++"] = true,
  m = true,
  mm = true,
  cu = true,
}
local takes_value = {
  "-o",
  "-I",
  "-isystem",
  "-iquote",
  "-idirafter",
  "-isysroot",
  "--sysroot",
  "-include",
  "-include-pch",
  "-imacros",
  "-MF",
  "-MT",
  "-MQ",
  "-D",
  "-U",
  "-x",
  "-Xclang",
  "-Xlinker",
  "-Xassembler",
  "-Xpreprocessor",
}

local function split_command(line)
  local words, current, quote, started, i = {}, {}, nil, false, 1
  while i <= #line do
    local char = line:sub(i, i)
    if quote then
      if char == quote then
        quote = nil
      elseif char == "\\" and quote == '"' and line:sub(i + 1, i + 1):match('["\\$`]') then
        i = i + 1
        current[#current + 1] = line:sub(i, i)
      else
        current[#current + 1] = char
      end
    elseif char == "'" or char == '"' then
      quote, started = char, true
    elseif char == "\\" and i < #line then
      i = i + 1
      current[#current + 1], started = line:sub(i, i), true
    elseif char:match("%s") then
      if started then
        words[#words + 1] = table.concat(current)
        current, started = {}, false
      end
    else
      current[#current + 1], started = char, true
    end
    i = i + 1
  end
  if quote then
    return nil
  end
  if started then
    words[#words + 1] = table.concat(current)
  end
  return words
end

local function make_entries(output, root)
  local entries, seen, dirs = {}, {}, { root }
  local function resolve(dir, path)
    return vim.fs.normalize(absolute(path) and path or vim.fs.joinpath(dir, path))
  end
  for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
    local entering = line:match("Entering directory [`'](.+)'%s*$")
    local leaving = line:match("Leaving directory [`'](.+)'%s*$")
    if entering then
      dirs[#dirs + 1] = resolve(dirs[#dirs] or root, entering)
    elseif leaving then
      if #dirs > 1 then
        dirs[#dirs] = nil
      end
    else
      local dir = dirs[#dirs] or root
      local args = split_command(line:gsub("^%s*[@+-]+", ""))
      while args and args[1] == "cd" and args[2] and args[3] == "&&" do
        dir = resolve(dir, args[2])
        args = vim.list_slice(args, 4)
      end

      local first
      if args then
        for index, word in ipairs(args) do
          local name = (word:match("[^/\\]+$") or ""):lower():gsub("%.exe$", ""):gsub("%-%d+$", "")
          if compilers[name] then
            first = index
            break
          end
        end
      end
      if first then
        local command = {}
        for index = first, #args do
          if args ~= nil then
            local word = args[index]
            if word == "&&" or word == "||" or word == ";" or word == "|" or word == "&" or word == ">" then
              break
            end
            command[#command + 1] = word
          end
        end
        if not absolute(command[1]) then
          local resolved = vim.fn.exepath(command[1])
          if resolved ~= "" then
            command[1] = resolved
          end
        end

        local skip = false
        for index = 2, #command do
          local word = command[index]
          if skip then
            skip = false
          elseif takes_value[word] then
            skip = true
          elseif word:sub(1, 1) ~= "-" and sources[extension(word)] then
            local file = vim.fs.normalize(absolute(word) and word or vim.fs.joinpath(dir, word))
            local signature = dir .. "\0" .. file .. "\0" .. table.concat(command, "\0")
            if not seen[signature] then
              seen[signature] = true
              entries[#entries + 1] = { directory = dir, file = file, arguments = command }
            end
          end
        end
      end
    end
  end
  return entries
end

local function refresh_make(root, profile, executable_name)
  job(root, { executable_name, "-nB", "BUILD=" .. profile }, {
    title = "Make compilation database (" .. profile .. ")",
    on_ok = function(output)
      local entries = make_entries(output, root)
      if #entries == 0 then
        return notify("`make -nB` listed no compiler commands", WARN)
      end

      local path = vim.fs.joinpath(root, "compile_commands.json")
      local temporary = path .. ".tmp." .. vim.uv.os_getpid()
      if vim.fn.writefile({ vim.json.encode(entries) }, temporary) ~= 0 then
        vim.fn.delete(temporary)
        return notify("Cannot write " .. temporary, ERROR)
      end
      local renamed, err = vim.uv.fs_rename(temporary, path)
      if not renamed then
        vim.fn.delete(temporary)
        return notify("Cannot replace " .. path .. ": " .. err, ERROR)
      end
      notify(("Wrote %d entries to %s"):format(#entries, path))
    end,
  })
end

local function cmake_presets(root, profile)
  local path = vim.fs.joinpath(root, "CMakePresets.json")
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return
  end

  local configure_presets = type(data.configurePresets) == "table" and data.configurePresets or {}
  local configure = vim.iter(configure_presets):find(function(preset)
    return type(preset) == "table" and preset.name == profile
  end)
  if not configure then
    return
  end

  local build_presets = type(data.buildPresets) == "table" and data.buildPresets or {}
  local build = vim.iter(build_presets):find(function(preset)
    return type(preset) == "table" and preset.name == profile and preset.configurePreset == profile
  end)
  local binary_dir = configure.binaryDir
  if binary_dir == nil and not configure.inherits then
    binary_dir = vim.fs.joinpath(root, "build")
  end
  if type(binary_dir) == "string" then
    binary_dir = binary_dir
      :gsub(vim.pesc("${sourceDirName}"), function()
        return vim.fs.basename(root)
      end)
      :gsub(vim.pesc("${sourceDir}"), function()
        return root
      end)
      :gsub(vim.pesc("${presetName}"), profile)
    if
      binary_dir:match("%${")
      or binary_dir:match("%$env{")
      or binary_dir:match("%$penv{")
      or binary_dir:match("%$vendor{")
    then
      binary_dir = nil
    elseif not absolute(binary_dir) then
      binary_dir = vim.fs.normalize(vim.fs.joinpath(root, binary_dir))
    else
      binary_dir = vim.fs.normalize(binary_dir)
    end
  else
    binary_dir = nil
  end

  return { binary_dir = binary_dir, build = build }
end

local function cmake_build_dir(root, profile)
  return vim.fs.joinpath(root, "build", profile)
end

local function cmake_configure(ctx, profile, config, preset, on_ok)
  local argv
  if preset then
    argv = { "cmake", "--preset", profile }
  else
    local build_dir = cmake_build_dir(ctx.root, profile)
    vim.fn.mkdir(build_dir, "p")
    local build_type = profile == "release" and "Release" or profile == "sanitize" and "Sanitize" or "Debug"
    argv = {
      "cmake",
      "-S",
      ctx.root,
      "-B",
      build_dir,
      "-DCMAKE_BUILD_TYPE=" .. build_type,
      "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
    }
    if config.cmake.generator and config.cmake.generator ~= "" then
      vim.list_extend(argv, { "-G", config.cmake.generator })
    end
  end
  job(ctx.root, argv, { title = "CMake configure (" .. profile .. ")", on_ok = on_ok })
end

local function cmake_ensure(ctx, profile, config, preset, on_ok)
  local build_dir = preset and preset.binary_dir or (not preset and cmake_build_dir(ctx.root, profile))
  if build_dir and exists(vim.fs.joinpath(build_dir, "CMakeCache.txt")) then
    return on_ok()
  end
  cmake_configure(ctx, profile, config, preset, on_ok)
end

local function cmake_build(ctx, profile, preset, on_ok)
  local configuration = profile == "release" and "Release" or profile == "sanitize" and "Sanitize" or "Debug"
  local argv
  if preset and preset.build then
    argv = { "cmake", "--build", "--preset", profile }
  else
    local build_dir = preset and preset.binary_dir or (not preset and cmake_build_dir(ctx.root, profile))
    if not build_dir then
      return notify("CMake preset needs a matching build preset or a resolvable binaryDir", ERROR)
    end
    argv = { "cmake", "--build", build_dir, "--config", configuration }
  end
  job(ctx.root, argv, { title = "CMake build (" .. profile .. ")", on_ok = on_ok })
end

local function cmake_executable(ctx, profile, config, preset)
  local configured = config.cmake.executable
  if configured and configured ~= "" then
    return absolute(configured) and configured or vim.fs.joinpath(ctx.root, configured)
  end

  local build_dir = preset and preset.binary_dir or (not preset and cmake_build_dir(ctx.root, profile))
  if not build_dir then
    return
  end
  local name = vim.fs.basename(ctx.root) .. (vim.fn.has("win32") == 1 and ".exe" or "")
  local configuration = profile == "release" and "Release" or profile == "sanitize" and "Sanitize" or "Debug"
  for _, candidate in ipairs({ vim.fs.joinpath(build_dir, configuration, name), vim.fs.joinpath(build_dir, name) }) do
    if exists(candidate) then
      return candidate
    end
  end
end

local function cmake(ctx, action, profile, config)
  local preset = cmake_presets(ctx.root, profile)
  if action == "refresh" then
    return cmake_configure(ctx, profile, config, preset)
  end

  cmake_ensure(ctx, profile, config, preset, function()
    cmake_build(ctx, profile, preset, function()
      if action ~= "run" then
        return
      end
      local executable_path = cmake_executable(ctx, profile, config, preset)
      if not executable_path then
        return notify("CMake build succeeded, but the executable was not found; set cmake.executable", WARN)
      end
      launch(vim.list_extend({ executable_path }, config.cmake.run_args or {}), ctx.root)
    end)
  end)
end

local function dotnet_files(root)
  local solutions, projects = {}, {}
  for name, kind in vim.fs.dir(root) do
    local ext = kind ~= "directory" and extension(name) or nil
    if ext == "sln" or ext == "slnx" then
      solutions[#solutions + 1] = name
    elseif ext == "csproj" then
      projects[#projects + 1] = name
    end
  end
  table.sort(solutions)
  table.sort(projects)
  return solutions, projects
end

local DOTNET_EFM = "%E%f(%l\\,%c): %trror %m,%W%f(%l\\,%c): %tarning %m,%-G%.%#"

local function make_output(ctx, profile)
  local executable_name = vim.fs.basename(ctx.root) .. (vim.fn.has("win32") == 1 and ".exe" or "")
  return vim.fs.joinpath(ctx.root, "build", profile, executable_name)
end

local function build_and_run(ctx, profile, argv, title)
  local output = make_output(ctx, profile)
  vim.fn.mkdir(vim.fs.dirname(output), "p")
  job(ctx.root, argv(output), {
    title = title,
    on_ok = function()
      launch({ output }, ctx.root)
    end,
  })
end

local function typescript_build(root, profile)
  local pnpm = uses_pnpm(root)
  local scripts = package_scripts(root)
  local script = scripts.build
  if profile == "release" and scripts["build:release"] then
    script = "build:release"
  elseif script then
    script = "build"
  end
  if pnpm and script then
    return { "pnpm", "run", script }
  end

  local argv = pnpm and { "pnpm", "exec", "tsc" } or { "tsc" }
  vim.list_extend(argv, { "--project", "tsconfig.json" })
  if profile == "release" then
    argv[#argv + 1] = "--removeComments"
  end
  return argv
end

local function unreal_context(ctx, config)
  local projects = {}
  for name, kind in vim.fs.dir(ctx.root) do
    if kind ~= "directory" and name:match("%.uproject$") then
      projects[#projects + 1] = name
    end
  end
  table.sort(projects)
  if #projects ~= 1 then
    notify((#projects == 0 and "No .uproject in " or "Multiple .uproject files in ") .. ctx.root, WARN)
    return
  end

  local engine = config.engines.unreal.root
  if not engine or engine == "" then
    engine = vim.env.UE_ROOT
  end
  if not engine or engine == "" then
    return notify("Set engines.unreal.root or $UE_ROOT to the Unreal Engine directory", ERROR)
  end
  engine = vim.fs.normalize(vim.fn.fnamemodify(engine, ":p"))

  local system = vim.uv.os_uname().sysname
  local script, platform
  if system == "Windows_NT" then
    script, platform = "Engine/Build/BatchFiles/Build.bat", "Win64"
  elseif system == "Darwin" then
    script, platform = "Engine/Build/BatchFiles/Mac/Build.sh", "Mac"
  else
    script, platform = "Engine/Build/BatchFiles/Linux/Build.sh", "Linux"
  end
  script = vim.fs.joinpath(engine, script)
  if not exists(script) then
    return notify("Unreal BuildTool script not found: " .. script, ERROR)
  end

  local project_file = vim.fs.joinpath(ctx.root, projects[1])
  local target = config.engines.unreal.target
  if not target or target == "" then
    target = projects[1]:gsub("%.uproject$", "") .. "Editor"
  end
  local editor = config.engines.unreal.executable
  if not editor or editor == "" then
    local executable_name = system == "Windows_NT" and "Engine/Binaries/Win64/UnrealEditor.exe"
      or system == "Darwin" and "Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor"
      or "Engine/Binaries/Linux/UnrealEditor"
    editor = vim.fs.joinpath(engine, executable_name)
  end
  return { script = script, platform = platform, project = project_file, target = target, editor = editor }
end

local function unreal_argv(context, profile, extra)
  local configuration = profile == "release" and not context.target:match("Editor$") and "Shipping" or "Development"
  local argv
  if vim.fn.has("win32") == 1 then
    argv = {
      "cmd.exe",
      "/c",
      context.script,
      context.target,
      context.platform,
      configuration,
      "-project=" .. context.project,
    }
  else
    argv = { "bash", context.script, context.target, context.platform, configuration, "-project=" .. context.project }
  end
  return vim.list_extend(argv, extra or {})
end

local function ensure_unreal_files(root, catalog)
  local data, err = template.load(catalog)
  if not data then
    return notify(err, WARN)
  end
  local project_file
  for name, kind in vim.fs.dir(root) do
    if kind ~= "directory" and name:match("%.uproject$") then
      project_file = name
      break
    end
  end
  local clangd = data.unreal and data.unreal[".clangd"]
  local format = data.shared and data.shared.c_family and data.shared.c_family[".clang-format"]
  if type(clangd) ~= "string" or type(format) ~= "string" then
    return notify("Template catalog needs Unreal .clangd and shared C-family .clang-format templates", WARN)
  end
  local files = { [".clangd"] = clangd, [".clang-format"] = format }
  local written, write_err = template.write_files(files, root, {
    name = project_file and project_file:gsub("%.uproject$", "") or vim.fs.basename(root),
  }, true)
  if not written then
    return notify(write_err, WARN)
  end
  if #written > 0 then
    notify("Wrote " .. table.concat(written, " and "))
  end
end

local function unity_executable(config)
  local name = config.engines.unity.executable
  name = name and name ~= "" and name or "Unity"
  return executable(name) and name or nil
end

local function godot_executable(config)
  local name = config.engines.godot.executable
  name = name and name ~= "" and name or "godot"
  return executable(name) and name or nil
end

local function engine_action(ctx, action, profile, config)
  if ctx.kind == "unreal" then
    local unreal = unreal_context(ctx, config)
    if not unreal then
      return
    end
    if profile == "sanitize" then
      return notify("Unreal does not provide the Projman sanitize profile", WARN)
    end
    if action == "build" then
      return job(ctx.root, unreal_argv(unreal, profile), { title = "UnrealBuildTool " .. unreal.target })
    elseif action == "refresh" then
      return job(ctx.root, unreal_argv(unreal, "debug", { "-mode=GenerateClangDatabase", "-OutputDir=" .. ctx.root }), {
        title = "Unreal compilation database",
        on_ok = function()
          local db = vim.fs.joinpath(ctx.root, "compile_commands.json")
          if not exists(db) then
            return notify("UBT finished but wrote no compile_commands.json", WARN)
          end
          ensure_unreal_files(ctx.root, config.catalog)
          local stat = vim.uv.fs_stat(db)
          if stat ~= nil then
            notify(("%s (%.1f MB)"):format(db, stat.size / 1048576))
          end
        end,
      })
    elseif action == "open" or action == "run" then
      if not executable(unreal.editor) then
        return notify("Unreal Editor not found: " .. unreal.editor, ERROR)
      end
      return detached({ unreal.editor, unreal.project }, ctx.root)
    end
  elseif ctx.kind == "unity" then
    local exe = unity_executable(config)
    if not exe then
      return notify("Unity Editor not found; configure engines.unity.executable", ERROR)
    end
    if profile == "sanitize" then
      return notify("Unity does not provide the Projman sanitize profile", WARN)
    end
    if action == "open" or action == "run" then
      return detached({ exe, "-projectPath", ctx.root }, ctx.root)
    end
    local argv = { exe, "-batchmode", "-nographics", "-quit", "-projectPath", ctx.root, "-logFile", "-" }
    local method = config.engines.unity.build_methods[profile]
    if action == "build" and method and method ~= "" then
      vim.list_extend(argv, { "-executeMethod", method })
    end
    return job(ctx.root, argv, { title = action == "refresh" and "Unity import/compile" or "Unity batch build" })
  elseif ctx.kind == "godot" then
    local exe = godot_executable(config)
    if not exe then
      return notify("Godot executable not found; configure engines.godot.executable", ERROR)
    end
    if profile == "sanitize" then
      return notify("Godot does not provide the Projman sanitize profile", WARN)
    end
    if action == "open" then
      return detached({ exe, "--editor", "--path", ctx.root }, ctx.root)
    elseif action == "run" then
      return launch({ exe, "--path", ctx.root }, ctx.root)
    end

    local godot = config.engines.godot or {}
    local preset = (godot.export_presets or {})[profile]
    local argv = { exe, "--headless", "--path", ctx.root }
    if action == "build" and preset and preset ~= "" then
      argv[#argv + 1] = profile == "release" and "--export-release" or "--export-debug"
      argv[#argv + 1] = preset
      local output = (godot.export_paths or {})[profile]
      if output and output ~= "" then
        argv[#argv + 1] = output
      end
      return job(ctx.root, argv, { title = "Godot export (" .. profile .. ")" })
    end
    vim.list_extend(argv, { "--editor", "--quit" })
    return job(ctx.root, argv, { title = "Godot import/validation" })
  end
end

local handlers = {
  cmake = {
    build = function(ctx, profile, config)
      cmake(ctx, "build", profile, config)
    end,
    run = function(ctx, profile, config)
      cmake(ctx, "run", profile, config)
    end,
    refresh = function(ctx, profile, config)
      cmake(ctx, "refresh", profile, config)
    end,
  },
  make = {
    build = function(ctx, profile, config)
      job(ctx.root, { make_executable(config), "BUILD=" .. profile }, { title = "make " .. profile })
    end,
    run = function(ctx, profile, config)
      local target = config.make.run_target ~= "" and config.make.run_target or "run"
      launch({ make_executable(config), "BUILD=" .. profile, target }, ctx.root, nil, ctx.root)
    end,
    refresh = function(ctx, profile, config)
      refresh_make(ctx.root, profile, make_executable(config))
    end,
  },
  rust = {
    build = function(ctx, profile)
      local argv = profile == "release" and { "cargo", "build", "--release" } or { "cargo", "build" }
      job(ctx.root, argv, { title = "cargo build" })
    end,
    run = function(ctx, profile)
      launch(profile == "release" and { "cargo", "run", "--release" } or { "cargo", "run" }, ctx.root)
    end,
  },
  go = {
    build = function(ctx, profile)
      local argv = { "go", "build" }
      if profile == "debug" then
        argv[#argv + 1] = "-gcflags=all=-N -l"
      end
      argv[#argv + 1] = "./..."
      job(ctx.root, argv, { title = "go build" })
    end,
    run = function(ctx, profile)
      local argv = { "go", "run" }
      if profile == "debug" then
        argv[#argv + 1] = "-gcflags=all=-N -l"
      end
      argv[#argv + 1] = "."
      launch(argv, ctx.root)
    end,
  },
  dotnet = {
    build = function(ctx, profile)
      local solutions, projects = dotnet_files(ctx.root)
      local target = #solutions == 1 and solutions[1] or (#solutions == 0 and #projects == 1 and projects[1])
      if not target then
        local message = ("%s holds %d solutions and %d projects; select one solution or one project."):format(
          ctx.root,
          #solutions,
          #projects
        )
        return notify(message, WARN)
      end
      local configuration = profile == "release" and "Release" or "Debug"
      local argv = {
        "dotnet",
        "build",
        "-c",
        configuration,
        "-nologo",
        "-consoleloggerparameters:NoSummary",
        target,
      }
      job(ctx.root, argv, { title = "dotnet build", efm = DOTNET_EFM })
    end,
    run = function(ctx, profile)
      local _, projects = dotnet_files(ctx.root)
      if #projects ~= 1 then
        return notify(("dotnet run needs exactly one root-level project (found %d)"):format(#projects), WARN)
      end
      local configuration = profile == "release" and "Release" or "Debug"
      launch({ "dotnet", "run", "--configuration", configuration, "--project", projects[1] }, ctx.root)
    end,
  },
  java = {
    build = function(ctx, profile)
      local argv = gradle_command(ctx.root, { "build", "-Pprofile=" .. profile })
      if argv then
        job(ctx.root, argv, { title = "gradle build" })
      end
    end,
    run = function(ctx, profile)
      local argv = gradle_command(ctx.root, { "run", "-Pprofile=" .. profile })
      if argv then
        launch(argv, ctx.root)
      end
    end,
  },
  python = {
    build = function(ctx, profile)
      local argv = python_command(ctx.root)
      if profile == "release" then
        argv[#argv + 1] = "-O"
      end
      vim.list_extend(argv, { "-m", "compileall", "-q" })
      if profile == "release" then
        vim.list_extend(argv, { "-o", "1" })
      end
      argv[#argv + 1] = "src"
      job(ctx.root, argv, { title = "Python compile" })
    end,
    run = function(ctx, profile)
      local argv = python_command(ctx.root)
      if profile == "release" then
        argv[#argv + 1] = "-O"
      end
      argv[#argv + 1] = "src/main.py"
      launch(argv, ctx.root)
    end,
  },
  javascript = {
    build = function(ctx)
      local scripts = package_scripts(ctx.root)
      local argv = uses_pnpm(ctx.root) and scripts.build and { "pnpm", "run", "build" }
        or { "node", "--check", "src/main.js" }
      job(ctx.root, argv, { title = argv[1] == "pnpm" and "pnpm build" or "node --check" })
    end,
    run = function(ctx)
      local scripts = package_scripts(ctx.root)
      local argv = uses_pnpm(ctx.root) and scripts.start and { "pnpm", "run", "start" } or { "node", "src/main.js" }
      launch(argv, ctx.root)
    end,
  },
  typescript = {
    build = function(ctx, profile)
      job(ctx.root, typescript_build(ctx.root, profile), { title = "TypeScript build" })
    end,
    run = function(ctx, profile)
      local argv = uses_pnpm(ctx.root) and package_scripts(ctx.root).start and { "pnpm", "run", "start" }
        or { "node", "build/main.js" }
      job(ctx.root, typescript_build(ctx.root, profile), {
        title = "TypeScript build",
        on_ok = function()
          launch(argv, ctx.root)
        end,
      })
    end,
  },
  zig = {
    build = function(ctx, profile)
      local output = make_output(ctx, profile)
      vim.fn.mkdir(vim.fs.dirname(output), "p")
      local optimization = profile == "release" and "ReleaseFast" or "Debug"
      job(ctx.root, { "zig", "build-exe", "main.zig", "-O", optimization, "-femit-bin=" .. output }, {
        title = "zig build-exe",
      })
    end,
    run = function(ctx, profile)
      build_and_run(ctx, profile, function(output)
        local optimization = profile == "release" and "ReleaseFast" or "Debug"
        return { "zig", "build-exe", "main.zig", "-O", optimization, "-femit-bin=" .. output }
      end, "zig build-exe")
    end,
  },
  odin = {
    build = function(ctx, profile)
      local output = make_output(ctx, profile)
      vim.fn.mkdir(vim.fs.dirname(output), "p")
      local optimization = profile == "release" and "-o:speed" or "-debug"
      job(ctx.root, { "odin", "build", ".", "-out:" .. output, optimization }, { title = "odin build" })
    end,
    run = function(ctx, profile)
      build_and_run(ctx, profile, function(output)
        return { "odin", "build", ".", "-out:" .. output, profile == "release" and "-o:speed" or "-debug" }
      end, "odin build")
    end,
  },
}

function M.run(action, requested_profile, config)
  local ctx = project.context()
  if not ctx then
    return notify("No supported project found around this buffer", WARN)
  end

  local profile = requested_profile and requested_profile ~= "" and requested_profile or "debug"
  if profile ~= "debug" and profile ~= "release" and profile ~= "sanitize" then
    return notify("Profile must be debug, release or sanitize", WARN)
  end
  if profile == "sanitize" and ctx.kind ~= "cmake" and ctx.kind ~= "make" then
    return notify("ASan + UBSan is supported by C/C++ CMake and Make projects only", WARN)
  end
  if profile == "sanitize" and ctx.kind == "make" and not make_sanitizer(ctx.root) then
    return notify("The Makefile does not enable both AddressSanitizer and UBSan", WARN)
  end
  if
    profile == "sanitize"
    and ctx.kind == "cmake"
    and not has_text(ctx.root, "CMakeLists.txt", "%-fsanitize=address,undefined")
  then
    return notify("The CMake project does not enable both AddressSanitizer and UBSan", WARN)
  end

  local handler = handlers[ctx.kind] and handlers[ctx.kind][action]
  if handler then
    vim.cmd("wall")
    return handler(ctx, profile, config)
  end
  if ctx.kind == "unreal" or ctx.kind == "unity" or ctx.kind == "godot" then
    vim.cmd("wall")
    return engine_action(ctx, action, profile, config)
  end
  notify((ctx.kind .. " projects do not support " .. action), WARN)
end

function M.open(config)
  local ctx = project.context()
  if not ctx then
    return notify("No supported project found around this buffer", WARN)
  end
  if ctx.kind ~= "unreal" and ctx.kind ~= "unity" and ctx.kind ~= "godot" then
    return notify("Open is available for Unreal, Unity and Godot projects", WARN)
  end
  return engine_action(ctx, "open", "debug", config)
end

function M.run_file()
  local compiler = ({
    c = { name = vim.env.CC, default = "cc", standard = "-std=c17" },
    cpp = { name = vim.env.CXX, default = "c++", standard = "-std=c++17" },
  })[vim.bo.filetype]
  local source = vim.api.nvim_buf_get_name(0)
  if not compiler or source == "" then
    return notify("RunFile needs a saved C or C++ buffer", WARN)
  end

  compiler.name = compiler.name and compiler.name ~= "" and compiler.name or compiler.default
  if not executable(compiler.name) then
    return notify("Compiler not found: " .. compiler.name, ERROR)
  end

  vim.cmd("write")
  local output = vim.fn.tempname() .. (vim.fn.has("win32") == 1 and ".exe" or "")
  local root = vim.fs.dirname(source)
  local function cleanup()
    vim.fn.delete(output)
  end
  local process = job(root, { compiler.name, compiler.standard, "-g", "-Wall", "-Wextra", source, "-o", output }, {
    title = vim.fs.basename(source),
    on_error = cleanup,
    on_ok = function()
      if not launch({ output }, root, cleanup) then
        cleanup()
      end
    end,
  })
  if not process then
    cleanup()
  end
end

function M.info(config)
  local ctx = project.context()
  if not ctx then
    return notify("No supported project found around this buffer", WARN)
  end
  local database
  for _, relative in ipairs({
    "compile_commands.json",
    "build/compile_commands.json",
    "build/debug/compile_commands.json",
    "build/release/compile_commands.json",
    "build/sanitize/compile_commands.json",
  }) do
    if exists(vim.fs.joinpath(ctx.root, relative)) then
      database = relative
      break
    end
  end
  local details = { "kind: " .. ctx.kind, "root: " .. ctx.root, "compile_commands.json: " .. (database or "none") }
  if ctx.kind == "godot" and config.engines.godot.external_editor then
    details[#details + 1] = "Godot RPC socket: " .. (godot_servers[ctx.root] or "not started")
  end
  notify(table.concat(details, "\n"))
end

function M.ensure_godot_server(config)
  if not config.engines.godot.external_editor then
    return
  end
  local ctx = project.context()
  if not ctx or ctx.kind ~= "godot" or godot_servers[ctx.root] then
    return
  end

  local hash = vim.fn.sha256(ctx.root):sub(1, 16)
  local runtime = vim.env.XDG_RUNTIME_DIR
  local path = runtime
      and runtime ~= ""
      and vim.fs.joinpath(runtime, ("projman-godot-%s-%d.sock"):format(hash, vim.uv.os_getpid()))
    or vim.fs.joinpath(ctx.root, (".projman-godot-%d.sock"):format(vim.uv.os_getpid()))
  local stat = vim.uv.fs_lstat(path)

  if stat and stat.type == "socket" then
    local channel = vim.fn.sockconnect("pipe", path, { rpc = true })
    if channel > 0 then
      vim.fn.chanclose(channel)
      godot_servers[ctx.root] = path
      return path
    end
    vim.uv.fs_unlink(path)
  elseif stat then
    return notify("Godot socket path exists and is not a socket: " .. path, WARN)
  end

  if vim.fn.serverstart(path) == "" then
    return notify("Cannot start Godot external-editor socket: " .. path, WARN)
  end
  godot_servers[ctx.root] = path
  return path
end

return M
