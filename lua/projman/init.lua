-- Public API and Neovim commands of projman.nvim.
local M = {}
local project = require("projman.project")
local build = require("projman.build")
local scaffold = require("projman.scaffold")
local engines = require("projman.engines")

-- Every option and its default. An empty string means "not set"; an empty table is a list or map of strings.
local defaults = {
  catalog = "",
  scaffold = { directory = "", chdir = true, open_file = true },
  cmake = { generator = "", executable = "", run_args = {} },
  make = { executable = "make", run_target = "run" },
  engines = {
    unreal = { root = "", target = "", executable = "" },
    unity = { executable = "Unity", build_methods = {} },
    godot = { executable = "godot", external_editor = true, export_presets = {}, export_paths = {} },
  },
}

local config = vim.deepcopy(defaults)

-- Raise an error for options that do not exist or have another type than their default.
local function validate(options, reference, path)
  for key, value in pairs(options) do
    local name, default = path .. key, reference[key]
    if default == nil then
      error("projman: unknown option " .. name, 0)
    elseif type(value) ~= type(default) then
      error(("projman: %s must be a %s"):format(name, type(default)), 0)
    elseif type(default) == "table" and next(default) ~= nil then
      validate(value, default, name .. ".")
    elseif type(default) == "table" then
      for _, item in pairs(value) do
        if type(item) ~= "string" then
          error(("projman: %s must contain only strings"):format(name), 0)
        end
      end
    end
  end
end

local function matching(candidates, lead)
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, lead)
  end, candidates)
end

local function profiles(lead)
  local ctx = project.context()
  local all = { "debug", "release" }
  if ctx and (ctx.kind == "cmake" or ctx.kind == "make") then
    all[#all + 1] = "sanitize"
  end
  return matching(all, lead)
end

local function command(name, callback, description, options)
  options = vim.tbl_extend("force", { desc = description, force = true }, options or {})
  vim.api.nvim_create_user_command(name, callback, options)
end

function M.setup(options)
  options = options or {}
  if type(options) ~= "table" then
    error("projman: setup expects a table", 0)
  end
  validate(options, defaults, "")
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options)

  local function action_command(name, action, description)
    command(name, function(args)
      build.run(action, args.args, config)
    end, description, { nargs = "?", complete = profiles })
  end
  action_command("ProjmanBuild", "build", "Build the detected project [debug|release|sanitize]")
  action_command("ProjmanRun", "run", "Run the detected project [debug|release|sanitize]")
  action_command("ProjmanRefresh", "refresh", "Refresh project metadata and compilation databases")

  command(
    "ProjmanNew",
    function(args)
      scaffold.new(args.args, config)
    end,
    "Create a project from templates.toml",
    {
      nargs = "?",
      complete = function(lead)
        return matching(scaffold.complete(config), lead)
      end,
    }
  )

  command("ProjmanRoot", function()
    local ctx = project.context()
    if ctx then
      vim.api.nvim_set_current_dir(ctx.root)
    else
      vim.notify("No project root found", vim.log.levels.WARN)
    end
  end, "Change to the detected project root")

  command("ProjmanInfo", function()
    build.info(config)
  end, "Show information about the detected project")

  command("ProjmanOpen", function()
    build.run("open", "debug", config)
  end, "Open the detected Unreal, Unity or Godot project in its editor")

  command("ProjmanRunFile", build.run_file, "Compile and run the current C/C++ file")

  local group = vim.api.nvim_create_augroup("Projman", { clear = true })
  if config.engines.godot.external_editor then
    vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, {
      group = group,
      callback = function()
        engines.serve()
      end,
    })
    engines.serve()
  end
  return M
end

function M.context(buf)
  return project.context(buf)
end

function M.find(path)
  return project.find(path)
end

function M.build(profile)
  return build.run("build", profile, config)
end

function M.run(profile)
  return build.run("run", profile, config)
end

function M.refresh(profile)
  return build.run("refresh", profile, config)
end

function M.open()
  return build.run("open", "debug", config)
end

function M.new(spec)
  return scaffold.new(spec, config)
end

function M.info()
  return build.info(config)
end

function M.run_file()
  return build.run_file()
end

function M.get_config()
  return vim.deepcopy(config)
end

return M
