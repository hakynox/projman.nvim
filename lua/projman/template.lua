-- Read and write the project's declarative templates.toml catalog.
local M = {}

local function error_at(path, line, message)
  return ("Invalid template catalog %s:%d: %s"):format(path, line, message)
end

local function multiline(lines, line_no, rhs, key, path)
  local content = {}
  local first = rhs:sub(4)
  local close = first:find("'''", 1, true)
  if close then
    local trailing = first:sub(close + 3)
    if not trailing:match("^%s*$") and not trailing:match("^%s*#") then
      return nil, line_no, error_at(path, line_no, "unexpected text after " .. key)
    end
    return first:sub(1, close - 1), line_no
  end

  if first ~= "" then
    content[#content + 1] = first
  end

  repeat
    line_no = line_no + 1
    local line = lines[line_no]
    if not line then
      return nil, line_no, error_at(path, line_no, "unterminated multiline literal string for " .. key)
    end
    close = line:find("'''", 1, true)
    content[#content + 1] = close and line:sub(1, close - 1) or line
  until close

  local trailing = lines[line_no]:sub(close + 3)
  if not trailing:match("^%s*$") and not trailing:match("^%s*#") then
    return nil, line_no, error_at(path, line_no, "unexpected text after " .. key)
  end
  return table.concat(content, "\n"), line_no
end

function M.default_path()
  local paths = vim.api.nvim_get_runtime_file("templates.toml", false)
  return paths[1]
end

function M.load(path)
  path = path or M.default_path()
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil, "Template catalog not found: " .. (path or "templates.toml")
  end

  local lines, data, current, sections = vim.fn.readfile(path), {}, nil, {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match("^%s*$") or line:match("^%s*#") then
      i = i + 1
    else
      local section = line:match("^%s*%[([%w_.%-]+)%]%s*$")
      if section then
        if sections[section] then
          return nil, error_at(path, i, "duplicate table: " .. section)
        end
        sections[section] = true
        current = data
        for part in section:gmatch("[^%.]+") do
          if current[part] ~= nil and type(current[part]) ~= "table" then
            return nil, error_at(path, i, "table conflicts with a string key: " .. part)
          end
          current[part] = current[part] or {}
          current = current[part]
        end
        i = i + 1
      else
        local key, rhs = line:match('^%s*"([^"]+)"%s*=%s*(.-)%s*$')
        if not current or not key then
          return nil, error_at(path, i, "expected a table header or quoted-key assignment")
        end
        if current[key] ~= nil then
          return nil, error_at(path, i, "duplicate key: " .. key)
        end

        local value
        if rhs == '""' or rhs == "''" then
          value = ""
        elseif rhs:sub(1, 3) == "'''" then
          local err
          value, i, err = multiline(lines, i, rhs, key, path)
          if err then
            return nil, err
          end
        else
          local quote = rhs:sub(1, 1)
          if (quote == '"' or quote == "'") and rhs:sub(-1) == quote then
            value = rhs:sub(2, -2)
          else
            return nil, error_at(path, i, "expected a quoted string or triple-single-quoted string")
          end
        end

        current[key] = value
        i = i + 1
      end
    end
  end

  if type(data.choices) ~= "table" or type(data.templates) ~= "table" then
    return nil, "Template catalog needs [choices.*] and [templates.*] tables"
  end
  for language, choices in pairs(data.choices) do
    if type(choices) ~= "table" or type(data.templates[language]) ~= "table" then
      return nil, ("Invalid template catalog %s: missing choices or templates for %s"):format(path, language)
    end
    for _, key in ipairs({ "vcs", "build", "package" }) do
      if type(choices[key]) ~= "string" or choices[key] == "" then
        return nil, ("Invalid template catalog %s: %s.%s must be a non-empty option list"):format(path, language, key)
      end
    end
    if
      vim.tbl_contains(vim.split(choices.build, ",", { plain = true, trimempty = true }), "cmake")
      and (type(choices.generator) ~= "string" or choices.generator == "")
    then
      return nil, ("Invalid template catalog %s: %s needs CMake generator choices"):format(path, language)
    end
  end
  data.shared = data.templates.shared
  return data
end

local function render(value, variables)
  local rendered = value:gsub("{{([%w_]+)}}", function(key)
    local replacement = variables[key]
    return replacement == nil and ("{{" .. key .. "}}") or tostring(replacement)
  end)
  local unresolved = rendered:match("{{[%w_]+}}")
  if unresolved then
    return nil, "Unresolved template variable: " .. unresolved
  end
  return rendered
end

local function safe_path(path)
  if
    path == ""
    or path:sub(-1) == "/"
    or path:match("^[/\\]")
    or path:match("^%a:")
    or path:find("\\", 1, true)
    or path:find("//", 1, true)
    or path:find(":", 1, true)
    or path:find("\0", 1, true)
  then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return true
end

function M.write_files(files, destination, variables, only_missing)
  variables = variables or {}
  local written, paths = {}, vim.tbl_keys(files)
  table.sort(paths)

  for _, relative in ipairs(paths) do
    local output, err = render(relative, variables)
    if not output then
      return nil, err
    end
    if not safe_path(output) then
      return nil, "Invalid template output path: " .. output
    end

    local path = vim.fs.joinpath(destination, output)
    local stat = vim.uv.fs_lstat(path)
    if only_missing and stat then
      if stat.type ~= "file" then
        return nil, "Cannot create " .. path .. ": path is not a regular file"
      end
    else
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local content, content_err = render(files[relative], variables)
      if not content then
        return nil, content_err
      end
      local lines = vim.split(content, "\n", { plain = true, trimempty = false })
      if vim.fn.writefile(lines, path, "b") ~= 0 then
        return nil, "Cannot write " .. path
      end
      written[#written + 1] = output
    end
  end

  return written
end

return M
