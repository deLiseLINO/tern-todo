--!strict
-- The `list` block: a Synara-style Tasks view over the JSON file named by args[1].
-- The file is re-read every 5 seconds, except while a text field or popover has focus.
--
-- Keys (no field focused): j/k or up/down move, space or x toggles done, Enter
-- focuses the linked pane, resumes the linked omp chat in a new tab, or starts
-- the task in omp; Tab or a adds a task, e edits the notes, F2 or n renames the task,
-- p picks the project, r reloads the file, z archives or restores, Delete or Backspace
-- deletes (press twice), Z shows or hides the archived section. Alt+Up / Alt+Down (or
-- cmd+shift+Up / Down) move the selected task one place within its group. Double-clicking a
-- row selects it, opens its card and does what Enter does. The grip at the right of a row
-- picks the task up; the next click on a row drops it there (Esc or the grip again cancels).
-- Keys (field focused): typing edits the field, Enter adds the task (add row), saves the
-- title or inserts a newline (notes), Esc or Tab leaves the field (Esc restores a title).
--
-- Fields are natively edited: the block opts into `features = {"edit", "undo"}`, so Tern
-- keeps the selection (shift-arrows, drag, double/triple click, cmd+a) and sends edits as
-- `edit` events and cmd+z as `undo`. The block's `Field` model applies those, plus the
-- keys Tern leaves to the program (typing, deletes, word moves, ctrl+a, redo).

local ui = tern.ui

local POLL_MS = 5 * 1000
local TERN = "/Users/delise/.local/bin/tern"
local ROLE = "todo-proto."
local PRIORITIES = { "none", "low", "medium", "high", "urgent" }
local PRIORITY_LABEL: { [string]: string } = {
	none = "No priority",
	low = "Low",
	medium = "Medium",
	high = "High",
	urgent = "Urgent",
}
local PRIORITY_TONE: { [string]: string } = {
	urgent = "error",
	high = "warning",
	medium = "accent",
	low = "neutral",
	none = "muted",
}
-- Tone of the priority pill: No priority and Medium stay uncoloured.
local PILL_TONE: { [string]: string } = { low = "muted", high = "warning", urgent = "error" }
-- Thinking levels as omp lists them for a model with reasoning: off, auto, then the
-- model's own efforts (cycleThinkingLevel in omp's model-controls.ts). Used for the
-- default model, whose efforts are not known.
local DEFAULT_EFFORTS = { "minimal", "low", "medium", "high", "xhigh", "max" }
local LEVEL_LABEL: { [string]: string } = {
	off = "Off",
	minimal = "Minimal",
	low = "Low",
	medium = "Medium",
	high = "High",
	xhigh = "Extra high",
	max = "Max",
	auto = "Auto",
}
-- Task status kinds, as Synara's TaskStatusKind; the label is the chip's text and the
-- line is the quiet word under the row's title.
local STATUS_LABEL: { [string]: string } = {
	starting = "Starting",
	running = "Working",
	needs = "Needs you",
	review = "Ready for you",
	stopped = "Stopped",
}
-- Window-side omp states (cx.agents:list) and debug words mapped to status kinds.
local KIND_OF_STATE: { [string]: string } = {
	working = "running",
	waiting_input = "needs",
	idle = "review",
	exited = "stopped",
	running = "running",
	needs = "needs",
	review = "review",
	stopped = "stopped",
	starting = "starting",
	todo = "todo",
}
local STARTING_S = 8
-- Rows PageUp/PageDown move in a popover.
local PAGE_ROWS = 8
-- Longest task title, in UTF-16 units (Synara's TODO_TITLE_MAX_LENGTH).
local TITLE_MAX = 500
-- Popovers that have a search field; the others are plain lists.
local SEARCH: { [string]: string } = {
	project = "Search projects",
	model = "Search models",
	chat = "Search chats",
}


type Links = { tern_pane: number?, cwd: string?, omp_session: string? }
type Agent = { model: string?, thinking: string? }
type Todo = {
	id: string,
	title: string,
	notes: string,
	priority: string,
	due: string?,
	done: boolean,
	archived: boolean,
	links: Links,
	agent: Agent,
}

type Model = { selector: string, id: string, provider: string, reasoning: boolean, efforts: { string }, context: string }
type Chat = { id: string, title: string, cwd: string, mtime: number }

-- Popover state. `kind` is project, model or chat; `text` is the search
-- field; `sel` is the highlighted item (0 = none); `dir`/`names` cache the last directory
-- listing of the project picker's path mode.
type Pick = {
	kind: string,
	task: string,
	q: Field,
	sel: number,
	dir: string?,
	names: { string },
	missing: boolean,
	want: string?,
	hint: string?,
}

type State = {
	cx: BlockCx,
	path: string?,
	todos: { Todo },
	cursor: string?,
	error: string?,
	timer: TimerHandle?,
	-- "add" (the add row), "title" or "notes" (the detail fields), "picker" (a popover) or
	-- nil (list keys).
	focus: string?,
	detail_open: boolean,
	add: Field,
	-- Drafts of the focused detail fields, valid while focus == "title" / "notes".
	notes: Field,
	title: Field,
	-- The task being renamed and its title when the rename started (Esc and an empty title
	-- restore it).
	title_id: string?,
	title_orig: string,
	pick: Pick?,
	-- Models from `omp models --json`, loaded once per block run.
	models: { Model }?,
	models_state: string,
	models_error: string?,
	-- Recent omp chats, newest first; reloaded whenever the chat popover opens.
	chats: { Chat }?,
	chats_loading: boolean,
	chats_token: number,
	-- omp state per linked pane ("working", "waiting_input", "idle", "exited"), written by
	-- window.luau into tern.kv "states" and read here (see window.luau for the handshake).
	agent_states: { [string]: string },
	-- Test hook: tern.kv "todo-proto.debug_states" ({ [pane id string] = state word })
	-- replaces live detection for those panes. Words: starting, running/working, needs/waiting_input,
	-- review/idle, stopped/exited, todo.
	debug_states: { [string]: string },
	states_sig: string,
	st_timer: TimerHandle?,
	-- Counter of window.luau's "todo-proto.nudge" already handled (see `reload_if_nudged`).
	nudge_seen: number,
	-- When a pane was last seen working / launched by this block (os.time()).
	since: { [number]: number },
	launched: { [number]: number },
	-- Archived section expanded; id of the task whose Delete awaits its second press (view
	-- state only, never saved to the file).
	arch_open: boolean,
	confirm: string?,
	confirm_timer: TimerHandle?,
	-- The task picked up by its grip, waiting to be dropped on a row (view state only).
	lift: string?,
	-- The last press on a glyph or grip (key, tern.now()): a double click delivers it twice.
	tap: { key: string, at: number }?,
	-- Tasks whose `tern new tab` is still running, so a repeated double click starts one tab.
	launching: { [string]: boolean },
}

-- A pane ID survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local CONFIRM_MS = 4000

local function clear_confirm(state: State)
	state.confirm = nil
	if state.confirm_timer then
		state.confirm_timer:cancel()
		state.confirm_timer = nil
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	if state.st_timer then
		state.st_timer:cancel()
		state.st_timer = nil
	end
	clear_confirm(state)
	state.todos = {}
end

-- Check this run first, not just its pane: Restart reuses the pane ID.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function live_panes(): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		set[p.pane] = true
	end
	return set
end

-- Open todos first, then done ones, file order inside each group; archived ones last, and
-- only while the Archived section is expanded.
local function ordered(todos: { Todo }, with_archived: boolean): { Todo }
	local out: { Todo } = {}
	for _, t in todos do
		if not t.done and not t.archived then
			table.insert(out, t)
		end
	end
	for _, t in todos do
		if t.done and not t.archived then
			table.insert(out, t)
		end
	end
	if with_archived then
		for _, t in todos do
			if t.archived then
				table.insert(out, t)
			end
		end
	end
	return out
end

local function str_or_nil(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function parse(text: string): ({ Todo }?, string?)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" or type(data.todos) ~= "table" then
		return nil, "The file is not a {\"todos\": [...]} document."
	end
	local todos: { Todo } = {}
	for _, item in data.todos do
		if type(item) == "table" and type(item.id) == "string" then
			local links = if type(item.links) == "table" then item.links else {}
			local agent = if type(item.agent) == "table" then item.agent else {}
			table.insert(todos, {
				id = item.id,
				title = tostring(item.title or ""),
				notes = tostring(item.notes or ""),
				priority = if PRIORITY_TONE[tostring(item.priority)] then tostring(item.priority) else "none",
				due = if type(item.due) == "string" then item.due else nil,
				done = item.done == true,
				archived = item.archived == true,
				links = {
					tern_pane = tonumber(links.tern_pane),
					cwd = str_or_nil(links.cwd),
					omp_session = str_or_nil(links.omp_session),
				},
				agent = { model = str_or_nil(agent.model), thinking = str_or_nil(agent.thinking) },
			})
		end
	end
	return todos, nil
end

local function ensure_cursor(state: State)
	local shown = ordered(state.todos, state.arch_open)
	for _, t in shown do
		if t.id == state.cursor then
			return
		end
	end
	state.cursor = if shown[1] then shown[1].id else nil
end

local function load(state: State)
	local path = state.path
	if not path then
		return
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		state.error = "Cannot read " .. path .. ": " .. tostring(text)
		return
	end
	local todos, err = parse(text)
	if not todos then
		state.error = err
		return
	end
	state.error = nil
	state.todos = todos
	ensure_cursor(state)
end

-- Replaces every `: null` outside a string by a marker string and back after decoding:
-- tern.json.decode drops null object members, which would delete explicit nulls the
-- block knows nothing about (unknown keys of a task, nested objects, other top-level keys).
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

-- Re-reads the file, lets `change` edit its `todos` array, and writes it back.
-- Reading first keeps edits made elsewhere; known keys that are absent are filled in
-- as explicit nulls (`due` is kept as it is, null when unset;
-- `agent` is optional and only filled in where a task has one).
-- Returns whether the file was written.
local function rewrite(state: State, change: ({ any }) -> ()): boolean
	local path = state.path
	if not path then
		return false
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		state.cx:toast("error", "Cannot read todo file", tostring(text))
		return false
	end
	local dok, data = pcall(tern.json.decode, mark_nulls(text))
	if not dok or type(data) ~= "table" or type(data.todos) ~= "table" then
		state.cx:toast("error", "Todo file is not valid JSON")
		return false
	end
	data = restore_nulls(data)
	local list = tern.json.array(data.todos)
	change(list)
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
		state.cx:toast("error", "Cannot write todo file", tostring(werr))
		return false
	end
	load(state)
	return true
end

local function patch(state: State, id: string, change: (any) -> ())
	rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and item.id == id then
				change(item)
			end
		end
	end)
end

local function toggle(state: State, id: string)
	patch(state, id, function(item)
		item.done = not (item.done == true)
	end)
end

local function add_task(state: State, title: string)
	local new_id = ""
	local written = rewrite(state, function(list)
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
		new_id = "t" .. n
		table.insert(list, {
			id = new_id,
			title = title,
			notes = "",
			priority = "none",
			due = tern.json.null,
			done = false,
			links = {},
		})
	end)
	if written then
		state.cursor = new_id
		state.detail_open = true
	end
end

local function index_of(state: State): number
	for i, t in ordered(state.todos, state.arch_open) do
		if t.id == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: State): Todo?
	return ordered(state.todos, state.arch_open)[index_of(state)]
