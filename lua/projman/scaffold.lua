-- Create a project by composing the fragments in templates.toml.
local M = {}
local template = require("projman.template")

local labels = {
  c = "C",
  cpp = "C++",
  rust = "Rust",
  zig = "Zig",
  odin = "Odin",
  cs = "C#",
  go = "Go",
  java = "Java",
  python = "Python",
  javascript = "JavaScript",
  typescript = "TypeScript",
  none = "None (Local)",
  git = "Git",
  cmake = "CMake",
  make = "Make",
  native = "Built-in",
  ninja = "Ninja",
  makefiles = "Unix Makefiles",
  vcpkg = "vcpkg",
  uv = "uv",
  pnpm = "pnpm",
  builtin = "Built-in",
}

local builtins = {
  rust = { build = "Cargo", package = "Built-in (Cargo)" },
  zig = { build = "Zig compiler" },
  odin = { build = "Odin compiler" },
  cs = { build = ".NET", package = "Built-in (NuGet)" },
  go = { build = "Go", package = "Built-in (Go Modules)" },
  java = { build = "Gradle", package = "Built-in (Gradle)" },
  python = { build = "Python" },
  javascript = { build = "Node.js" },
  typescript = { build = "TypeScript" },
}

local main_files = { main = true, Main = true, Program = true }

local function label(value)
  return labels[value] or value
end

local function options(value)
  return vim.split(value or "", ",", { plain = true, trimempty = true })
end

local function option_label(language, key, value)
  if key == "vcs" and value == "none" then
    return "None (Local)"
  elseif key == "package" and value == "none" then
    return "None (System / Local)"
  end
  return builtins[language] and builtins[language][key] or label(value)
end

local function choose(values, prompt, done, format_item)
  if #values == 1 then
    return done(values[1])
  end
  vim.ui.select(values, { prompt = prompt, format_item = format_item or label }, function(value)
    if value then
      done(value)
    end
  end)
end

local function package_name(name)
  local slug = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "project"
end

local function variables(language, selected, name)
  local values = { name = name, package_name = package_name(name) }
  local family = {
    c = {
      extension = "c",
      cmake_language = "C",
      compile_feature = "c_std_17",
      compiler_id = "C",
      compiler_variable = "CC",
      compiler = "cc",
      standard_variable = "CSTD",
      standard = "c17",
      flags_variable = "CFLAGS",
    },
    cpp = {
      extension = "cpp",
      cmake_language = "CXX",
      compile_feature = "cxx_std_17",
      compiler_id = "CXX",
      compiler_variable = "CXX",
      compiler = "c++",
      standard_variable = "CXXSTD",
      standard = "c++17",
      flags_variable = "CXXFLAGS",
    },
  }
  values = vim.tbl_extend("force", values, family[language] or {})
  values.generator = selected.generator == "makefiles" and "Unix Makefiles" or "Ninja"
  values.vcpkg_setup = selected.package == "vcpkg"
      and selected.build == "cmake"
      and [[if(NOT DEFINED ENV{VCPKG_ROOT})
  message(FATAL_ERROR "Set VCPKG_ROOT to use vcpkg")
endif()
set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" CACHE STRING "")
]]
    or ""
  return values
end

local function resolve_files(data, language, selected)
  local files, templates = {}, data.templates
  local function merge(source)
    for path, content in pairs(source or {}) do
      if type(content) == "string" then
        files[path] = content
      end
    end
  end

  local shared = templates.shared or {}
  if selected.vcs == "git" then
    merge(shared.git)
  end
  if language == "c" or language == "cpp" then
    merge(shared.c_family)
    merge(shared[selected.build])
    if selected.package == "vcpkg" then
      merge(shared.vcpkg)
    end
  end

  local source = templates[language]
  if not source then
    return nil, "No templates for " .. language
  end
  merge(source)
  merge(source.package and source.package[selected.package])
  return files
end

