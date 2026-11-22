-- Make workflow, and a compilation database derived from the commands `make -nB` prints.
local M = {}
local process = require("projman.process")
local project = require("projman.project")
local template = require("projman.template")

local COMPILERS = { "gcc", "g++", "cc", "c++", "clang", "clang++", "clang-cl", "nvcc" }
local SOURCES = { "c", "cc", "cpp", "cxx", "c++", "m", "mm", "cu" }
local OPERATORS = { "&&", "||", ";", "|", "&", ">" }
-- Options whose next word is their value, not a source file.
local TAKES_VALUE = {
  "-o",
  "-I",
  "-isystem",
  "-iquote",
  "-idirafter",
  "-isysroot",
  "--sysroot",
  "-include",
  "-include-pch",
  "-imacros",
  "-MF",
  "-MT",
  "-MQ",
  "-D",
  "-U",
  "-x",
  "-Xclang",
  "-Xlinker",
  "-Xassembler",
  "-Xpreprocessor",
}

-- Split a shell command line into words, honouring quotes and backslashes. Nil when a quote is left open.
local function split(line)
  local words, word, quote, started, i = {}, {}, nil, false, 1
  while i <= #line do
    local char = line:sub(i, i)
    if quote then
      if char == quote then
        quote = nil
      elseif char == "\\" and quote == '"' and line:sub(i + 1, i + 1):find('["\\$`]') then
        i = i + 1
        word[#word + 1] = line:sub(i, i)
      else
        word[#word + 1] = char
      end
    elseif char == "'" or char == '"' then
      quote, started = char, true
    elseif char == "\\" and i < #line then
      i = i + 1
      word[#word + 1], started = line:sub(i, i), true
    elseif char:find("%s") then
      if started then
        words[#words + 1], word, started = table.concat(word), {}, false
      end
    else
      word[#word + 1], started = char, true
    end
    i = i + 1
  end
  if quote then
    return nil
  end
  if started then
    words[#words + 1] = table.concat(word)
  end
  return words
end

-- The compiler invocation in `words`: from the first compiler word up to the first shell operator.
local function compile_command(words)
  for first, word in ipairs(words) do
    local name = (word:match("[^/\\]+$") or ""):lower():gsub("%.exe$", ""):gsub("%-%d+$", "")
    if vim.list_contains(COMPILERS, name) then
      local command = {}
      for index = first, #words do
        if vim.list_contains(OPERATORS, words[index]) then
          break
        end
        command[#command + 1] = words[index]
      end
      local path = vim.fn.exepath(command[1])
      command[1] = path ~= "" and path or command[1]
      return command
    end
  end
end

-- The source files named by a compiler command.
local function sources(command)
  local files, skip = {}, false
  for index = 2, #command do
    local word = command[index]
    local extension = (word:match("%.([^./\\]+)$") or ""):lower()
    if skip then
      skip = false
    elseif vim.list_contains(TAKES_VALUE, word) then
      skip = true
    elseif word:sub(1, 1) ~= "-" and vim.list_contains(SOURCES, extension) then
      files[#files + 1] = word
    end
  end
  return files
end

-- compile_commands.json entries for the compiler commands in the output of `make -nB`.
local function entries(output, root)
  local result, seen, dirs = {}, {}, { root }
  for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
    local entering = line:match("Entering directory [`'](.+)'%s*$")
    if entering then
      dirs[#dirs + 1] = process.resolve(dirs[#dirs], entering)
    elseif line:find("Leaving directory [`'].+'%s*$") then
      if #dirs > 1 then
        dirs[#dirs] = nil
      end
    else
      local dir = dirs[#dirs]
      local words = split((line:gsub("^%s*[@+-]+", "")))
      while words and words[1] == "cd" and words[2] and words[3] == "&&" do
        dir = process.resolve(dir, words[2])
        words = vim.list_slice(words, 4)
      end

      local command = words and compile_command(words)
      if command then
        for _, source in ipairs(sources(command) or {}) do
          local file = process.resolve(dir, source)
          local signature = table.concat({ dir, file, table.concat(command, "\0") }, "\0")
          if not seen[signature] then
            seen[signature] = true
            result[#result + 1] = { directory = dir, file = file, arguments = command }
          end
        end
      end
    end
  end
  return result
end

local function executable(config)
  return config.make.executable ~= "" and config.make.executable or "make"
end

function M.build(ctx, profile, config)
  process.job(ctx.root, { executable(config), "BUILD=" .. profile }, { title = "make " .. profile })
end

function M.run(ctx, profile, config)
  local target = config.make.run_target ~= "" and config.make.run_target or "run"
  process.launch({ executable(config), "BUILD=" .. profile, target }, ctx.root)
end

function M.refresh(ctx, profile, config)
  process.job(ctx.root, { executable(config), "-nB", "BUILD=" .. profile }, {
    title = "Make compilation database (" .. profile .. ")",
    limit = math.huge, -- a truncated listing would silently produce an incomplete database
    on_ok = function(output)
      local result = entries(output, ctx.root)
      if #result == 0 then
        return vim.notify("`make -nB` listed no compiler commands", vim.log.levels.WARN)
      end
      -- A Makefile can belong to any language; compiler commands show that this is a C-family project.
      template.restore(ctx.root, config.catalog, "c_family")

      -- Write beside the target and rename, so clangd never reads a half-written file.
      local path = vim.fs.joinpath(ctx.root, "compile_commands.json")
      local temporary = path .. ".tmp." .. vim.uv.os_getpid()
      if vim.fn.writefile({ vim.json.encode(result) }, temporary) ~= 0 then
        vim.fn.delete(temporary)
        return vim.notify("Cannot write " .. temporary, vim.log.levels.ERROR)
      end
      local ok, err = vim.uv.fs_rename(temporary, path)
      if not ok then
        vim.fn.delete(temporary)
        return vim.notify("Cannot replace " .. path .. ": " .. err, vim.log.levels.ERROR)
      end
      vim.notify(("Wrote %d entries to %s"):format(#result, path))
    end,
  })
end

-- Whether the Makefile enables both AddressSanitizer and UBSan, as the `sanitize` profile needs.
function M.sanitizer(root)
  for _, name in ipairs({ "GNUmakefile", "makefile", "Makefile" }) do
    if project.has(root, name) then
      return project.grep(root, name, "%-fsanitize=address,undefined")
    end
  end
  return false
end

return M
