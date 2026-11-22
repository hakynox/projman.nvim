-- CMake workflow: configure, build and run, with CMakePresets.json support.
local M = {}
local process = require("projman.process")
local project = require("projman.project")
local template = require("projman.template")

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
local CONFIG = { debug = "Debug", release = "Release", sanitize = "Sanitize" }

-- The named presets of CMakePresets.json and CMakeUserPresets.json, includes first, as { configure = {}, build = {} }.
local function load_presets(root)
  local all, seen = { configure = {}, build = {} }, {}
  local function load(path)
    path = vim.fs.normalize(path)
    local data = not seen[path] and project.json(path)
    seen[path] = true
    if not data then
      return
    end
    for _, include in ipairs(type(data.include) == "table" and data.include or {}) do
      if type(include) == "string" then
        load(process.resolve(vim.fs.dirname(path), include))
      end
    end
    for kind, key in pairs({ configure = "configurePresets", build = "buildPresets" }) do
      for _, preset in ipairs(type(data[key]) == "table" and data[key] or {}) do
        if type(preset) == "table" and type(preset.name) == "string" then
          all[kind][preset.name] = preset
        end
      end
    end
  end
  load(vim.fs.joinpath(root, "CMakePresets.json"))
  load(vim.fs.joinpath(root, "CMakeUserPresets.json"))
  return all
end

