-- Public API and Neovim command integration for projman.nvim.
local M = {}

local defaults = {
  catalog = nil,
  scaffold = {
    directory = nil,
    chdir = true,
    open_file = true,
  },
  cmake = {
    generator = nil,
    executable = nil,
    run_args = {},
  },
  make = {
    executable = "make",
    run_target = "run",
  },
  engines = {
    unreal = {
      root = nil,
      target = nil,
      executable = nil,
    },
    unity = {
      executable = "Unity",
      build_methods = {},
    },
    godot = {
      executable = "godot",
      external_editor = true,
      export_presets = {},
      export_paths = {},
    },
  },
}

local config = vim.deepcopy(defaults)
local project = require("projman.project")
local build = require("projman.build")
local scaffold = require("projman.scaffold")

local function command(name, callback, description, options)
  options = vim.tbl_extend("force", { desc = description, force = true }, options or {})
  vim.api.nvim_create_user_command(name, callback, options)
end

local function profiles()
  local ctx = project.context()
  if ctx and (ctx.kind == "cmake" or ctx.kind == "make") then
    return { "debug", "release", "sanitize" }
  end
  return { "debug", "release" }
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  local function profile_command(name, action, description)
    command(name, function(args)
      build.run(action, args.args, config)
    end, description, { nargs = "?", complete = profiles })
  end

  profile_command("ProjmanBuild", "build", "Build the detected project [debug|release|sanitize]")
  profile_command("ProjmanRun", "run", "Run the detected project [debug|release|sanitize]")
  profile_command("ProjmanRefresh", "refresh", "Refresh project metadata and compilation databases")

  command(
    "ProjmanNew",
    function(args)
      scaffold.new(args.args, config)
    end,
    "Create a project from templates.toml",
    {
      nargs = "?",
      complete = function()
        return scaffold.complete(config)
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
    build.open(config)
  end, "Open the detected Unreal, Unity or Godot project in its editor")

  command("ProjmanRunFile", build.run_file, "Compile and run the current C/C++ file")

  local group = vim.api.nvim_create_augroup("Projman", { clear = true })
  if config.engines.godot.external_editor then
    vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, {
      group = group,
      callback = function()
        build.ensure_godot_server(config)
      end,
    })
    build.ensure_godot_server(config)
  end
  return M
end

function M.context(buf)
  return project.context(buf)
end

function M.find(root)
  return project.find(root)
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
  return build.open(config)
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
