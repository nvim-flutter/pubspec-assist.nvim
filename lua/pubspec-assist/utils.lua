local M = {}

local api = vim.api

_G.__pubspec_assist_callbacks = {}

---This utility wraps a callback so it can be passed arguments from an outer scope.
---then later called with the initial arguments and those from the subsequent call.
---this is a 1 stage partial application.
---@param cb any
---@return function
function M.wrap(cb, ...)
  local args = { ... }
  return function(...)
    for i = 1, select("#", ...) do
      args[#args + 1] = select(i, ...)
    end
    return cb(unpack(args))
  end
end

---Add a function to the global callback map
---@param f function
---@return number
local function _create(f)
  table.insert(__pubspec_assist_callbacks, f)
  return #__pubspec_assist_callbacks
end

function M._execute(id, args)
  __pubspec_assist_callbacks[id](args)
end

---Create a mapping
---@param mode string
---@param lhs string
---@param rhs string | function
---@param opts table
function M.map(mode, lhs, rhs, opts)
  -- add functions to a global table keyed by their index
  if type(rhs) == "function" then
    local fn_id = _create(rhs)
    rhs = string.format("<cmd>lua require('pubspec-assist.utils')._execute(%s)<CR>", fn_id)
  end
  local buffer = opts.buffer
  opts.silent = opts.silent ~= nil and opts.silent or true
  opts.noremap = opts.noremap ~= nil and opts.noremap or true
  opts.buffer = nil
  if buffer and type(buffer) == "number" then
    api.nvim_buf_set_keymap(buffer, mode, lhs, rhs, opts)
  else
    api.nvim_set_keymap(mode, lhs, rhs, opts)
  end
end

return M
