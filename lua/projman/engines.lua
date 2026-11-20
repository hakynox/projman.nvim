-- Unreal, Unity and Godot workflows. `M.handlers[kind][action]` follows the (ctx, profile, config) convention of
-- the build modules; the `sanitize` profile never reaches an engine.
local M = {}
local process = require("projman.process")
local project = require("projman.project")
local template = require("projman.template")

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

-- The name of `tool` if it can be run (falling back to `default` when unset), else nil.
local function binary(tool, default)
  tool = tool ~= "" and tool or default
  return vim.fn.executable(tool) == 1 and tool or nil
end

---------------------------------------------------------------------------------------------------------------------
-- Unreal
---------------------------------------------------------------------------------------------------------------------

-- Platform name, BuildTool script and editor binary below the engine directory.
local PLATFORMS = {
  Windows_NT = { "Win64", "Engine/Build/BatchFiles/Build.bat", "Engine/Binaries/Win64/UnrealEditor.exe" },
  Darwin = {
    "Mac",
    "Engine/Build/BatchFiles/Mac/Build.sh",
    "Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor",
  },
  Linux = { "Linux", "Engine/Build/BatchFiles/Linux/Build.sh", "Engine/Binaries/Linux/UnrealEditor" },
}

-- Everything needed to drive UnrealBuildTool, or nil after saying what is missing.
local function unreal_setup(ctx, config)
  local projects = project.files(ctx.root, "uproject")
  if #projects ~= 1 then
    return vim.notify((#projects == 0 and "No .uproject in " or "Multiple .uproject files in ") .. ctx.root, WARN)
  end

  local settings = config.engines.unreal
  local engine = settings.root ~= "" and settings.root or vim.env.UE_ROOT or ""
  if engine == "" then
    return vim.notify("Set engines.unreal.root or $UE_ROOT to the Unreal Engine directory", ERROR)
  end
  engine = vim.fs.normalize(vim.fn.fnamemodify(engine, ":p"))

  local platform, script, editor = unpack(PLATFORMS[vim.uv.os_uname().sysname] or PLATFORMS.Linux)
  script = vim.fs.joinpath(engine, script)
  if not vim.uv.fs_stat(script) then
    return vim.notify("Unreal BuildTool script not found: " .. script, ERROR)
  end

  return {
    script = script,
    platform = platform,
    project = vim.fs.joinpath(ctx.root, projects[1]),
    target = settings.target ~= "" and settings.target or vim.fn.fnamemodify(projects[1], ":t:r") .. "Editor",
    editor = settings.executable ~= "" and settings.executable or vim.fs.joinpath(engine, editor),
  }
end

local function unreal_argv(unreal, profile, extra)
  local configuration = profile == "release" and not unreal.target:find("Editor$") and "Shipping" or "Development"
  local argv = vim.fn.has("win32") == 1 and { "cmd.exe", "/c", unreal.script } or { "bash", unreal.script }
  vim.list_extend(argv, { unreal.target, unreal.platform, configuration, "-project=" .. unreal.project })
  return vim.list_extend(argv, extra or {})
end

-- Write .clangd and .clang-format from the catalog unless the project has them.
local function write_clang_files(root, catalog)
  local data, err = template.load(catalog)
  if not data then
    return vim.notify(err or "Failed to load template catalog", WARN)
  end
  local clangd = vim.tbl_get(data, "unreal", ".clangd")
  local format = vim.tbl_get(data, "templates", "shared", "c_family", ".clang-format")
  if type(clangd) ~= "string" or type(format) ~= "string" then
    return vim.notify("Template catalog needs Unreal .clangd and shared C-family .clang-format templates", WARN)
  end

  local files = {}
  for path, content in pairs({ [".clangd"] = clangd, [".clang-format"] = format }) do
    if not vim.uv.fs_lstat(vim.fs.joinpath(root, path)) then
      files[path] = content
    end
  end
  local written, write_err = template.write_files(files, root)
  if not written then
    return vim.notify(write_err or "Failed to write clang config files", WARN)
  end
  if #written > 0 then
    vim.notify("Wrote " .. table.concat(written, " and "))
  end
end

local unreal = {}

function unreal.build(ctx, profile, config)
  local setup = unreal_setup(ctx, config)
  if setup then
    process.job(ctx.root, unreal_argv(setup, profile), { title = "UnrealBuildTool " .. setup.target })
  end
end

function unreal.refresh(ctx, _, config)
  local setup = unreal_setup(ctx, config)
  if not setup then
    return
  end
  local extra = { "-mode=GenerateClangDatabase", "-OutputDir=" .. ctx.root }
  process.job(ctx.root, unreal_argv(setup, "debug", extra), {
    title = "Unreal compilation database",
    on_ok = function()
      local database = vim.fs.joinpath(ctx.root, "compile_commands.json")
      local stat = vim.uv.fs_stat(database)
      if not stat then
        return vim.notify("UBT finished but wrote no compile_commands.json", WARN)
      end
      write_clang_files(ctx.root, config.catalog)
      vim.notify(("%s (%.1f MB)"):format(database, stat.size / 1048576))
    end,
  })
end

function unreal.open(ctx, _, config)
  local setup = unreal_setup(ctx, config)
  if not setup then
    return
  elseif vim.fn.executable(setup.editor) ~= 1 then
    return vim.notify("Unreal Editor not found: " .. setup.editor, ERROR)
  end
  process.detached({ setup.editor, setup.project }, ctx.root)
end
unreal.run = unreal.open

---------------------------------------------------------------------------------------------------------------------
-- Unity
---------------------------------------------------------------------------------------------------------------------

local unity = {}

local function unity_binary(config)
  local exe = binary(config.engines.unity.executable, "Unity")
  if not exe then
    vim.notify("Unity Editor not found; configure engines.unity.executable", ERROR)
  end
  return exe
end

function unity.open(ctx, _, config)
  local exe = unity_binary(config)
  if exe then
    process.detached({ exe, "-projectPath", ctx.root }, ctx.root)
  end
end
unity.run = unity.open

-- Import assets and compile scripts in batch mode, optionally through the project's own build method.
local function unity_batch(ctx, config, title, method)
  local exe = unity_binary(config)
  if not exe then
    return
  end
  local argv = { exe, "-batchmode", "-nographics", "-quit", "-projectPath", ctx.root, "-logFile", "-" }
  if method and method ~= "" then
    vim.list_extend(argv, { "-executeMethod", method })
  end
  process.job(ctx.root, argv, { title = title })
end

function unity.build(ctx, profile, config)
  unity_batch(ctx, config, "Unity batch build", config.engines.unity.build_methods[profile])
end

function unity.refresh(ctx, _, config)
  unity_batch(ctx, config, "Unity import/compile")
end

---------------------------------------------------------------------------------------------------------------------
-- Godot
---------------------------------------------------------------------------------------------------------------------

local godot = {}

local function godot_binary(config)
  local exe = binary(config.engines.godot.executable, "godot")
  if not exe then
    vim.notify("Godot executable not found; configure engines.godot.executable", ERROR)
  end
  return exe
end

function godot.open(ctx, _, config)
  local exe = godot_binary(config)
  if exe then
    process.detached({ exe, "--editor", "--path", ctx.root }, ctx.root)
  end
end

function godot.run(ctx, _, config)
  local exe = godot_binary(config)
  if exe then
    process.launch({ exe, "--path", ctx.root }, ctx.root)
  end
end

function godot.refresh(ctx, _, config)
  local exe = godot_binary(config)
  if exe then
    process.job(ctx.root, { exe, "--headless", "--path", ctx.root, "--editor", "--quit" }, {
      title = "Godot import/validation",
    })
  end
end

-- Export the profile's preset when one is configured, else do what :ProjmanRefresh does.
function godot.build(ctx, profile, config)
  local settings = config.engines.godot
  local preset = settings.export_presets[profile]
  if not preset or preset == "" then
    return godot.refresh(ctx, profile, config)
  end
  local exe = godot_binary(config)
  if not exe then
    return
  end
  local argv =
    { exe, "--headless", "--path", ctx.root, profile == "release" and "--export-release" or "--export-debug" }
  argv[#argv + 1] = preset
  if settings.export_paths[profile] and settings.export_paths[profile] ~= "" then
    argv[#argv + 1] = settings.export_paths[profile]
  end
  process.job(ctx.root, argv, { title = "Godot export (" .. profile .. ")" })
end

-- Godot's external-editor setting needs a fixed address to send files to. Each Godot project gets a socket
-- named after its root; if another Neovim already serves it, that one is used.
local servers = {} -- project root -> socket path, or false after a failed attempt

local function socket_path(root)
  local dir = vim.env.XDG_RUNTIME_DIR
  if not dir or dir == "" then
    dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "projman")
  end
  if vim.fn.isdirectory(dir) == 0 and not pcall(vim.fn.mkdir, dir, "p", 448) then -- 448 = 0700
    return nil, "Cannot create " .. dir
  end
  return vim.fs.joinpath(dir, ("godot-%s.sock"):format(vim.fn.sha256(root):sub(1, 16)))
end

-- Make sure something serves RPC on `path`: this Neovim, another one, or a new server replacing a stale socket.
local function serve(path)
  if vim.list_contains(vim.fn.serverlist(), path) then
    return true
  end
  local stat = vim.uv.fs_lstat(path)
  if stat then
    if stat.type ~= "socket" then
      return false, path .. " exists and is not a socket"
    end
    local alive, channel = pcall(vim.fn.sockconnect, "pipe", path, { rpc = true }) -- throws when refused
    if alive and channel > 0 then
      vim.fn.chanclose(channel)
      return true
    end
    vim.uv.fs_unlink(path)
  end
  local ok, err = pcall(vim.fn.serverstart, path)
  return ok, not ok and err or nil
end

-- Called whenever the buffer or directory changes; cheap unless it finds a new Godot project.
function M.serve()
  local root = vim.fs.root(0, "project.godot")
  if not root or servers[root] ~= nil then
    return
  end
  servers[root] = false
  local path, err = socket_path(root)
  if path then
    local ok
    ok, err = serve(path)
    servers[root] = ok and path
  end
  if not servers[root] then
    vim.notify("Cannot start Godot external-editor socket: " .. tostring(err), WARN)
  end
end

-- The socket serving a Godot project, if any.
function M.socket(root)
  return servers[root] or nil
end

M.handlers = { unreal = unreal, unity = unity, godot = godot }

return M
