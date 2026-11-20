-- Read the templates.toml catalog and write rendered files.
--
-- The catalog is a deliberately small TOML subset: [tables], "quoted" keys, and values that are either a quoted
-- string (no escapes) or a '''multiline literal'''.
local M = {}

function M.default_path()
  return vim.api.nvim_get_runtime_file("templates.toml", false)[1]
end

-- Split a comma-separated option list.
function M.options(value)
  return vim.split(value or "", ",", { plain = true, trimempty = true })
end

local function parse(lines)
  local data, current, headers, i = {}, nil, {}, 0
  local function fail(message)
    error({ line = i, message = message }, 0)
  end

  -- The value of a '''...''' string whose opening quotes were followed by `rest`.
  local function multiline(rest)
    local parts = {}
    if rest == "" then -- like TOML, ignore the newline right after the opening quotes
      i = i + 1
      rest = lines[i]
    end
    while rest do
      local close = rest:find("'''", 1, true)
      if close then
        local trailing = rest:sub(close + 3)
        if not (trailing:find("^%s*$") or trailing:find("^%s*#")) then
          fail("unexpected text after closing '''")
        end
        parts[#parts + 1] = rest:sub(1, close - 1)
        return table.concat(parts, "\n")
      end
      parts[#parts + 1] = rest
      i = i + 1
      rest = lines[i]
    end
    fail("unterminated multiline literal string")
  end

  while i < #lines do
    i = i + 1
    local line = lines[i]
    local header = line:match("^%s*%[([%w_.%-]+)%]%s*$")
    local key, rhs = line:match('^%s*"([^"]+)"%s*=%s*(.-)%s*$')
    if line:find("^%s*$") or line:find("^%s*#") then
      -- blank line or comment
    elseif header then
      if headers[header] then
        fail("duplicate table: " .. header)
      end
      headers[header], current = true, data
      for part in header:gmatch("[^.]+") do
        if current[part] ~= nil and type(current[part]) ~= "table" then
          fail("table conflicts with a string key: " .. part)
        end
        current[part] = current[part] or {}
        current = current[part]
      end
    elseif key and current then
      if current[key] ~= nil then
        fail("duplicate key: " .. key)
      end
      local quote = rhs:sub(1, 1)
      if rhs:sub(1, 3) == "'''" then
        current[key] = multiline(rhs:sub(4))
      elseif (quote == '"' or quote == "'") and #rhs >= 2 and rhs:sub(-1) == quote then
        current[key] = rhs:sub(2, -2)
      else
        fail("expected a quoted string or triple-single-quoted string")
      end
    else
      fail("expected a table header or quoted-key assignment")
    end
  end
  return data
end

-- Describe what is wrong with the parsed catalog, if anything.
local function problem(data)
  if type(data.choices) ~= "table" or type(data.templates) ~= "table" then
    return "needs [choices.*] and [templates.*] tables"
  end
  for language, choices in pairs(data.choices) do
    if type(choices) ~= "table" or type(data.templates[language]) ~= "table" then
      return "missing choices or templates for " .. language
    end
    for _, key in ipairs({ "vcs", "build", "package" }) do
      if type(choices[key]) ~= "string" or choices[key] == "" then
        return ("%s.%s must be a non-empty option list"):format(language, key)
      end
    end
    if vim.list_contains(M.options(choices.build), "cmake") and (choices.generator or "") == "" then
      return language .. " needs CMake generator choices"
    end
  end
end

-- Load the catalog at `path` (default: the bundled one). Returns the data, or nil and a message.
function M.load(path)
  if not path or path == "" then
    path = M.default_path()
  end
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil, "Template catalog not found: " .. (path or "templates.toml")
  end

  local ok, data = pcall(parse, vim.fn.readfile(path))
  if not ok then
    if type(data) ~= "table" then
      error(data, 0)
    end
    return nil, ("Invalid template catalog %s:%d: %s"):format(path, data.line, data.message)
  end
  local reason = problem(data)
  if reason then
    return nil, ("Invalid template catalog %s: %s"):format(path, reason)
  end
  return data
end

-- Replace {{name}} with vars.name; an unknown name is an error.
local function render(text, vars)
  local missing
  local result = text:gsub("{{([%w_]+)}}", function(name)
    if vars[name] == nil then
      missing = missing or name
      return
    end
    return tostring(vars[name])
  end)
  if missing then
    return nil, "Unresolved template variable: {{" .. missing .. "}}"
  end
  return result
end

-- Whether `path` stays inside the destination directory on every platform.
local function safe(path)
  if path == "" or path:find("[\\:%z]") or path:find("^/") or path:find("/$") or path:find("//", 1, true) then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return true
end

-- Create `path` and its parents; true when the directory exists afterwards.
function M.mkdir(path)
  return vim.fn.isdirectory(path) == 1 or (pcall(vim.fn.mkdir, path, "p") and vim.fn.isdirectory(path) == 1)
end

-- Render `files` (a { path = content } table) below `dir`. Everything is rendered and checked before the first
-- write. Returns the sorted relative paths written, or nil and a message.
function M.write_files(files, dir, vars)
  vars = vars or {}
  local paths, plan = vim.tbl_keys(files), {}
  table.sort(paths)

  for _, path in ipairs(paths) do
    local relative, err = render(path, vars)
    if not relative then
      return nil, err
    end
    if not safe(relative) then
      return nil, "Invalid template output path: " .. relative
    end
    local content, content_err = render(files[path], vars)
    if not content then
      return nil, content_err
    end
    plan[#plan + 1] = { relative = relative, path = vim.fs.joinpath(dir, relative), content = content }
  end

  for _, file in ipairs(plan) do
    local parent = vim.fs.dirname(file.path)
    if not M.mkdir(parent) then
      return nil, "Cannot create directory " .. parent
    end
    local ok, status = pcall(vim.fn.writefile, vim.split(file.content, "\n", { plain = true }), file.path, "b")
    if not ok or status ~= 0 then
      return nil, "Cannot write " .. file.path
    end
  end
  return vim.tbl_map(function(file)
    return file.relative
  end, plan)
end

return M
