--!strict
-- `tern open <name>.todo.json` opens the file as a Todos block instead of a file viewer.
local session = require("./session")
local remote = require("./remote")

tern.route.open(function(req, _cx)
	if string.match(req.path, "%.todo%.json$") then
		return { block = "todo-proto.list", args = { req.path } }
	end
	return nil
end)

tern.command({
	id = "open",
	title = "Todo: open tasks",
	group = "Todo",
	icon = "check",
	run = remote.open,
})

-- omp agent states for the Todos block. Only the window half can read agent blocks
-- (cx.agents:list), so it samples them and hands the result to the host half through
-- tern.kv:
--   host   -> "watch":  os.time() every few seconds while a Todos block is open
--   window -> "states": { [pane id as string] = "working" | "waiting_input" | "idle" | "exited" }
-- The window samples only while "watch" is fresh and writes only when the states changed.
-- `busy` follows the omp turn; the progress escape can outlive it.
local SAMPLE_MS = 200
local WATCH_FRESH_S = 15

local last_sig = ""
local armed = false
local previous: { [string]: string } = {}
local previous_panes: { [number]: boolean } = {}
local saved_ok, saved = pcall(tern.kv.get, "states")
if saved_ok and type(saved) == "table" then
	for key, value in saved do
		if type(value) == "string" then
			previous[tostring(key)] = value
		end
	end
end

-- The ask tool renders in the editor region (root "e"), not in the layer, so an empty layer does
-- not mean the wait is stale while a question is on screen.
local function has_ask(node: any): boolean
	if type(node) ~= "table" then
		return false
	end
	if type(node.p) == "table" and node.p.role == "omp.ask.question" then
		return true
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			if has_ask(child) then
				return true
			end
		end
	end
	return false
end

local function ask_open(cx: WindowCx, pane: number): boolean
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", root = "e", depth = 3, nodes = 40 })
	end)
	return ok and type(tree) == "table" and has_ask(tree.main)
end