local function create(data, language, selected, name, config)
  if type(name) ~= "string" or name == "" then
    return vim.notify("Project name cannot be empty", vim.log.levels.ERROR)
  end

  local directory = config.scaffold.directory or vim.uv.cwd()
  if type(directory) ~= "string" or directory == "" then
    return vim.notify("Cannot determine the project creation directory", vim.log.levels.ERROR)
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(directory, ":p"))
  if vim.fn.mkdir(root, "p") == 0 and vim.fn.isdirectory(root) ~= 1 then
    return vim.notify("Cannot create project directory: " .. root, vim.log.levels.ERROR)
  end
  local dir = vim.fs.joinpath(root, name)
  if vim.uv.fs_lstat(dir) then
    return vim.notify(dir .. " already exists", vim.log.levels.ERROR)
  end
  if selected.vcs == "git" and vim.fn.executable("git") ~= 1 then
    return vim.notify("Git was selected but `git` is not installed", vim.log.levels.ERROR)
  end

  local files, err = resolve_files(data, language, selected)
  if not files then
    return vim.notify(err or ("No templates for " .. language), vim.log.levels.ERROR)
  end
  if vim.fn.mkdir(dir) ~= 1 then
    return vim.notify("Cannot create " .. dir, vim.log.levels.ERROR)
  end

  local written, write_err = template.write_files(files, dir, variables(language, selected, name))
  if not written then
    vim.fn.delete(dir, "rf")
    return vim.notify(write_err or "Cannot write project files", vim.log.levels.ERROR)
  end

  if selected.vcs == "git" then
    local ok, result = pcall(function()
      return vim.system({ "git", "init" }, { cwd = dir, text = true }):wait()
    end)
    if not ok or not result or result.code ~= 0 then
      vim.fn.delete(dir, "rf")
      local output = not ok and tostring(result)
        or result and ((result.stderr or "") ~= "" and result.stderr or result.stdout or "")
        or ""
      local message = "Git initialization failed: " .. (output ~= "" and output or "unknown error")
      return vim.notify(message, vim.log.levels.ERROR)
    end
  end

  if config.scaffold.chdir then
    vim.api.nvim_set_current_dir(dir)
  end
  if config.scaffold.open_file then
    for _, relative in ipairs(written) do
      if main_files[vim.fn.fnamemodify(relative, ":t:r")] then
        vim.api.nvim_cmd({ cmd = "edit", args = { vim.fs.joinpath(dir, relative) } }, {})
        break
      end
    end
  end
  vim.notify(("Created %s project: %s"):format(label(language), dir))
end

local function configure(data, language, selected, config)
  local choices = data.choices[language]
  selected = selected or {}
  local steps = {
    { key = "vcs", prompt = "Version control" },
    { key = "build", prompt = "Build system / pipeline" },
    {
      key = "generator",
      prompt = "CMake generator",
      when = function()
        return selected.build == "cmake"
      end,
    },
    { key = "package", prompt = "Package manager" },
  }

  local function next_step(index)
    local step = steps[index]
    if not step then
      local title = {
        label(language),
        option_label(language, "vcs", selected.vcs),
        option_label(language, "build", selected.build),
      }
      if selected.generator then
        title[#title + 1] = label(selected.generator)
      end
      title[#title + 1] = option_label(language, "package", selected.package)
      vim.ui.input({ prompt = table.concat(title, " / ") .. " project name: " }, function(name)
        if not name or name == "" then
          return
        end
        if not name:match("^[%a_][%w_-]*$") then
          return vim.notify("Use letters, digits, - and _ (first character a letter or _)", vim.log.levels.ERROR)
        end
        create(data, language, selected, name, config)
      end)
      return
    end

    if (step.when and not step.when()) or selected[step.key] then
      return next_step(index + 1)
    end
    choose(options(choices[step.key]), step.prompt, function(value)
      selected[step.key] = value
      next_step(index + 1)
    end, function(value)
      return option_label(language, step.key, value)
    end)
  end

  next_step(1)
end

function M.complete(config)
  local data = template.load(config.catalog)
  if not data then
    return {}
  end

  local result, seen = {}, {}
  local order = { "vcs", "build", "generator", "package" }
  local function add(value)
    if not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end

  for language, choices in pairs(data.choices) do
    add(language)

    local selected, parts = {}, { language }
    local function visit(first)
      for index = first, #order do
        local key = order[index]
        if key ~= "generator" or selected.build == "cmake" then
          for _, value in ipairs(options(choices[key])) do
            selected[key] = value
            parts[#parts + 1] = value
            add(table.concat(parts, "-"))
            visit(index + 1)
            parts[#parts] = nil
          end
          selected[key] = nil
        end
      end
    end
    visit(1)
  end

  table.sort(result)
  return result
end

function M.new(spec, config)
  local data, err = template.load(config.catalog)
  if not data then
    return vim.notify(err or "Cannot load template catalog", vim.log.levels.ERROR)
  end

  local languages = vim.tbl_keys(data.choices)
  table.sort(languages)
  local parts = vim.split(spec or "", "-", { plain = true, trimempty = true })
  local language = table.remove(parts, 1)
  if language and not data.choices[language] then
    return vim.notify(("Unknown language %q (use :ProjmanNew <Tab>)"):format(language), vim.log.levels.ERROR)
  end

  local selected, previous = {}, 0
  local order = { "vcs", "build", "generator", "package" }
  if language then
    local choices = data.choices[language]
    for _, value in ipairs(parts) do
      local key, position
      for index = previous + 1, #order do
        local candidate = order[index]
        if candidate ~= "generator" or selected.build == "cmake" then
          if vim.tbl_contains(options(choices[candidate]), value) then
            key, position = candidate, index
            break
          end
        end
      end
      if not key then
        return vim.notify(
          ("Invalid project option %q in :ProjmanNew %s"):format(value, spec or ""),
          vim.log.levels.ERROR
        )
      end
      selected[key], previous = value, position
    end
  elseif #parts > 0 then
    return vim.notify("Specify a language before project options", vim.log.levels.ERROR)
  end

  choose(language and { language } or languages, "Language", function(value)
    configure(data, value, language and selected or nil, config)
  end)
end

return M