-- A preset followed by its ancestors in CMake's order of precedence: earlier `inherits` entries win.
local function chain(all, kind, name, result, seen)
  local preset = all[kind][name]
  if not preset or seen[name] then
    return result
  end
  seen[name] = true
  result[#result + 1] = preset
  local parents = type(preset.inherits) == "string" and { preset.inherits } or preset.inherits
  for _, parent in ipairs(type(parents) == "table" and parents or {}) do
    chain(all, kind, parent, result, seen)
  end
  return result
end

-- The first value of `key` along a preset chain.
local function field(presets, key)
  for _, preset in ipairs(presets) do
    if preset[key] ~= nil then
      return preset[key]
    end
  end
end

-- Expand the preset macros of `value`; nil when one cannot be expanded here. `depth` stops cyclic $env{} chains.
local function expand(value, root, presets, depth)
  depth = depth or 0
  if type(value) ~= "string" or depth > 8 then
    return
  end
  local macros = {
    sourceDir = root,
    sourceDirName = vim.fs.basename(root),
    sourceParentDir = vim.fs.dirname(root),
    presetName = presets[1].name,
    generator = field(presets, "generator"),
    hostSystemName = (vim.uv.os_uname().sysname:gsub("_NT$", "")),
    dollar = "$",
  }
  local function replace(kind, name)
    if kind == "" then
      return macros[name]
    elseif kind == "env" then
      for _, preset in ipairs(presets) do
        local value_preset = type(preset.environment) == "table" and preset.environment[name]
        if type(value_preset) == "string" then
          return expand(value_preset, root, presets, depth + 1)
        end
      end
      return vim.env[name]
    elseif kind == "penv" then
      return vim.env[name]
    end
  end
  value = value:gsub("%$(%a*){([^}]*)}", replace)
  return not value:find("%$%a*{") and value or nil
end

-- The configure preset named after `profile` and what is needed to build with it. Nil without a usable preset.
local function find_preset(root, profile)
  local all = load_presets(root)
  local configure = chain(all, "configure", profile, {}, {})
  if #configure == 0 or configure[1].hidden == true then
    return
  end

  local build = chain(all, "build", profile, {}, {})
  local target = field(build, "configurePreset")
  if #build == 0 or build[1].hidden == true or (target ~= nil and target ~= profile) then
    build = nil
  end

  local binary_dir = field(configure, "binaryDir")
  local dir = expand(binary_dir or root, root, configure) -- without binaryDir CMake builds in the source directory
  return {
    dir = dir and process.resolve(root, dir),
    configuration = build and field(build, "configuration"),
    -- `cmake --build --preset` fails when the configure preset has no binaryDir; otherwise CMake knows best.
    use_build_preset = build ~= nil and (binary_dir ~= nil or dir == nil),
  }
end

-- The commands of a profile: `configure`, `build` (nil when the preset leaves no way to build), the build
-- directory `dir` (nil when unknown) and the `configuration` to look for the executable in.
local function plan(root, profile, config)
  local preset = find_preset(root, profile)
  local configuration = CONFIG[profile]
  if not preset then
    local dir = vim.fs.joinpath(root, "build", profile)
    local configure = {
      "cmake",
      "-S",
      root,
      "-B",
      dir,
      "-DCMAKE_BUILD_TYPE=" .. configuration,
      "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
    }
    if config.cmake.generator ~= "" then
      vim.list_extend(configure, { "-G", config.cmake.generator })
    end
    return {
      configure = configure,
      build = { "cmake", "--build", dir, "--config", configuration },
      dir = dir,
      configuration = configuration,
    }
  end

  local result = {
    configure = { "cmake", "--preset", profile, "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" },
    dir = preset.dir,
    configuration = preset.configuration or configuration,
  }
  if preset.use_build_preset then
    result.build = { "cmake", "--build", "--preset", profile }
    if not preset.configuration then
      vim.list_extend(result.build, { "--config", configuration })
    end
  elseif preset.dir then
    result.build = { "cmake", "--build", preset.dir, "--config", result.configuration }
  end
  return result
end

local function executable(root, config, target)
  if config.cmake.executable ~= "" then
    return process.resolve(root, config.cmake.executable)
  elseif not target.dir then
    return
  end
  local name = project.binary(root)
  local candidates = { vim.fs.joinpath(target.dir, target.configuration, name), vim.fs.joinpath(target.dir, name) }
  for _, path in ipairs(candidates) do
    if vim.uv.fs_stat(path) then
      return path
    end
  end
end

-- Whether `dir` still holds what a configure step generates: the cache and, for generators that can write
-- one, the compilation database. Without either, building would fail or leave clangd without a database.
local function configured(dir)
  local function generator(pattern)
    return project.grep(dir, "CMakeCache.txt", "^CMAKE_GENERATOR:INTERNAL=" .. pattern)
  end
  if not (dir and vim.uv.fs_stat(vim.fs.joinpath(dir, "CMakeCache.txt"))) then
    return false
  end
  local exports = generator(".*Ninja") or generator(".*Makefiles")
  return not exports or vim.uv.fs_stat(vim.fs.joinpath(dir, "compile_commands.json")) ~= nil
end

-- Point clangd at the build: <root>/compile_commands.json becomes a link to the database CMake exported
-- (a copy where links are not allowed). Builds in the source directory already have it at the root.
local function link_database(root, dir)
  local source = dir and dir ~= root and vim.fs.joinpath(dir, "compile_commands.json")
  if not (source and vim.uv.fs_stat(source)) then
    return
  end
  local link = vim.fs.joinpath(root, "compile_commands.json")
  local existing = vim.uv.fs_lstat(link)
  if existing and existing.type ~= "link" then
    return vim.notify(link .. " is not a link; remove it so Projman can point clangd at the build", WARN)
  end
  vim.uv.fs_unlink(link)
  local target = vim.startswith(source, root .. "/") and source:sub(#root + 2) or source
  if not vim.uv.fs_symlink(target, link) and not vim.uv.fs_copyfile(source, link) then
    vim.notify("Cannot create " .. link, WARN)
  end
end

local function workflow(action)
  return function(ctx, profile, config)
    local target = plan(ctx.root, profile, config)
    local function configure(on_ok)
      process.job(ctx.root, target.configure, { title = "CMake configure (" .. profile .. ")", on_ok = on_ok })
    end
    if action == "refresh" then
      template.restore(ctx.root, config.catalog, "c_family")
      return configure(function()
        link_database(ctx.root, target.dir)
      end)
    elseif not target.build then
      return vim.notify("CMake preset needs a matching build preset or a resolvable binaryDir", ERROR)
    end

    local function launch()
      local path = executable(ctx.root, config, target)
      if not path then
        return vim.notify("CMake build succeeded, but the executable was not found; set cmake.executable", WARN)
      end
      process.launch(vim.list_extend({ path }, config.cmake.run_args), ctx.root)
    end

    local function build()
      link_database(ctx.root, target.dir)
      local title = "CMake build (" .. profile .. ")"
      process.job(ctx.root, target.build, { title = title, on_ok = action == "run" and launch or nil })
    end

    if configured(target.dir) then
      return build()
    end
    configure(build)
  end
end

M.build, M.run, M.refresh = workflow("build"), workflow("run"), workflow("refresh")

-- Whether the project enables both AddressSanitizer and UBSan, as the `sanitize` profile needs.
function M.sanitizer(root)
  return project.grep(root, "CMakeLists.txt", "%-fsanitize=address,undefined")
end

-- The compile_commands.json CMake or Make left in or below `root`, if any.
function M.database(root)
  local dirs = { root, vim.fs.joinpath(root, "build") }
  for _, profile in ipairs(project.PROFILES) do
    dirs[#dirs + 1] = vim.fs.joinpath(root, "build", profile)
  end
  for _, profile in ipairs(project.PROFILES) do
    local preset = find_preset(root, profile)
    if preset and preset.dir then
      dirs[#dirs + 1] = preset.dir
    end
  end
  for _, dir in ipairs(dirs) do
    local path = vim.fs.joinpath(dir, "compile_commands.json")
    if vim.uv.fs_stat(path) then
      return vim.fs.normalize(path)
    end
  end
end

return M
