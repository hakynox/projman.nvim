-- Create a project by composing the fragments of templates.toml.
local M = {}
local template = require("projman.template")

local ERROR = vim.log.levels.ERROR

local LABELS = {
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

-- Per-language names of the single native build system and package manager.
local NATIVE = {
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

-- The questions asked after the language, in the order of the spec tokens (:ProjmanNew cpp-git-cmake-ninja-vcpkg).
local STEPS = {
  { key = "vcs", prompt = "Version control" },
  { key = "build", prompt = "Build system / pipeline" },
  {
    key = "generator",
    prompt = "CMake generator",
    when = function(selected)
      return selected.build == "cmake"
    end,
  },
  { key = "package", prompt = "Package manager" },
}

local FAMILY = {
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

local VCPKG_SETUP = [[
if(NOT DEFINED ENV{VCPKG_ROOT})
  message(FATAL_ERROR "Set VCPKG_ROOT to use vcpkg")
endif()
set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" CACHE STRING "")
]]

local MAIN_FILES = { main = true, Main = true, Program = true }

local function fail(message)
  vim.notify(message, ERROR)
end

local function label(value)
  return LABELS[value] or value
end

local function option_label(language, key, value)
  if key == "vcs" and value == "none" then
    return "None (Local)"
  elseif key == "package" and value == "none" then
    return "None (System / Local)"
  end
  return NATIVE[language] and NATIVE[language][key] or label(value)
end

-- Ask for one of `values`; a single value is chosen without asking.
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

local function variables(language, selected, name)
  local slug = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-", ""):gsub("%-+$", "")
  local vars =
    vim.tbl_extend("force", { name = name, package_name = slug ~= "" and slug or "project" }, FAMILY[language] or {})
  vars.generator = selected.generator == "makefiles" and "Unix Makefiles" or "Ninja"
  vars.vcpkg_setup = selected.package == "vcpkg" and selected.build == "cmake" and VCPKG_SETUP or ""
  return vars
end

-- The template files of a project: later groups replace earlier ones.
local function collect(data, language, selected)
  local files, templates = {}, data.templates
  local function merge(group)
    for path, content in pairs(group or {}) do
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
  merge(templates[language])
  merge(templates[language].package and templates[language].package[selected.package])
  return files
end

local function git_init(dir)
  local ok, result = pcall(function()
    return vim.system({ "git", "init" }, { cwd = dir, text = true }):wait()
  end)
  if ok and result.code == 0 then
    return true
  end
  local output
  if ok then
    local stderr, stdout = result.stderr or "", result.stdout or ""
    output = vim.trim(stderr ~= "" and stderr or stdout)
  else
    output = tostring(result)
  end
  return false, output ~= "" and output or "unknown error"
end

local function create(data, language, selected, name, config)
  local base = config.scaffold.directory ~= "" and config.scaffold.directory or vim.fn.getcwd()
  base = vim.fs.normalize(vim.fn.fnamemodify(base, ":p"))
  local dir = vim.fs.joinpath(base, name)
  if not template.mkdir(base) then
    return fail("Cannot create project directory: " .. base)
  elseif vim.uv.fs_lstat(dir) then
    return fail(dir .. " already exists")
  elseif selected.vcs == "git" and vim.fn.executable("git") ~= 1 then
    return fail("Git was selected but `git` is not installed")
  end

  local files = collect(data, language, selected)
  if not template.mkdir(dir) then
    return fail("Cannot create " .. dir)
  end
  local written, err = template.write_files(files, dir, variables(language, selected, name))
  if not written then
    vim.fn.delete(dir, "rf")
    return fail(err)
  end
  if selected.vcs == "git" then
    local ok, output = git_init(dir)
    if not ok then
      vim.fn.delete(dir, "rf")
      return fail("Git initialization failed: " .. output)
    end
  end

  if config.scaffold.chdir then
    vim.api.nvim_set_current_dir(dir)
  end
  if config.scaffold.open_file then
    for _, relative in ipairs(written) do
      if MAIN_FILES[vim.fn.fnamemodify(relative, ":t:r")] then
        vim.api.nvim_cmd({ cmd = "edit", args = { vim.fs.joinpath(dir, relative) } }, {})
        break
      end
    end
  end
  vim.notify(("Created %s project: %s"):format(label(language), dir))
end

-- Ask the questions `selected` does not answer yet, then the project name, then create the project.
local function configure(data, language, selected, config)
  local choices = data.choices[language]

  local function ask(index)
    local step = STEPS[index]
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
      return vim.ui.input({ prompt = table.concat(title, " / ") .. " project name: " }, function(name)
        if not name or name == "" then
          return
        elseif not name:find("^[%a_][%w_-]*$") then
          return fail("Use letters, digits, - and _ (first character a letter or _)")
        end
        create(data, language, selected, name, config)
      end)
    end

    if (step.when and not step.when(selected)) or selected[step.key] then
      return ask(index + 1)
    end
    choose(template.options(choices[step.key]), step.prompt, function(value)
      selected[step.key] = value
      ask(index + 1)
    end, function(value)
      return option_label(language, step.key, value)
    end)
  end

  ask(1)
end

-- Assign spec tokens to steps in order (skipping steps is allowed). Returns the selection, or nil and the bad token.
local function parse(choices, tokens)
  local selected, previous = {}, 0
  for _, token in ipairs(tokens) do
    local found = false
    for index = previous + 1, #STEPS do
      local step = STEPS[index]
      if (not step.when or step.when(selected)) and vim.list_contains(template.options(choices[step.key]), token) then
        selected[step.key], previous, found = token, index, true
        break
      end
    end
    if not found then
      return nil, token
    end
  end
  return selected
end

-- Every valid partial spec, for :ProjmanNew completion.
function M.complete(config)
  local data = template.load(config.catalog)
  if not data then
    return {}
  end

  local result, seen = {}, {}
  local function add(spec)
    if not seen[spec] then
      seen[spec] = true
      result[#result + 1] = spec
    end
  end
  local function visit(choices, selected, first, prefix)
    for index = first, #STEPS do
      local step = STEPS[index]
      if not step.when or step.when(selected) then
        for _, value in ipairs(template.options(choices[step.key])) do
          selected[step.key] = value
          add(prefix .. "-" .. value)
          visit(choices, selected, index + 1, prefix .. "-" .. value)
        end
        selected[step.key] = nil
      end
    end
  end

  for language, choices in pairs(data.choices) do
    add(language)
    visit(choices, {}, 1, language)
  end
  table.sort(result)
  return result
end

function M.new(spec, config)
  local data, err = template.load(config.catalog)
  if not data then
    return fail(err)
  end

  local tokens = vim.split(spec or "", "-", { plain = true, trimempty = true })
  local language = table.remove(tokens, 1)
  ---@type table|nil
  local selected = {}
  if language then
    if not data.choices[language] then
      return fail(("Unknown language %q (use :ProjmanNew <Tab>)"):format(language))
    end
    local token
    selected, token = parse(data.choices[language], tokens)
    if not selected then
      return fail(("Invalid project option %q in :ProjmanNew %s"):format(token or "", spec or ""))
    end
  end

  local languages = vim.tbl_keys(data.choices)
  table.sort(languages)
  choose(language and { language } or languages, "Language", function(value)
    configure(data, value, selected or {}, config)
  end)
end

return M
