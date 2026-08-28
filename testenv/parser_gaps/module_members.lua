local M = {}

function M.open(path)
  return path
end

function M:close()
  return self.handle
end

M.assigned = function(value)
  return value
end

return M
