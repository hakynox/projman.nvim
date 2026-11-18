-- Detect the nearest supported project around a buffer or directory.
local M = {}

local function extension(path)
  return vim.fn.fnamemodify(path, ":e")
end

local function has_extension(...)
  local extensions = {}
  for _, ext in ipairs({ ... }) do
    extensions[ext] = true
  end
  return function(name)
    return extensions[extension(name)] == true
  end
end

local function stat(path, kind)
  local result = vim.uv.fs_stat(path)
  return result ~= nil and (not kind or result.type == kind)
end

local function unity(root)
  return stat(vim.fs.joinpath(root, "ProjectSettings", "ProjectVersion.txt"), "file")
    and stat(vim.fs.joinpath(root, "Assets"), "directory")
end

local kinds = {
  { name = "unreal", markers = has_extension("uproject") },
  { name = "godot", markers = { "project.godot" } },
  { name = "unity", check = unity },
  { name = "cmake", markers = { "CMakeLists.txt" } },
  { name = "make", markers = { "GNUmakefile", "makefile", "Makefile" } },
  { name = "dotnet", markers = has_extension("sln", "slnx", "csproj") },
  { name = "rust", markers = { "Cargo.toml" } },
  { name = "go", markers = { "go.mod" } },
  { name = "java", markers = { "build.gradle", "build.gradle.kts" } },
  { name = "typescript", markers = { "tsconfig.json" } },
  { name = "javascript", markers = { "package.json" } },
  { name = "python", markers = { "pyproject.toml" } },
  { name = "zig", markers = { "main.zig" } },
  { name = "odin", markers = { "main.odin" } },
}

local function has_marker(root, markers)
  if type(markers) == "function" then
    for name, kind in vim.fs.dir(root) do
      if kind ~= "directory" and markers(name) then
        return true
      end
    end
    return false
  end

  for _, name in ipairs(markers) do
    if stat(vim.fs.joinpath(root, name), "file") then
      return true
    end
  end
  return false
end

local function project_at(root)
  for _, kind in ipairs(kinds) do
    if (kind.check and kind.check(root)) or (kind.markers and has_marker(root, kind.markers)) then
      return { kind = kind.name, root = root }
    end
  end
end

function M.find(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path or vim.uv.cwd(), ":p"))
  if not stat(path, "directory") then
    path = vim.fs.dirname(path)
  end

  while path do
    if stat(path, "directory") then
      local context = project_at(path)
      if context then
        return context
      end
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
      break
    end
    path = parent
  end
end

function M.context(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  return M.find(name ~= "" and name or vim.uv.cwd())
end

return M
