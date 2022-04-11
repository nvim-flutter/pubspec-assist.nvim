local M = {}

local api = vim.api
local fn = vim.fn
local fmt = string.format
local notify = vim.notify
local async = require("plenary.async")
local curl = require("plenary.curl")

local L = vim.log.levels

local AUGROUP = api.nvim_create_augroup("PubspecAssist", { clear = true })
local NAMESPACE = api.nvim_create_namespace("pubspec_assist")
local BASE_URI = "https://pub.dartlang.org/api"
local PUBSPEC_FILE = "pubspec.yaml"
local HL_PREFIX = "PubspecAssist"
local PLUGIN_TITLE = "Pubspec Assist"
local DEV_DEPENDENCY_PATTERN = "dev_dependencies:"
local DEPENDENCY_PATTERN = "dependencies:"

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

local dep_type = {
  DEV = 1,
  DEPENDENCY = 2,
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
---@field type number

---@table<number, table<number, Package>>
local packages = {}

local defaults = {
  highlights = {
    up_to_date = "Comment",
    outdated = "WarningMsg",
    unknown = "ErrorMsg",
  },
}

local function to_version(str)
  local parts = vim.tbl_map(tonumber, vim.split(str:gsub("%^", ""), ".", { plain = true }))
  return { parts[1], parts[2], parts[3] or 0 }
end

local function is_greater(version_1, version_2)
  if version_1[1] > version_2[1] then
    return true
  elseif version_1[1] < version_2[1] then
    return false
  end

  if version_1[2] > version_2[2] then
    return true
  elseif version_1[2] < version_2[2] then
    return false
  end

  if version_1[3] > version_2[3] then
    return true
  elseif version_1[3] < version_2[3] then
    return false
  end
end

---@param package Package
---@return State
local function get_package_state(package)
  local current, latest = package.current, package.latest
  if (not current or type(current) ~= "string") or (not latest or type(latest) ~= "string") then
    return state.UNKNOWN
  end
  local latest_v, current_v = to_version(latest), to_version(current)
  return is_greater(latest_v, current_v) and state.OUTDATED or state.UP_TO_DATE
end

---Render the version text beside each line of the pubspec yaml
---@param buf_id number
---@param package Package
local function add_version(buf_id, package)
  if package and package.latest and package.lnum and not package.error then
    local p_state = get_package_state(package)
    package.ui = { icon = icons[p_state], hl = hls[p_state] }
    packages[buf_id] = packages[buf_id] or {}
    packages[buf_id][package.lnum] = package
  end
end

local set_line_version = function(buf_id, package, line)
  if not package then
    return
  end
  api.nvim_buf_set_extmark(buf_id, NAMESPACE, line - 1, -1, {
    virt_text = { { package.ui.icon .. " " .. package.latest, package.ui.hl } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    ephemeral = true,
  })
end

---Fetch implementation
---@param path string
---@param on_err function(rsp: table)
---@param on_success function(rsp: table)
---@return Job
local function fetch(path, on_err, on_success)
  curl.get(fmt("%s/%s", BASE_URI, path), {
    compressed = true,
    accept = "application/json",
    callback = function(result)
      if result.status ~= 200 then
        return on_err(result.body)
      end
      vim.schedule(function()
        local data = vim.json.decode(result.body)
        if not data then
          return notify("No data returned for " .. path, L.ERROR, { title = PLUGIN_TITLE })
        end
        on_success(data)
      end)
    end,
  })
end

---@param dependency table<string, any>
---@return Package
local function extract_dependency_info(dependency)
  local data = { name = dependency.name }
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

---Add the line number for each package to the Package object
---@param lines string[]
---@return table<string, number>
local function get_lnum_lookup(lines)
  local lookup = {}
  for lnum, line in ipairs(lines) do
    if line and line ~= "" then
      local key = line:match(".-:")
      if key then
        local package_name = vim.trim(key:gsub(":", ""))
        lookup[package_name] = lnum
      end
    end
  end
  return lookup
end

---@type table<number, table<string, Package>>
local versions = {}

---Add a dependency to the buffer variable dependencies table
--- TODO: verify whether this causes race conditions as multiple async jobs
--- are updating this variable potentially simultaneously.
---@param buf number
---@param package Package
local function persist_package(buf, package)
  versions[buf] = versions[buf] or {}
  versions[buf][package.name] = package
  versions[buf].last_changed = api.nvim_buf_get_changedtick(buf)
end

local function on_package_fetch_success(context, data)
  assert(context, "The context must be passed in")
  assert(data, "The response body must be passed in")
  local results = context.results
  local name = context.package_name
  local buf_id = context.buf_id
  if results[name] then
    results[name] = vim.tbl_extend("force", results[name], extract_dependency_info(data))
    persist_package(buf_id, results[name])
    add_version(buf_id, results[name])
  end
end

local function on_package_fetch_err(results, name, err)
  if type(err) == "table" and err[1] ~= "" then
    results[name] = results[name] or {}
    results[name] = { error = err }
    notify(fmt("Error fetching package info for %s", name), L.ERROR, { title = PLUGIN_TITLE })
  end
end

---Recursively search for the pubspec.yaml file by walking up the directory tree.
---@return string|nil
local function find_dependency_file()
  local Path = require("plenary.path")
  local limit = 0
  local path = Path.new(fn.expand("%:p:h"))
  local filepath = path:joinpath(PUBSPEC_FILE)
  while not filepath:exists() and limit < 5 do
    limit = limit + 1
    path = path:parent()
    filepath = path:joinpath(PUBSPEC_FILE)
  end
  if filepath:exists() then
    return filepath:absolute()
  end
end

local function get_block_end(dependency_type)
  local pattern = (not dependency_type or dependency_type == dep_type.DEPENDENCY)
      and DEPENDENCY_PATTERN
    or DEV_DEPENDENCY_PATTERN
  local pos = fn.searchpos(pattern, "n")
  local lnum = pos[1]
  local indent = fn.indent(lnum + 1)
  local next_indent = indent
  local curr_line = lnum + 1
  local line_count = api.nvim_buf_line_count(0)
  while next_indent > 0 and curr_line <= line_count do
    next_indent = fn.indent(curr_line + 1)
    curr_line = curr_line + 1
  end
  return curr_line - 1, indent
end

---Insert the package information into the buffer after finding the correct section for it
---@param package Package
---@param dependency_type number?
local function insert_package(package, dependency_type)
  local lnum, indent = get_block_end(dependency_type)
  local indent_str = string.rep(" ", indent)
  local dep = fmt("%s%s: ^%s", indent_str, package.name, package.latest)
  api.nvim_buf_set_lines(0, lnum, lnum, false, { dep })
  api.nvim_win_set_cursor(0, { lnum, indent + 1 })
end

---Parse a yaml string to lua table (object)
---@param str string
---@return table?
local function parse_yaml(str)
  local ok, yaml = pcall(require("lyaml").load, str)
  if not ok then
    return nil
  end
  return yaml
end

local function open_version_picker()
  local line = fn.getline(".")
  local lnum = unpack(api.nvim_win_get_cursor(0))
  local package = parse_yaml(line)
  if not package then
    return
  end
  local package_name = vim.tbl_keys(package)[1]
  local data = versions[api.nvim_get_current_buf()]
  if not data or not data[package_name] then
    return
  end
  local pkg_versions = data[package_name].versions
  local buf = api.nvim_create_buf(false, true)
  local lines = vim.tbl_map(function(item)
    return item.version
  end, pkg_versions)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local title = package_name .. " versions:"
  vim.ui.select(lines, { prompt = title }, function(choice)
    if choice then
      local separator = string.find(line, ":")
      api.nvim_buf_set_text(0, lnum - 1, separator, lnum - 1, #line, { " ^" .. choice })
    end
  end)
end

-- Create floating window to collect user input
function M.add_package()
  vim.ui.input({ prompt = "Enter dependency name(s)" }, function(input)
    if input and input ~= "" then
      fetch(fmt("packages/%s", input), function(err)
        vim.notify(err, "error", { title = "Pubspec assist" })
      end, function(data)
        local path = find_dependency_file()
        if path then
          vim.cmd(fmt("edit %s", path))
          insert_package(extract_dependency_info(data))
        end
      end)
    end
  end)
end

---Add the type of a dependency to the Package object
---@param list table<string, string|table>
---@param dependency_type number
---@param lnum_map table<string, number>
---@return Package[]
local function create_packages(list, dependency_type, lnum_map)
  local result = {}
  if not list then
    return {}
  end
  for name, version in pairs(list) do
    if type(version) ~= "table" then
      local lnum = lnum_map[name]
      result[name] = { type = dependency_type, current = version, name = name, lnum = lnum }
    end
  end
  return result
end

-- First read the pubspec.yaml file into a lua table loop through this table and use plenary to cURL
-- pub.dev for the version of each dependency.
local show_dependency_versions = async.void(function()
  -- TODO: make this whole function asynchronous using plenary's async library
  local wrap = require("pubspec-assist.utils").wrap
  local buf_id = api.nvim_get_current_buf()
  local last_changed = api.nvim_buf_get_changedtick(buf_id)
  local cached_versions = versions[buf_id]
  if
    last_changed
    and cached_versions
    and cached_versions.last_changed
    and cached_versions.last_changed >= last_changed
  then
    return
  end

  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local filtered = vim.tbl_filter(function(line)
    return line ~= "" and not vim.startswith(line, "//")
  end, lines)
  local content = table.concat(filtered, "\n")
  local pubspec = parse_yaml(content)
  if not pubspec then
    return
  end
  local lnum_map = get_lnum_lookup(lines)
  local dependencies = vim.tbl_extend(
    "keep",
    {},
    create_packages(pubspec.dependencies, dep_type.DEV, lnum_map) or {},
    create_packages(pubspec.dev_dependencies, dep_type.DEPENDENCY, lnum_map) or {}
  )
  for package, _ in pairs(dependencies) do
    -- NOTE: ignore packages who's values are tables as these are usually SDK packages e.g.
    -- flutter_test: { sdk = "flutter" }
    local context = {
      buf_id = buf_id,
      results = dependencies,
      package_name = package,
    }
    fetch(
      fmt("packages/%s", package),
      wrap(on_package_fetch_err, context),
      wrap(on_package_fetch_success, context)
    )
  end
end)

local function dependencies_installed()
  local ok = pcall(require, "lyaml")
  if not ok then
    notify("Please ensure lyaml is installed see the README for more information", L.ERROR, {
      title = PLUGIN_TITLE,
    })
    return false
  end
  return true
end

---@param bufnr number
---@return boolean
local is_dep_file = function(bufnr)
  return vim.endswith(api.nvim_buf_get_name(bufnr), PUBSPEC_FILE)
end

---Adopt user config and initialise the plugin.
---@param user_config PubspecAssistConfig
function M.setup(user_config)
  user_config = user_config or {}
  if not dependencies_installed() then
    return
  end
  M.config = vim.tbl_deep_extend("force", defaults, user_config)
  api.nvim_set_hl(0, hls[state.OUTDATED], { link = M.config.highlights.outdated })
  api.nvim_set_hl(0, hls[state.UP_TO_DATE], { link = M.config.highlights.up_to_date })
  api.nvim_set_hl(0, hls[state.UNKNOWN], { link = M.config.highlights.unknown })

  api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = AUGROUP,
    pattern = PUBSPEC_FILE,
    callback = show_dependency_versions,
  })

  api.nvim_create_autocmd({ "BufEnter" }, {
    group = AUGROUP,
    pattern = PUBSPEC_FILE,
    callback = function()
      -- FIXME: make this command buffer local
      api.nvim_create_user_command("PubspecAssistPickVersion", open_version_picker, {})
    end,
  })

  api.nvim_create_user_command("PubspecAssistSearch", M.add_package, {})

  api.nvim_set_decoration_provider(NAMESPACE, {
    on_win = function(_, _, bufnr, topline, botline)
      if packages[bufnr] and is_dep_file(bufnr) then
        for index = topline, botline, 1 do
          local lnum = index - 1
          local package = packages[bufnr][lnum]
          set_line_version(bufnr, package, lnum)
        end
      end
    end,
  })
end

return M
