end

local passed, failed = 0, 0
local DAY_MS = 24 * 3600 * 1000

local function check(cond, name, detail)
	if cond then
		passed = passed + 1
		print("ok   " .. name)
	else
		failed = failed + 1
		print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
	end
end

local function has(text, part)
	return type(text) == "string" and string.find(text, part, 1, true) ~= nil
end

local function tick(w, cx)
	w.timers[1].fn(cx)
end

-- The stored schedule and history of one task.
local function task_state(w, id)
	return ((w.kv.state or {}).tasks or {})[id]
end

local function last_run(w, id)
	local runs = task_state(w, id).runs
	return runs and runs[#runs]
end

-- Prompts sent and blocks opened so far.
local function deliveries(cx)
	return #cx.asks + #cx.starts
end

-- Ticks every 30 seconds, up to `seconds` past T0.
local function tick_for(w, cx, seconds)
	for at = 30, seconds, 30 do
		w.now = T0 + at
		tick(w, cx)
	end
end

-- A task already armed and due now, its block pinned to pane 7.
local function pinned_world(task, extra)
	local w = new_world({
		tasks = { task },
		files = { ["/plugin/p.md"] = "go" },
		kv = {
			state = { tasks = { [task.id] = { interval = 3600 * 1000, next = T0 * 1000 } } },
			pins = { [task.id] = { pane = 7 } },
		},
	})
	if extra then
		extra(w)
	end
	return w
end

print("a new task runs at once, then on its interval")
do
	local w = new_world({ tasks = { { id = "t", every = "1h", prompt = "p.md", cwd = "~" } }, files = { ["/plugin/p.md"] = "go" } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check(deliveries(cx) == 1, "  the first tick delivers", deliveries(cx))
	w.now = T0 + 30
	tick(w, cx)
	check(deliveries(cx) == 1, "  the next tick does not", deliveries(cx))
	w.now = T0 + 3600
	tick(w, cx)
	check(deliveries(cx) == 2, "  one interval later it does", deliveries(cx))
end

print("an unreadable prompt fails its run instead of losing it")
do
	local w = new_world({ tasks = { { id = "t1", every = "30s", prompt = "prompts/missing.md", cwd = "~" } } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx) -- the first slot is due at once
	local run = last_run(w, "t1")
	check(run ~= nil and run.outcome == "failed", "  the run is recorded as failed", run and run.outcome)
	check(has(run and run.detail, "missing.md"), "  the record names the prompt file", run and run.detail)
	check(
		#cx.toasts == 1 and has(cx.toasts[1], "run failed") and has(cx.toasts[1], "missing.md"),
		"  one toast names the run and the prompt file",
		table.concat(cx.toasts, " | ")
	)
	check(task_state(w, "t1").next == T0 * 1000 + 30000, "  the next slot is one interval on", task_state(w, "t1").next)
end
do
	local w = new_world({ tasks = { { id = "t1", title = "T1", every = "30s", prompt = "prompts/missing.md", cwd = "~" } } })
	load_plugin()
	local cx = make_cx("A", { pick = 1 })
	w.commands.tasks.run(cx)
	check(
		#cx.toasts == 1 and has(cx.toasts[1], "run failed") and has(cx.toasts[1], "missing.md"),
		"  a manual run from the picker reports it as well",
		table.concat(cx.toasts, " | ")
	)
end

print("the task list says why the last run failed")
do
	local w = new_world({ tasks = { { id = "t1", title = "T1", every = "1h", prompt = "nope.md", cwd = "~" } } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	w.commands.tasks.run(cx)
	local rows = cx.picks[1]
	check(rows ~= nil and has(rows[1].detail, "nope.md"), "  the row carries the reason", rows and rows[1].detail)
end

print("a run that raises after its slot is claimed is logged")
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "idle" } },
		on_ask = function()
			w.write_fails = true -- the store that follows the delivery
		end,
	})
	tick(w, cx)
	check(#cx.asks == 1 and #cx.starts == 0, "  the prompt went out first", deliveries(cx))
	local logged = false
	for _, line in ipairs(w.logs) do
		if has(line, "t: run failed") then
			logged = true
		end
	end
	check(logged, "  the lost run is logged", table.concat(w.logs, " | "))
end

print("the commands report tasks.json when it cannot be read")
for _, case in ipairs({ { "missing", {} }, { "unreadable", { ["/plugin/tasks.json"] = "not json" } } }) do
	local w = new_world({ files = case[2] })
	load_plugin()
	local cx = make_cx("A", { focused = 7, panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } } })
	for _, id in ipairs({ "tasks", "status", "pin" }) do
		local ok, err = pcall(w.commands[id].run, cx)
		check(ok, "  Scheduler: " .. id .. " returns with tasks.json " .. case[1], err)
	end
	check(#cx.toasts == 3, "  each of them toasts the reason once", table.concat(cx.toasts, " | "))
end

print("entries that share an id are skipped, and said so")
do
	local w = new_world({
		tasks = {
			{ id = "dup", every = "1h", prompt = "p.md", cwd = "~" },
			{ id = "dup", every = "2h", prompt = "p.md", cwd = "~" },
		},
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	tick_for(w, cx, 7200)
	check(deliveries(cx) == 0, "  nothing is delivered for a duplicated id", deliveries(cx))
	local named = 0
	for _, toast in ipairs(cx.toasts) do
		if has(toast, "dup") and has(toast, "duplicate") then
			named = named + 1
		end
	end
	check(named == 1, "  one toast names the id", table.concat(cx.toasts, " | "))
end
do
	local w = new_world({
		tasks = {
			{ id = "dup", every = "1h", prompt = "p.md", cwd = "~" },
			{ id = "dup", every = "2h", prompt = "p.md", cwd = "~" },
		},
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A")
	w.commands.tasks.run(cx)
	local rows = cx.picks[1]
	check(
		rows ~= nil and #rows == 2 and has(rows[1].detail, "duplicate id") and has(rows[2].detail, "duplicate id"),
		"  the picker's rows say so too",
		rows and (rows[1].detail .. " | " .. rows[2].detail)
	)
end
do
	local w = new_world({
		tasks = { { id = "solo", every = "1h", prompt = "p.md", cwd = "~" } },
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	tick_for(w, cx, 7200)
	check(deliveries(cx) == 3, "  a task whose id is unique still runs every hour", deliveries(cx))
end

print("a task entry without a string id is reported, not run")
do
	local w = new_world({
		tasks = { { id = "good", every = "1h", prompt = "p.md", cwd = "~" }, { every = "30s" } },
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check(deliveries(cx) == 1, "  the valid entry still runs", deliveries(cx))
	w.now = T0 + 30
	tick(w, cx)
	check(#cx.toasts == 1 and has(cx.toasts[1], "no string id"), "  the entry is reported", table.concat(cx.toasts, " | "))
end

print("a block is found by its task's title, at a cwd that starts with ~")
-- The pinned block (12345) is gone and a block with the task's title is open.
local function reattach(task_cwd, pane_cwd)
	local w = new_world({
		tasks = { { id = "t", title = "Patrol", every = "30s", prompt = "p.md", cwd = task_cwd } },
		files = { ["/plugin/p.md"] = "go" },
		kv = { state = { tasks = { t = { pane = 12345, interval = 30000, next = T0 * 1000 } } } },
	})
	load_plugin()
	local cx = make_cx("A", { panes = { { pane = 7, kind = "agent", cwd = pane_cwd, title = "Patrol" } } })
	tick(w, cx)
	return cx
end
for _, case in ipairs({
	{ "~/Project", "/home/x/Project" },
	{ "~", "/home/x" },
	{ "/home/x/Project", "/home/x/Project" },
}) do
	local cx = reattach(case[1], case[2])
	check(
		#cx.asks == 1 and #cx.starts == 0,
		"  cwd " .. case[1] .. " reuses the block at " .. case[2],
		"asks " .. #cx.asks .. ", starts " .. #cx.starts
	)
end
do
	local cx = reattach("~/Project", "/home/x/Other")
	check(
		#cx.asks == 0 and #cx.starts == 1,
		"  a block with that title at another cwd is still left alone",
		"asks " .. #cx.asks .. ", starts " .. #cx.starts
	)
end

print("a block that is busy or exited is not prompted")
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "working" } },
	})
	tick(w, cx)
	check(#cx.asks == 0 and #cx.starts == 0, "  a working block gets nothing", deliveries(cx))
	local run = last_run(w, "t")
	check(run and run.outcome == "skipped" and has(run.detail, "working"), "  the slot is recorded as skipped", run and run.detail)
	local next_at = task_state(w, "t").next
	check(next_at > T0 * 1000 and next_at <= (T0 + 300) * 1000, "  it looks again within five minutes", next_at / 1000 - T0)
end
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "idle" } },
	})
	tick(w, cx)
	check(#cx.asks == 1 and #cx.starts == 0, "  an idle block is prompted", deliveries(cx))
end
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "exited" } },
	})
	tick(w, cx)
	check(#cx.asks == 0 and #cx.starts == 1, "  an exited block is replaced", deliveries(cx))
	check((w.kv.pins or {}).t.pane ~= 7, "  the stale pin is replaced", (w.kv.pins or {}).t.pane)
end

print("a pin made while a run is sending survives it")
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = {
			{ pane = 7, kind = "agent", cwd = "/x", title = "a" },
			{ pane = 8, kind = "agent", cwd = "/x", title = "b" },
		},
		agents = { { pane = 7, state = "idle" }, { pane = 8, state = "idle" } },
		transcript = { [7] = { { role = "user", text = "head" } }, [8] = { { role = "user", text = "other" } } },
		on_ask = function()
			-- another window pins pane 8 right here
			w.kv.pins = { t = { pane = 8 } }
		end,
	})
	tick(w, cx)
	check(#cx.asks == 1 and cx.asks[1].pane == 7, "  the prompt went to the old pin", cx.asks[1] and cx.asks[1].pane)
	check((w.kv.pins or {}).t.pane == 8, "  the newer pin stays", (w.kv.pins or {}).t.pane)
end

print("a daily at time anchors the slot")
do
	local w = new_world({
		tasks = { { id = "daily", every = "1d", at = "09:00", prompt = "p.md", cwd = "~" } },
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A", { panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } }, agents = { { pane = 7, state = "idle" } } })
	tick(w, cx)
	local slot = task_state(w, "daily").next
	local d = os.date("*t", math.floor(slot / 1000))
	check(deliveries(cx) == 0, "  nothing runs before the first 09:00", deliveries(cx))
	check(d and d.hour == 9 and d.min == 0, "  the slot is at 09:00 local", d and (d.hour .. ":" .. d.min))
	check(slot > T0 * 1000 and slot - T0 * 1000 <= DAY_MS, "  the slot is within a day", slot - T0 * 1000)
	w.now = math.floor(slot / 1000) - 1
	tick(w, cx)
	check(deliveries(cx) == 0, "  not a second early", deliveries(cx))
	w.now = math.floor(slot / 1000)
	tick(w, cx)
	check(deliveries(cx) == 1, "  it runs at the slot", deliveries(cx))
	local after = task_state(w, "daily").next
	local d2 = os.date("*t", math.floor(after / 1000))
	check(after > slot and d2 and d2.hour == 9 and d2.min == 0, "  the next slot is 09:00 again", after - slot)
	check(after - slot >= 23 * 3600 * 1000 and after - slot <= 25 * 3600 * 1000, "  one day on", after - slot)
end
do
	local w = new_world({ tasks = { { id = "x", every = "30m", at = "09:00", prompt = "p.md", cwd = "~" } }, files = { ["/plugin/p.md"] = "go" } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check(
		deliveries(cx) == 0 and #cx.toasts == 1 and has(cx.toasts[1], "at needs every"),
		"  at with a non-daily every is reported",
		table.concat(cx.toasts, " | ")
	)
end
do
	local w = new_world({ tasks = { { id = "x", every = "1d", at = "25:00", prompt = "p.md", cwd = "~" } }, files = { ["/plugin/p.md"] = "go" } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check(
		deliveries(cx) == 0 and #cx.toasts == 1 and has(cx.toasts[1], "bad at"),
		"  a bad at time is reported",
		table.concat(cx.toasts, " | ")
	)
end

print("tasks that left tasks.json lose their state and pin")
do
	local w = new_world({ tasks = { { id = "gone", every = "1h", prompt = "p.md", cwd = "~" } }, files = { ["/plugin/p.md"] = "go" } })
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check((w.kv.pins or {}).gone ~= nil, "  the run left a pin", true)
	w.decoded["TASKS"] = {}
	tick(w, cx)
	check(task_state(w, "gone") == nil, "  its schedule is dropped", task_state(w, "gone"))
	check((w.kv.pins or {}).gone == nil, "  its pin is dropped", (w.kv.pins or {}).gone)
end

print("a fixed and re-broken configuration is reported again")
do
	local w = new_world({})
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx) -- tasks.json missing
	local first = #cx.toasts
	w.files["/plugin/tasks.json"] = "TASKS"
	w.decoded["TASKS"] = {}
	tick(w, cx) -- fine again
	w.files["/plugin/tasks.json"] = "BROKEN"
	tick(w, cx) -- broken again
	check(first == 1 and #cx.toasts == 2, "  the second break toasts too", #cx.toasts)
end

print("the task list shows the pinned block")
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" })
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "idle" } },
	})
	w.commands.tasks.run(cx)
	local rows = cx.picks[1]
	check(rows ~= nil and has(rows[1].detail, "pinned 7"), "  the row names the pinned pane", rows and rows[1].detail)
	check(
		rows ~= nil and has(rows[1].detail, "conversation unknown"),
		"  and says its conversation is unknown",
		rows and rows[1].detail
	)
end
do
	local w = pinned_world({ id = "t", every = "1h", prompt = "p.md", cwd = "~" }, function(world)
		world.kv.pins.t.fp = { n = 1, head = 7 }
	end)
	load_plugin()
	local cx = make_cx("A")
	w.commands.tasks.run(cx)
	local rows = cx.picks[1]
	check(
		rows ~= nil and has(rows[1].detail, "pinned 7") and not has(rows[1].detail, "unknown"),
		"  a known conversation needs no note",
		rows and rows[1].detail
	)
end

print("placing a block in a new session returns the window")
do
	local w = new_world({
		tasks = { { id = "t", every = "1h", prompt = "p.md", cwd = "~", place = { session = "fresh" } } },
		files = { ["/plugin/p.md"] = "go" },
	})
	load_plugin()
	local cx = make_cx("A", { sessions = { { id = 1, name = "current", tabs = { 10 } } } })
	tick(w, cx)
	check(#cx.starts == 1, "  a block is opened", #cx.starts)
	check(w.shown == 1, "  the window shows the session it showed before", w.shown)
end

print("a scan of the blocks in a place is spread over ticks")
do
	local panes = { { pane = 7, kind = "agent", cwd = "/home/x", title = "a", tab = 20 } }
	local agents = { { pane = 7, state = "idle" } }
	local transcript = { [7] = { { role = "user", text = "head" } } }
	for i = 1, 8 do
		local pane = 100 + i
		panes[#panes + 1] = { pane = pane, kind = "agent", cwd = "/elsewhere/" .. i, title = "b" .. i, tab = 20 }
		agents[#agents + 1] = { pane = pane, state = "idle" }
		transcript[pane] = { { role = "user", text = i == 8 and "head" or ("other " .. i) } }
	end
	local w = new_world({
		tasks = { { id = "t", every = "1h", prompt = "p.md", cwd = "~/work", place = { session = "work" } } },
		files = { ["/plugin/p.md"] = "go" },
		kv = { pins = { t = { pane = 7 } } },
	})
	load_plugin()
	local cx = make_cx("A", {
		panes = panes,
		agents = agents,
		transcript = transcript,
		sessions = { { id = 2, name = "work", tabs = { 20 } } },
		tabs = { { id = 20, session = 2, name = "work" } },
	})
	tick(w, cx) -- sends into the pinned pane; no read without a fingerprint
	check(#cx.reads == 0 and #cx.asks == 1 and cx.asks[1].pane == 7, "  an unknown pin needs no chat read", #cx.reads)
	for _, timer in ipairs(w.timers) do
		if timer.ms == 4000 then
			timer.fn(cx) -- the fingerprint refresh
		end
	end
	local fp = (((w.kv.pins or {}).t or {}).fp)
	check(fp ~= nil and fp.n == 1, "  the refresh stored its fingerprint", fp and fp.n)
	table.remove(panes, 1) -- the pinned pane is gone; eight blocks remain in the place
	w.now = T0 + 3600
	cx.reads = {}
	tick(w, cx)
	check(#cx.reads == 6 and #cx.asks == 1, "  the first tick reads six blocks at most", #cx.reads)
	check(task_state(w, "t").next == (T0 + 3600) * 1000, "  the slot stays due", task_state(w, "t").next)
	check(#(task_state(w, "t").runs or {}) == 1, "  no run is recorded yet", #(task_state(w, "t").runs or {}))
	w.now = T0 + 3630
	tick(w, cx)
	check(#cx.reads == 8, "  the next tick finishes the scan", #cx.reads)
	check(#cx.asks == 2 and cx.asks[2].pane == 108, "  it found the block with that conversation", cx.asks[2] and cx.asks[2].pane)
end

print("a scan looks at the block at the task's cwd first")
do
	local panes = { { pane = 31, kind = "agent", cwd = "/home/x/work", title = "w", tab = 20 } }
	local agents = { { pane = 31, state = "idle" } }
	local transcript = { [31] = { { role = "user", text = "head" } } }
	local w = new_world({
		tasks = { { id = "t", every = "1h", prompt = "p.md", cwd = "~/work", place = { session = "work" } } },
		files = { ["/plugin/p.md"] = "go" },
		kv = { pins = { t = { pane = 31 } } },
	})
	load_plugin()
	local cx = make_cx("A", {
		panes = panes,
		agents = agents,
		transcript = transcript,
		sessions = { { id = 2, name = "work", tabs = { 20 } } },
		tabs = { { id = 20, session = 2, name = "work" } },
	})
	tick(w, cx)
	for _, timer in ipairs(w.timers) do
		if timer.ms == 4000 then
			timer.fn(cx)
		end
	end
	table.remove(panes, 1)
	panes[#panes + 1] = { pane = 32, kind = "agent", cwd = "/home/x/work", title = "w2", tab = 20 }
	panes[#panes + 1] = { pane = 33, kind = "agent", cwd = "/elsewhere", title = "x", tab = 20 }
	agents[#agents + 1] = { pane = 32, state = "idle" }
	agents[#agents + 1] = { pane = 33, state = "idle" }
	transcript[32] = { { role = "user", text = "head" } }
	transcript[33] = { { role = "user", text = "other" } }
	cx.reads = {}
	w.now = T0 + 3600
	tick(w, cx)
	check(cx.reads[1] == 32, "  the block at the task's cwd is looked at first", cx.reads[1])
	check(#cx.asks == 2 and cx.asks[2].pane == 32, "  it is the one that gets the prompt", cx.asks[2] and cx.asks[2].pane)
end

print("an unfingerprinted pin picks a block without reading chats")
do
	local w = new_world({
		tasks = { { id = "t", every = "1h", prompt = "p.md", cwd = "~", place = { session = "work" } } },
		files = { ["/plugin/p.md"] = "go" },
		kv = { pins = { t = { pane = 999 } } },
	})
	load_plugin()
	local cx = make_cx("A", {
		panes = {
			{ pane = 41, kind = "agent", cwd = "/x", title = "a", tab = 20 },
			{ pane = 42, kind = "agent", cwd = "/y", title = "b", tab = 20 },
		},
		agents = { { pane = 41, state = "idle" }, { pane = 42, state = "idle" } },
		sessions = { { id = 2, name = "work", tabs = { 20 } } },
		tabs = { { id = 20, session = 2, name = "work" } },
	})
	tick(w, cx)
	check(#cx.reads == 0, "  no chat is read", #cx.reads)
	check(#cx.asks == 1 and cx.asks[1].pane == 41, "  the first block in the place gets the prompt", cx.asks[1] and cx.asks[1].pane)
end

print("two tasks that come due together are sent a tick apart")
do
	local w = new_world({
		tasks = {
			{ id = "a", every = "1h", prompt = "a.md", cwd = "~" },
			{ id = "b", every = "1h", prompt = "b.md", cwd = "~" },
		},
		files = { ["/plugin/a.md"] = "A", ["/plugin/b.md"] = "B" },
	})
	load_plugin()
	local cx = make_cx("A")
	tick(w, cx)
	check(#cx.starts == 1 and cx.starts[1].prompt == "A", "  the first tick sends the first task", #cx.starts)
	w.now = T0 + 30
	tick(w, cx)
	check(#cx.starts == 2 and cx.starts[2].prompt == "B", "  the next tick sends the other", #cx.starts)
	w.now = T0 + 60
	tick(w, cx)
	check(#cx.starts == 2, "  then nothing until a slot is due", #cx.starts)
end

print("a busy block does not hold back the next task")
do
	local w = new_world({
		tasks = {
			{ id = "busy", every = "1h", prompt = "a.md", cwd = "~" },
			{ id = "next", every = "1h", prompt = "b.md", cwd = "~" },
		},
		files = { ["/plugin/a.md"] = "A", ["/plugin/b.md"] = "B" },
		kv = {
			state = { tasks = { busy = { interval = 3600 * 1000, next = T0 * 1000 } } },
			pins = { busy = { pane = 7 } },
		},
	})
	load_plugin()
	local cx = make_cx("A", {
		panes = { { pane = 7, kind = "agent", cwd = "/x", title = "a" } },
		agents = { { pane = 7, state = "working" } },
	})
	tick(w, cx)
	local run = last_run(w, "busy")
	check(run and run.outcome == "skipped", "  the busy task is skipped", run and run.outcome)
	check(#cx.starts == 1 and cx.starts[1].prompt == "B", "  the next task still runs", #cx.starts)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error(failed .. " check(s) failed", 0)
end
