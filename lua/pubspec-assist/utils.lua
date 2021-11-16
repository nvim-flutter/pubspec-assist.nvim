local M = {}

local api = vim.api

_G.__pubspec_assist_callbacks = {}

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