local function sample(cx: WindowCx)
	local ok, watch = pcall(tern.kv.get, "watch")
	if not ok or type(watch) ~= "number" or os.time() - watch > WATCH_FRESH_S then
		previous_panes = {}
		return
	end
	local panes: { [number]: boolean } = {}
	for _, pane in cx.session:panes() do
		panes[pane.pane] = true
	end
	local closed: { [number]: boolean } = {}
	for pane in previous_panes do
		if not panes[pane] then
			closed[pane] = true
		end
	end
	if next(closed) ~= nil then
		local recorded = tern.kv.get("closed_panes")
		local events = if type(recorded) == "table" then recorded else {}
		for pane in closed do
			events[tostring(pane)] = true
		end
		tern.kv.set("closed_panes", events)
	end
	previous_panes = panes
	local lok, list = pcall(function()
		return cx.agents:list()
	end)
	if not lok or type(list) ~= "table" then
		return
	end
	local states: { [string]: string } = {}
	for _, a in list :: { any } do
		local state = if type(a.state) == "string" then a.state else "idle"
		if state == "working" and a.busy == false then
			state = "idle"
		end
		if type(a.pane) == "number" then
			-- Tern can retain waiting_input after omp closes its approval layer.
			if state == "waiting_input" then
				local layer_ok, tree = pcall(function()
					return cx.session:surface(a.pane, { as = "table", root = "layer", depth = 1, nodes = 16 })
				end)
				if layer_ok and type(tree) == "table" and tree.surface
					and tree.surface.role == "omp.session" and tree.main
					and tree.main.id == "layer" and not tree.main.more
					and (tree.main.c == nil or #tree.main.c == 0)
					and not ask_open(cx, a.pane) then
					state = if a.busy == false then "idle" else "working"
				end
			end
			states[tostring(a.pane)] = state
		end
	end
	-- omp returning to its shell removes the agent, not the still-live pane.
	for key in previous do
		if states[key] == nil then
			states[key] = "exited"
		end
	end
	previous = states
	local sig = tern.json.encode(states)
	if sig ~= last_sig then
		local wrote = pcall(tern.kv.set, "states", states)
		if wrote then
			last_sig = sig
		end
	end
end


local function arm()
	if armed then
		return
	end
	armed = true
	tern.timer(SAMPLE_MS, function(cx)
		armed = false
		if cx then
			pcall(sample, cx)
		end
		arm()
	end)
end

tern.on("window_start", function(_cx)
	arm()
end)

-- Linking/reloading creates a VM in an existing window without window_start.
tern.timer(300, function(_cx)
	arm()
end)

local tern_bin = require("./executable").tern_bin
local FILE_KEY = "todo-proto.file"
local NUDGE_KEY = "todo-proto.nudge"
local session_tasks = require("./session-tasks")
local edit_file = session_tasks.edit_file
local add_task = session_tasks.add_task
local strip_glyph = session_tasks.strip_glyph
local iso_now = session_tasks.iso_now
local is_text = session_tasks.is_text
tern.command({
	id = "add-omp-session",
	title = "Todo: add this omp session to tasks",
	group = "Todo",
	icon = "check",
	run = require("./session-command").add,
})

-- Auto-import: while a Todos block is open, every AUTO_MS this half lists the panes running
-- omp and adds each saved session the file does not know yet. A session is imported at most
-- once (kv "auto-seen"), so deleting an imported task does not bring it back while its pane lives.
-- A session without a saved file or a title is retried on the next scan.
local AUTO_MS = 10000
local SEEN_KEY = "auto-seen"
local SEEN_MAX = 500

local auto_armed = false
local auto_busy = false

local function load_seen(): ({ [string]: boolean }, { string })
	local set: { [string]: boolean } = {}
	local order: { string } = {}
	local ok, saved_seen = pcall(tern.kv.get, SEEN_KEY)
	if ok and type(saved_seen) == "table" then
		for _, id in saved_seen :: { any } do
			if type(id) == "string" and not set[id] then
				set[id] = true
				table.insert(order, id)
			end
		end
	end
	return set, order
end

local function mark_seen(id: string)
	local set, order = load_seen()
	if set[id] then
		return
	end
	table.insert(order, id)
	while #order > SEEN_MAX do
		table.remove(order, 1)
	end
	pcall(tern.kv.set, SEEN_KEY, order)
end

type Candidate = { pane: number, cwd: string, file: string, id: string, pane_title: string }

local function omp_titles_on(): boolean
	local ok, v = pcall(tern.kv.get, "settings")
	return ok and type(v) == "table" and v.omp_titles == true
end

local function bump_nudge(path: string)
	local okv, old = pcall(tern.kv.get, NUDGE_KEY)
	local n = if okv and type(old) == "table" and type(old.n) == "number" then old.n + 1 else 1
	pcall(tern.kv.set, NUDGE_KEY, { path = path, n = n })
end

-- Setting "Task titles from omp": every scan, a task linked to a live omp session takes the
-- title omp gave that session. Only omp's own title counts (the title slot or session header),
-- never the pane title, so an unnamed session leaves the task's title alone. A block write
-- that lands between our read and write is harmless: the next scan applies the title again.
local function sync_titles(path: string, all: { Candidate }, index: number, titles: { [string]: string })
	local c = all[index]
	if not c then
		auto_busy = false
		if next(titles) == nil then
			return
		end
		local changed = edit_file(path, function(list)
			local touched = false
			for _, item in list do
				local links = if type(item) == "table" then item.links else nil
				local want = if type(links) == "table" and is_text(links.omp_session) then titles[links.omp_session] else nil
				if want and item.title ~= want then
					item.title = want
					item.updated = iso_now()
					touched = true
				end
			end
			return touched
		end)
		if changed then
			bump_nudge(path)
		end
		return
	end
	tern.process.run({ "/usr/bin/head", "-n", "2", "--", c.file }, { timeout_ms = 5000 }, function(head, _)
		if head.status == 0 then
			local title, id = session.read_head(head.stdout)
			title = strip_glyph((string.gsub(title, "%s+", " ")))
			if id == c.id and title ~= "" then
				titles[c.id] = title
			end
		end
		sync_titles(path, all, index + 1, titles)
	end)
end

local function import_next(path: string, queue: { Candidate }, index: number, all: { Candidate })
	local c = queue[index]
	if not c then
		if omp_titles_on() and #all > 0 then
			sync_titles(path, all, 1, {})
		else
			auto_busy = false
		end
		return
	end
	tern.process.run({ "/usr/bin/head", "-n", "2", "--", c.file }, { timeout_ms = 5000 }, function(head, _)
		local title, id = "", nil :: string?
		if head.status == 0 then
			title, id = session.read_head(head.stdout)
		end
		if id == c.id then
			if title == "" and c.pane_title ~= "omp" then
				title = c.pane_title
			end
			title = strip_glyph((string.gsub(title, "%s+", " ")))
			if title ~= "" then
				local outcome = add_task(path, { pane = c.pane, cwd = c.cwd, session = c.id, title = title })
				if outcome then
					mark_seen(c.id)
					if outcome ~= "exists" then
						bump_nudge(path)
					end
				end
			end
		end
		import_next(path, queue, index + 1, all)
	end)
end

local function auto_scan()
	if auto_busy then
		return
	end
	local wok, watch = pcall(tern.kv.get, "watch")
	if not wok or type(watch) ~= "number" or os.time() - watch > WATCH_FRESH_S then
		return
	end
	local fok, path = pcall(tern.kv.get, FILE_KEY)
	if not fok or type(path) ~= "string" or path == "" then
		return
	end
	auto_busy = true
	local started = pcall(tern.process.run, { tern_bin(), "inspect", "--json" }, { timeout_ms = 8000 }, function(result, _)
		local iok, doc = pcall(tern.json.decode, result.stdout)
		local queue: { Candidate } = {}
		local all: { Candidate } = {}
		if result.status == 0 and iok and type(doc) == "table" and type(doc.panes) == "table" then
			local seen = load_seen()
			local queued: { [string]: boolean } = {}
			for _, p in doc.panes do
				if type(p) == "table" and type(p.pane) == "number" and is_text(p.omp_session_file) then
					local id = string.match(p.omp_session_file, "_([%w%-]+)%.jsonl$")
					if id and not queued[id] then
						queued[id] = true
						local cand: Candidate = {
							pane = p.pane,
							cwd = if type(p.cwd) == "string" then p.cwd else "",
							file = p.omp_session_file,
							id = id,
							pane_title = if type(p.title) == "string" then strip_glyph(p.title) else "",
						}
						table.insert(all, cand)
						if not seen[id] then
							table.insert(queue, cand)
						end
					end
				end
			end
		end
		import_next(path, queue, 1, all)
	end)
	if not started then
		auto_busy = false
	end
end

local function auto_arm()
	if auto_armed then
		return
	end
	auto_armed = true
	tern.timer(AUTO_MS, function(_cx)
		auto_armed = false
		pcall(auto_scan)
		auto_arm()
	end)
end

tern.on("window_start", function(_cx)
	auto_arm()
end)

tern.timer(500, function(_cx)
	auto_arm()
end)

-- Palette command: open the settings sheet of the focused Todos block. The block runs in the
-- host half, so the request goes through tern.kv "todo-proto.settings_req" = { pane, n }; the
-- block of that pane opens its sheet on its next state tick (about 2 seconds).
local SETTINGS_REQ_KEY = "todo-proto.settings_req"

local function open_settings(cx: WindowCx)
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	if not pane or not info or type(info.block) ~= "string" or not string.find(info.block, "todo-proto.list", 1, true) then
		cx:toast("error", "Focus a Todos block first")
		return
	end
	local okv, old = pcall(tern.kv.get, SETTINGS_REQ_KEY)
	local n = if okv and type(old) == "table" and type(old.n) == "number" then old.n + 1 else 1
	pcall(tern.kv.set, SETTINGS_REQ_KEY, { pane = pane, n = n })
end

tern.command({
	id = "settings",
	title = "Todo: settings",
	group = "Todo",
	icon = "check",
	run = open_settings,
})
