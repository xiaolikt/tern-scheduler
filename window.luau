-- Prompt Scheduler, window half: keeps each task's next run in tern.kv and
-- delivers its prompt into one fixed agent block per task.
local TICK_MS = 30 * 1000
local MIN_INTERVAL_MS = 30 * 1000
local BUSY_RETRY_MS = 5 * 60 * 1000
local DAY_MS = 24 * 3600 * 1000
local HISTORY = 10
local OWNER_STALE_MS = 3 * 60 * 1000
local HEARTBEAT_MS = 60 * 1000
local FP_WINDOW = 1000
local SCAN_MS = 120
local SCAN_PROBES = 6
local SCAN_TTL_MS = 10 * 60 * 1000
local UNITS = { s = 1000, m = 60 * 1000, h = 3600 * 1000, d = DAY_MS }
local warned = {}
local scans = {}

local function warn_once(key, text)
	if warned[key] then
		return false
	end
	warned[key] = true
	tern.log.warn("scheduler: " .. text)
	return true
end

-- Re-arms a warning once its condition is gone, so a configuration that is
-- fixed and broken again is reported again.
local function warn_ok(key)
	warned[key] = nil
end

local function now_ms()
	return os.time() * 1000
end

-- Two documents: `state` holds the owner and each task's schedule and history,
-- `pins` the block each task was given. They are written separately, so a run
-- can never revert a pin made while it was sending.
local function state()
	return tern.kv.get("state") or {}
end

local function pins()
	return tern.kv.get("pins") or {}
end

local function save_state(s)
	tern.kv.set("state", s)
end

local function save_pins(p)
	tern.kv.set("pins", p)
end

local function task_state(s, id)
	s.tasks = s.tasks or {}
	if s.tasks[id] == nil then
		s.tasks[id] = {}
	end
	return s.tasks[id]
end

local function write_state(fn)
	local s = state()
	fn(s)
	save_state(s)
end

-- Changes one task in the freshest document: a run or a command touches only
-- its own task, never another window's edits to the rest.
local function write_task(id, fn)
	write_state(function(s)
		fn(task_state(s, id))
	end)
end

-- Returns the task list, or nil plus a reason when the configuration cannot be
-- read. The caller surfaces the reason instead of silently doing nothing.
local function tasks()
	local ok, raw = pcall(tern.fs.read, tern.plugin.dir .. "/tasks.json")
	if not ok then
		return nil, "cannot read tasks.json: " .. tostring(raw)
	end
	local ok_json, parsed = pcall(tern.json.decode, raw)
	if not ok_json or type(parsed) ~= "table" then
		return nil, "tasks.json is not a JSON array"
	end
	return parsed
end

-- Ids that appear more than once in the task list. Every entry with such an
-- id is skipped: two entries would share one task state and reset each
-- other's slot on every tick, so neither would ever run.
local function duplicate_ids(list)
	local seen, dup = {}, {}
	for _, task in ipairs(list) do
		if type(task) == "table" and type(task.id) == "string" then
			if seen[task.id] then
				dup[task.id] = true
			end
			seen[task.id] = true
		end
	end
	return dup
end

local function test_mode()
	return tern.fs.exists(tern.plugin.dir .. "/test-once")
end

-- A task's interval and, when it has a daily `at`, its local hour and minute;
-- nil plus the reason when the task cannot be scheduled.
local function schedule_of(task)
	if test_mode() then
		return 60 * 1000
	end
	local n, unit = tostring(task.every or ""):match("^(%d+)([smhd])$")
	local interval = n and tonumber(n) * UNITS[unit]
	if not interval or interval < MIN_INTERVAL_MS then
		return nil, nil, "bad every " .. tostring(task.every)
	end
	if task.at == nil then
		return interval
	end
	local h, m = tostring(task.at):match("^(%d%d?):(%d%d)$")
	h, m = h and tonumber(h), m and tonumber(m)
	if not h or h > 23 or m > 59 then
		return nil, nil, "bad at " .. tostring(task.at)
	end
	if interval ~= DAY_MS then
		return nil, nil, "at needs every: 1d"
	end
	return interval, { h = h, m = m }
end

-- The next slot: the local time `at` names when the task has one, else one
-- interval from now. A task's first slot is due at once (or at the next `at`).
local function arm_next(at, interval, now, first)
	if not at then
		return first and now or now + interval
	end
	local d = os.date("*t", math.floor(now / 1000))
	local today = os.time({ year = d.year, month = d.month, day = d.day, hour = at.h, min = at.m, sec = 0 })
	if today and today * 1000 > now then
		return today * 1000
	end
	local tomorrow = os.time({ year = d.year, month = d.month, day = d.day + 1, hour = at.h, min = at.m, sec = 0 })
	if tomorrow then
		return tomorrow * 1000
	end
	return first and now or now + interval