end

local function move(state: State, to: number)
	local shown = ordered(state.todos, state.arch_open)
	local t = shown[math.clamp(to, 1, math.max(1, #shown))]
	if t then
		if state.cursor ~= t.id then
			clear_confirm(state)
		end
		state.cursor = t.id
		state.detail_open = true
	end
end

-- The task to select once `id` leaves the list or its group: the next one, else the
-- previous one, preferring its own group (open/done vs archived).
local function neighbour(state: State, id: string): string?
	local shown = ordered(state.todos, state.arch_open)
	local at = 0
	for i, t in shown do
		if t.id == id then
			at = i
		end
	end
	local own = if shown[at] then shown[at].archived else false
	for i = at + 1, #shown do
		if shown[i].archived == own then
			return shown[i].id
		end
	end
	for i = at - 1, 1, -1 do
		if shown[i].archived == own then
			return shown[i].id
		end
	end
	local other = shown[at + 1] or shown[at - 1]
	return if other then other.id else nil
end

-- Archive keeps the record, its links and any running agent untouched; Restore drops the key.
local function archive_toggle(state: State, t: Todo)
	local target = not t.archived
	local after = neighbour(state, t.id)
	clear_confirm(state)
	local written = rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and item.id == t.id then
				item.archived = if target then true else nil
			end
		end
	end)
	if written then
		state.cursor = after
		state.cx:toast("info", if target then "Archived" else "Restored")
	end
end

-- First press arms the confirmation, the second removes the record (never a pane or session).
local function delete_press(state: State)
	local t = selected(state)
	if not t then
		return
	end
	-- The confirm button lives in the detail card; arming it unseen would be a trap.
	if not state.detail_open then
		state.detail_open = true
		return
	end
	if state.confirm ~= t.id then
		clear_confirm(state)
		state.confirm = t.id
		state.confirm_timer = tern.timer(CONFIRM_MS, function()
			state.confirm_timer = nil
			if alive(state) and state.confirm == t.id then
				state.confirm = nil
				state.cx:render()
			end
		end)
		return
	end
	local after = neighbour(state, t.id)
	clear_confirm(state)
	local written = rewrite(state, function(list)
		for i, item in list do
			if type(item) == "table" and item.id == t.id then
				table.remove(list, i)
				break
			end
		end
	end)
	if written then
		state.cursor = after
	end
end

local function toggle_archived(state: State)
	state.arch_open = not state.arch_open
	clear_confirm(state)
	ensure_cursor(state)
end

-- Reorder -------------------------------------------------------------------

-- The group a task is listed in: 1 open, 2 done, 3 archived (the order of `ordered`).
local function group_of(item: any): number
	if type(item) ~= "table" then
		return 0
	end
	if item.archived == true then
		return 3
	elseif item.done == true then
		return 2
	end
	return 1
end

-- Moves the item `id` of `list` (the file's todos array) onto `target`: within one group it
-- takes the target's place (before it when moving up, after it when moving down). A target
-- of another group puts it at the near edge of its own group instead (after the last item
-- when the target's group is listed later, before the first when earlier). Only the array
-- order changes. Returns whether the order changed.
local function place(list: { any }, id: string, target: string): boolean
	local from, to = 0, 0
	for i, item in list do
		if type(item) == "table" then
			if item.id == id then
				from = i
			elseif item.id == target then
				to = i
			end
		end
	end
	if from == 0 or to == 0 then
		return false
	end
	local g, tg = group_of(list[from]), group_of(list[to])
	local item = table.remove(list, from)
	local at = from
	if g == tg then
		at = to
	else
		local first, last = 0, 0
		for i, other in list do
			if group_of(other) == g then
				if first == 0 then
					first = i
				end
				last = i
			end
		end
		if first > 0 then
			at = if tg > g then last + 1 else first
		end
	end
	table.insert(list, at, item)
	return at ~= from
end

-- Writes the new order through the safe path (re-read, apply by id, write), so another
-- writer's changes survive. A move that would change nothing writes nothing.
local function reorder(state: State, id: string, target: string): boolean
	local probe = table.clone(state.todos) :: { any }
	if not place(probe, id, target) then
		return false
	end
	return rewrite(state, function(list)
		place(list, id, target)
	end)
end

-- The neighbour `delta` places away in the same group, if there is one (a group's edge stops).
local function neighbour_in_group(state: State, t: Todo, delta: number): Todo?
	local other = ordered(state.todos, state.arch_open)[index_of(state) + delta]
	if other and group_of(other) == group_of(t) then
		return other
	end
	return nil
end

local function can_move(state: State, t: Todo, delta: number): boolean
	return neighbour_in_group(state, t, delta) ~= nil
end

-- Moves the selected task one place up (-1) or down (1) within its group.
local function step(state: State, delta: number)
	local t = selected(state)
	local other = if t then neighbour_in_group(state, t, delta) else nil
	if t and other then
		reorder(state, t.id, other.id)
	end
end

local TAP_MS = 450

-- True when this press repeats the previous one on the same target within TAP_MS.
local function repeated(state: State, key: string): boolean
	local now = tern.now()
	local last = state.tap
	state.tap = { key = key, at = now }
	return last ~= nil and last.key == key and now - last.at < TAP_MS
end

-- Paths -------------------------------------------------------------------

local function home_dir(): string
	local h = tern.getenv("HOME")
	return if h and h ~= "" then h else "/"
end

local function normalize(path: string): string
	local parts: { string } = {}
	for seg in string.gmatch(path, "[^/]+") do
		if seg == ".." then
			table.remove(parts)
		elseif seg ~= "." then
			table.insert(parts, seg)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function expand(text: string, base: string): string
	if text == "~" or string.sub(text, 1, 2) == "~/" then
		text = home_dir() .. string.sub(text, 2)
	end
	if string.sub(text, 1, 1) ~= "/" then
		text = base .. "/" .. text
	end
	return normalize(text)
end

local function basename(p: string): string
	return string.match(p, "([^/]+)/*$") or p
end

local function abbreviate(p: string): string
	local home = home_dir()
	if p == home then
		return "~"
	elseif home ~= "/" and string.sub(p, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(p, #home + 1)
	end
	return p
end

local function is_path_text(text: string): boolean
	local c = string.sub(text, 1, 1)
	return c == "/" or c == "~" or string.find(text, "/", 1, true) ~= nil or text == "." or text == ".."
end

-- omp ---------------------------------------------------------------------

-- The daemon has no shell PATH, so look omp up the way a login shell would.
local function omp_bin(): string
	local env = tern.getenv("OMP_BIN")
	if env and env ~= "" then
		return env
	end
	local home = home_dir()
	for _, c in { home .. "/.local/bin/omp", home .. "/.bun/bin/omp", "/opt/homebrew/bin/omp", "/usr/local/bin/omp" } do
		if tern.fs.exists(c) then
			return c
		end
	end
	return "omp"
end

local function sessions_root(): string
	return home_dir() .. "/.omp/agent/sessions"
end

-- omp's session bucket directory for a cwd (see omp docs, session.md "On-disk layout").
local function bucket_of(cwd: string): string
	local home = home_dir()
	if cwd == home then
		return "-"
	elseif home ~= "/" and string.sub(cwd, 1, #home + 1) == home .. "/" then
		return "-" .. (string.gsub(string.sub(cwd, #home + 2), "/", "-"))
	end
	return "--" .. (string.gsub(string.sub(cwd, 2), "/", "-")) .. "--"
end

type SessionFile = { mtime: number, path: string, dir: string, id: string }

-- Parses `stat -f '%m %N'` lines of session files, newest first.
local function parse_stat(stdout: string): { SessionFile }
	local files: { SessionFile } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local mtime, path = string.match(line, "^(%d+) (.+)$")
		if mtime and path then
			local dir = string.match(path, "([^/]+)/[^/]+$")
			local id = string.match(path, "_([^/_]+)%.jsonl$")
			if dir and id then
				table.insert(files, { mtime = tonumber(mtime) or 0, path = path, dir = dir, id = id })
			end
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	return files
end

local function untitled(timestamp: string): string
	local stamp = string.gsub(string.sub(timestamp, 1, 16), "T", " ")
	return "Untitled · " .. stamp
end

-- Lists recent sessions without a shell: one `find`+`stat` for every file's mtime, then one
-- `head -n 2` over the newest of them (title slot and header lines only, never whole files).
-- Files of the `cwd` bucket are preferred so a project's own chats are not pushed out.
local function scan_chats(state: State, cwd: string?)
	state.chats_token += 1
	local token = state.chats_token
	state.chats_loading = true
	local function finish(chats: { Chat }?)
		if alive(state) and state.chats_token == token then
			state.chats_loading = false
			if chats then
				state.chats = chats
			end
			state.cx:render()
		end
	end
	local ok = pcall(
		tern.process.run,
		{ "/usr/bin/find", sessions_root(), "-maxdepth", "2", "-name", "*.jsonl", "-exec", "/usr/bin/stat", "-f", "%m %N", "{}", "+" },
		{ timeout_ms = 8000 },
		function(found: ProcessResult, _)
			if not alive(state) or state.chats_token ~= token then
				return
			end
			local files = parse_stat(found.stdout)
			local bucket = if cwd then bucket_of(cwd) else nil
			local chosen: { SessionFile } = {}
			local mtimes: { [string]: number } = {}
			local near, far = 0, 0
			for _, f in files do
				if bucket and f.dir == bucket and near < 25 then
					near += 1
					table.insert(chosen, f)
				elseif far < 40 then
					far += 1
					table.insert(chosen, f)
				end
				mtimes[f.id] = f.mtime
			end
			if #chosen == 0 then
				finish({})
				return
			end
			local argv = { "/usr/bin/head", "-n", "2" }
			for _, f in chosen do
				table.insert(argv, f.path)
			end
			local hok = pcall(tern.process.run, argv, { timeout_ms = 8000 }, function(heads: ProcessResult, _)
				local chats: { Chat } = {}
				local slot_title = ""
				for line in string.gmatch(heads.stdout, "[^\n]+") do
					local dok, entry = pcall(tern.json.decode, line)
					if dok and type(entry) == "table" then
						if entry.type == "title" then
							slot_title = tostring(entry.title or "")
						elseif entry.type == "session" and type(entry.id) == "string" then
							local title = slot_title
							if title == "" then
								title = tostring(entry.title or "")
							end
							if title == "" then
								title = untitled(tostring(entry.timestamp or ""))
							end
							table.insert(chats, {
								id = entry.id,
								title = title,
								cwd = tostring(entry.cwd or ""),
								mtime = mtimes[entry.id] or 0,
							})
							slot_title = ""
						end
					end
				end
				table.sort(chats, function(a, b)
					return a.mtime > b.mtime
				end)
				finish(chats)
			end)
			if not hok then
				finish(nil)
			end
		end
	)
	if not ok then
		state.chats_loading = false
	end
end

-- Loads the model list once per block run (`omp models --json`, about a second).
local function load_models(state: State)
	if state.models or state.models_state == "loading" then
		return
	end
	state.models_state = "loading"
	local function fail(reason: string)
		state.models_state = "error"
		state.models_error = reason
		state.cx:render()
	end
	local ok, err = pcall(tern.process.run, { omp_bin(), "models", "--json" }, { timeout_ms = 20000 }, function(result: ProcessResult, _)
		if not alive(state) then
			return
		end
		if result.status ~= 0 then
			local first = string.match(result.stderr, "[^\n]+") or ("exit " .. result.status)
			fail("omp models failed: " .. first)
			return
		end
		local dok, data = pcall(tern.json.decode, result.stdout)
		if not dok or type(data) ~= "table" or type(data.models) ~= "table" then
			fail("omp models gave no JSON")
			return
		end
		local models: { Model } = {}
		for _, m in data.models do
			if type(m) == "table" and type(m.selector) == "string" then
				local efforts: { string } = {}
				if type(m.thinking) == "table" then
					for _, e in m.thinking do
						table.insert(efforts, tostring(e))
					end
				end
				local ctx = tonumber(m.contextWindow)
				table.insert(models, {
					selector = m.selector,
					id = tostring(m.id or m.selector),
					provider = tostring(m.provider or ""),
					reasoning = m.reasoning == true,
					efforts = efforts,
					context = if not ctx then "" elseif ctx >= 1000000 then string.format("%dM", math.floor(ctx / 1000000 + 0.5)) else string.format("%dK", ctx // 1000),
				})
			end
		end
		state.models = models
		state.models_state = "ready"
		state.cx:render()
	end)
	if not ok then
		fail("Cannot run omp: " .. tostring(err))
	end
end

-- Finds the id of the chat a freshly started omp creates: omp has no flag to choose a
-- session id, so look for a new file in the project's bucket every few seconds.
local function discover_session(state: State, task_id: string, cwd: string, since: number, attempt: number)
	if attempt > 12 then
		return
	end
	tern.timer(5000, function()
		if not alive(state) then
			return
		end
		local ok = pcall(
			tern.process.run,
			{ "/usr/bin/find", sessions_root() .. "/" .. bucket_of(cwd), "-maxdepth", "1", "-name", "*.jsonl", "-exec", "/usr/bin/stat", "-f", "%m %N", "{}", "+" },
			{ timeout_ms = 3000 },
			function(found: ProcessResult, _)
				if not alive(state) then
					return
				end
				local used: { [string]: boolean } = {}
				local target: Todo? = nil
				for _, t in state.todos do
					if t.links.omp_session then
						used[t.links.omp_session] = true
					end
					if t.id == task_id then
						target = t
					end
				end
				if not target or target.links.omp_session then
					return
				end
				for _, f in parse_stat(found.stdout) do
					if f.mtime >= since - 2 and not used[f.id] then
						patch(state, task_id, function(item)
							local links = if type(item.links) == "table" then item.links else {}
							links.omp_session = f.id
							item.links = links
						end)
						state.cx:render()
						return
					end
				end
				discover_session(state, task_id, cwd, since, attempt + 1)
			end
		)
		if not ok then
			discover_session(state, task_id, cwd, since, attempt + 1)
		end
	end)
end

local function pane_from(stdout: string): number?
	local ok, data = pcall(tern.json.decode, stdout)
	if ok and type(data) == "table" then
		for _, k in { "pane", "block", "id" } do
			local n = tonumber(data[k])
			if n then
				return n
			end
		end
	end
	return tonumber(string.match(stdout, "%d+"))
end

-- Opens a new Tern tab in the task's project running `argv` (one argv element each, no
-- shell) and links the new pane to the task.
local function launch(state: State, t: Todo, argv: { string }, find_session: boolean)
	if state.launching[t.id] then
		return
	end
	local cwd = t.links.cwd or state.cx.cwd or home_dir()
	local cmd = { TERN, "new", "tab", "--json", "--cwd", cwd, "--" }
	for _, a in argv do
		table.insert(cmd, a)
	end
	local since = os.time()
	local id = t.id
	state.launching[id] = true
	local ok, err = pcall(tern.process.run, cmd, { timeout_ms = 10000 }, function(result: ProcessResult, _)
		state.launching[id] = nil
		if result.status ~= 0 then
			local first = string.match(result.stderr, "[^\n]+") or ("exit " .. result.status)
			state.cx:toast("error", "tern new tab failed", first)
			return
		end
		local pane = pane_from(result.stdout)
		if not pane then
			state.cx:toast("error", "tern new tab gave no pane id", result.stdout)
			return
		end
		if not alive(state) then
			return
		end
		-- `tern new tab` leaves the new tab in the background: show it.
		pcall(tern.process.run, { TERN, "focus", tostring(pane) }, { timeout_ms = 5000 }, function(shown: ProcessResult, _)
			if shown.status ~= 0 then
				state.cx:toast("error", "tern focus failed", shown.stderr)
			end
		end)
		patch(state, id, function(item)
			local links = if type(item.links) == "table" then item.links else {}
			links.tern_pane = pane
			item.links = links
		end)
		state.launched[pane] = os.time()
		state.cx:render()
		if find_session then
			discover_session(state, id, cwd, since, 1)
		end
	end)
	if not ok then
		state.launching[id] = nil
		state.cx:toast("error", "Cannot run tern", tostring(err))
	end
end

local function live_pane_of(t: Todo): number?
	local pane = t.links.tern_pane
	if pane and live_panes()[pane] then
		return pane
	end
	return nil
end

-- What the primary button does for a task right now.
local function primary_label(t: Todo): string
	if live_pane_of(t) then
		return "Open pane"
	elseif t.links.omp_session then
		return "Open chat"
	end
	return "Start"
end

-- Done wins. A task without a live pane is a plain todo; stopped only describes
-- a live pane whose omp exited back to the shell.
local function status_of(state: State, t: Todo, live: { [number]: boolean }): string
	if t.done then
		return "done"
	end
	local pane = t.links.tern_pane
	if not pane then
		return "todo"
	end
	local key = tostring(pane)
	local dbg = state.debug_states[key]
	local word = dbg or state.agent_states[key]
	local kind = if word then KIND_OF_STATE[word] else nil
	local launched = state.launched[pane]
	local fresh = launched ~= nil and os.time() - (launched :: number) < STARTING_S
	if launched and not fresh then
		state.launched[pane] = nil
	end
	if not dbg then
		if not live[pane] then
			kind = if fresh then "starting" else "todo"
		elseif kind == nil and fresh then
			kind = "starting"
		end
	end
	kind = kind or (if t.links.omp_session then "stopped" else "todo")
	if kind ~= "running" then
		state.since[pane] = nil
	elseif not state.since[pane] then
		state.since[pane] = os.time()
	end
	return kind
end

-- The quiet line under a row's title for a task with an agent.
local function agent_line(state: State, t: Todo, kind: string): string?
	if kind == "running" then
		local pane = t.links.tern_pane
		local started = if pane then state.since[pane] else nil
		local secs = if started then os.time() - started else 0
		if secs >= 3600 then
			return string.format("Working · %dh %dm", secs // 3600, (secs % 3600) // 60)
		elseif secs >= 60 then
			return string.format("Working · %dm", secs // 60)
		end
		return "Working"
	elseif kind == "needs" then
		return "Needs you"
	elseif kind == "review" then
		return "Ready for you"
	elseif kind == "starting" then
		return "Starting…"
	elseif kind == "stopped" then
		return "Stopped"
	end
	return nil
end

-- Reads window.luau's states and the debug hook; returns whether anything changed.
local function update_states(state: State): boolean
	local states: { [string]: string } = {}
	local debug: { [string]: string } = {}
	local ok, raw = pcall(tern.kv.get, "states")
	if ok and type(raw) == "table" then
		for k, v in raw do
			if type(v) == "string" then
				states[tostring(k)] = v
			end
		end
	end
	local dok, draw = pcall(tern.kv.get, "todo-proto.debug_states")
	if dok and type(draw) == "table" then
		for k, v in draw do
			if type(v) == "string" then
				debug[tostring(k)] = v
			end
		end
	end
	local sig = tern.json.encode({ states, debug })
	if sig == state.states_sig then
		return false
	end
	state.states_sig = sig
	state.agent_states = states
	state.debug_states = debug
	return true
end

-- window.luau's `add-omp-session` command writes the file itself and bumps
-- kv "todo-proto.nudge" = { path, n }; reloading here shows the new task within a state tick.
-- A focused field keeps its text, so the nudge stays pending until the field is left.
local function nudge_n(state: State): number?
	local ok, v = pcall(tern.kv.get, "todo-proto.nudge")
	if ok and type(v) == "table" and v.path == state.path and type(v.n) == "number" then
		return v.n
	end
	return nil
end

local function reload_if_nudged(state: State): boolean
	local n = nudge_n(state)
	if n == nil or n == state.nudge_seen or state.focus ~= nil then
		return false
	end
	state.nudge_seen = n
	load(state)
	return true
end

-- Tells window.luau a todo block is watching, so it samples omp agents (see window.luau).
local function heartbeat()
	pcall(tern.kv.set, "watch", os.time())
end

-- Cycles the thinking level the way omp does: off, auto, then the model's efforts, then
-- back to Default (no flag).
local function cycle_level(state: State, t: Todo)
	local efforts = DEFAULT_EFFORTS
	local reasoning = true
	if t.agent.model then
		if state.models then
			for _, m in state.models do
				if m.selector == t.agent.model then
					reasoning = m.reasoning
					efforts = m.efforts
				end
			end
		else
			load_models(state)
		end
	end
	if not reasoning then
		state.cx:toast("info", "This model has no thinking levels")
		return
	end
	local levels: { string } = { "off", "auto" }
	for _, e in efforts do
		table.insert(levels, e)
	end
	local at = if t.agent.thinking then table.find(levels, t.agent.thinking) else 0
	local nextlevel = levels[(at or 0) + 1]
	if t.agent.thinking and not at then
		nextlevel = levels[1]
	end
	patch(state, t.id, function(item)
		local agent = if type(item.agent) == "table" then item.agent else {}
		agent.thinking = if nextlevel then nextlevel else tern.json.null
		item.agent = agent
	end)
end

-- Cycles the priority none -> low -> medium -> high -> urgent -> none.
local function cycle_priority(state: State, t: Todo)
	local at = table.find(PRIORITIES, t.priority) or 1
	local next_priority = PRIORITIES[at % #PRIORITIES + 1]
	patch(state, t.id, function(item)
		item.priority = next_priority
	end)
end

local function activate(state: State, t: Todo)
	local pane = live_pane_of(t)
	if pane then
		local ok, err = pcall(function()
			tern.process.run({ TERN, "focus", tostring(pane) }, { timeout_ms = 5000 }, function(result: ProcessResult, _)
				if result.status ~= 0 then
					state.cx:toast("error", "tern focus failed", result.stderr)
				end
			end)
		end)
		if not ok then
			state.cx:toast("error", "Cannot run tern", tostring(err))
		end
	elseif t.links.omp_session then
		launch(state, t, { omp_bin(), "--resume", t.links.omp_session }, false)
	else
		local argv = { omp_bin() }
		if t.agent.model then
			table.insert(argv, "--model")
			table.insert(argv, t.agent.model)
		end
		if t.agent.thinking then
			table.insert(argv, "--thinking")
			table.insert(argv, t.agent.thinking)
		end
		local prompt = t.title
		if t.notes ~= "" then
			prompt ..= "\n\n" .. t.notes
		end
		-- omp reads a leading "-" as a flag and "@" as a file attachment.
		local first = string.sub(prompt, 1, 1)
		if first == "-" or first == "@" then
			prompt = "Task: " .. prompt
		end
		table.insert(argv, prompt)
		launch(state, t, argv, true)
	end
end

local function refresh(state: State)
	if not alive(state) then
		return
	end
	load(state)
end

-- A field being edited owns its text: the timer leaves the file alone then.
local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	heartbeat()
	state.timer = tern.timer(POLL_MS, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		heartbeat()
		if state.focus == nil then
			refresh(state)
			state.cx:render()
		end
		poll(state)
	end)
end

local STATE_MS = 2000

-- Samples window.luau's omp states every STATE_MS; renders only when they changed.
local function poll_states(state: State)
	if not alive(state) or state.st_timer then
		return
	end
	state.st_timer = tern.timer(STATE_MS, function()
		if not alive(state) then
			return
		end
		state.st_timer = nil
		local changed = update_states(state)
		if reload_if_nudged(state) then
			changed = true
		end
		if changed or next(state.launched) ~= nil then
			state.cx:render()
		end
		poll_states(state)
	end)
end

-- Text fields -----------------------------------------------------------

local function chars_of(s: string): { string }
	local out: { string } = {}
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(cp))
	end
	return out
end

local function length_of(s: string): number
	return utf8.len(s) or #s
end

-- Tern counts offsets in UTF-16 code units: the units before the first `cur` characters.
local function utf16_offset(s: string, cur: number): number
	local n, i = 0, 0
	for _, cp in utf8.codes(s) do
		if i >= cur then
			break
		end
		n += if cp > 0xFFFF then 2 else 1
		i += 1
	end
	return n
end

-- The number of characters that fit in the first `off` UTF-16 units (an offset inside a
-- surrogate pair rounds down, as Tern does).
local function char_index(s: string, off: number): number
	local units, n = 0, 0
	for _, cp in utf8.codes(s) do
		local w = if cp > 0xFFFF then 2 else 1
		if units + w > off then
			break
		end
		units += w
		n += 1
	end
	return n
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function line_start(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and chars[i] ~= "\n" do
		i -= 1
	end
	return i
end

local function line_end(chars: { string }, from: number): number
	local i = from
	while i < #chars and chars[i + 1] ~= "\n" do
		i += 1
	end
	return i
end

-- Letters, digits and everything non-ASCII (Cyrillic, emoji) belong to words.
local function is_word(c: string): boolean
	return #c > 1 or string.find(c, "^[%w_]$") ~= nil
end

local function word_left(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and not is_word(chars[i]) do
		i -= 1
	end
	while i > 0 and is_word(chars[i]) do
		i -= 1
	end
	return i
end

local function word_right(chars: { string }, cur: number): number
	local n, i = #chars, cur
	while i < n and not is_word(chars[i + 1]) do
		i += 1
	end
	while i < n and is_word(chars[i + 1]) do
		i += 1
	end
	return i
end

-- A field's text, caret and selection anchor (both counted in characters), with its own
-- undo history: Tern's undo event carries no state, so each field keeps its steps. `max` is a
-- limit in UTF-16 units.
type Snap = { text: string, cur: number }
type Field = {
	text: string,
	cur: number,
	anchor: number?,
	undo: { Snap },
	redo: { Snap },
	-- The last change was typing, so the next typed character joins its undo step.
	typing: boolean,
	multiline: boolean,
	max: number?,
}

local HISTORY = 200

local function reset_field(f: Field, text: string)
	f.text, f.cur, f.anchor = text, length_of(text), nil
	f.undo, f.redo, f.typing = {}, {}, false
end

local function new_field(text: string, multiline: boolean, max: number?): Field
	local f: Field = { text = "", cur = 0, anchor = nil, undo = {}, redo = {}, typing = false, multiline = multiline, max = max }
	reset_field(f, text)
	return f
end

-- Single-line fields take pasted line breaks as spaces.
local function tidy(f: Field, s: string): string
	if f.multiline then
		return (string.gsub(s, "\r\n?", "\n"))
	end
	return (string.gsub(s, "[\r\n]+", " "))
end

-- Ordered selection bounds; equal when nothing is selected.
local function bounds(f: Field): (number, number)
	local a = f.anchor
	if a == nil or a == f.cur then
		return f.cur, f.cur
	end
	return math.min(a, f.cur), math.max(a, f.cur)
end

-- Replaces characters [from, to) by `ins`, the caret after them. One undo step; typing
-- joins the open one. Returns whether the text changed.
local function replace(f: Field, from: number, to: number, ins: { string }, typing: boolean): boolean
	local chars = chars_of(f.text)
	local head = table.concat(chars, "", 1, from)
	local tail = table.concat(chars, "", to + 1)
	local max = f.max
	if max then
		while #ins > 0 and utf16_offset(head .. table.concat(ins) .. tail, math.huge) > max do
			table.remove(ins)
		end
	end
	local text = head .. table.concat(ins) .. tail
	if text == f.text then
		return false
	end
	if not (typing and f.typing) then
		table.insert(f.undo, { text = f.text, cur = f.cur })
		if #f.undo > HISTORY then
			table.remove(f.undo, 1)
		end
	end
	f.redo = {}
	f.typing = typing
	f.text, f.cur, f.anchor = text, from + #ins, nil
	return true
end

-- Steps back (redo = false) or forward through the field's history.
local function undo_step(f: Field, redo: boolean): boolean
	local from = if redo then f.redo else f.undo
	local snap = table.remove(from)
	if not snap then
		return false
	end
	table.insert(if redo then f.undo else f.redo, { text = f.text, cur = f.cur })
	f.text, f.cur, f.anchor, f.typing = snap.text, snap.cur, nil, false
	return true
end

-- Applies Tern's `edit` event: replace UTF-16 [from, to) by `text`, caret at `cursor`.
-- Returns "text", "caret", or nil when the event is stale (its `len` is not our text's).
local function apply_edit(f: Field, ev: UiEvent): string?
	if tonumber(ev.len) ~= utf16_offset(f.text, math.huge) then
		return nil
	end
	local from = char_index(f.text, tonumber(ev.from) or 0)
	local to = char_index(f.text, tonumber(ev.to) or 0)
	local ins = chars_of(tidy(f, if type(ev.text) == "string" then ev.text else ""))
	local changed = replace(f, from, to, ins, false)
	f.cur = char_index(f.text, tonumber(ev.cursor) or 0)
	f.anchor, f.typing = nil, false
	return if changed then "text" else "caret"
end

-- Applies a key to a field. Returns "text" (changed), "caret" (moved or selected), "submit"
-- (Enter in a single-line field), "blur" (Esc or Tab), or nil (the key is not for the field).
-- Tern turns keys that act on its own selection into `edit` events, so this sees the rest:
-- typing and deletes without a selection, word and line moves, ctrl+a, redo, and every
-- key on a selection the block drew itself.
local function edit_key(f: Field, key: Key, cx: BlockCx): string?
	local chars = chars_of(f.text)
	local n = #chars
	f.cur = math.clamp(f.cur, 0, n)
	local lo, hi = bounds(f)
	local name = key.name
	local mod = key.ctrl or key.meta
	local function remove(from: number, to: number): string
		return if replace(f, from, to, {}, false) then "text" else "caret"
	end
	local function go(to: number): string
		to = math.clamp(to, 0, n)
		if key.shift then
			f.anchor = f.anchor or f.cur
		else
			f.anchor = nil
		end
		f.cur, f.typing = to, false
		return "caret"
	end
	if name == "escape" or name == "tab" then
		return "blur"
	elseif name == "enter" then
		if not f.multiline then
			return "submit"
		end
		return if replace(f, lo, hi, { "\n" }, false) then "text" else "caret"
	elseif mod and not key.alt and name == "a" and not key.shift then
		-- cmd+a is Tern's own on a non-empty field; ctrl+a is the select-all the user asked
		-- for (it is not readline's line start here).
		f.anchor, f.cur, f.typing = 0, n, false
		return "caret"
	elseif mod and not key.alt and name == "z" then
		return if undo_step(f, key.shift) then "text" else nil
	elseif key.ctrl and name == "y" then
		return if undo_step(f, true) then "text" else nil
	elseif mod and (name == "c" or name == "x") and lo ~= hi then
		cx:copy(table.concat(chars, "", lo + 1, hi))
		return if name == "x" then remove(lo, hi) else "caret"
	elseif name == "backspace" or (key.ctrl and (name == "u" or name == "w")) then
		if lo ~= hi then
			return remove(lo, hi)
		end
		-- cmd+backspace reaches the program as ctrl+u; ctrl+w and option+backspace delete a word.
		local to = f.cur - 1
		if key.meta or name == "u" then
			to = line_start(chars, f.cur)
			if to == f.cur then
				to = f.cur - 1
			end
		elseif key.alt or name == "w" then
			to = word_left(chars, f.cur)
		end
		return remove(math.max(0, to), f.cur)
	elseif name == "delete" or (key.ctrl and name == "k") then
		if lo ~= hi then
			return remove(lo, hi)
		end
		local to = f.cur + 1
		if key.meta or name == "k" then
			to = line_end(chars, f.cur)
			if to == f.cur then
				to = f.cur + 1
			end
		elseif key.alt then
			to = word_right(chars, f.cur)
		end
		return remove(f.cur, math.min(n, to))
	elseif name == "left" or (key.alt and name == "b") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(lo)
		end
		if key.alt then
			return go(word_left(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_start(chars, f.cur) else 0)
		end
		return go(f.cur - 1)
	elseif name == "right" or (key.alt and name == "f") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(hi)
		end
		if key.alt then
			return go(word_right(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_end(chars, f.cur) else n)
		end
		return go(f.cur + 1)
	elseif name == "home" then
		return go(if f.multiline and not mod then line_start(chars, f.cur) else 0)
	elseif name == "end" then
		return go(if f.multiline and not mod then line_end(chars, f.cur) else n)
	elseif key.ctrl and not key.alt and not key.meta and name == "e" then
		return go(if f.multiline then line_end(chars, f.cur) else n)
	elseif name == "up" then
		return go(0)
	elseif name == "down" then
		return go(n)
	end
	local typed = key.text
	if name == "space" and not typed then
		typed = " "
	end
	if name == "paste" or (typed and typed ~= "" and not (key.ctrl or key.alt or key.meta)) then
		local ins = chars_of(tidy(f, typed or ""))
		return if replace(f, lo, hi, ins, name ~= "paste") then "text" else "caret"
	end
	return nil
end

local function set_focus(state: State, field: string?)
	local t = selected(state)
	if state.focus == "title" and field ~= "title" then
		-- Leaving the title commits it; a title left empty is rejected and the old one restored.
		local id = state.title_id
		state.title_id = nil
		if id and trim(state.title.text) == "" then
			for _, todo in state.todos do
				if todo.id == id and todo.title ~= state.title_orig then
					patch(state, id, function(item)
						item.title = state.title_orig
					end)
				end
			end
		end
	end
	if field == "notes" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "notes" then
			reset_field(state.notes, t.notes)
		end
	elseif field == "title" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "title" then
			reset_field(state.title, t.title)
			state.title_id, state.title_orig = t.id, t.title
		end
	end
	state.focus = field
	local id: any = tern.json.null
	if field == "add" then
		id = "main.ws.left.add.field"
	elseif field == "notes" then
		id = "main.ws.detail.notes"
	elseif field == "title" then
		id = "main.ws.detail.head.title"
	elseif field == "picker" and state.pick and SEARCH[state.pick.kind] then
		id = "layer.q"
	end
	state.cx:frame({ { "focus", id } })
end

-- Writes the title being typed to the file as it changes; an empty draft is not written
-- (the commit on leaving restores the old title).
local function save_title(state: State)
	local id = state.title_id
	local title = trim(state.title.text)
	if not id or title == "" then
		return
	end
	for _, todo in state.todos do
		if todo.id == id and todo.title ~= title then
			patch(state, id, function(item)
				item.title = title
			end)
		end
	end
end

-- Esc: puts the title back as it was and leaves the field.
local function cancel_title(state: State)
	reset_field(state.title, state.title_orig)
	local id = state.title_id
	for _, todo in state.todos do
		if todo.id == id and todo.title ~= state.title_orig then
			patch(state, todo.id, function(item)
				item.title = state.title_orig
			end)
		end
	end
	set_focus(state, nil)
end

-- Rename: focuses the title with its whole text selected, as Synara's inline rename does.
local function begin_rename(state: State)
	if not selected(state) then
		return
	end
	set_focus(state, "title")
	local f = state.title
	if #f.text > 0 then
		f.anchor, f.cur = 0, length_of(f.text)
	end
end

-- The field a Tern edit/undo event belongs to, when that field is the focused one.
local function field_of(state: State, id: string): Field?
	local tail = string.match(id, "%.(%w+)$")
	if tail == "field" and state.focus == "add" then
		return state.add
	elseif tail == "notes" and state.focus == "notes" then
		return state.notes
	elseif tail == "title" and state.focus == "title" then
		return state.title
	elseif tail == "q" and state.focus == "picker" and state.pick then
		return state.pick.q
	end
	return nil
end

-- Writes what a changed field holds: the detail fields go to the file, a popover's search
-- resets the highlighted row.
local function field_changed(state: State)
	local t = selected(state)
	if state.focus == "title" then
		save_title(state)
	elseif state.focus == "notes" and t then
		patch(state, t.id, function(item)
			item.notes = state.notes.text
		end)
	elseif state.focus == "picker" and state.pick then
		state.pick.sel = 0
		state.pick.hint = nil
	end
end

-- Popovers -----------------------------------------------------------------

type PickItem = {
	kind: string, -- "none" (the default/clear row), "opt", "dir" or "complete"
	path: string?, -- the value the row stores (a directory, model selector, level, ...)
	name: string,
	hint: string?,
	group: string?,
	current: boolean,
}

local function pick_base(state: State): string
	local t = selected(state)
	return (t and t.links.cwd) or state.cx.cwd or home_dir()
end

-- Directory to list for the typed path and the name prefix to filter by.
local function listing_target(text: string, base: string): (string, string)
	local full = expand(text, base)
	if string.sub(text, -1) == "/" or text == "~" or text == "." or text == ".." then
		return full, ""
	end
	return normalize(full .. "/.."), basename(full)
end

-- The typed text up to and including the last "/", where a completion goes.
local function completion_base(text: string): string
	if string.sub(text, -1) == "/" then
		return text
	elseif text == "~" or text == "." or text == ".." then
		return text .. "/"
	end
	return string.match(text, "^(.*/)") or ""
end

local function is_dir(p: string): boolean
	return (pcall(tern.fs.list, p))
end

-- Starts `ls` for the typed path's directory unless that listing is cached or in flight.
local function request_listing(state: State)
	local pk = state.pick
	if not pk or pk.kind ~= "project" then
		return
	end
	if not is_path_text(pk.q.text) then
		pk.want = nil
		return
	end
	local dir = listing_target(pk.q.text, pick_base(state))
	if pk.dir == dir or pk.want == dir then
		return
	end
	pk.want = dir
	tern.process.run({ "/bin/ls", "-1ALp", dir }, { timeout_ms = 3000 }, function(result: ProcessResult, _)
		local cur = state.pick
		if not cur or cur.want ~= dir then
			return
		end
		cur.want = nil
		local names: { string } = {}
		for line in string.gmatch(result.stdout, "[^\n]+") do
			if string.sub(line, -1) == "/" and line ~= ".git/" then
				table.insert(names, string.sub(line, 1, -2))
			end
		end
		table.sort(names, function(a, b)
			return string.lower(a) < string.lower(b)
		end)
		cur.dir = dir
		cur.names = names
		cur.missing = result.status ~= 0 and result.stdout == ""
		state.cx:render()
	end)
end

local function contains(haystack: string, filter: string): boolean
	return string.find(string.lower(haystack), filter, 1, true) ~= nil
end

local function project_items(state: State, pk: Pick, t: Todo): ({ PickItem }, string?)
	local items: { PickItem } = {}
	local current = t.links.cwd
	if is_path_text(pk.q.text) then
		local dir, prefix = listing_target(pk.q.text, pick_base(state))
		if pk.dir ~= dir then
			return items, "Loading…"
		end
		if pk.missing then
			return items, "No such directory"
		end
		local lowered = string.lower(prefix)
		for _, name in pk.names do
			if string.sub(string.lower(name), 1, #lowered) == lowered then
				local full = if dir == "/" then "/" .. name else dir .. "/" .. name
				table.insert(items, { kind = "complete", path = full, name = name, current = full == current })
			end
		end
		return items, if #items == 0 then "No sub-directories" else nil
	end
	local filter = string.lower(pk.q.text)
	if filter == "" then
		table.insert(items, { kind = "none", name = "No project", current = current == nil })
	end
	local seen: { [string]: boolean } = {}
	local function add(path: string, group: string)
		path = if path == "/" then path else string.gsub(path, "/+$", "")
		if seen[path] then
			return
		end
		seen[path] = true
		local name = basename(path)
		if filter ~= "" and not contains(name, filter) and not contains(path, filter) then
			return
		end
		table.insert(items, {
			kind = "dir",
			path = path,
			name = name,
			hint = abbreviate(normalize(path .. "/..")),
			group = group,
			current = path == current,
		})
	end
	for _, p in tern.pane.list() do
		if p.cwd and p.cwd ~= "" then
			add(p.cwd, "Open panes")
		end
	end
	for _, other in state.todos do
		if other.links.cwd then
			add(other.links.cwd, "Used in tasks")
		end
	end
	return items, if #items == 0 then "No matching projects" else nil
end

-- Rows of the open popover and a status line shown when there are none.
local function picker_items(state: State): ({ PickItem }, string?)
	local pk = state.pick
	local items: { PickItem } = {}
	local t = selected(state)
	if not pk or not t then
		return items, nil, 0
	end
	local filter = string.lower(pk.q.text)
	local status: string? = nil
	if pk.kind == "project" then
		return project_items(state, pk, t)
	elseif pk.kind == "model" then
		if filter == "" then
			table.insert(items, { kind = "none", name = "Default model", current = t.agent.model == nil })
		end
		if not state.models then
			status = if state.models_state == "error" then state.models_error else "Loading models…"
		else
			for _, m in state.models do
				if filter == "" or contains(m.selector, filter) then
					table.insert(items, {
						kind = "opt",
						path = m.selector,
						name = m.selector,
						hint = m.context,
						current = m.selector == t.agent.model,
					})
				end
			end
			if #items == 0 then
				status = "No matching models"
			end
		end
	elseif pk.kind == "chat" then
		if filter == "" then
			table.insert(items, { kind = "none", name = "New chat", current = t.links.omp_session == nil })
		end
		local chats = state.chats
		if not chats then
			status = if state.chats_loading then "Loading chats…" else "No chats found"
		else
			local base = t.links.cwd
			local matched = 0
			for pass = 1, 2 do
				for _, c in chats do
					if (pass == 1) == (base ~= nil and c.cwd == base) then
						if filter == "" or contains(c.title, filter) or contains(c.cwd, filter) then
							matched += 1
							table.insert(items, {
								kind = "opt",
								path = c.id,
								name = c.title,
								hint = basename(c.cwd),
								group = "Recent chats",
								current = c.id == t.links.omp_session,
							})
						end
					end
				end
			end
			if matched == 0 then
				status = if state.chats_loading then "Loading chats…" else "No matching chats"
			end
		end
	end
	return items, status
end

local function close_picker(state: State)
	state.pick = nil
	set_focus(state, nil)
end

local function open_picker(state: State, kind: string)
	local t = selected(state)
	if not t then
		return
	end
	state.detail_open = true
	state.pick = {
		kind = kind,
		task = t.id,
		q = new_field("", false, nil),
		sel = 0,
		dir = nil,
		names = {},
		missing = false,
		want = nil,
		hint = nil,
	}
	if kind == "model" then
		load_models(state)
	elseif kind == "chat" then
		scan_chats(state, t.links.cwd)
	end
	local initial = picker_items(state)
	for i, it in initial do
		if it.current then
			state.pick.sel = i
			break
		end
	end
	set_focus(state, "picker")
end

-- Stores the picked value (nil = the default/cleared value), writes the file and closes the popover.
local function apply_pick(state: State, kind: string, value: string?)
	local pk = state.pick
	close_picker(state)
	if not pk then
		return
	end
	patch(state, pk.task, function(item)
		local null = tern.json.null
		if kind == "project" or kind == "chat" then
			local links = if type(item.links) == "table" then item.links else {}
			links[if kind == "project" then "cwd" else "omp_session"] = if value then value else null
			item.links = links
		elseif kind == "priority" then
			item.priority = value or "none"
		else
			local agent = if type(item.agent) == "table" then item.agent else {}
			agent[if kind == "model" then "model" else "thinking"] = if value then value else null
			item.agent = agent
		end
	end)
end

local function picker_key(state: State, key: Key): boolean
	local pk = state.pick
	if not pk then
		set_focus(state, nil)
		return true
	end
	local items = picker_items(state)
	local name = key.name
	local searchable = SEARCH[pk.kind] ~= nil
	if name == "escape" then
		close_picker(state)
	elseif name == "up" or name == "down" or name == "page_up" or name == "page_down" or name == "home" or name == "end" then
		local step = if name == "up" then -1 elseif name == "down" then 1 elseif name == "page_up" then -PAGE_ROWS else PAGE_ROWS
		if name == "home" then
			pk.sel = math.min(1, #items)
		elseif name == "end" then
			pk.sel = #items
		else
			pk.sel = math.clamp(pk.sel + step, if name == "up" then 0 else math.min(1, #items), #items)
		end
		pk.hint = nil
	elseif name == "tab" then
		local it = items[if pk.sel > 0 then pk.sel else 1]
		if pk.kind == "project" and is_path_text(pk.q.text) and it and it.kind == "complete" then
			reset_field(pk.q, completion_base(pk.q.text) .. it.name .. "/")
			pk.sel = 0
			pk.hint = nil
			request_listing(state)
		end
	elseif name == "enter" then
		local it = items[pk.sel]
		local typed_path = pk.kind == "project" and is_path_text(pk.q.text)
		if not it and searchable and not typed_path then
			for _, candidate in items do
				if candidate.kind ~= "none" then
					it = candidate
					break
				end
			end
		end
		if it then
			apply_pick(state, pk.kind, if it.kind == "none" then nil else it.path)
		elseif typed_path then
			local target = expand(pk.q.text, pick_base(state))
			if is_dir(target) then
				apply_pick(state, "project", target)
			else
				pk.hint = "Not a directory"
			end
		end
	elseif searchable then
		local what = edit_key(pk.q, key, state.cx)
		if what == nil then
			return false
		end
		if what == "text" then
			pk.sel = 0
			pk.hint = nil
		end
		request_listing(state)
	end
	return true
end

local function field_key(state: State, key: Key): boolean
	if state.focus == "picker" then
		return picker_key(state, key)
	end
	if state.focus == "add" then
		local what = edit_key(state.add, key, state.cx)
		if what == nil then
			return false
		elseif what == "blur" then
			set_focus(state, nil)
		elseif what == "submit" then
			local title = trim(state.add.text)
			if title ~= "" then
				add_task(state, title)
				reset_field(state.add, "")
			end
		end
		return true
	end
	if not selected(state) then
		set_focus(state, nil)
		return true
	end
	local f = if state.focus == "title" then state.title else state.notes
	local what = edit_key(f, key, state.cx)
	if what == nil then
		return false
	elseif state.focus == "title" and key.name == "escape" then
		cancel_title(state)
	elseif what == "blur" or what == "submit" then
		set_focus(state, nil)
	elseif what == "text" then
		field_changed(state)
	end
	return true
end

-- View ------------------------------------------------------------------

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

-- A text field node whose text, caret and selection come from `f` while it is being
-- edited, else from `idle` with the caret at its end.
local function field_node(kind: string, props: { [string]: any }, f: Field?, idle: string): Node
	if f then
		props.text = f.text
		props.cursor = utf16_offset(f.text, f.cur)
		if f.anchor and f.anchor ~= f.cur then
			props.anchor = utf16_offset(f.text, f.anchor)
		end
	else
		props.text = idle
		props.cursor = utf16_offset(idle, math.huge)
	end
	return ui.node(kind, props)
end

local function open_count(state: State): number
	local open = 0
	for _, t in state.todos do
		if not t.done and not t.archived then
			open += 1
		end
	end
	return open
end

local function archived_count(state: State): number
	local n = 0
	for _, t in state.todos do
		if t.archived then
			n += 1
		end
	end
	return n
end

local function badges(t: Todo, live: { [number]: boolean }): { Node }
	local out: { Node } = {}
	if t.priority ~= "none" then
		table.insert(out, el("span", "badge", "prio", { text = PRIORITY_LABEL[t.priority], tone = PRIORITY_TONE[t.priority] }))
	end
	local pane = t.links.tern_pane
	if pane and live[pane] == true then
		table.insert(out, el("span", "badge", "pane", { text = "pane", tone = "success" }))
	end
	if t.links.omp_session then
		table.insert(out, el("span", "badge", "omp", { text = "omp", tone = "accent" }))
	end
	return out
end

local function row_view(state: State, t: Todo, live: { [number]: boolean }, lifted: Todo?, pos: { [string]: number }): Node
	local picked = t.id == state.cursor
	local kind = status_of(state, t, live)
	local glyph = el("button", "check", "check", {
		attrs = { ["data-status"] = kind },
		aria = STATUS_LABEL[kind] or (if t.done then "Mark as not done" else "Mark as done"),
		actions = { click = "glyph=" .. t.id, dblclick = "tap=" .. t.id },
	})
	local text: { Node } = { el("div", "title", "title", { text = t.title }) }
	-- Status line and badges share one wrapping line under the title, so nothing can
	-- overflow the row however narrow the block is.
	local meta: { Node } = {}
	local line = agent_line(state, t, kind)
	if line then
		table.insert(meta, el("div", "agent-line", "line", { text = line, attrs = { ["data-kind"] = kind } }))
	end
	for _, badge in badges(t, live) do
		table.insert(meta, badge)
	end
	if #meta > 0 then
		table.insert(text, el("div", "meta", "meta", nil, meta))
	end
	-- While a task is picked up: it carries the accent bar (mark = pick); rows of its own group
	-- show a drop line above (they sit earlier) or below (later) on hover; rows of another
	-- group are dimmed (mark = drop) because a drop there only moves it to its group's edge.
	local drop = "off"
	local mark: string? = nil
	local tip: string? = nil
	if lifted then
		if t.id == lifted.id then
			mark = "pick"
			tip = "Click to put it down where it was"
		elseif group_of(t) == group_of(lifted) then
			drop = if (pos[t.id] or 0) < (pos[lifted.id] or 0) then "before" else "after"
			tip = "Move here"
		else
			drop = "edge"
			mark = "drop"
			tip = if group_of(t) > group_of(lifted) then "Move to the end of its group" else "Move to the start of its group"
		end
	end
	local grip = el("button", "grip", "grip", {
		aria = "Move",
		title = if lifted and t.id == lifted.id then "Cancel move" else "Pick up to move, then click where it goes",
		attrs = { ["data-active"] = if lifted and t.id == lifted.id then "true" else "false" },
		actions = { click = "lift=" .. t.id, dblclick = "tap=" .. t.id },
	})
	return el("div", "row", t.id, {
		attrs = {
			["data-state"] = if picked then "selected" else "idle",
			["data-done"] = if t.done then "true" else "false",
			["data-archived"] = if t.archived then "true" else "false",
			["data-drop"] = drop,
		},
		mark = mark,
		title = tip,
		actions = { click = "sel=" .. t.id, dblclick = "open=" .. t.id },
	}, { glyph, el("div", "rowtext", "text", nil, text), grip })
end

local function left_view(state: State): Node
	local open = open_count(state)
	local archived = archived_count(state)
	local subtitle = if #state.todos == 0
		then "No tasks yet"
		elseif open > 0 then open .. " open"
		elseif #state.todos == archived then "All archived"
		else "All done"
	local head = el("div", "head", "head", nil, {
		el("div", "heading", "heading", { text = "Tasks" }),
		el("div", "subtitle", "subtitle", { text = subtitle }),
	})
	local input = field_node("input", {
		key = "field",
		role = ROLE .. "input",
		placeholder = "Add a task",
	}, state.add, "")
	local add = el("div", "add", "add", nil, {
		el("span", "add-circle", "circle"),
		input,
	})
	local live = live_panes()
	local pos: { [string]: number } = {}
	for i, t in ordered(state.todos, true) do
		pos[t.id] = i
	end
	local lifted: Todo? = nil
	for _, t in state.todos do
		if t.id == state.lift then
			lifted = t
		end
	end
	local rows: { Node } = {}
	for _, t in ordered(state.todos, false) do
		table.insert(rows, row_view(state, t, live, lifted, pos))
	end
	if archived > 0 then
		table.insert(rows, el("button", "arch-head", "arch", {
			text = "Archived (" .. archived .. ")",
			attrs = { ["data-open"] = if state.arch_open then "true" else "false" },
			actions = { click = "arch" },
		}))
		if state.arch_open then
			for _, t in state.todos do
				if t.archived then
					table.insert(rows, row_view(state, t, live, lifted, pos))
				end
			end
		end
	end
	return el("div", "left", "left", nil, {
		head,
		add,
		el("div", "rows", "rows", { attrs = { ["data-lift"] = if lifted then "on" else "off" } }, rows),
	})
end

-- The popover is Tern's own picker sheet (the one omp's model and session pickers use): it
-- sits in the block's layer, centred and sized to the block, so it cannot be clipped at the
-- block's edges, and it virtualizes and scrolls its rows itself (wheel included).
local PICK_TITLE: { [string]: string } = { project = "Project", model = "Model", chat = "Chat" }
local PICK_NOUN: { [string]: string } = { project = "projects", model = "models", chat = "chats" }

local function picker_node(state: State): Node?
	local pk = state.pick
	if not pk then
		return nil
	end
	local list, status = picker_items(state)
	local items: { any } = {}
	local order: { any } = {}
	local current: { string } = {}
	local group: string? = nil
	for i, it in list do
		if it.kind ~= "none" and it.group and it.group ~= group then
			group = it.group
			table.insert(order, { group = it.group, label = it.group })
		end
		local id = "i" .. i
		table.insert(items, {
			id = id,
			label = if it.kind == "complete" then it.name .. "/" else it.name,
			detail = it.hint,
			mono = pk.kind == "model" and it.kind == "opt",
		})
		table.insert(order, id)
		if it.current then
			table.insert(current, id)
		end
	end
	-- The count reads "shown of total" only while filtering; unfiltered lists also hold the
	-- default/clear row, which is not part of the catalog.
	local total: number? = nil
	if pk.q.text ~= "" and pk.kind == "model" and state.models then
		total = #state.models
	elseif pk.q.text ~= "" and pk.kind == "chat" and state.chats then
		total = #state.chats
	end
	local failure = pk.hint or (if pk.kind == "model" and state.models_state == "error" then state.models_error else nil)
	local props: { [string]: any } = {
		key = "pick",
		role = ROLE .. "pick",
		size = "md",
		title = PICK_TITLE[pk.kind],
		noun = PICK_NOUN[pk.kind],
		placeholder = SEARCH[pk.kind],
		query = pk.q.text,
		cursor = utf16_offset(pk.q.text, pk.q.cur),
		-- The search line is a native input in the layer (see pick_input); this one is hidden.
		items = items,
		order = order,
		current = current,
		selected = if pk.sel > 0 then "i" .. pk.sel else nil,
		total = total,
		empty = status,
		actions = {
			{ id = "pick-close", label = "Cancel", keys = { "esc" } },
			{ id = "pick-use", label = "Choose", keys = { "enter" }, primary = true },
		},
	}
	if failure then
		props.state = "error"
		props.message = failure
	elseif status and string.sub(status, 1, 7) == "Loading" then
		props.state = "loading"
	end
	return ui.node("picker", props)
end

-- The picker sheet draws its search line but cannot edit or select in it, so the layer
-- carries a native input placed over that line (styles.css); all three popovers search.
local function pick_input(state: State): Node
	local pk = state.pick :: Pick
	return field_node("input", {
		key = "q",
		role = ROLE .. "pickq",
		placeholder = SEARCH[pk.kind],
		aria = "Search",
	}, pk.q, "")
end

-- A pill button that opens the `kind` popover.
local function pill_box(state: State, kind: string, key: string, text: string, tone: string?, icon: string?): Node
	local open = state.pick ~= nil and state.pick.kind == kind
	return el("button", "pillbtn", key, {
		text = text,
		tone = tone,
		attrs = { ["data-icon"] = icon or "none", ["data-open"] = if open then "true" else "false" },
		actions = { click = "pick=" .. kind },
	})
end

-- A pill that acts on click (priority, level), with a glyph on the left and no chevron.
local function click_pill(key: string, text: string, tone: string?, icon: string, act: string): Node
	return el("button", "pillbtn", key, {
		text = text,
		tone = tone,
		attrs = { ["data-icon"] = icon, ["data-chev"] = "no", ["data-open"] = "false" },
		actions = { click = act },
	})
end

-- omp's own thinking-level symbols (nerd preset, packages/tui/src/theme/symbols.ts) and
-- the status line's "auto" marker; the hue per level is set in styles.css by data-level.
local LEVEL_GLYPH: { [string]: string } = {
	off = "\u{F05E}",
	minimal = "\u{F0A9E}",
	low = "\u{F0A9F}",
	medium = "\u{F0AA1}",
	high = "\u{F0AA3}",
	xhigh = "\u{F0AA5}",
	max = "\u{F06D}",
	auto = "\u{F074}",
}

local function level_pill(level: string?): Node
	local kids: { Node } = {}
	local glyph = if level then LEVEL_GLYPH[level] else nil
	if glyph then
		table.insert(kids, el("span", "level-ic", "ic", { text = glyph }))
	end
	table.insert(kids, el("span", "level-name", "name", { text = if level then LEVEL_LABEL[level] or level else "Default" }))
	return el("button", "pillbtn", "level", {
		attrs = { ["data-icon"] = "level", ["data-level"] = level or "default", ["data-chev"] = "no", ["data-open"] = "false" },
		actions = { click = "level" },
	}, kids)
end

local function chat_title(state: State, t: Todo): string
	local id = t.links.omp_session
	if not id then
		return "New chat"
	end
	for _, c in state.chats or {} do
		if c.id == id then
			return c.title
		end
	end
	return "Chat " .. string.sub(id, 1, 8)
end

local function detail_view(state: State, t: Todo): Node
	local notes = field_node("editor", {
		key = "notes",
		role = ROLE .. "notes",
		placeholder = "Add notes",
	}, if state.focus == "notes" then state.notes else nil, t.notes)
	local icons = el("div", "icons", "icons", nil, {
		click_pill("prio", PRIORITY_LABEL[t.priority], PILL_TONE[t.priority], "prio-" .. t.priority, "prio"),
		el("button", "hbtn", "up", {
			aria = "Move up",
			title = "Move up (Alt+↑)",
			attrs = { ["data-kind"] = "up", ["data-edge"] = if can_move(state, t, -1) then "false" else "true" },
			actions = { click = "mv=up" },
		}),
		el("button", "hbtn", "down", {
			aria = "Move down",
			title = "Move down (Alt+↓)",
			attrs = { ["data-kind"] = "down", ["data-edge"] = if can_move(state, t, 1) then "false" else "true" },
			actions = { click = "mv=down" },
		}),
	})
	local agent = el("div", "agent", "agent", nil, {
		el("div", "agent-title", "title", { text = "Hand it to an agent" }),
		el("div", "agent-row", "r1", nil, {
			pill_box(state, "model", "model", t.agent.model or "Default model", nil, nil),
			level_pill(t.agent.thinking),
		}),
		el("div", "agent-row", "r2", nil, {
			pill_box(state, "project", "cwd", if t.links.cwd then basename(t.links.cwd) else "No project", nil, "folder"),
		}),
		el("div", "agent-row", "r3", nil, {
			pill_box(state, "chat", "chat", chat_title(state, t), nil, nil),
		}),
	})
	local buttons = el("div", "buttons", "buttons", nil, {
		el("button", "pill", "open", { text = primary_label(t), actions = { click = "primary" } }),
		el("button", "pill", "done", {
			text = if t.done then "Mark as not done" else "Mark as done",
			actions = { click = "toggle=" .. t.id },
		}),
	})
	local kind = status_of(state, t, live_panes())
	local head: { Node } = {
		el("div", "detail-head", "head", nil, {
			field_node("editor", {
				key = "title",
				role = ROLE .. "detail-title",
				aria = "Task title",
			}, if state.focus == "title" then state.title else nil, t.title),
			el("button", "hbtn", "archive", {
				aria = if t.archived then "Restore" else "Archive",
				title = if t.archived then "Restore (z)" else "Archive (z)",
				attrs = { ["data-kind"] = if t.archived then "restore" else "archive" },
				actions = { click = "archive" },
			}),
			el("button", "hbtn", "delete", {
				text = if state.confirm == t.id then "Delete?" else nil,
				aria = if state.confirm == t.id then "Click again to delete permanently" else "Delete",
				title = if state.confirm == t.id then "Click again to delete permanently" else "Delete (Delete key)",
				attrs = { ["data-kind"] = "delete", ["data-confirm"] = if state.confirm == t.id then "true" else "false" },
				actions = { click = "delete" },
			}),
			el("button", "close", "close", { aria = "Close", title = "Close", actions = { click = "close" } }),
		}),
	}
	if STATUS_LABEL[kind] then
		table.insert(head, el("div", "chiprow", "chiprow", nil, {
			el("span", "statuschip", "chip", { text = STATUS_LABEL[kind], attrs = { ["data-kind"] = kind } }),
		}))
	end
	table.insert(head, notes)
	table.insert(head, icons)
	table.insert(head, agent)
	table.insert(head, buttons)
	return el("div", "detail", "detail", {
		attrs = { ["data-focus"] = if state.focus == "notes" then "notes" else "none" },
	}, head)
end

local function hint_view(): Node
	local card = ui.card({ ui.span("Todo Prototype", "strong") }, {
		ui.md("No data file given. Open this block with the path to the JSON file as its argument."),
	})
	local p: { [string]: any } = card.p or {}
	p.tone = "muted"
	card.p = p
	return card
end

local function root(children: { Node }): Node
	local col = ui.col(children)
	local p: { [string]: any } = col.p or {}
	p.role = ROLE .. "main"
	col.p = p
	return col
end

tern.block.define("list", {
	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local state: State = {
			cx = cx,
			path = args[1],
			todos = {},
			cursor = nil,
			error = nil,
			timer = nil,
			focus = nil,
			detail_open = true,
			add = new_field("", false, nil),
			notes = new_field("", true, nil),
			title = new_field("", false, TITLE_MAX),
			title_id = nil,
			title_orig = "",
			pick = nil,
			models = nil,
			models_state = "idle",
			models_error = nil,
			chats = nil,
			chats_loading = false,
			chats_token = 0,
			agent_states = {},
			debug_states = {},
			states_sig = "",
			st_timer = nil,
			since = {},
			nudge_seen = 0,
			launched = {},
			arch_open = false,
			confirm = nil,
			confirm_timer = nil,
			lift = nil,
			tap = nil,
			launching = {},
		}
		running[cx.pane] = state
		-- The add-omp-session command (window.luau) writes into the most recently opened file.
		if state.path and string.sub(state.path, 1, 1) == "/" then
			pcall(tern.kv.set, "todo-proto.file", state.path)
		end
		state.nudge_seen = nudge_n(state) or 0
		if state.path then
			load(state)
			poll(state)
			scan_chats(state, nil)
			update_states(state)
			poll_states(state)
		end
		return state
	end,

	features = { "edit", "undo" },
	title = function(state: State): string?
		return "Tasks (" .. open_count(state) .. ")"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if not state.path then
			return { main = root({ hint_view() }) }
		end
		if state.error then
			local card = ui.card({ ui.span("Could not load todos", "strong") }, { ui.md(state.error) })
			local p: { [string]: any } = card.p or {}
			p.tone = "error"
			card.p = p
			return { main = root({ card }) }
		end
		local cols: { Node } = { left_view(state) }
		local t = selected(state)
		if t and state.detail_open then
			table.insert(cols, detail_view(state, t))
		end
		local dock = ui.col({
			el("div", "hint", "hint", {
				text = if state.focus == "picker"
					then "↑↓ PgUp PgDn choose  ·  Tab complete path  ·  ⏎ pick  ·  Esc close"
					elseif state.focus == "title"
					then "Enter save  ·  Esc cancel"
					elseif state.focus
					then "Enter " .. (if state.focus == "add" then "add task" else "new line") .. "  ·  Esc leave field"
					else if state.lift
						then "Click a task to move it there  ·  click the grip or Esc to cancel"
						else "j/k move  ·  space done  ·  ⏎ open  ·  Tab add  ·  e notes  ·  F2 rename  ·  p project  ·  z archive  ·  ⌫ delete",
			}),
		})
		local dp: { [string]: any } = dock.p or {}
		dp.role = ROLE .. "dock"
		dock.p = dp
		local layer: Node? = nil
		local sheet = picker_node(state)
		if sheet then
			layer = ui.col({ sheet, pick_input(state) })
		end
		return { main = root({ el("div", "ws", "ws", nil, cols) }), dock = dock, layer = layer }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if not state.path then
			return false
		end
		if state.focus then
			return field_key(state, key)
		end
		if (key.alt and not key.ctrl and not key.meta) or (key.meta and key.shift and not key.ctrl and not key.alt) then
			if key.name == "up" or key.name == "down" then
				step(state, if key.name == "up" then -1 else 1)
				return true
			end
		end
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local i = index_of(state)
		local k = key.text or key.name
		if key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #state.todos)
		elseif key.name == "space" or k == " " or k == "x" then
			local t = selected(state)
			if t then
				toggle(state, t.id)
			end
		elseif key.name == "enter" then
			local t = selected(state)
			if t then
				activate(state, t)
			end
		elseif key.name == "tab" or k == "a" then
			set_focus(state, "add")
		elseif k == "e" then
			set_focus(state, "notes")
		elseif key.name == "f2" or k == "n" then
			begin_rename(state)
		elseif k == "p" then
			open_picker(state, "project")
		elseif k == "r" then
			refresh(state)
		elseif k == "z" then
			local t = selected(state)
			if t then
				archive_toggle(state, t)
			end
		elseif k == "Z" then
			toggle_archived(state)
		elseif key.name == "delete" or key.name == "backspace" then
			delete_press(state)
		elseif key.name == "escape" and (state.confirm or state.lift) then
			clear_confirm(state)
			state.lift = nil
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "focus" and type(ev.id) == "string" then
			local tail = string.match(ev.id, "%.(%w+)$")
			if tail == "field" then
				set_focus(state, "add")
			elseif tail == "notes" then
				set_focus(state, "notes")
			elseif tail == "title" then
				set_focus(state, "title")
			end
			return
		end
		if ev.ev == "edit" or ev.ev == "undo" then
			local f = if type(ev.id) == "string" then field_of(state, ev.id) else nil
			if f then
				local what = if ev.ev == "undo" then (if undo_step(f, false) then "text" else nil) else apply_edit(f, ev)
				if what == "text" then
					field_changed(state)
					if state.focus == "picker" then
						request_listing(state)
					end
				end
			end
			return
		end
		if (ev.ev == "select" or ev.ev == "activate") and state.pick and type(ev.item) == "string" then
			-- One click picks, as the popover did before it became a sheet.
			local it = picker_items(state)[tonumber(string.sub(ev.item, 2)) or 0]
			if it then
				apply_pick(state, state.pick.kind, if it.kind == "none" then nil else it.path)
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		if state.focus == "title" then
			set_focus(state, nil)
		end
		local t = selected(state)
		-- Anything but a row click, the grip or a row double click puts a picked-up task down.
		if state.lift and act ~= "sel" and act ~= "lift" and act ~= "open" and act ~= "tap" then
			state.lift = nil
		end
		if act == "sel" and type(value) == "string" then
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			local carried = state.lift
			if carried then
				-- The click drops the picked-up task here; it stays selected.
				state.lift = nil
				if carried ~= value then
					reorder(state, carried, value)
				end
				value = carried
			end
			if state.cursor ~= value then
				clear_confirm(state)
			end
			state.cursor = value
			state.detail_open = true
		elseif act == "lift" and type(value) == "string" then
			if repeated(state, "lift=" .. value) then
				return
			end
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			if state.lift == value then
				state.lift = nil
			else
				if state.cursor ~= value then
					clear_confirm(state)
				end
				state.cursor = value
				state.lift = value
			end
		elseif act == "open" and type(value) == "string" then
			-- Double click: select the row, open its card, then do what Enter does.
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			state.lift = nil
			if state.cursor ~= value then
				clear_confirm(state)
			end
			state.cursor = value
			state.detail_open = true
			for _, candidate in state.todos do
				if candidate.id == value then
					activate(state, candidate)
				end
			end
		elseif act == "mv" then
			step(state, if value == "up" then -1 else 1)
		elseif act == "tap" then
			-- The double click on a glyph or grip: its clicks already ran, and having an
			-- action of its own keeps it from reaching the row's double click.
		elseif act == "toggle" and type(value) == "string" then
			toggle(state, value)
		elseif act == "close" then
			if state.focus == "notes" then
				set_focus(state, nil)
			end
			clear_confirm(state)
			state.detail_open = false
		elseif act == "glyph" and type(value) == "string" then
			if repeated(state, "glyph=" .. value) then
				return
			end
			local target: Todo? = nil
			for _, candidate in state.todos do
				if candidate.id == value then
					target = candidate
				end
			end
			if target then
				local kind = status_of(state, target, live_panes())
				if kind == "todo" or kind == "done" then
					toggle(state, value)
				else
					activate(state, target)
				end
			end
		elseif act == "prio" and t then
			cycle_priority(state, t)
		elseif act == "level" and t then
			cycle_level(state, t)
		elseif act == "primary" and t then
			activate(state, t)
		elseif act == "pick" and type(value) == "string" then
			if state.pick and state.pick.kind == value then
				close_picker(state)
			else
				open_picker(state, value)
			end
		elseif act == "pick-close" then
			close_picker(state)
		elseif act == "pick-use" and state.pick then
			picker_key(state, { name = "enter" } :: any)
		elseif act == "archive" and t then
			archive_toggle(state, t)
		elseif act == "delete" then
			delete_press(state)
		elseif act == "arch" then
			toggle_archived(state)
		end
	end,
})
