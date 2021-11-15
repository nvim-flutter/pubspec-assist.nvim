local M = {}

local api = vim.api
local fn = vim.fn
local fmt = string.format

local NAMESPACE = api.nvim_create_namespace("pubspec_assist")
local BASE_URI = "https://pub.dartlang.org/api"
local PUBSPEC_FILE = "pubspec.yaml"

---@class PubspecAssistConfig

local defaults = {
  highlights = {
    dependency = "Comment",
  },
}

---Adopt user config and initialise the plugin.
---@param user_config PubspecAssistConfig
function M.setup(user_config)
  user_config = user_config or {}
  M.config = vim.tbl_deep_extend("force", defaults, user_config)
  vim.cmd("highlight link PubspecAssistDependency " .. M.config.highlights.dependency)
  vim.cmd(
    fmt(
      'autocmd! BufEnter %s lua require("pubspec-assist").show_dependency_versions()',
      PUBSPEC_FILE
    )
  )
end

local function show_version(package)
  if package and package.latest and package.lnum and not package.error then
    api.nvim_buf_set_extmark(0, NAMESPACE, package.lnum - 1, -1, {
      virt_text = { { package.latest, "PubspecAssistDependency" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end
end

---Fetch implementation
---@param path string
---@param on_err function(rsp: table)
---@param on_success function(rsp: table)
---@return Job
local function fetch(path, on_err, on_success)
  local content_type = '"Content-Type: application/json"'
  local command = fmt('curl -sS --compressed -X GET "%s/%s" -H %s', BASE_URI, path, content_type)
  return fn.jobstart(command, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, err, _)
      on_err(err)
    end,
    on_stdout = function(_, data, _)
      on_success(data)
    end,
  })
end

local function wrap(cb, ...)
  local args = { ... }
  return function(...)
    for i = 1, select("#", ...) do
      args[#args + 1] = select(i, ...)
    end
    return cb(unpack(args))
  end
end

local function extract_dependency_info(dependency)
  local data = {}
  if dependency.versions then
    data.versions = vim.tbl_map(function(version)
      return { version = version.version, published = version.published }
    end, dependency.versions)
  end
  if dependency.latest then
    data.latest = dependency.latest.version
    data.latest_published = dependency.latest.published
  end
  return data
end

local function on_success(results, name, body)
  assert(results, "The results must be passed in")
  assert(name, "The package name must be passed in")
  assert(body, "The response body must be passed in")
  local dependency = vim.fn.json_decode(table.concat(body, "\n"))
  if results[name] then
    results[name] = vim.tbl_extend("force", results[name], extract_dependency_info(dependency))
    show_version(results[name])
  end
end

local function on_err(results, name, err)
  if type(err) == "table" and err[1] ~= "" then
    results[name] = results[name] or {}
    results[name] = {
      error = err,
    }
    vim.notify(fmt("Error fetching package info for %s", name), vim.log.levels.ERROR, {
      title = "Pubspec Assist",
    })
  end
end

local function match_dependencies(dependencies, lines)
  local results = {}
  for lnum, line in ipairs(lines) do
    if line and line ~= "" then
      local key = line:match(".-:")
      if key then
        local package_name = vim.trim(key:gsub(":", ""))
        if dependencies[package_name] then
          results[package_name] = results[package_name] or {}
          results[package_name].lnum = lnum
        end
      end
    end
  end
  return results
end

-- First read the pubspec.yaml file into a lua table loop through this table and use plenary to cURL
-- pub.dev for the version of each dependency.
function M.show_dependency_versions()
  api.nvim_buf_clear_namespace(0, NAMESPACE, 0, -1)
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local filtered = vim.tbl_filter(function(line)
    return line ~= "" and not vim.startswith(line, "//")
  end, lines)
  local content = table.concat(filtered, "\n")
  local pubspec = require("yaml").eval(content)
  local jobs = {}
  local dependencies = vim.tbl_extend(
    "keep",
    {},
    pubspec.dependencies or {},
    pubspec.dev_dependencies or {}
  )
  local results = match_dependencies(dependencies, lines)
  for package, _ in pairs(dependencies) do
    local err, success = wrap(on_err, results, package), wrap(on_success, results, package)
    local job = fetch(fmt("packages/%s", package), err, success)
    jobs[#jobs + 1] = job
  end
end

return M
