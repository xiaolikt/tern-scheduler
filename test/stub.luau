-- Stubs that stand in for Tern while test/run.sh runs window.luau unchanged.
-- The runner concatenates this file, the plugin and test/scenarios.luau into
-- one script, so the plugin's code becomes the body of load_plugin() below and
-- every call of it starts from a freshly loaded plugin. What the stubs keep
-- true to tern.d.luau: tern.kv hands out and stores copies (a save is a JSON
-- round trip), tern.fs.read raises for a missing file, PaneInfo.cwd is an
-- absolute path and cx.agents:start answers with the new pane's id.
local real_os = os
local T0 = 1000000 -- seconds; the plugin works in os.time() * 1000
local W -- the world the global `tern` reads

local function deepcopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = deepcopy(val)
	end
	return out
end

-- One plugin's worth of surroundings: the files it can read, the decoded
-- tasks.json (its text is the key into `decoded`), the store and its clock.
-- `write_fails` makes the next store write raise.
local function new_world(opts)
	opts = opts or {}
	W = {
		now = opts.now or T0,
		shown = opts.shown or 1,
		files = opts.files or {},
		decoded = opts.decoded or {},
		kv = opts.kv or {},
		write_fails = false,
		timers = {},
		commands = {},
		logs = {},
	}
	if opts.tasks then
		W.files["/plugin/tasks.json"] = "TASKS"
		W.decoded["TASKS"] = opts.tasks
	end
	return W
end

tern = {
	plugin = { dir = "/plugin", data = "/data" },
	fs = {
		read = function(path)
			local text = W.files[path]
			if text == nil then
				error("cannot read " .. path .. ": no such file", 0)
			end
			return text
		end,
		exists = function(path)
			return W.files[path] ~= nil
		end,
		write = function() end,
	},
	json = { decode = function(text) return W.decoded[text] end },
	kv = {
		get = function(key)
			local value = W.kv[key]
			return value ~= nil and deepcopy(value) or nil
		end,
		set = function(key, value)
			if W.write_fails then
				W.write_fails = false
				error("kv store is read-only", 0)
			end
			W.kv[key] = value ~= nil and deepcopy(value) or nil
		end,
	},
	getenv = function(name)
		return name == "HOME" and "/home/x" or nil
	end,
	now = function() return W.now * 1000 end,
	timer = function(ms, fn)
		W.timers[#W.timers + 1] = { ms = ms, fn = fn }
	end,
	log = { warn = function(text) W.logs[#W.logs + 1] = tostring(text) end },
	command = function(def)
		W.commands[def.id] = def
	end,
}

-- Tern's VM reads an os.time table as local time, the Luau CLI as UTC. Shift a
-- CLI answer to what those fields mean locally, so the plugin sees the host's
-- behaviour in the tests too.
local function local_stamp(fields)
	local t = real_os.time(fields)
	for _ = 1, 3 do
		local d = real_os.date("*t", t)
		local want = real_os.time({
			year = fields.year,
			month = fields.month,
			day = fields.day,
			hour = fields.hour,
			min = fields.min,
			sec = fields.sec,
		})
		local got = real_os.time({
			year = d.year,
			month = d.month,
			day = d.day,
			hour = d.hour,
			min = d.min,
			sec = d.sec,
		})
		local delta = want - got
		if delta == 0 then
			break
		end
		t = t + delta
	end
	return t
end

os = {
	time = function(at)
		if type(at) == "table" then
			return local_stamp(at)
		end
		return W.now
	end,
	date = function(fmt, at) return real_os.date(fmt, at or real_os.time()) end,
	clock = real_os.clock,
}

-- A window: `panes` are its PaneInfos, `transcript[pane]` what
-- cx.agents:transcript answers for it, `on_ask` runs while a prompt is being
-- sent (another window's doing), `pick` the row cx:pick settles on.
local function make_cx(key, opts)
	opts = opts or {}
	local cx = { key = key, asks = {}, starts = {}, toasts = {}, picks = {}, reads = {} }
	local panes = opts.panes or {}
	local function find(id)
		if type(id) ~= "number" then
			return nil
		end
		for _, pane in ipairs(panes) do
			if pane.pane == id then
				return pane
			end
		end
		return nil
	end
	local session = {}
	function session:focused()
		return opts.focused
	end
	function session:pane(id)
		local pane = find(id)
		return pane and deepcopy(pane) or nil
	end
	function session:resolve(spec)
		spec = tostring(spec)
		for _, pane in ipairs(panes) do
			if tostring(pane.title) == spec or tostring(pane.pane) == spec then
				return pane.pane
			end
		end
		return nil
	end
	function session:sessions()
		return opts.sessions or {}
	end
	function session:tabs()
		return opts.tabs or {}
	end
	function session:panes()
		local out = {}
		for _, pane in ipairs(panes) do
			out[#out + 1] = deepcopy(pane)
		end
		return out
	end
	function session:find_session(name)
		for _, s in ipairs(opts.sessions or {}) do
			if s.name == name then
				return s.id
			end
		end
		return nil
	end
	function session:find_tab(name, id)
		for _, tab in ipairs(opts.tabs or {}) do
			if tab.session == id and tab.name == name then
				return tab.id
			end
		end
		return nil
	end
	cx.session = session
	cx.sessions = {
		current = function()
			return { id = W.shown, name = "current", tabs = 1 }
		end,
		create = function(_, spec)
			-- creating a session shows it, as Tern does
			W.shown = 2
			if opts.sessions then
				opts.sessions[#opts.sessions + 1] = { id = 2, name = spec.name, current = true, locked = false, tabs = { 20 } }
			end
			return { id = 2, name = spec.name, tabs = 1 }
		end,
		switch = function(_, id)
			W.shown = id
		end,
	}
	cx.layout = setmetatable({}, { __index = function()
		return function()
			return 1
		end
	end })
	local agents = {}
	function agents:list()
		local out = {}
		for _, block in ipairs(opts.agents or {}) do
			out[#out + 1] = deepcopy(block)
		end
		return out
	end
	function agents:get(pane)
		local found = find(pane)
		if found and found.kind == "agent" then
			return { pane = pane }
		end
		error("no agent at pane " .. tostring(pane))
	end
	function agents:start(spec)
		cx.starts[#cx.starts + 1] = spec
		return 9000 + #cx.starts
	end
	function agents:ask(pane, text)
		cx.asks[#cx.asks + 1] = { pane = pane, text = text }
		if opts.on_ask then
			opts.on_ask()
		end
	end
	function agents:transcript(pane, spec)
		cx.reads[#cx.reads + 1] = pane
		local chat = (opts.transcript or {})[pane] or {}
		local out = {}
		local first = math.max(1, #chat - (spec and spec.last or 50) + 1)
		for i = first, #chat do
			out[#out + 1] = { role = chat[i].role, text = chat[i].text, tools = {} }
		end
		return out
	end
	cx.agents = agents
	function cx:window_key()
		return key
	end
	function cx:toast(level, text, sub)
		self.toasts[#self.toasts + 1] = level .. ": " .. text .. (sub and (" / " .. tostring(sub)) or "")
	end
	function cx:pick(spec)
		local items = spec.items
		self.picks[#self.picks + 1] = items
		return {
			next = function(_, next)
				if opts.pick then
					next(items[opts.pick], nil, cx)
				else
					next(nil, nil, nil) -- dismissed
				end
			end,
		}
	end
	return cx
end

-- The plugin's code follows, so each call is a plugin loaded from scratch.
local function load_plugin()
