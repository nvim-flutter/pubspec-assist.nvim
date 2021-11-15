local M = {}

local api = vim.api
local fn = vim.fn
local fmt = string.format

local NAMESPACE = api.nvim_create_namespace("pubspec_assist")
local BASE_URI = "https://pub.dartlang.org/api"
local PUBSPEC_FILE = "pubspec.yaml"
local PUBSPEC_VAR_NAME = "pubspec_versions"
local HL_PREFIX = "PubspecAssist"

---@class State
---@field OUTDATED number
---@field UP_TO_DATE number
---@field UNKNOWN number

---@type State
local state = {
  OUTDATED = 1,
  UP_TO_DATE = 2,
  UNKNOWN = 3,
}

local hls = {
  [state.OUTDATED] = HL_PREFIX .. "DependencyOutdated",
  [state.UP_TO_DATE] = HL_PREFIX .. "DependencyUpToDate",
  [state.UNKNOWN] = HL_PREFIX .. "DependencyUnknown",
}

local icons = {
  [state.OUTDATED] = "",
  [state.UP_TO_DATE] = "",
  [state.UNKNOWN] = "",
}

---@class PubspecAssistConfig

---@class Package
---@field current string
---@field latest string
---@field latest_published string
---@field versions table[]
---@field lnum number
---@field error table
---@field name string

local defaults = {
  highlights = {
    up_to_date = "Comment",
    outdated = "WarningMsg",
    unknown = "ErrorMsg",
  },
}

---Adopt user config and initialise the plugin.
---@param user_config PubspecAssistConfig
function M.setup(user_config)
  user_config = user_config or {}
  M.config = vim.tbl_deep_extend("force", defaults, user_config)
  vim.cmd(fmt("highlight link %s %s", hls[state.OUTDATED], M.config.highlights.outdated))
  vim.cmd(fmt("highlight link %s %s", hls[state.UP_TO_DATE], M.config.highlights.up_to_date))
  vim.cmd(fmt("highlight link %s %s", hls[state.UNKNOWN], M.config.highlights.unknown))
  vim.cmd(
    fmt(
      'autocmd! BufEnter,BufWritePost %s lua require("pubspec-assist").show_dependency_versions()',
      PUBSPEC_FILE
    )
  )
end

---@param package Package
---@return State
local function get_package_state(package)
  local current, latest = package.current, package.latest
  if (not current or type(current) ~= "string") or (not latest or type(latest) ~= "string") then
    return state.UNKNOWN
  end
  local v = require("semver")
  local latest_v, current_v = v(latest:gsub("%^", "")), v(current:gsub("%^", ""))
  return latest_v > current_v and state.OUTDATED or state.UP_TO_DATE
end

---Render the version text beside each line of the pubspec yaml
---@param buf_id number
---@param package Package
local function show_version(buf_id, package)
  if package and package.latest and package.lnum and not package.error then
    local p_state = get_package_state(package)
    local icon, hl = icons[p_state], hls[p_state]
    api.nvim_buf_set_extmark(buf_id, NAMESPACE, package.lnum - 1, -1, {
      virt_text = { { icon .. " " .. package.latest, hl } },
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

---Add a dependency to the buffer variable dependencies table
--- TODO: verify whether this causes race conditions as multiple async jobs
--- are updating this variable potentially simultaneously.
---@param buf number
---@param package Package
local function persist_package(buf, package)
  local ok, versions = pcall(api.nvim_buf_get_var, buf, PUBSPEC_VAR_NAME)
  versions = ok and versions or {}
  versions[package.name] = package
  versions.last_changed = api.nvim_buf_get_changedtick(buf)
  api.nvim_buf_set_var(buf, PUBSPEC_VAR_NAME, versions)
end

local function on_success(context, body)
  assert(context, "The context must be passed in")
  assert(body, "The response body must be passed in")
  local results = context.results
  local name = context.package_name
  local buf_id = context.buf_id
  local dependency = vim.fn.json_decode(table.concat(body, "\n"))
  if results[name] then
    results[name] = vim.tbl_extend("force", results[name], extract_dependency_info(dependency))
    persist_package(buf_id, results[name])
    show_version(buf_id, results[name])
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
          results[package_name].name = package_name
          results[package_name].current = dependencies[package_name]
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
  vim.schedule(function()
    local buf_id = api.nvim_get_current_buf()
    local last_changed = api.nvim_buf_get_changedtick(buf_id)
    local ok, cached_versions = pcall(api.nvim_buf_get_var, buf_id, PUBSPEC_VAR_NAME)
    if
      ok
      and last_changed
      and cached_versions
      and cached_versions.last_changed
      and cached_versions.last_changed >= last_changed
    then
      return
    end

    api.nvim_buf_clear_namespace(0, NAMESPACE, 0, -1)
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local filtered = vim.tbl_filter(function(line)
      return line ~= "" and not vim.startswith(line, "//")
    end, lines)
    local content = table.concat(filtered, "\n")
    local pubspec = require("lyaml").load(content)
    local dependencies = vim.tbl_extend(
      "keep",
      {},
      pubspec.dependencies or {},
      pubspec.dev_dependencies or {}
    )
    local jobs = {}
    local results = match_dependencies(dependencies, lines)
    for package, value in pairs(dependencies) do
      -- NOTE: ignore packages who's values are tables as these are usually SDK packages e.g.
      -- flutter_test: {
      --   sdk = "flutter"
      -- }
      if type(value) ~= "table" then
        local context = {
          buf_id = buf_id,
          results = results,
          package_name = package,
        }
        local err, success = wrap(on_err, context), wrap(on_success, context)
        local job_id = fetch(fmt("packages/%s", package), err, success)
        jobs[#jobs + 1] = job_id
      end
    end
  end)
end

return M
