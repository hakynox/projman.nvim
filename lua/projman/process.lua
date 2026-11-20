-- Run external commands: one at a time per directory, in the background or in a terminal split.
local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
local busy = {}

local function lock(dir)
  if busy[dir] then
    vim.notify("Already running in " .. dir, WARN)
    return false
  end
  busy[dir] = true
  return true
end

-- Absolute, normalized form of `path`, relative paths being taken from `dir`.
function M.resolve(dir, path)
  if not (path:find("^[/\\]") or path:find("^%a:[/\\]")) then
    path = vim.fs.joinpath(dir, path)
  end
  return vim.fs.normalize(path)
end

-- Run `argv` in `root` without blocking. Output is kept up to `opts.limit` bytes (its tail); a failure sends it
-- to the quickfix list. `opts`: title, efm, limit, on_ok(output), on_error().
function M.job(root, argv, opts)
  opts = opts or {}
  if not lock(root) then
    return
  end

  local title, limit = opts.title or argv[1], opts.limit or (256 * 1024)
  local chunks, first, last, size = {}, 1, 0, 0
  local function collect(_, data)
    if not data then
      return
    end
    last = last + 1
    chunks[last], size = data, size + #data
    while size - #chunks[first] >= limit do -- drop whole old chunks, always keeping at least `limit` bytes
      size = size - #chunks[first]
      chunks[first] = nil
      first = first + 1
    end
  end

  local ok, process = pcall(
    vim.system,
    argv,
    { cwd = root, text = true, stdout = collect, stderr = collect },
    function(result)
      vim.schedule(function()
        busy[root] = nil
        local output = table.concat(chunks, "", first, last)
        if result.code == 0 then
          vim.notify(title .. ": done")
          if opts.on_ok then
            opts.on_ok(output)
          end
          return
        end

        if opts.on_error then
          opts.on_error()
        end
        local lines = vim.split(output, "\n", { trimempty = true })
        if #lines > 0 then
          vim.fn.setqflist({}, " ", { title = title, lines = lines, efm = opts.efm })
          vim.cmd("botright copen 12")
        end
        vim.notify(("%s: failed (exit %d)"):format(title, result.code), ERROR)
      end)
    end
  )

  if not ok then
    busy[root] = nil
    vim.notify(("Cannot run %s: %s"):format(argv[1], (tostring(process):gsub("^.-:%d+: ", ""))), ERROR)
    return
  end
  vim.notify(title .. "…")
  return process
end

-- Neovim 0.11 replaced termopen() with jobstart({ term = true }).
local function terminal(argv, opts)
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    return vim.fn.jobstart(argv, opts)
  end
  ---@diagnostic disable-next-line: deprecated
  return vim.fn.termopen(argv, opts)
end

-- Run `argv` in a terminal split at the bottom. `cwd` is locked until the command exits, then `on_exit()` runs.
function M.launch(argv, cwd, on_exit)
  if not lock(cwd) then
    return
  end

  vim.cmd("botright 15new")
  local ok, job = pcall(terminal, argv, {
    cwd = cwd,
    on_exit = function()
      vim.schedule(function()
        busy[cwd] = nil
        if on_exit then
          on_exit()
        end
      end)
    end,
  })
  if not ok or job <= 0 then
    busy[cwd] = nil
    vim.cmd("bwipeout")
    vim.notify("Cannot start " .. argv[1], ERROR)
    return
  end
  vim.cmd("startinsert")
  return job
end

-- Start `argv` independently of Neovim (editors, mostly).
function M.detached(argv, cwd)
  local job = vim.fn.jobstart(argv, { cwd = cwd, detach = true })
  if job <= 0 then
    vim.notify("Cannot start " .. argv[1], ERROR)
    return
  end
  return job
end

return M
