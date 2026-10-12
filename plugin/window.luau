--!strict
-- `tern open <name>.todo.json` opens the file as a Todos block instead of a file viewer.
local session = require("./session")

tern.route.open(function(req, _cx)
	if string.match(req.path, "%.todo%.json$") then
		return { block = "todo-proto.list", args = { req.path } }
	end
	return nil
end)

-- omp agent states for the Todos block. Only the window half can read agent blocks
-- (cx.agents:list), so it samples them and hands the result to the host half through
-- tern.kv:
--   host   -> "watch":  os.time() every few seconds while a Todos block is open
--   window -> "states": { [pane id as string] = "working" | "waiting_input" | "idle" | "exited" }
-- The window samples only while "watch" is fresh and writes only when the states changed.
-- `busy` follows the omp turn; the progress escape can outlive it.
local SAMPLE_MS = 2000
local WATCH_FRESH_S = 15

local last_sig = ""
local armed = false
local previous: { [string]: string } = {}
local saved_ok, saved = pcall(tern.kv.get, "states")
if saved_ok and type(saved) == "table" then
	for key, value in saved do
		if type(value) == "string" then
			previous[tostring(key)] = value
		end
	end
end

local function sample(cx: WindowCx)
	local ok, watch = pcall(tern.kv.get, "watch")
	if not ok or type(watch) ~= "number" or os.time() - watch > WATCH_FRESH_S then
		return
	end
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
					and (tree.main.c == nil or #tree.main.c == 0) then
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

-- Palette command: add the omp session running in the focused pane to the tasks file.
--
-- The file is the one the most recently opened Todos block published in tern.kv
-- "todo-proto.file". This half edits it directly and then bumps "todo-proto.nudge" so an
-- open block reloads within a state tick. No lost updates: the block's own writes
-- (host.luau `rewrite`) re-read the file each time, and this write re-reads it right before
-- writing and once more after, repeating if a concurrent block write dropped the task.
--
-- The omp session comes from `tern inspect --json`: omp tells Tern its session file
-- (OSC 1337 SetUserVar) and Tern lists it as `omp_session_file` on the pane, null when no omp runs
-- there. The id in the file name is what `omp --resume <id>` resolves. The title is read from the
-- first line of that file (omp's fixed-width title slot), so no glyph or PR suffix from the pane
-- title is involved.
local TERN = "/Users/delise/.local/bin/tern"
local FILE_KEY = "todo-proto.file"
local NUDGE_KEY = "todo-proto.nudge"
local WRITE_TRIES = 3

-- Twin of host.luau: tern.json.decode drops `null` members, so explicit nulls are marked.
local NULL_MARK = "__todo_proto_null__"

local function mark_nulls(text: string): string
	local out: { string } = {}
	local from, i, n = 1, 1, #text
	local in_string = false
	while i <= n do
		local c = string.sub(text, i, i)
		if in_string then
			if c == "\\" then
				i += 1
			elseif c == '"' then
				in_string = false
			end
		elseif c == '"' then
			in_string = true
		elseif c == ":" then
			local s, e = string.find(text, "^%s*null", i + 1)
			if s and not string.match(string.sub(text, e + 1, e + 1), "[%w_]") then
				table.insert(out, string.sub(text, from, e - 4))
				table.insert(out, '"' .. NULL_MARK .. '"')
				from = e + 1
				i = e
			end
		end
		i += 1
	end
	table.insert(out, string.sub(text, from))
	return table.concat(out)
end

local function restore_nulls(value: any): any
	if value == NULL_MARK then
		return tern.json.null
	elseif type(value) == "table" then
		for k, v in value do
			value[k] = restore_nulls(v)
		end
	end
	return value
end

local function is_text(v: any): boolean
	return type(v) == "string" and v ~= ""
end

-- Reads the file, lets `change` edit its `todos` array (it returns whether it changed
-- anything) and writes it back with the key fill-in host.luau's `rewrite` applies.
-- Returns changed, error.
local function edit_file(path: string, change: ({ any }) -> boolean): (boolean, string?)
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return false, "Cannot read " .. path
	end
	local dok, data = pcall(tern.json.decode, mark_nulls(text))
	if not dok or type(data) ~= "table" or type(data.todos) ~= "table" then
		return false, "Todo file is not valid JSON"
	end
	data = restore_nulls(data)
	local list = tern.json.array(data.todos)
	if not change(list) then
		return false, nil
	end
	for _, item in list do
		if type(item) == "table" then
			if item.due == nil then
				item.due = tern.json.null
			end
			local links = if type(item.links) == "table" then item.links else {}
			for _, k in { "tern_pane", "cwd", "omp_session" } do
				if links[k] == nil then
					links[k] = tern.json.null
				end
			end
			item.links = links
			if type(item.agent) == "table" then
				for _, k in { "model", "thinking" } do
					if item.agent[k] == nil then
						item.agent[k] = tern.json.null
					end
				end
			end
		end
	end
	data.todos = list
	local wok, werr = pcall(tern.fs.write, path, tern.json.encode(data, true) .. "\n")
	if not wok then
		return false, "Cannot write todo file: " .. tostring(werr)
	end
	return true, nil
end

-- The task that already stands for this session: same omp session id, else a task linked to
-- this pane that has no omp session yet (a pane with another session is another task).
local function find_task(list: { any }, pane: number, session: string): any
	for _, item in list do
		if type(item) == "table" and type(item.links) == "table" and item.links.omp_session == session then
			return item
		end
	end
	for _, item in list do
		if type(item) == "table" and type(item.links) == "table"
			and tonumber(item.links.tern_pane) == pane and not is_text(item.links.omp_session) then
			return item
		end
	end
	return nil
end

type Target = { pane: number, cwd: string, session: string, title: string }

-- Adds the task, or fills the missing/stale links of the one that exists.
-- Returns "added" | "exists" | "updated" (nil on failure), the task's title, and the error.
local function add_task(path: string, target: Target): (string?, string, string?)
	local outcome = "exists"
	local shown = target.title
	local function change(list: { any }): boolean
		local found = find_task(list, target.pane, target.session)
		if found then
			shown = tostring(found.title or target.title)
			local links = if type(found.links) == "table" then found.links else {}
			found.links = links
			local touched = false
			if links.omp_session ~= target.session then
				links.omp_session = target.session
				touched = true
			end
			if tonumber(links.tern_pane) ~= target.pane then
				links.tern_pane = target.pane
				touched = true
			end
			if not is_text(links.cwd) and target.cwd ~= "" then
				links.cwd = target.cwd
				touched = true
			end
			outcome = if touched then "updated" else "exists"
			return touched
		end
		local taken: { [string]: boolean } = {}
		for _, item in list do
			if type(item) == "table" and type(item.id) == "string" then
				taken[item.id] = true
			end
		end
		local n = #list + 1
		while taken["t" .. n] do
			n += 1
		end
		table.insert(list, {
			id = "t" .. n,
			title = target.title,
			notes = "",
			priority = "none",
			due = tern.json.null,
			done = false,
			links = {
				tern_pane = target.pane,
				cwd = if target.cwd ~= "" then target.cwd else tern.json.null,
				omp_session = target.session,
			},
		})
		outcome = "added"
		return true
	end
	for _ = 1, WRITE_TRIES do
		local changed, err = edit_file(path, change)
		if err then
			return nil, shown, err
		end
		if not changed then
			return outcome, shown, nil
		end
		-- A block write between our read and write would have dropped the task: the
		-- fresh file then has no task for this session.
		local lost = false
		local _, perr = edit_file(path, function(list)
			lost = find_task(list, target.pane, target.session) == nil
			return false
		end)
		if perr then
			return nil, shown, perr
		end
		if not lost then
			return outcome, shown, nil
		end
	end
	return nil, shown, "Todo file kept changing; try again"
end

-- Strips a leading private-use glyph (omp's title icon) and the spaces after it.
local function strip_glyph(title: string): string
	local s = title
	while true do
		local rest = string.match(s, "^\238[\128-\191][\128-\191]%s*(.*)$")
			or string.match(s, "^\239[\128-\191][\128-\191]%s*(.*)$")
			or string.match(s, "^\243[\176-\191][\128-\191][\128-\191]%s*(.*)$")
		if not rest then
			break
		end
		s = rest
	end
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end


local function add_omp_session(cx: WindowCx)
	local fok, path = pcall(tern.kv.get, FILE_KEY)
	if not fok or type(path) ~= "string" or path == "" then
		cx:toast("error", "Open the Tasks block once (tern open <file>.todo.json)")
		return
	end
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	if not pane or not info then
		cx:toast("error", "No focused pane")
		return
	end
	if info.kind ~= "terminal" and info.kind ~= "agent" then
		cx:toast("error", "Focus the pane running omp", "This pane is not a terminal")
		return
	end
	local cwd = if type(info.cwd) == "string" then info.cwd else ""
	local pane_title = strip_glyph(info.title)

	local function fail(cx2: WindowCx?, text: string, sub: string?)
		(cx2 or cx):toast("error", text, sub)
	end

	tern.process.run({ TERN, "inspect", "--json" }, { timeout_ms = 8000 }, function(result, cx1)
		if result.status ~= 0 then
			fail(cx1, "Cannot list Tern panes", result.stderr)
			return
		end
		local iok, doc = pcall(tern.json.decode, result.stdout)
		local file: string? = nil
		if iok and type(doc) == "table" and type(doc.panes) == "table" then
			for _, p in doc.panes do
				if type(p) == "table" and p.pane == pane and is_text(p.omp_session_file) then
					file = p.omp_session_file
					if cwd == "" and is_text(p.cwd) then
						cwd = p.cwd
					end
				end
			end
		end
		if not file then
			fail(cx1, "This pane is not running omp", "Focus the omp pane and run the command again")
			return
		end
		local file_id = string.match(file, "_([%w%-]+)%.jsonl$")
		if not file_id then
			fail(cx1, "Unrecognized omp session file", file)
			return
		end
		tern.process.run({ "/usr/bin/head", "-n", "2", "--", file }, { timeout_ms = 5000 }, function(head, cx2)
			if head.status ~= 0 then
				fail(cx2, "The omp session is not saved yet", "Send a message in omp first")
				return
			end
			local title, id = session.read_head(head.stdout)
			if id ~= file_id then
				fail(cx2, "Cannot read the omp session id", file)
				return
			end
			if title == "" then
				-- An unnamed session shows the program name as the pane title.
				title = if pane_title ~= "omp" then pane_title else ""
			end
			title = strip_glyph((string.gsub(title, "%s+", " ")))
			local target: Target = { pane = pane, cwd = cwd, session = file_id, title = title }
			local function commit(c: WindowCx, final: string)
				target.title = final
				local outcome, shown, err = add_task(path, target)
				if not outcome then
					c:toast("error", "Could not add the task", err)
					return
				end
				if outcome ~= "exists" then
					local okv, old = pcall(tern.kv.get, NUDGE_KEY)
					local n = if okv and type(old) == "table" and type(old.n) == "number" then old.n + 1 else 1
					pcall(tern.kv.set, NUDGE_KEY, { path = path, n = n })
				end
				if outcome == "added" then
					c:toast("success", "Added to tasks", shown)
				else
					c:toast("info", "Already in tasks", shown)
				end
			end
			-- A session already in the file needs no title: skip the prompt.
			local known = false
			local _, rerr = edit_file(path, function(list)
				known = find_task(list, pane, file_id) ~= nil
				return false
			end)
			if rerr then
				fail(cx2, "Could not add the task", rerr)
				return
			end
			if known then
				commit(cx2 or cx, title)
				return
			end
			local ask = (cx2 or cx):prompt({ value = title, placeholder = "Task title", action = "add" })
			ask:next(function(value, _err, cx3)
				local final = if type(value) == "string" then strip_glyph((string.gsub(value, "%s+", " "))) else ""
				if final ~= "" then
					commit(cx3 or cx, final)
				end
			end)
		end)
	end)
end

tern.command({
	id = "add-omp-session",
	title = "Todo: add this omp session to tasks",
	group = "Todo",
	icon = "check",
	run = add_omp_session,
})