end

local function prompt_text(task)
	local name = tostring(task.prompt or "")
	if test_mode() then
		name = string.gsub(name, "%.md$", ".test.md")
	end
	return tern.fs.read(tern.plugin.dir .. "/" .. name)
end

-- Every agent block's state by pane id; empty when the list is unavailable.
local function agent_states(cx)
	local states = {}
	local ok, list = pcall(cx.agents.list, cx.agents)
	if ok and type(list) == "table" then
		for _, block in ipairs(list) do
			if block.pane then
				states[block.pane] = block.state
			end
		end
	end
	return states
end

local function usable(cx, pane, states)
	if type(pane) ~= "number" then
		return false
	end
	local info = cx.session:pane(pane)
	if info == nil or info.kind ~= "agent" then
		return false
	end
	-- An agent that exited cannot take a prompt; open a fresh block instead.
	return not (states and states[pane] == "exited")
end

local function hash_head(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- Conversation fingerprint: message count plus a hash of the first message.
-- Conversations only grow, so the count may rise and the head must stay put.
-- A block that switched to a different conversation shrinks or changes head,
-- and the task reopens its own block instead of prompting a stranger's chat.
local function fingerprint(cx, pane)
	local ok, list = pcall(cx.agents.transcript, cx.agents, pane, { last = FP_WINDOW })
	if not ok or type(list) ~= "table" then
		return nil
	end
	local first = list[1]
	return { n = #list, head = hash_head(first and first.text or "") }
end

-- An empty transcript, a fingerprint without a head, or a transcript longer
-- than the window (whose first message is no longer visible) is "unknown", not
-- "a different conversation": never reopen because of one.
local function fp_matches(fp, now_fp)
	if fp == nil or fp.n == 0 or fp.head == nil or now_fp == nil or now_fp.n == 0 then
		return true
	end
	if now_fp.n >= FP_WINDOW then
		return true
	end
	return now_fp.n >= fp.n and now_fp.head == fp.head
end

-- Agent panes inside task.place's session (and tab, when named). The title
-- fallback only ever considers these, so a same-named pane elsewhere can no
-- longer receive the prompt.
local function scoped_panes(cx, task)
	local place = type(task.place) == "table" and task.place or nil
	if not place or not place.session then
		return nil
	end
	local session = cx.session:find_session(tostring(place.session))
	if not session then
		return {}
	end
	local tabs = {}
	for _, tab in ipairs(cx.session:tabs()) do
		if tab.session == session and (not place.tab or tab.name == tostring(place.tab)) then
			tabs[tab.id] = true
		end
	end
	local panes = {}
	for _, info in ipairs(cx.session:panes()) do
		if tabs[info.tab] and info.kind == "agent" then
			panes[#panes + 1] = info
		end
	end
	return panes
end

-- task.cwd spelled the way PaneInfo.cwd spells it: Tern expands a leading
-- "~" when it opens a block, so the comparison has to as well.
local function expanded_cwd(path)
	local home = tern.getenv("HOME")
	if home and (path == "~" or path:sub(1, 2) == "~/") then
		return home .. path:sub(2)
	end
	return path
end

-- Finds the task's block among the panes of its place. Comparing fingerprints
-- means reading a block's chat, and the first read of a chat can be slow, so a
-- scan looks at only a few blocks per callback and remembers the rest for the
-- next tick. Returns a pane, or nil plus true while blocks remain to look at.
local function scoped_target(cx, task, pin, states, scoped)
	local cwd = task.cwd and expanded_cwd(tostring(task.cwd))
	local matching, others = {}, {}
	for _, info in ipairs(scoped) do
		if usable(cx, info.pane, states) then
			if cwd ~= nil and info.cwd == cwd then
				matching[#matching + 1] = info.pane
			else
				others[#others + 1] = info.pane
			end
		end
	end
	local candidates = {}
	for _, pane in ipairs(matching) do
		candidates[#candidates + 1] = pane
	end
	for _, pane in ipairs(others) do
		candidates[#candidates + 1] = pane
	end
	if #candidates == 0 then
		return nil
	end
	if not (pin and pin.fp) then
		-- No fingerprint to compare: any agent in the place will do.
		return candidates[1]
	end
	local clock = tern.now()
	local scan = scans[task.id]
	if scan == nil or clock - scan.at > SCAN_TTL_MS then
		scan = { tried = {}, at = clock }
		scans[task.id] = scan
	end
	local deadline = clock + SCAN_MS
	local probes, pending = 0, false
	for _, pane in ipairs(candidates) do
		if not scan.tried[pane] then
			if probes >= SCAN_PROBES or tern.now() > deadline then
				pending = true
				break
			end
			probes = probes + 1
			local fp = fingerprint(cx, pane)
			scan.tried[pane] = true
			if fp and fp_matches(pin.fp, fp) then
				scans[task.id] = nil
				return pane
			end
		end
	end
	if pending then
		return nil, true
	end
	scans[task.id] = nil
	return nil
end

-- The block a task was given: the pins document, else the pane an older
-- version kept in the task's own state.
local function pin_of(p, s, id)
	local pin = p[id]
	if pin and type(pin.pane) == "number" then
		return pin
	end
	local ts = ((s or {}).tasks or {})[id]
	if ts and type(ts.pane) == "number" then
		return { pane = ts.pane, fp = ts.fp }
	end
	return nil
end

local function target(cx, task, pin, states)
	local pinned = pin and pin.pane
	if usable(cx, pinned, states) then
		if not pin.fp or fp_matches(pin.fp, fingerprint(cx, pinned)) then
			warn_ok("drift:" .. task.id)
			return pinned
		end
		warn_once("drift:" .. task.id, task.id .. ": pinned block changed conversation; reopening")
		return nil
	end
	local scoped = scoped_panes(cx, task)
	if scoped then
		return scoped_target(cx, task, pin, states, scoped)
	end
	-- No placement configured: title lookup, but only at the task's own cwd.
	local cwd = task.cwd and expanded_cwd(tostring(task.cwd))
	for _, spec in ipairs({ task.id, task.title }) do
		local resolved = cx.session:resolve(tostring(spec))
		if usable(cx, resolved, states) then
			local info = cx.session:pane(resolved)
			if not cwd or info.cwd == cwd then
				return resolved
			end
		end
	end
	return nil
end

-- Moves a freshly opened block to where task.place asks for it:
--   { "session": "name" }                     a dedicated session (created if missing)
--   { "session": "name", "tab": "name" }      ... into that session's tab (created if missing)
--   { "tab": "name" }                         that tab in the current session
local function plain_shell(cx, tab)
	for _, info in ipairs(cx.session:panes()) do
		if info.tab == tab and info.program ~= nil then
			return info.pane
		end
	end
	return nil
end

local function place_block(cx, pane, p)
	local before = cx.sessions:current()
	local session, born_tab, created
	if p.session then
		session = cx.session:find_session(tostring(p.session))
		if not session then
			local made = cx.sessions:create({ name = tostring(p.session) })
			session = made and made.id
			created = session
			-- A new session is born with one empty shell tab; remember it so the
			-- block's own tab can replace it.
			for _, info in ipairs(cx.session:sessions()) do
				if info.id == session then
					born_tab = info.tabs and info.tabs[1]
				end
			end
		end
	else
		session = before and before.id
	end
	if not session then
		return false
	end
	local moved
	if p.tab then
		local tab = cx.session:find_tab(tostring(p.tab), session)
		if tab then
			moved = cx.layout:move_to_tab(pane, tab, { focus = false }) and tab
		end
	end
	if not moved then
		local tab = cx.layout:move_to_new_tab(pane, session, { focus = false })
		if tab and p.tab then
			cx.layout:name_tab(tab, tostring(p.tab))
		end
		moved = tab
	end
	if born_tab and moved ~= born_tab then
		local shell = plain_shell(cx, born_tab)
		if shell then
			pcall(function()
				cx.layout:close(shell)
			end)
		end
	end
	-- Creating the session showed it; put the window back where the user was.
	if created and before and before.id ~= created then
		pcall(cx.sessions.switch, cx.sessions, before.id)
	end
	return moved ~= nil
end

-- Sends into `pane` when a target was found, else opens a new block (and moves
-- it to the task's place). Returns pane, created, note.
local function deliver(cx, task, pane, prompt)
	if pane then
		cx.agents:ask(pane, prompt)
		return pane, false, nil
	end
	local created = cx.agents:start({ prompt = prompt, cwd = task.cwd or "~", how = "tab" })
	local note
	if type(task.place) == "table" then
		local ok, placed = pcall(place_block, cx, created, task.place)
		if not ok then
			note = "place error: " .. tostring(placed)
		elseif not placed then
			note = "place failed; block stays in the current session"
		end
	end
	return created, true, note
end

-- Remembers the block a run went to, unless the user pinned another block
-- while it was being sent.
local function remember_pin(task, pin, pane)
	local current = pins()
	local existing = current[task.id]
	if existing and existing.pane and existing.pane ~= pane and existing.pane ~= (pin and pin.pane) then
		return
	end
	current[task.id] = {
		pane = pane,
		fp = existing and existing.pane == pane and existing.fp or nil,
	}
	save_pins(current)
	scans[task.id] = nil
end

local function record(ts, outcome, detail)
	ts.runs = ts.runs or {}
	table.insert(ts.runs, { at = now_ms(), outcome = outcome, detail = detail })
	while #ts.runs > HISTORY do
		table.remove(ts.runs, 1)
	end
end

local function when_text(ms)
	if type(ms) ~= "number" then
		return "unscheduled"
	end
	return os.date("%Y-%m-%d %H:%M", math.floor(ms / 1000))
end

-- One window owns the schedule; the owner refreshes a heartbeat and another
-- window takes over once it goes stale. Claims still make a handover safe.
local function own(cx, now)
	local s = state()
	local key = cx:window_key()
	local function take()
		write_state(function(doc)
			doc.owner = key
			doc.heartbeat = now
		end)
	end
	if s.owner == key then
		if type(s.heartbeat) ~= "number" or now - s.heartbeat >= HEARTBEAT_MS then
			take()
		end
		return true
	end
	if type(s.owner) == "string" and type(s.heartbeat) == "number" and now - s.heartbeat < OWNER_STALE_MS then
		return false
	end
	take()
	return true
end

-- The prompt lands in the block's transcript only after the block takes it, so
-- the fingerprint is retried with growing delays until it is non-empty.
local function refresh_fp(task_id, pane)
	local delays = { 4000, 11000, 30000, 60000 }
	local function attempt(i)
		tern.timer(delays[i], function(cx)
			local settled = false
			local ok = pcall(function()
				local fp = fingerprint(cx, pane)
				if fp and fp.n > 0 then
					local p = pins()
					local pin = p[task_id]
					if pin and pin.pane == pane then
						pin.fp = fp
						save_pins(p)
					end
					settled = true
				end
			end)
			if not ok then
				warn_once("fp:" .. task_id, task_id .. ": fingerprint refresh failed")
				settled = true
			end
			if settled then
				warn_ok("fp:" .. task_id)
				warn_ok("fp-empty:" .. task_id)
			elseif i < #delays then
				attempt(i + 1)
			else
				warn_once("fp-empty:" .. task_id, task_id .. ": transcript still empty; fingerprint left unknown")
			end
		end)
	end
	attempt(1)
end

-- One due check and, when due, one delivery. Reads this task's own state fresh
-- and writes back only that task, so another window's edits to the rest of the
-- document survive.
local function run_task(cx, task, now)
	local interval, at = schedule_of(task)
	if not interval then
		return false
	end
	local id = task.id
	local at_key = at and tostring(task.at) or nil
	local s = state()
	local ts = task_state(s, id)

	local dirty = false
	if ts.interval ~= interval or ts.at ~= at_key then
		local had = type(ts.interval) == "number"
		ts.interval = interval
		ts.at = at_key
		-- Adopt the interval without moving a slot a first run already armed;
		-- recompute only a real change (state from older versions has no interval).
		if had and type(ts.next) == "number" then
			ts.next = arm_next(at, interval, now, false)
		end
		dirty = true
	end
	if type(ts.next) ~= "number" then
		ts.next = arm_next(at, interval, now, true)
		dirty = true
	end
	if now < ts.next then
		if dirty then
			write_task(id, function(t)
				t.interval = interval
				t.at = at_key
				t.next = ts.next
			end)
		end
		return false
	end
	ts.next = arm_next(at, interval, now, false)

	local pin = pin_of(pins(), s, id)
	local states = agent_states(cx)
	local pane, scanning = target(cx, task, pin, states)
	if scanning then
		-- The blocks in the task's place are not all looked at yet; keep the
		-- slot due and finish on a later tick instead of pausing this hook.
		return false
	end
	if pane and (states[pane] == "working" or states[pane] == "waiting_input") then
		-- The block is still on an earlier turn: leave it alone, look again soon.
		write_task(id, function(t)
			t.interval = interval
			t.at = at_key
			t.next = now + math.min(interval, BUSY_RETRY_MS)
			t.claim = nil
			record(t, "skipped", "block " .. pane .. " is " .. states[pane])
		end)
		return false
	end

	local ok_prompt, prompt = pcall(prompt_text, task)
	if not ok_prompt then
		write_task(id, function(t)
			t.interval = interval
			t.at = at_key
			t.next = ts.next
			t.claim = nil
			record(t, "failed", tostring(prompt))
		end)
		cx:toast("error", id .. ": run failed", tostring(prompt))
		return true
	end

	-- Claim the slot before anything is sent: only the window whose token
	-- survives the store write delivers, so two windows cannot send twice.
	local token = tostring(now) .. ":" .. cx:window_key()
	local claimed = pcall(write_task, id, function(t)
		t.interval = interval
		t.at = at_key
		t.next = ts.next
		t.claim = token
	end)
	if not claimed then
		return false -- the store never took the claim; the next tick retries
	end
	local fresh = ((state().tasks or {})[id]) or {}
	if fresh.claim ~= token then
		return false
	end

	local ok, sent, created, note = pcall(deliver, cx, task, pane, prompt)
	if ok then
		write_task(id, function(t)
			t.interval = interval
			t.at = at_key
			t.next = ts.next
			t.claim = nil
			record(t, created and "opened" or "sent", note)
		end)
		if note then
			cx:toast("error", id .. ": " .. note, nil)
		end
		remember_pin(task, pin, sent)
		refresh_fp(id, sent)
	else
		write_task(id, function(t)
			t.interval = interval
			t.at = at_key
			t.next = ts.next
			t.claim = nil
			record(t, "failed", tostring(sent))
		end)
		cx:toast("error", id .. ": run failed", tostring(sent))
	end
	return true
end

local function tick(cx)
	local ok, err = pcall(function()
		local now = now_ms()
		if not own(cx, now) then
			return
		end
		local list, cfg_err = tasks()
		if cfg_err then
			if warn_once("config", cfg_err) then
				cx:toast("error", "scheduler: " .. cfg_err, nil)
			end
			return
		end
		warn_ok("config")
		local dup = duplicate_ids(list)
		local seen, bad_entry, stopped = {}, false, false
		for _, task in ipairs(list) do
			local id = type(task) == "table" and type(task.id) == "string" and task.id or nil
			if not id then
				bad_entry = true
				if warn_once("entry", "a task entry has no string id; skipped") then
					cx:toast("error", "scheduler: a task entry has no string id; skipped", nil)
				end
			else
				seen[id] = true
				if dup[id] then
					if warn_once("dup:" .. id, id .. ": duplicate task id; skipped") then
						cx:toast("error", "scheduler: " .. id .. ": duplicate id in tasks.json", nil)
					end
				else
					warn_ok("dup:" .. id)
					local interval, _, why = schedule_of(task)
					if not interval then
						if warn_once("schedule:" .. id, id .. ": " .. why) then
							cx:toast("error", "scheduler: " .. id .. ": " .. why, nil)
						end
					else
						warn_ok("schedule:" .. id)
						local ok_run, acted = pcall(run_task, cx, task, now_ms())
						if not ok_run then
							-- The slot may be claimed already: say what lost the run.
							tern.log.warn("scheduler: " .. id .. ": run failed: " .. tostring(acted))
						elseif acted then
							-- One prompt per tick: a burst of opens can outrun the hook
							-- budget, so the rest wait half a minute.
							stopped = true
							break
						end
					end
				end
			end
		end
		if not bad_entry and not stopped then
			warn_ok("entry")
		end
		-- Forget tasks that left tasks.json, their schedule and their pin both.
		local stale
		for id in pairs((state().tasks or {})) do
			if not seen[id] then
				stale = stale or {}
				stale[#stale + 1] = id
			end
		end
		if stale then
			write_state(function(doc)
				for _, id in ipairs(stale) do
					doc.tasks[id] = nil
				end
			end)
		end
		local p = pins()
		local pruned = false
		for id in pairs(p) do
			if not seen[id] then
				p[id] = nil
				pruned = true
			end
		end
		if pruned then
			save_pins(p)
		end
	end)
	if not ok then
		tern.log.warn("scheduler: tick failed: " .. tostring(err))
	end
	tern.timer(TICK_MS, tick)
end

-- Picker rows, or nil plus the reason when the configuration cannot be read;
-- the caller toasts the reason instead of offering an empty list.
local function items()
	local s = state()
	local p = pins()
	local list, cfg_err = tasks()
	if not list then
		return nil, cfg_err
	end
	local dup = duplicate_ids(list)
	local rows = {}
	for _, task in ipairs(list) do
		local id = type(task) == "table" and type(task.id) == "string" and task.id or nil
		if id then
			local ts = (s.tasks or {})[id] or {}
			local last = ts.runs and ts.runs[#ts.runs]
			local pin = pin_of(p, s, id)
			table.insert(rows, {
				label = task.title or id,
				detail = "next " .. when_text(ts.next)
					.. (last and (" · last " .. when_text(last.at) .. " " .. last.outcome) or " · no runs")
					.. (last and last.detail and (" (" .. last.detail .. ")") or "")
					.. (pin and (" · pinned " .. pin.pane .. (pin.fp and "" or " (conversation unknown)")) or "")
					.. (dup[id] and " · duplicate id, skipped" or ""),
				task = task,
			})
		end
	end
	return rows
end

tern.command({
	id = "tasks",
	title = "Scheduler: tasks",
	icon = "list",
	run = function(cx)
		local list, cfg_err = items()
		if not list then
			cx:toast("error", "scheduler: " .. cfg_err, nil)
			return
		end
		if #list == 0 then
			cx:toast("info", "scheduler: no tasks in tasks.json", nil)
			return
		end
		cx:pick({ items = list, placeholder = "Pick a task; Enter runs it now" }):next(function(choice, _err, pick_cx)
			if not choice or not pick_cx then
				return
			end
			local task = choice.task
			local pin = pin_of(pins(), state(), task.id)
			local ok, pane, created, note, scanning = pcall(function()
				local prompt = prompt_text(task)
				local target_pane, wait = target(pick_cx, task, pin, agent_states(pick_cx))
				if wait then
					return nil, nil, nil, true
				end
				return deliver(pick_cx, task, target_pane, prompt)
			end)
			if not ok then
				pick_cx:toast("error", task.id .. ": run failed", tostring(pane))
				return
			end
			if scanning then
				pick_cx:toast("info", task.id .. ": still looking for its block", "run it again in a moment")
				return
			end
			write_task(task.id, function(t)
				record(t, "manual", note)
			end)
			remember_pin(task, pin, pane)
			refresh_fp(task.id, pane)
			if note then
				pick_cx:toast("error", task.id .. ": " .. note, nil)
			end
			pick_cx:toast("info", task.id .. ": sent", created and ("opened block " .. pane) or ("block " .. pane))
		end)
	end,
})

tern.command({
	id = "pin",
	title = "Scheduler: pin this block",
	icon = "pin",
	run = function(cx)
		local focused = cx.session:focused()
		if not focused then
			cx:toast("error", "scheduler: focus an agent block first", nil)
			return
		end
		local ok, err = pcall(cx.agents.get, cx.agents, focused)
		if not ok then
			cx:toast("error", "scheduler: the focused block is not an agent", tostring(err))
			return
		end
		local list, cfg_err = items()
		if not list then
			cx:toast("error", "scheduler: " .. cfg_err, nil)
			return
		end
		if #list == 0 then
			cx:toast("info", "scheduler: no tasks in tasks.json", nil)
			return
		end
		cx:pick({ items = list, placeholder = "Pin the focused block to which task" }):next(function(choice, _err, pick_cx)
			if not choice or not pick_cx then
				return
			end
			local p = pins()
			p[choice.task.id] = { pane = focused, fp = fingerprint(pick_cx, focused) }
			save_pins(p)
			scans[choice.task.id] = nil
			pick_cx:toast("success", choice.task.id .. ": pinned", "pane " .. focused)
		end)
	end,
})

tern.command({
	id = "status",
	title = "Scheduler: status",
	icon = "clock",
	run = function(cx)
		local list, cfg_err = items()
		if not list then
			cx:toast("error", "scheduler: " .. cfg_err, nil)
			return
		end
		if #list == 0 then
			cx:toast("info", "scheduler: no tasks in tasks.json", nil)
			return
		end
		local s = state()
		local nearest
		for _, item in ipairs(list) do
			local ts = (s.tasks or {})[item.task.id] or {}
			if type(ts.next) == "number" and (nearest == nil or ts.next < nearest) then
				nearest = ts.next
			end
		end
		cx:toast("info", "scheduler: " .. #list .. " tasks", "next " .. when_text(nearest))
	end,
})

tern.timer(1000, tick)
