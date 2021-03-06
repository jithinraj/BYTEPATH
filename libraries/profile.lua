local clock = os.clock
local getinfo = debug.getinfo
local sethook = debug.sethook
local sort = table.sort
local format = string.format
local len = string.len
local rep = string.rep
local sub = string.sub
local concat = table.concat

local profile = {}

-- filter non-hooked functions
local _filter = nil
-- user-hooked functions
local _hooked = {}
-- function labels
local _labeled = {}
-- function definitions
local _defined = {}
-- time of last call
local _tcalled = {}
-- total execution time
local _telapsed = {}
-- number of calls
local _ncalls = {}
-- recursion counter
local _rcount = {}
-- list of internal profiler functions
local _internal = {}

local function _hooker(event)
  local info = getinfo(2, 'nfS')
  -- function address
  local f = info.func
  -- ignore if not hooked
  if _filter then
    if _filter == "hooked" then
      if not _hooked[f] then
        return
      end
    elseif _filter == "internal" then
      if not _internal[f] then
        return
      end
    elseif _filter ~= info.what then
      return
    end
  end
  -- ignore if explicitly unhooked
  if _hooked[f] == false then
    return
  end
  -- grab the function name and line definition
  if not _labeled[f] then
    _labeled[f] = info.name
    if not _defined[f] then
      _defined[f] = format("%s:%s", info.short_src, info.linedefined)
      _ncalls[f] = 0
      _rcount[f] = 0
      _telapsed[f] = 0
    end
  end
  -- count the number of calls and execution time
  if event == "call" then
    -- call time, ignoring recursion
    if not _tcalled[f] then
      _tcalled[f] = clock()
    end
    _rcount[f] = _rcount[f] + 1
    _ncalls[f] = _ncalls[f] + 1
  elseif event == "return" then
    -- elapsed time
    local rc = _rcount[f]
    if rc then
      -- last return, including recursion
      if rc == 1 and _tcalled[f] then
        local c = clock()
        local dt = c - _tcalled[f]
        _telapsed[f] = _telapsed[f] + dt
        _tcalled[f] = nil
      end
      if rc > 0 then
        _rcount[f] = rc - 1
      end
    end
  end
end

local _i, _i2 = 0, 0
local _f = {}
local function _iterator()
  if _i == _i2 then
    return
  end
  local f = _f[_i]
  _i = _i - 1
  local d = _defined[f]
  return _labeled[f] or d, _ncalls[f] or 0, _telapsed[f] or 0, d
end

local _fs, _fs2 = nil, nil
local function _comp(a, b)
  if _fs[a] == _fs[b] then
    return _fs2[a] < _fs2[b]
  end
  return _fs[a] < _fs[b] 
end

--- Sets a clock function to be used by the profiler.
-- @param f Clock function that returns a number
function profile.setclock(f)
  assert(type(f) == "function", "clock must be a function")
  clock = f
end

--- Starts collecting data.
function profile.start()
  sethook(_hooker, "cr")
end

--- Stops collecting data.
function profile.stop()
  sethook()
  local t1 = clock()
  for f, t2 in pairs(_tcalled) do
    local dt = t1 - t2
    _telapsed[f] = _telapsed[f] + dt
    _tcalled[f] = nil
  end
  for k in pairs(_rcount) do
    _rcount[k] = 0
  end
  collectgarbage('collect')
end

--- Resets all collected data.
function profile.reset()
  for k in pairs(_ncalls) do
    _ncalls[k] = 0
  end
  for f in pairs(_tcalled) do
    _tcalled[f] = nil
  end
  for k in pairs(_telapsed) do
    _telapsed[k] = 0
  end
  for k in pairs(_rcount) do
    _rcount[k] = 0
  end
  collectgarbage('collect')
end

-- Combines data generated by closures, should be called prior to queries
function profile.combine()
  local lookup = {}
  for f, d in pairs(_defined) do
    local id = (_labeled[f] or "?")..d
    local f2 = lookup[id]
    if f2 then
      _ncalls[f2] = _ncalls[f2] + (_ncalls[f] or 0)
      _telapsed[f2] = _telapsed[f2] + (_telapsed[f] or 0)
      _defined[f], _labeled[f] = nil, nil
      _ncalls[f], _telapsed[f] = nil, nil
    else
      lookup[id] = f
    end
  end
end

--- Collects data for a given function.
-- @param f Function
-- @param fn Function name or label
function profile.hook(f, fn)
  assert(type(f) == "function", "cannot hook a non-function")
  assert(fn == nil or type(fn) == "string", "function label must be a string")
  local info = getinfo(f, 'nS')
  _hooked[f] = true
  _labeled[f] = fn or info.name
  if not _defined[f] then
    _defined[f] = format("%s:%s", info.short_src, info.linedefined)
    _ncalls[f] = 0
    _rcount[f] = 0
    _telapsed[f] = 0
  end
  fn = info.name
  _filter = "hooked"
end

--- Ignores data for a given function.
-- @param f Function
function profile.unhook(f)
  assert(type(f) == "function", "cannot unhook a non-function")
  _hooked[f] = false
  _labeled[f] = nil
end

--- Collects data for functions of a given type.
-- @param what Type of functions to profile, could be "Lua", "C", "hooked" or "internal" (optional)
function profile.hookall(what)
  _filter = what
  if what == "internal" then
    for f in pairs(_internal) do
      profile.hook(f)
    end
  end
end

--- Iterates all functions that have been called since the profile was started.
-- @param s Type of sorting, could be by "call" or "time" (optional)
-- @param n Number of results (optional)
function profile.query(s, n)
  _fs, _fs2 = _ncalls, _telapsed
  if s == "time" then
    _fs, _fs2 = _fs2, _fs
  end
  for i = #_f, 1, -1 do
    _f[i] = nil
  end
  for f in pairs(_ncalls) do
    _f[#_f + 1] = f
  end
  sort(_f, _comp)
  _i = #_f
  _i2 = 0
  if n and _i > n then
    _i2 = _i - n
  end
  -- todo: check for nested queries
  return _iterator
end

local function expand(s, l2)
  s = tostring(s)
  local l1 = len(s)
  if l1 < l2 then
    s = s..rep(' ', l2-l1)
  elseif l1 > l2 then
    s = sub(s, l1-l2 + 1)
  end
  return s
end

local function pretty(t)
  local c = { 3, 32, 8, 24, 32 }
  for i = 1, #t do
    if type(t[i] == 'table') then
      for j = 1, 5 do
        t[i][j] = expand(t[i][j], c[j])
      end
      t[i] = concat(t[i], ' | ')
    end
  end
  local row = " +-----+----------------------------------+----------+--------------------------+----------------------------------+ \n"
  local col = " | #   | Function                         | Calls    | Time                     | Code                             | \n"
  local out = row..col..row
  if #t > 0 then
    out = out..' | '..concat(t, ' | \n | ')..' | \n'
  end
  out = out..row
  return out
end

function profile.report(s, n)
  local i = 0
  local out = {}
  for f, c, t, d in profile.query(s, n) do
    i = i + 1
    out[i] = { i, f, c, t, d }
  end
  return 'Profilling report:\n'..pretty(out)
end

-- store all internal profiler functions
for k, v in pairs(profile) do
  if type(v) == "function" then
    _internal[v] = true
  end
end
_internal[_iterator] = true
_internal[_comp] = true
_internal[sethook] = true
_internal[getinfo] = true
_internal[expand] = true
_internal[pretty] = true

-- don't remove unless you want to profile the profiler
for f in pairs(_internal) do
  profile.unhook(f)
end

return profile