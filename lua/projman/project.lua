-- Detect the nearest supported project around a buffer or directory.
local M = {}

local function extension(name)
  return (name:match("%.([^.]+)$") or ""):lower()
end

M.PROFILES = { "debug", "release", "sanitize" }

-- The decoded JSON object in `path`, or nil when it is missing or invalid.
function M.json(path)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return ok and type(data) == "table" and data or nil
end

-- Entries of `dir` as { name = type }; unreadable or missing directories are empty.
local function list(dir)
  local entries, handle = {}, vim.uv.fs_scandir(dir)
  while handle do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[name] = kind
  end
  return entries
end

-- Sorted names of the non-directory entries whose extension is one of `extensions`.
local function pick(entries, extensions)
  local names = {}
  for name, kind in pairs(entries) do
    if kind ~= "directory" and vim.list_contains(extensions, extension(name)) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function named(...)
  local names = { ... }
  return function(entries)
    for _, name in ipairs(names) do
      if entries[name] and entries[name] ~= "directory" then
        return true
      end
    end
    return false
  end
end

local function with_extension(...)
  local extensions = { ... }
  return function(entries)
    return #pick(entries, extensions) > 0
  end
end

local function unity(entries, dir)
  local assets = entries.Assets and vim.uv.fs_stat(vim.fs.joinpath(dir, "Assets"))
  local version = entries.ProjectSettings
    and vim.uv.fs_stat(vim.fs.joinpath(dir, "ProjectSettings", "ProjectVersion.txt"))
  return assets ~= nil and assets.type == "directory" and version ~= nil and version.type == "file"
end

---@alias ProjmanEntries table<string, string|nil>
---@alias ProjmanDetect fun(entries: ProjmanEntries, dir: string): boolean

-- In priority order: engine projects win over the build files they generate (Unity writes .csproj files).
---@type { [1]: string, [2]: ProjmanDetect }[]
local kinds = {
  { "unreal", with_extension("uproject") },
  { "godot", named("project.godot") },
  { "unity", unity },
  { "cmake", named("CMakeLists.txt") },
  { "make", named("GNUmakefile", "makefile", "Makefile") },
  { "dotnet", with_extension("sln", "slnx", "csproj") },
  { "rust", named("Cargo.toml") },
  { "go", named("go.mod") },
  { "java", named("build.gradle", "build.gradle.kts") },
  { "typescript", named("tsconfig.json") },
  { "javascript", named("package.json") },
  { "python", named("pyproject.toml") },
  { "zig", named("build.zig", "main.zig") },
  { "odin", named("main.odin") },
}

-- Detect a project from a file or directory path (default: the current directory).
function M.find(path)
  local dir = vim.fs.normalize(vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p"))
  while true do
    local entries = list(dir)
    for _, kind in ipairs(kinds) do
      if kind[2](entries, dir) then
        return { kind = kind[1], root = dir }
      end
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return
    end
    dir = parent
  end
end

-- Detect the project of a buffer. Special buffers (terminals, oil://, fugitive://, ...) use the cwd.
function M.context(buf)
  buf = buf or 0
  local name = vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) or ""
  if name:find("^%a[%w+.-]*://") then
    name = ""
  end
  return M.find(name ~= "" and name or nil)
end

-- Sorted names of the files in `root` with one of the given extensions.
function M.files(root, ...)
  return pick(list(root), { ... })
end

-- Whether any of the named files or directories exists in `root`.
function M.has(root, ...)
  for _, name in ipairs({ ... }) do
    if vim.uv.fs_stat(vim.fs.joinpath(root, name)) then
      return true
    end
  end
  return false
end

-- Whether a line of `root/file` matches the Lua `pattern`.
function M.grep(root, file, pattern)
  local ok, lines = pcall(vim.fn.readfile, vim.fs.joinpath(root, file))
  return ok and vim.iter(lines):any(function(line)
    return line:find(pattern) ~= nil
  end)
end

-- Default executable name of a project: its directory name.
function M.binary(root)
  return vim.fs.basename(root) .. (vim.fn.has("win32") == 1 and ".exe" or "")
end

return M
