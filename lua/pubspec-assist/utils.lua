local M = {}

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

return M
