--!strict
-- The file is re-read every 5 seconds, except while a text field or popover has focus.
--
-- Keys (no field focused): j/k or up/down move, space or x toggles done, Enter
-- focuses the linked pane, resumes the linked omp chat in a new tab, or starts
-- the task in omp; Tab or a opens a new task card and the add field, e edits the notes, F2 or n renames the task,
-- p picks the project, r reloads the file, z archives or restores, Delete or Backspace
-- deletes (press twice), Z shows or hides the archived section. Alt+Up / Alt+Down (or
-- cmd+shift+Up / Down) move the selected task one place within its group. Double-clicking a
-- row selects it, opens its card and does what Enter does. The grip at the right of a row
-- picks the task up; the next click on a row drops it there (Esc or the grip again cancels).
-- Done closes the pane: marking a task done (x / space, the glyph, the card button or the bulk
-- button) closes its linked pane with `tern close` unless the agent is working or needs you, or
-- a command runs in it; the link is then cleared. Marking it not done again reopens its omp
-- chat (`omp --resume`) when it has a session. Several tasks can be selected (cmd/ctrl-click
-- toggles a row, shift-click a range; shift+Up/Down, v, cmd/ctrl+A, Esc) and archived, deleted or
-- marked done together from the bulk panel (z, Delete and x act on the whole selection too).
-- Keys (field focused): typing edits the field, Enter adds the task (add row), saves the
-- title or inserts a newline (notes), Tab commits; Esc discards title/notes drafts.
--
-- Settings: the bottom-right gear, the `,` key (no field focused) and the palette command
-- "Todo: settings" open a centred sheet of switches (see SETTINGS), kept in tern.kv "settings"
-- and shared by every block and window. Up/Down, Space/Enter toggle, Esc or `,` closes.
--
-- Times: the block stamps the tasks it changes with ISO UTC `created` (new tasks), `updated` (any
-- change of that task; a reorder is none) and `completed` (while done). Each row shows the age
-- of `completed` (done), the later of `updated` and the linked omp session file's mtime, or
-- `updated`/`created`, as now/Nm/Nh/Nd/Nw/Nmo/Ny; tasks without a valid stamp show nothing.
--
-- Fields are natively edited: the block opts into `features = {"edit", "undo"}`, so Tern
-- keeps the selection (shift-arrows, drag, double/triple click, cmd+a) and sends edits as
-- `edit` events and cmd+z as `undo`. The block's `Field` model applies those, plus the
-- keys Tern leaves to the program (typing, deletes, word moves, ctrl+a, redo).

local ui = tern.ui
local session = require("./session")

local POLL_MS = 5 * 1000
-- fswatch reports a file change within about WATCH_LATENCY_S; POLL_MS stays as the fallback when it is missing or misses an event.
local FSWATCH = "/opt/homebrew/bin/fswatch"
local WATCH_LATENCY_S = "0.1"
local WATCH_RUN_MS = 15 * 1000
local TERN = require("./executable").tern_bin()
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

-- Settings (tern.kv "settings", shared by every Todos block and window; absent keys use
-- their default). Each one gates something real below.
local SETTINGS_KEY = "settings"
local SETTINGS_REQ_KEY = "todo-proto.settings_req"
local SETTINGS: { { id: string, label: string, hint: string, default: boolean } } = {
	{ id = "time", label = "Show time on rows", hint = "How long ago a task was last touched, at the right of the row.", default = true },
	{ id = "row_actions", label = "Show row action icons", hint = "Done, move to backlog, archive and delete buttons on hovered rows.", default = true },
	{ id = "close_on_done", label = "Close pane when a task is done", hint = "Done closes the linked pane unless the agent is busy.", default = true },
	{ id = "reopen_on_undone", label = "Reopen chat when a task is not done", hint = "Not done resumes the task's omp chat in a new tab.", default = true },
	{ id = "focus_on_start", label = "Open pane when a task starts", hint = "Switch to the new tab right away. Off opens it in the background.", default = true },
	{ id = "new_chat_worktree", label = "Create new chats in a worktree", hint = "Start new chats in a separate Git worktree. Existing chats keep their directory.", default = true },
	{ id = "dblclick", label = "Double-click opens pane", hint = "Double-click does what Enter does: focus, resume or start.", default = true },
	{ id = "archived", label = "Show archived section", hint = "The Archived list below the tasks.", default = true },
	{ id = "badges", label = "Show badges on rows", hint = "Priority, pane and omp chips under the title.", default = true },
	{ id = "status_line", label = "Show agent status on rows", hint = "Working, Needs you, Ready for you or Stopped under the title.", default = true },
	{ id = "hints", label = "Show key hints", hint = "The line of keyboard shortcuts at the bottom of the block.", default = true },
	{ id = "done_group", label = "Done tasks as a separate group", hint = "Collapse completed tasks into their own Done section.", default = false },
	{ id = "omp_titles", label = "Task titles from omp", hint = "Linked tasks take the title omp gives their session; a typed title is only the prompt.", default = false },
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
	backlog: boolean,
	links: Links,
	agent: Agent,
	-- ISO UTC stamps the block maintains (absent on tasks it has not touched yet).
	created: string?,
	updated: string?,
	completed: string?,
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
	fresh: string?, -- a task created by Tab/a whose title has not been entered yet
	add: Field,
	-- Drafts of the focused detail fields, valid while focus == "title" / "notes".
	notes: Field,
	title: Field,
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
	closed_panes: { [string]: boolean }?,
	st_timer: TimerHandle?,
	-- Counter of window.luau's "todo-proto.nudge" already handled (see `reload_if_nudged`).
	nudge_seen: number,
	-- When a pane was last seen working / launched by this block (os.time()).
	since: { [number]: number },
	launched: { [number]: number },
	-- Archived section expanded; id of the task whose Delete awaits its second press (view
	-- state only, never saved to the file).
	arch_open: boolean,
	-- Whether the optional Done section is expanded, kept only in this block.
	done_open: boolean,
	tab: string,
	confirm: string?,
	confirm_timer: TimerHandle?,
	-- The task picked up by its grip, waiting to be dropped on a row (view state only).
	lift: string?,
	-- The last press on a glyph or grip (key, tern.now()): a double click delivers it twice.
	tap: { key: string, at: number }?,
	-- Tasks whose `tern new tab` is still running, so a repeated double click starts one tab.
	launching: { [string]: boolean },
	-- Multi-selection (view state only, never saved): the ticked ids, the row a shift range
	-- starts at, whether Delete awaits its second press for the whole selection, and the
	-- tasks whose done toggle (pane close) is in flight.
	sel: { [string]: boolean },
	anchor: string?,
	confirm_bulk: boolean,
	closing: { [string]: boolean },
	-- Settings (see SETTINGS), the sheet that edits them, the last settings-sheet click, the
	-- palette request counter already handled, and the omp session files' last activity
	-- (mtime, seconds) with their paths and the last lookup try per session id.
	cfg: { [string]: boolean },
	settings_open: boolean,
	settings_sel: number,
	settings_tap: { id: string, at: number }?,
	settings_req: number,
	sess_mtime: { [string]: number },
	sess_path: { [string]: string },
	sess_tried: { [string]: number },
	sess_busy: boolean,
	-- True while an fswatch process waits for the next file change.
	fsw: boolean,
	-- The shared minute-aligned timer that refreshes the time labels.
	tick: TimerHandle?,
}

-- A pane ID survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

-- Defined with the picker functions, which it needs.
local open_settings: (State) -> ()

local CONFIRM_MS = 4000

local function clear_confirm(state: State)
	state.confirm = nil
	state.confirm_bulk = false
	if state.confirm_timer then
		state.confirm_timer:cancel()
		state.confirm_timer = nil
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.tick then
		state.tick:cancel()
		state.tick = nil
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
-- only while the Archived section is expanded. The Backlog tab lists only backlog tasks, the
-- Tasks tab everything else; an archived task is never in the backlog. `with_done` is false
-- while done tasks sit in a collapsed Done group.
local function in_backlog(t: Todo): boolean
	return t.backlog and not t.archived
end

local function ordered(todos: { Todo }, tab: string, with_archived: boolean, with_done: boolean): { Todo }
	local want = tab == "backlog"
	local out: { Todo } = {}
	for _, t in todos do
		if not t.done and not t.archived and in_backlog(t) == want then
			table.insert(out, t)
		end
	end
	if with_done then
		for _, t in todos do
			if t.done and not t.archived and in_backlog(t) == want then
				table.insert(out, t)
			end
		end
	end
	if with_archived and not want then
		for _, t in todos do
			if t.archived then
				table.insert(out, t)
			end
		end
	end
	return out
end

local function listed(state: State): { Todo }
	local all = ordered(state.todos, state.tab, state.arch_open and state.cfg.archived, not state.cfg.done_group or state.done_open)
	if not state.fresh then
		return all
	end
	local shown: { Todo } = {}
	for _, t in all do
		if t.id ~= state.fresh then
			table.insert(shown, t)
		end
	end
	return shown
end

-- The task created by Tab stays out of the list until Enter accepts its title.
local function is_draft(state: State, t: Todo): boolean
	return t.id == state.fresh
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
				backlog = item.backlog == true and item.done ~= true,
				links = {
					tern_pane = tonumber(links.tern_pane),
					cwd = str_or_nil(links.cwd),
					omp_session = str_or_nil(links.omp_session),
				},
				agent = { model = str_or_nil(agent.model), thinking = str_or_nil(agent.thinking) },
				created = str_or_nil(item.created),
				updated = str_or_nil(item.updated),
				completed = str_or_nil(item.completed),
			})
		end
	end
	return todos, nil
end

local function ensure_cursor(state: State)
	if state.fresh and state.cursor == state.fresh then
		return
	end
	local shown = listed(state)
	for _, t in shown do
		if t.id == state.cursor then
			return
		end
	end
	state.cursor = if shown[1] then shown[1].id else nil
end

-- Drops selected ids that are no longer listed (gone from the file, or in a collapsed section).
local function prune_sel(state: State)
	if next(state.sel) == nil and state.anchor == nil then
		return
	end
	local visible: { [string]: boolean } = {}
	for _, t in listed(state) do
		visible[t.id] = true
	end
	local changed = false
	for id in state.sel do
		if not visible[id] then
			state.sel[id] = nil
			changed = true
		end
	end
	if state.anchor and not visible[state.anchor] then
		state.anchor = nil
	end
	if changed then
		clear_confirm(state)
	end
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
	prune_sel(state)
end

-- Time ------------------------------------------------------------------

local function days_from_civil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- Seconds since the epoch of an ISO-8601 stamp ("2026-10-12T09:30:00Z", fraction and
-- +hh:mm offsets allowed; no zone means UTC), nil when it is not one.
local function parse_iso(text: string?): number?
	if not text then
		return nil
	end
	local y, mo, d, h, mi, s, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	local Y, M, D = tonumber(y) or 0, tonumber(mo) or 0, tonumber(d) or 0
	local H, I, S = tonumber(h) or 0, tonumber(mi) or 0, tonumber(s) or 0
	if M < 1 or M > 12 or D < 1 or D > 31 or H > 23 or I > 59 or S > 60 then
		return nil
	end
	local zone = (string.gsub(rest :: string, "^%.%d+", ""))
	local offset = 0
	if zone ~= "" and zone ~= "Z" and zone ~= "z" then
		local sign, oh, om = string.match(zone, "^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = ((tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60) * (if sign == "+" then 1 else -1)
	end
	return days_from_civil(Y, M, D) * 86400 + H * 3600 + I * 60 + S - offset
end

-- T3 Code / Synara row label: now, Nm, Nh, Nd, Nw, Nmo, Ny (each step floors).
local function format_age(now: number, ts: number): string
	local secs = now - ts
	if secs < 60 then
		return "now"
	end
	local mins = secs // 60
	if mins < 60 then
		return mins .. "m"
	end
	local hours = mins // 60
	if hours < 24 then
		return hours .. "h"
	end
	local days = hours // 24
	if days < 7 then
		return days .. "d"
	elseif days < 30 then
		return (days // 7) .. "w"
	elseif days < 365 then
		return (days // 30) .. "mo"
	end
	return (days // 365) .. "y"
end

-- The moment a row's label counts from, and what it means: a done task shows `completed`; a
-- task with an omp chat the later of `updated` and the chat file's last activity; any other
-- `updated`, else `created`. Nothing when the task carries no valid stamp (old tasks stay
-- unlabelled until the block first touches them).
local function stamp_of(state: State, t: Todo): (number?, string)
	if t.done then
		local c = parse_iso(t.completed)
		if c then
			return c, "completed"
		end
	end
	local base, kind = parse_iso(t.updated), "updated"
	if not base then
		base, kind = parse_iso(t.created), "created"
	end
	local sid = t.links.omp_session
	if sid and not t.done then
		local m = state.sess_mtime[sid]
		if m and (not base or m > base) then
			return m, "activity"
		end
	end
	return base, kind
end

local STAMP_PREFIX: { [string]: string } = {
	completed = "Completed",
	updated = "Updated",
	created = "Created",
	activity = "Last activity",
}

-- Label, absolute local date and a sentence for the card; nil without a stamp.
local function stamp_label(state: State, t: Todo): (string?, string?, string?)
	local ts, kind = stamp_of(state, t)
	if not ts then
		return nil, nil, nil
	end
	local label = format_age(os.time(), ts)
	local abs = os.date("%a %d %b %Y, %H:%M", ts)
	local ago = if label == "now" then "just now" else label .. " ago"
	return label, abs, STAMP_PREFIX[kind] .. " " .. ago .. " · " .. abs
end

-- Settings --------------------------------------------------------------

-- One-time cutover from master's former modal store. Canonical values take precedence.
local settings_migrated = false
local function migrate_settings()
	if settings_migrated then
		return
	end
	local ok, old = pcall(tern.kv.get, "todo-proto.settings")
	local cok, current = pcall(tern.kv.get, SETTINGS_KEY)
	if not ok or not cok then
		return
	end
	if type(old) == "table" then
		local merged = if type(current) == "table" then table.clone(current) else {}
		for key, value in old do
			if merged[key] == nil then
				merged[key] = value
			end
		end
		if not pcall(tern.kv.set, SETTINGS_KEY, merged) then
			return
		end
		if not pcall(tern.kv.set, "todo-proto.settings", nil) then
			return
		end
	end
	settings_migrated = true
end

local function read_settings(): { [string]: boolean }
	migrate_settings()
	local out: { [string]: boolean } = {}
	local ok, raw = pcall(tern.kv.get, SETTINGS_KEY)
	local src: { [string]: any } = if ok and type(raw) == "table" then raw else {}
	for key, value in src do
		if type(value) == "boolean" then
			out[key] = value
		end
	end
	for _, s in SETTINGS do
		local v = src[s.id]
		out[s.id] = if type(v) == "boolean" then v else s.default
	end
	return out
end

-- What a settings change implies for the view state.
local function apply_settings(state: State)
	if not state.cfg.done_group then
		state.done_open = false
	end
	if not state.cfg.archived then
		state.arch_open = false
	end
	ensure_cursor(state)
	prune_sel(state)
end

-- Re-reads the kv (another window or block may have changed it); true when a value differs.
local function refresh_cfg(state: State): boolean
	local fresh = read_settings()
	local changed = false
	for id, v in fresh do
		if state.cfg[id] ~= v then
			changed = true
		end
	end
	if changed then
		state.cfg = fresh
		apply_settings(state)
	end
	return changed
end

local function toggle_setting(state: State, id: string)
	refresh_cfg(state)
	local nextcfg = table.clone(state.cfg)
	nextcfg[id] = not nextcfg[id]
	local ok, err = pcall(tern.kv.set, SETTINGS_KEY, nextcfg)
	if not ok then
		state.cx:toast("error", "Cannot save settings", tostring(err))
		return
	end
	state.cfg = nextcfg
	apply_settings(state)
end

-- The palette command (window.luau) writes { pane, n } to tern.kv "todo-proto.settings_req";
-- the block of that pane opens its sheet on its next state tick.
local function settings_requested(state: State): boolean
	local ok, v = pcall(tern.kv.get, SETTINGS_REQ_KEY)
	if ok and type(v) == "table" and type(v.n) == "number" and v.n ~= state.settings_req then
		state.settings_req = v.n
		if v.pane == state.cx.pane then
			open_settings(state)
			return true
		end
	end
	return false
end

-- One timer for the whole list, first fired on the next minute boundary, then every minute.
local function start_tick(state: State)
	if state.tick or not state.path then
		return
	end
	state.tick = tern.timer((60 - os.time() % 60) * 1000 + 200, function()
		state.tick = nil
		if not running[state.cx.pane] or running[state.cx.pane] ~= state then
			return
		end
		if state.cfg.time then
			state.cx:render()
		end
		start_tick(state)
	end)
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

local function iso_now(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
end

local function deep_copy(v: any): any
	if type(v) ~= "table" or v == tern.json.null then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = deep_copy(x)
	end
	return out
end

local function deep_equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, x in a do
		if not deep_equal(x, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- Re-reads the file, lets `change` edit its `todos` array, and writes it back.
-- Reading first keeps edits made elsewhere; known keys that are absent are filled in
-- as explicit nulls (`due` is kept as it is, null when unset;
-- `agent` is optional and only filled in where a task has one).
-- Returns whether the file was written.
local function rewrite(state: State, change: ({ any }) -> boolean?): boolean
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
	-- Per-task snapshot: after `change`, only a task whose content differs is stamped.
	local snap: { [string]: any } = {}
	for _, item in list do
		if type(item) == "table" and type(item.id) == "string" then
			snap[item.id] = deep_copy(item)
		end
	end
	if change(list) == false then
		load(state)
		return false
	end
	-- `updated` moves on every task the change touched (a reorder touches none); a task that
	-- turned done gets `completed`, one that turned open loses it; new tasks get `created`.
	-- Tasks the change left alone, and keys the block does not know, are not rewritten.
	local now = iso_now()
	for _, item in list do
		if type(item) == "table" and type(item.id) == "string" then
			if item.done == true then
				item.backlog = nil
			end
			local before = snap[item.id]
			if before == nil then
				if item.created == nil then
					item.created = now
				end
				if item.updated == nil then
					item.updated = now
				end
			elseif not deep_equal(before, item) then
				item.updated = now
				if item.done == true and before.done ~= true then
					item.completed = now
				elseif item.done ~= true and before.done == true then
					item.completed = nil
				end
			end
		end
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

local LAST_PROJECT_KEY = "todo-proto.last_project"

local function last_project(): string?
	local ok, v = pcall(tern.kv.get, LAST_PROJECT_KEY)
	return if ok then str_or_nil(v) else nil
end

local function add_task(state: State, title: string)
	local new_id = ""
	local cwd = last_project()
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
			backlog = if state.tab == "backlog" then true else nil,
			links = if cwd then { cwd = cwd } else {},
		})
	end)
	if written then
		state.cursor = new_id
		state.sel = {}
		state.anchor = nil
		state.detail_open = true
	end
end

local function index_of(state: State): number
	for i, t in listed(state) do
		if t.id == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: State): Todo?
	local t = listed(state)[index_of(state)]
	if t or not state.fresh or state.cursor ~= state.fresh then
		return t
	end
	for _, draft in state.todos do
		if is_draft(state, draft) then
			return draft
		end
	end
	return nil
end

local function todo_by_id(state: State, id: string): Todo?
	for _, t in state.todos do
		if t.id == id then
			return t
		end
	end
	return nil
end

local function clear_sel(state: State)
	state.sel = {}
	clear_confirm(state)
end

-- The ids of a multi-selection (two or more rows), in list order; empty otherwise.
local function multi_ids(state: State): { string }
	local out: { string } = {}
	if next(state.sel) == nil then
		return out
	end
	for _, t in listed(state) do
		if state.sel[t.id] then
			table.insert(out, t.id)
		end
	end
	if #out < 2 then
		return {}
	end
	return out
end

-- Selects the visible rows from the anchor (else the cursor) to `to`, ends included.
local function select_range(state: State, to: string)
	local shown = listed(state)
	if not state.anchor then
		state.anchor = state.cursor
	end
	local a, b = 0, 0
	for i, t in shown do
		if t.id == state.anchor then
			a = i
		end
		if t.id == to then
			b = i
		end
	end
	if b == 0 then
		return
	end
	if a == 0 then
		a = b
	end
	if a > b then
		a, b = b, a
	end
	local sel: { [string]: boolean } = {}
	for i = a, b do
		sel[shown[i].id] = true
	end
	state.sel = sel
	clear_confirm(state)
end

-- Cmd/ctrl-click and `v`: ticks or unticks one row. The first tick also ticks the cursor row.
local function toggle_mark(state: State, id: string)
	if next(state.sel) == nil and state.cursor and state.cursor ~= id then
		state.sel[state.cursor] = true
	end
	if state.sel[id] then
		state.sel[id] = nil
	else
		state.sel[id] = true
	end
	state.anchor = id
	state.cursor = id
	state.detail_open = true
	state.lift = nil
	clear_confirm(state)
end

-- Shift+Up / Shift+Down: moves the cursor and selects from the anchor to it.
local function extend(state: State, delta: number)
	local shown = listed(state)
	local t = shown[math.clamp(index_of(state) + delta, 1, math.max(1, #shown))]
	if not t then
		return
	end
	state.lift = nil
	if not state.anchor then
		state.anchor = state.cursor
	end
	state.cursor = t.id
	state.detail_open = true
	select_range(state, t.id)
end

local function select_all(state: State)
	local sel: { [string]: boolean } = {}
	for _, t in listed(state) do
		sel[t.id] = true
	end
	state.lift = nil
	state.sel = sel
	state.anchor = state.cursor
	clear_confirm(state)
end

-- The row to put the cursor on once the rows in `gone` leave: the next one not in it, else the
-- previous one.
local function survivor(state: State, gone: { [string]: boolean }): string?
	local shown = listed(state)
	local last = 0
	for i, t in shown do
		if gone[t.id] then
			last = i
		end
	end
	for i = last + 1, #shown do
		if not gone[shown[i].id] then
			return shown[i].id
		end
	end
	for i = last - 1, 1, -1 do
		if not gone[shown[i].id] then
			return shown[i].id
		end
	end
	return nil
end

local function move(state: State, to: number)
	local shown = listed(state)
	local t = shown[math.clamp(to, 1, math.max(1, #shown))]
	if t then
		if state.cursor ~= t.id then
			clear_confirm(state)
		end
		state.cursor = t.id
		state.anchor = t.id
		state.detail_open = true
	end
end

-- The task to select once `id` leaves the list or its group: the next one, else the
-- previous one, preferring its own group (open/done vs archived).
local function neighbour(state: State, id: string): string?
	local shown = listed(state)
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

-- Archives the selected tasks, or restores them when all of them are archived (one write).
local function bulk_archive(state: State, ids: { string })
	local set: { [string]: boolean } = {}
	local all_archived = true
	for _, id in ids do
		set[id] = true
		local t = todo_by_id(state, id)
		if t and not t.archived then
			all_archived = false
		end
	end
	local target = not all_archived
	local after = survivor(state, set)
	clear_confirm(state)
	local written = rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and set[item.id] then
				item.archived = if target then true else nil
				if target then
					item.backlog = nil
				end
			end
		end
	end)
	if written then
		state.sel = {}
		state.anchor = nil
		state.cursor = after or state.cursor
		ensure_cursor(state)
		state.cx:toast("info", (if target then "Archived " else "Restored ") .. #ids .. " tasks")
	end
end

-- Archive keeps the record, its links and any running agent untouched; Restore drops the key.
local function archive_toggle(state: State, t: Todo)
	local ids = multi_ids(state)
	if #ids >= 2 then
		bulk_archive(state, ids)
		return
	end
	local target = not t.archived
	local after = neighbour(state, t.id)
	clear_confirm(state)
	local written = rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and item.id == t.id then
				item.archived = if target then true else nil
				if target then
					item.backlog = nil
				end
			end
		end
	end)
	if written then
		state.cursor = after
		state.cx:toast("info", if target then "Archived" else "Restored")
	end
end

-- First press arms the confirmation on the task's own button, the second removes the record.
local function delete_one(state: State, t: Todo)
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

-- First press arms the confirmation, the second removes the record (never a pane or session).
local function delete_press(state: State)
	local ids = multi_ids(state)
	if #ids >= 2 then
		if not state.confirm_bulk then
			clear_confirm(state)
			state.confirm_bulk = true
			state.confirm_timer = tern.timer(CONFIRM_MS, function()
				state.confirm_timer = nil
				if alive(state) and state.confirm_bulk then
					state.confirm_bulk = false
					state.cx:render()
				end
			end)
			return
		end
		local set: { [string]: boolean } = {}
		for _, id in ids do
			set[id] = true
		end
		local after = survivor(state, set)
		clear_confirm(state)
		-- Only the records go; panes and omp sessions are never touched.
		local written = rewrite(state, function(list)
			for i = #list, 1, -1 do
				local item = list[i]
				if type(item) == "table" and set[item.id] then
					table.remove(list, i)
				end
			end
		end)
		if written then
			state.sel = {}
			state.anchor = nil
			state.cursor = after or state.cursor
			ensure_cursor(state)
			state.cx:toast("info", "Deleted " .. #ids .. " tasks")
		end
		return
	end
	local t = selected(state)
	if not t then
		return
	end
	delete_one(state, t)
end

local function toggle_archived(state: State)
	if not state.cfg.archived then
		return
	end
	state.arch_open = not state.arch_open
	clear_confirm(state)
	ensure_cursor(state)
	prune_sel(state)
end

local function toggle_done_open(state: State)
	state.done_open = not state.done_open
	clear_confirm(state)
	ensure_cursor(state)
	prune_sel(state)
end


local function switch_tab(state: State, tab: string)
	if state.tab == tab then
		return
	end
	state.tab = tab
	state.lift = nil
	clear_sel(state)
	state.anchor = nil
	ensure_cursor(state)
end

-- Moves tasks between the Tasks list and the Backlog; archived tasks stay where they are.
local function backlog_ids(state: State, ids: { string })
	local set: { [string]: boolean } = {}
	local all_backlog = true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.archived then
			set[id] = true
			if not t.backlog then
				all_backlog = false
			end
		end
	end
	if next(set) == nil then
		return
	end
	local target = not all_backlog
	local after = survivor(state, set)
	clear_confirm(state)
	local written = rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and set[item.id] then
				item.backlog = if target then true else nil
				if target then
					item.done = false
				end
			end
		end
	end)
	if written then
		state.sel = {}
		state.anchor = nil
		state.cursor = after or state.cursor
		ensure_cursor(state)
		state.cx:toast("info", if target then "Moved to backlog" else "Back to tasks")
	end
end

local function backlog_toggle(state: State, t: Todo)
	local ids = multi_ids(state)
	if #ids >= 2 then
		backlog_ids(state, ids)
	else
		backlog_ids(state, { t.id })
	end
end

local function bulk_all_backlog(state: State, ids: { string }): boolean
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.archived and not t.backlog then
			return false
		end
	end
	return true
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
	local other = listed(state)[index_of(state) + delta]
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

-- omp reports its exact session file on the pane. Retry briefly while it starts;
-- never infer ownership from another session's cwd or modification time.
local function discover_session(state: State, task_id: string, pane: number, deadline: number)
	if tern.now() >= deadline then
		return
	end
	tern.timer(1500, function()
		if not alive(state) then
			return
		end
		local function retry()
			discover_session(state, task_id, pane, deadline)
		end
		local ok = pcall(tern.process.run, { TERN, "inspect", "--json" }, { timeout_ms = 3000 }, function(found: ProcessResult, _)
			if not alive(state) then
				return
			end
			local dok, doc = pcall(tern.json.decode, found.stdout)
			local file: string? = nil
			if found.status == 0 and dok and type(doc) == "table" and type(doc.panes) == "table" then
				for _, p in doc.panes do
					if type(p) == "table" and p.pane == pane and type(p.omp_session_file) == "string" then
						file = p.omp_session_file
					end
				end
			end
			local file_id = if file then string.match(file, "_([%w%-]+)%.jsonl$") else nil
			if not file_id then
				retry()
				return
			end
			local hok = pcall(tern.process.run, { "/usr/bin/head", "-n", "2", "--", file :: string }, { timeout_ms = 3000 }, function(head: ProcessResult, _)
				if not alive(state) then
					return
				end
				local _, id = session.read_head(head.stdout)
				if head.status ~= 0 or id ~= file_id then
					retry()
					return
				end
				rewrite(state, function(list)
					for _, item in list do
						if type(item) == "table" and item.id == task_id then
							local links = if type(item.links) == "table" then item.links else {}
							if links.tern_pane ~= pane or (type(links.omp_session) == "string" and links.omp_session ~= "") then
								return false
							end
							links.omp_session = id
							item.links = links
							return true
						end
					end
					return false
				end)
				state.cx:render()
			end)
			if not hok then
				retry()
			end
		end)
		if not ok then
			retry()
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
	local id = t.id
	state.launching[id] = true
	local function open_tab(directory: string)
		local cmd = { TERN, "new", "tab", "--json", "--cwd", directory, "--" }
		for _, a in argv do
			table.insert(cmd, a)
		end
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
			if state.cfg.focus_on_start then
				-- `tern new tab` leaves the new tab in the background: show it.
				pcall(tern.process.run, { TERN, "focus", tostring(pane) }, { timeout_ms = 5000 }, function(shown: ProcessResult, _)
					if shown.status ~= 0 then
						state.cx:toast("error", "tern focus failed", shown.stderr)
					end
				end)
			end
			patch(state, id, function(item)
				local links = if type(item.links) == "table" then item.links else {}
				links.tern_pane = pane
				if find_session then
					links.cwd = directory
				end
				item.links = links
			end)
			state.launched[pane] = os.time()
			state.cx:render()
			if find_session then
				discover_session(state, id, pane, tern.now() + 20000)
			end
		end)
		if not ok then
			state.launching[id] = nil
			state.cx:toast("error", "Cannot run tern", tostring(err))
		end
	end
	if not find_session or not state.cfg.new_chat_worktree then
		open_tab(cwd)
		return
	end
	local function failed(message: string)
		state.launching[id] = nil
		state.cx:toast("error", "Cannot create worktree", message)
		state.cx:render()
	end
	local ok, err = pcall(tern.process.run, {
		"/usr/bin/git", "-C", cwd, "for-each-ref", "--format=%(refname)",
		"refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/heads/main",
		"refs/remotes/origin/master", "refs/heads/master",
	}, { timeout_ms = 5000 }, function(refs: ProcessResult, _)
		if not alive(state) then
			state.launching[id] = nil
			return
		end
		local base: string? = nil
		for _, ref in { "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/heads/main", "refs/remotes/origin/master", "refs/heads/master" } do
			if string.find("\n" .. refs.stdout, "\n" .. ref .. "\n", 1, true) then
				base = ref
				break
			end
		end
		if refs.status ~= 0 or not base then
			failed(if refs.status ~= 0 then refs.stderr else "The project has no main or master branch")
			return
		end
		local name = "todo-" .. string.gsub(id, "[^%w%-]", "-") .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))
		local directory = home_dir() .. "/.omp/wt/" .. name
		local added, reason = pcall(tern.process.run, {
			"/usr/bin/git", "-C", cwd, "worktree", "add", "-b", name, directory, base :: string,
		}, { timeout_ms = 120000 }, function(result: ProcessResult, _)
			if result.status ~= 0 then
				failed(result.stderr)
			elseif alive(state) then
				open_tab(directory)
			else
				state.launching[id] = nil
			end
		end)
		if not added then
			failed(tostring(reason))
		end
	end)
	if not ok then
		failed(tostring(err))
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
	local live = live_panes()
	local ok_closed, raw_closed = pcall(tern.kv.get, "closed_panes")
	local events = if ok_closed and type(raw_closed) == "table" then raw_closed else {}
	local seen = state.closed_panes
	local closed: { [string]: boolean } = {}
	if seen then
		for pane in events do
			if not seen[pane] then
				closed[pane] = true
			end
		end
	else
		state.closed_panes = events
	end
	local completed = false
	if state.focus == nil and next(state.closing) == nil and next(state.launching) == nil and next(closed) ~= nil then
		local matched: boolean? = nil
		completed = rewrite(state, function(list)
			matched = false
			local changed = false
			for _, item in list do
				if type(item) == "table" and type(item.links) == "table" then
					local pane = tonumber(item.links.tern_pane)
					if pane and closed[tostring(pane)] then
						matched = true
						item.done = true
						item.links.tern_pane = nil
						changed = true
					end
				end
			end
			return changed
		end)
		if completed or matched == false then
			state.closed_panes = events
		end
	end
	local panes: { number } = {}
	for pane in live do
		table.insert(panes, pane)
	end
	table.sort(panes)
	local sig = tern.json.encode({ states, debug, panes })
	if sig == state.states_sig then
		return completed
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

-- Done and the pane -----------------------------------------------------

local SHELLS: { [string]: boolean } = {
	fish = true, bash = true, zsh = true, sh = true, dash = true, ksh = true,
	tcsh = true, csh = true, nu = true, xonsh = true, elvish = true,
}

local function exe_name(v: any): string
	local s = tostring(v or "")
	local base = string.match(s, "([^/]+)$") or s
	return (string.gsub(base, "^%-", ""))
end

local function proc_argv(proc: any): { any }
	return if type(proc) == "table" and type(proc.argv) == "table" then proc.argv else {}
end

local function is_shell(proc: any): boolean
	return type(proc) == "table" and SHELLS[exe_name(proc_argv(proc)[1] or proc.name)] == true
end

local function is_omp(proc: any): boolean
	if type(proc) ~= "table" then
		return false
	end
	local argv = proc_argv(proc)
	return exe_name(argv[1]) == "omp" or exe_name(proc.name) == "omp" or exe_name(argv[2]) == "omp"
end

-- Why the pane must stay open, or nil when closing it is safe. `stdout` is `tern process
-- --json PANE`: the pane may close when its foreground job is the shell (idle), or omp whose
-- sampled state is idle/exited; never while omp works or waits for the user, nor with any other
-- foreground job (tern has no confirm and no undo for a closed pane).
local function keep_reason(state: State, pane: number, stdout: string): string?
	local key = tostring(pane)
	local word = state.debug_states[key] or state.agent_states[key]
	if word == "working" or word == "running" then
		return "agent is working"
	elseif word == "waiting_input" or word == "needs" then
		return "needs you"
	end
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" then
		return "cannot inspect it"
	end
	local job = if type(data.foreground) == "table" then data.foreground else data.child
	if is_shell(job) then
		return nil
	elseif is_omp(job) then
		if word == "idle" or word == "review" or word == "exited" or word == "stopped" then
			return nil
		end
		return "agent state unknown"
	end
	return "running a command"
end

local function busy(state: State, id: string): boolean
	return state.closing[id] == true or state.launching[id] == true
end

local function plural(n: number, noun: string): string
	return n .. " " .. noun .. (if n == 1 then "" else "s")
end

-- Sets `done` on the tasks `ids` (those that differ), in ONE file write.
-- Going done closes each live linked pane when it is safe (keep_reason) and clears the link;
-- going open reopens the omp chat of a task that has a session and no live pane. A task
-- whose close or reopen is in flight ignores a second toggle.
local function set_done(state: State, ids: { string }, to: boolean)
	local want: { string } = {}
	local set: { [string]: boolean } = {}
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and t.done ~= to and not busy(state, id) and not set[id] then
			table.insert(want, id)
			set[id] = true
		end
	end
	if #want == 0 then
		return
	end
	local bulk = #ids > 1
	refresh_cfg(state)

	if not to then
		local written = rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and set[item.id] then
					item.done = false
				end
			end
		end)
		if written then
			local opened = 0
			for _, id in want do
				local t = todo_by_id(state, id)
				if t and state.cfg.reopen_on_undone and t.links.omp_session and not live_pane_of(t) then
					opened += 1
					launch(state, t, { omp_bin(), "--resume", t.links.omp_session }, false)
				end
			end
			if bulk then
				state.cx:toast("info", "Marked " .. #want .. " not done" .. (if opened > 0 then ", reopening " .. plural(opened, "chat") else ""))
			end
		end
		return
	end

	local function write_done(closed: { [string]: number }): boolean
		return rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and type(item.id) == "string" and set[item.id] then
					item.done = true
					local pane = closed[item.id]
					if pane and type(item.links) == "table" and tonumber(item.links.tern_pane) == pane then
						item.links.tern_pane = nil
					end
				end
			end
		end)
	end

	-- One entry per live pane; tasks sharing a pane follow its verdict.
	local live = live_panes()
	local groups: { { pane: number, ids: { string } } } = {}
	for _, id in want do
		local t = todo_by_id(state, id) :: Todo
		local pane = t.links.tern_pane
		if pane and live[pane] then
			local found = false
			for _, g in groups do
				if g.pane == pane then
					table.insert(g.ids, id)
					found = true
				end
			end
			if not found then
				table.insert(groups, { pane = pane, ids = { id } })
			end
		end
	end
	-- Setting off: the task only changes status; its pane and link stay.
	if not state.cfg.close_on_done then
		groups = {}
	end
	if #groups == 0 then
		if write_done({}) and bulk then
			state.cx:toast("info", "Marked " .. #want .. " done")
		end
		return
	end

	for _, id in want do
		state.closing[id] = true
	end
	local closed: { [string]: number } = {}
	local closed_panes, left_panes = 0, 0
	local why: { string } = {}
	local function finish()
		for _, id in want do
			state.closing[id] = nil
		end
		for _, g in groups do
			local key = tostring(g.pane)
			if closed[g.ids[1]] then
				state.agent_states[key] = nil
				state.since[g.pane] = nil
				state.launched[g.pane] = nil
			end
		end
		local written = write_done(closed)
		if written and #why > 0 and not bulk then
			state.cx:toast("info", "Pane left open (" .. why[1] .. ")")
		elseif written and bulk then
			local parts: { string } = {}
			if closed_panes > 0 then
				table.insert(parts, "Closed " .. plural(closed_panes, "pane"))
			end
			if left_panes > 0 then
				table.insert(parts, (if closed_panes > 0 then "left " else "Left ") .. left_panes .. " open")
			end
			if #parts == 0 then
				parts = { "Marked " .. #want .. " done" }
			end
			state.cx:toast("info", table.concat(parts, ", "), if #why > 0 then table.concat(why, "; ") else nil)
		end
		if alive(state) then
			state.cx:render()
		end
	end

	local function leave(reason: string)
		left_panes += 1
		if not table.find(why, reason) then
			table.insert(why, reason)
		end
	end

	local function close_phase(candidates: { { pane: number, ids: { string } } })
		local pending = #candidates
		if pending == 0 then
			finish()
			return
		end
		for _, g in candidates do
			local function settle()
				pending -= 1
				if pending == 0 then
					finish()
				end
			end
			local ok = pcall(tern.process.run, { TERN, "close", tostring(g.pane) }, { timeout_ms = 5000 }, function(result: ProcessResult, _)
				if result.status == 0 then
					closed_panes += 1
					for _, id in g.ids do
						closed[id] = g.pane
					end
				else
					leave("close failed")
					state.cx:toast("error", "tern close failed", string.match(result.stderr, "[^\n]+") or ("exit " .. result.status))
				end
				settle()
			end)
			if not ok then
				leave("cannot run tern")
				settle()
			end
		end
	end

	local candidates: { { pane: number, ids: { string } } } = {}
	local probing = #groups
	local function probed()
		probing -= 1
		if probing == 0 then
			close_phase(candidates)
		end
	end
	for _, g in groups do
		local reason: string? = nil
		if g.pane == state.cx.pane then
			reason = "this is the todo pane"
		else
			for _, other in state.todos do
				if other.links.tern_pane == g.pane and not set[other.id] and not other.done then
					reason = "shared with another task"
				end
			end
		end
		if reason then
			leave(reason)
			probed()
		else
			local ok = pcall(tern.process.run, { TERN, "process", "--json", tostring(g.pane) }, { timeout_ms = 5000 }, function(result: ProcessResult, _)
				local why_not = if result.status ~= 0 then "cannot inspect it" else keep_reason(state, g.pane, result.stdout)
				if why_not then
					leave(why_not)
				else
					table.insert(candidates, g)
				end
				probed()
			end)
			if not ok then
				leave("cannot run tern")
				probed()
			end
		end
	end
end

local function toggle_done(state: State, id: string)
	local t = todo_by_id(state, id)
	if t then
		set_done(state, { id }, not t.done)
	end
end

-- Mark done for the whole selection, or not done when every selected task is done.
local function bulk_done(state: State, ids: { string })
	local all_done = true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.done then
			all_done = false
		end
	end
	set_done(state, ids, not all_done)
end

local function bulk_action(state: State, which: string?)
	if which == "clear" then
		clear_sel(state)
		return
	end
	local ids = multi_ids(state)
	if #ids < 2 then
		return
	end
	if which == "archive" then
		bulk_archive(state, ids)
	elseif which == "backlog" then
		backlog_ids(state, ids)
	elseif which == "done" then
		bulk_done(state, ids)
	elseif which == "delete" then
		delete_press(state)
	end
end

-- Last activity of the omp chats linked to tasks: the mtime of each session jsonl, from one
-- `stat` over the known paths and (at most every 20 seconds per id) one `find` for new ids.
-- Runs on the file poll, not per frame; renders when a time changed.
local function absorb_stat(state: State, stdout: string): boolean
	local changed = false
	for _, f in parse_stat(stdout) do
		state.sess_path[f.id] = f.path
		if state.sess_mtime[f.id] ~= f.mtime then
			state.sess_mtime[f.id] = f.mtime
			changed = true
		end
	end
	return changed
end

local function poll_sessions(state: State)
	if state.sess_busy or not state.cfg.time then
		return
	end
	local now = os.time()
	local seen: { [string]: boolean } = {}
	local paths: { string } = {}
	local unknown: { string } = {}
	for _, t in state.todos do
		local id = t.links.omp_session
		if id and not seen[id] and string.match(id, "^[%w%-]+$") then
			seen[id] = true
			local path = state.sess_path[id]
			if path then
				table.insert(paths, path)
			elseif now - (state.sess_tried[id] or 0) >= 20 then
				state.sess_tried[id] = now
				table.insert(unknown, id)
			end
		end
	end
	local jobs = 0
	local changed = false
	local function done(stdout: string?)
		if stdout and absorb_stat(state, stdout) then
			changed = true
		end
		jobs -= 1
		if jobs == 0 then
			state.sess_busy = false
			if changed and alive(state) then
				state.cx:render()
			end
		end
	end
	local function run(argv: { string })
		jobs += 1
		state.sess_busy = true
		local ok = pcall(tern.process.run, argv, { timeout_ms = 8000 }, function(result: ProcessResult, _)
			done(result.stdout)
		end)
		if not ok then
			done(nil)
		end
	end
	if #paths > 0 then
		local argv = { "/usr/bin/stat", "-f", "%m %N" }
		for _, p in paths do
			table.insert(argv, p)
		end
		run(argv)
	end
	if #unknown > 0 then
		local argv = { "/usr/bin/find", sessions_root(), "-maxdepth", "2", "(" }
		for i, id in unknown do
			if i > 1 then
				table.insert(argv, "-o")
			end
			table.insert(argv, "-name")
			table.insert(argv, "*_" .. id .. ".jsonl")
		end
		for _, a in { ")", "-exec", "/usr/bin/stat", "-f", "%m %N", "{}", "+" } do
			table.insert(argv, a)
		end
		run(argv)
	end
end

local function refresh(state: State)
	if not alive(state) then
		return
	end
	load(state)
end

-- tern.process.run hands back stdout only after the process ends, so one fswatch run waits for
-- one batch of changes (or WATCH_RUN_MS, to pick up session files found since). The watcher is
-- armed before the reload, so a change during the reload starts the next run instead of getting lost.
local function sync(state: State)
	poll_sessions(state)
	-- A field being edited owns its text: the file is left alone then.
	if state.focus == nil then
		refresh(state)
		state.cx:render()
	end
end

local function watch_files(state: State)
	if state.fsw or not alive(state) or not state.path then
		return
	end
	local argv = { FSWATCH, "-1", "--latency", WATCH_LATENCY_S, state.path :: string }
	if state.cfg.time then
		for _, path in state.sess_path do
			table.insert(argv, path)
		end
	end
	state.fsw = true
	local ok = pcall(tern.process.run, argv, { timeout_ms = WATCH_RUN_MS }, function(result: ProcessResult, _)
		state.fsw = false
		if not alive(state) then
			return
		end
		if result.timed_out then
			watch_files(state)
		elseif result.status == 0 and result.stdout ~= "" then
			watch_files(state)
			sync(state)
		end
	end)
	if not ok then
		state.fsw = false
	end
end

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
		sync(state)
		poll(state)
	end)
end

local STATE_MS = 200

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
		if refresh_cfg(state) then
			changed = true
		end
		if settings_requested(state) then
			changed = true
		end
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
	id: string?,
	rev: number,
	undo: { Snap },
	redo: { Snap },
	-- The last change was typing, so the next typed character joins its undo step.
	typing: boolean,
	multiline: boolean,
	max: number?,
	task: string?,
	base: string,
	saved: string,
	conflict: boolean,
}

local HISTORY = 200

local function reset_field(f: Field, text: string)
	f.text, f.cur, f.anchor = text, length_of(text), nil
	f.undo, f.redo, f.typing = {}, {}, false
	f.base, f.saved, f.conflict, f.task = text, text, false, nil
	f.rev += 1
end

local function new_field(text: string, multiline: boolean, max: number?): Field
	local f: Field = { text = "", cur = 0, anchor = nil, rev = 0, base = "", saved = "", conflict = false, undo = {}, redo = {}, typing = false, multiline = multiline, max = max }
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
		-- A fresh node key drops Tern's retained native range before block select-all.
		f.anchor, f.cur, f.typing = 0, n, false
		f.rev += 1
		if f.id then
			f.id = string.gsub(f.id, "_%d+$", "_" .. f.rev)
			cx:frame({ { "focus", f.id } })
		end
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

-- The last value we wrote is the base version for the next live save. `base` stays
-- the edit-start value for Esc. Re-read inside rewrite, never from the sampled view.
local function save_field(state: State, f: Field, name: string, mode: string)
	local id = f.task
	if not id then
		return
	end
	local draft = if name == "title" then trim(f.text) else f.text
	local cancel = mode == "cancel" or (name == "title" and mode == "commit" and draft == "")
	rewrite(state, function(list)
		for _, item in list do
			if type(item) ~= "table" or item.id ~= id then
				continue
			end
			local disk = tostring(item[name] or "")
			if cancel then
				local value = if not f.conflict and disk == f.saved then f.base else disk
				reset_field(f, value)
				if value == disk then
					return false
				end
				item[name] = value
				return true
			end
			if disk ~= f.base and disk ~= f.saved and disk ~= draft and not f.conflict then
				f.conflict = true
				state.cx:toast("warning", "Task changed on disk")
			end
			if mode == "live" and (f.conflict or (name == "title" and draft == "")) then
				return false
			end
			if disk == draft then
				f.saved = draft
				return false
			end
			item[name], f.saved = draft, draft
			return true
		end
		return false
	end)
end

-- Removes a just-created task that Enter never accepted.
local function drop_fresh(state: State)
	local id = state.fresh
	state.fresh = nil
	if not id then
		return
	end
	rewrite(state, function(list)
		for i, item in list do
			if type(item) == "table" and item.id == id then
				table.remove(list, i)
				return true
			end
		end
		return false
	end)
	ensure_cursor(state)
end

local function set_focus(state: State, field: string?)
	if state.focus == "add" and state.fresh and field ~= "add" and field ~= "picker" then
		drop_fresh(state)
	end
	if state.focus == "title" and field ~= "title" then
		save_field(state, state.title, "title", "commit")
		state.title.task = nil
	elseif state.focus == "notes" and field ~= "notes" then
		save_field(state, state.notes, "notes", "commit")
		state.notes.task = nil
	end
	local t = selected(state)
	if field == "notes" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "notes" then
			reset_field(state.notes, t.notes)
			state.notes.task = t.id
		end
	elseif field == "title" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "title" then
			reset_field(state.title, t.title)
			state.title.task = t.id
		end
	end
	state.focus = field
	local id: any = tern.json.null
	if field == "add" then
		id = "main.ws.left.add.field_" .. state.add.rev
	elseif field == "notes" then
		id = "main.ws.detail.notes_" .. state.notes.rev
	elseif field == "title" then
		id = "main.ws.detail.head.title_" .. state.title.rev
	elseif field == "picker" and state.pick and SEARCH[state.pick.kind] then
		id = "layer.q_" .. state.pick.q.rev
	end
	state.cx:frame({ { "focus", id } })
end

-- Tab / a: creates an empty task with the last used project, opens its card and puts the
-- caret in the add field, whose text becomes the task title while it is typed.
local function new_task(state: State)
	set_focus(state, nil)
	reset_field(state.add, "")
	add_task(state, "")
	state.fresh = state.cursor
	set_focus(state, "add")
end

local function sync_fresh_title(state: State)
	local id = state.fresh
	local title = trim(state.add.text)
	if id and title ~= "" then
		patch(state, id, function(item)
			item.title = title
		end)
	end
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
	local f = if state.focus == "add" then state.add
		elseif state.focus == "notes" then state.notes
		elseif state.focus == "title" then state.title
		elseif state.focus == "picker" and state.pick then state.pick.q
		else nil
	return if f and f.id == id then f else nil
end

-- Writes what a changed field holds: the detail fields go to the file, a popover's search
-- resets the highlighted row.
local function field_changed(state: State)
	if state.focus == "add" then
		sync_fresh_title(state)
	elseif state.focus == "title" then
		save_field(state, state.title, "title", "live")
	elseif state.focus == "notes" then
		save_field(state, state.notes, "notes", "live")
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
	set_focus(state, if state.fresh then "add" else nil)
end

open_settings = function(state: State)
	state.pick = nil
	state.settings_sel = 1
	if state.focus then
		set_focus(state, nil)
	end
	state.lift = nil
	clear_confirm(state)
	refresh_cfg(state)
	state.settings_open = true
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
	if kind == "project" then
		pcall(tern.kv.set, LAST_PROJECT_KEY, value or "")
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
			local discard = state.fresh ~= nil
			set_focus(state, nil)
			if discard then
				reset_field(state.add, "")
			end
		elseif what == "submit" then
			local title = trim(state.add.text)
			if title ~= "" then
				if state.fresh then
					sync_fresh_title(state)
				else
					add_task(state, title)
				end
				state.fresh = nil
				reset_field(state.add, "")
				set_focus(state, nil)
			end
		elseif what == "text" then
			sync_fresh_title(state)
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
	elseif key.name == "escape" then
		local name = state.focus :: string
		save_field(state, f, name, "cancel")
		f.task = nil
		set_focus(state, nil)
	elseif what == "blur" or what == "submit" then
		set_focus(state, nil)
	elseif what == "text" then
		field_changed(state)
		if state.focus == "notes" and key.name == "enter" and not key.shift then
			save_field(state, f, "notes", "commit")
			f.conflict = false
		end
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

local FIELD_IDS = { field = "main.ws.left.add.field", notes = "main.ws.detail.notes", title = "main.ws.detail.head.title", q = "layer.q" }

-- A text field node whose text, caret and selection come from `f` while it is being
-- edited, else from `idle` with the caret at its end.
local function field_node(kind: string, props: { [string]: any }, f: Field?, idle: string): Node
	if f then
		f.id = FIELD_IDS[props.key] .. "_" .. f.rev
		props.key ..= "_" .. f.rev
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
	local want = state.tab == "backlog"
	local open = 0
	for _, t in state.todos do
		if not t.done and not t.archived and in_backlog(t) == want and not is_draft(state, t) then
			open += 1
		end
	end
	return open
end

local function tab_count(state: State): number
	local want = state.tab == "backlog"
	local n = 0
	for _, t in state.todos do
		if not t.archived and in_backlog(t) == want and not is_draft(state, t) then
			n += 1
		end
	end
	return n
end

local function backlog_count(state: State): number
	local n = 0
	for _, t in state.todos do
		if in_backlog(t) and not is_draft(state, t) then
			n += 1
		end
	end
	return n
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
	local line = if state.cfg.status_line then agent_line(state, t, kind) else nil
	if line then
		table.insert(meta, el("div", "agent-line", "line", { text = line, attrs = { ["data-kind"] = kind } }))
	end
	if state.cfg.badges then
		for _, badge in badges(t, live) do
			table.insert(meta, badge)
		end
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
	local multi = state.sel[t.id] == true
	local kids: { Node } = { glyph, el("div", "rowtext", "text", nil, text) }
	if multi then
		table.insert(kids, el("span", "tick", "tick"))
	end
	-- Time and row actions share a fixed box. Hover, confirmation or pick-up swaps them.
	local armed = state.confirm == t.id
	local label: string?, abs: string? = nil, nil
	if state.cfg.time and kind ~= "running" then
		label, abs = stamp_label(state, t)
	end
	local slot: { Node } = {}
	if label then
		table.insert(slot, el("span", "time", "time", { text = label, title = abs }))
	end
	local actions: { Node } = {}
	if state.cfg.row_actions then
		if not t.archived then
			table.insert(actions, el("button", "hbtn", "r-done", {
				aria = if t.done then "Mark as not done" else "Mark as done",
				title = if t.done then "Mark as not done" else "Mark as done",
				attrs = { ["data-kind"] = if t.done then "undone" else "done", ["data-row"] = "true" },
				actions = { click = "rdone=" .. t.id, dblclick = "tap=" .. t.id },
			}))
			table.insert(actions, el("button", "hbtn", "r-backlog", {
				aria = if t.backlog then "Back to tasks" else "Move to backlog",
				title = if t.backlog then "Back to tasks" else "Move to backlog",
				attrs = { ["data-kind"] = if t.backlog then "unbacklog" else "backlog", ["data-row"] = "true" },
				actions = { click = "rback=" .. t.id, dblclick = "tap=" .. t.id },
			}))
		end
		table.insert(actions, el("button", "hbtn", "r-archive", {
			aria = if t.archived then "Restore" else "Archive",
			title = if t.archived then "Restore" else "Archive",
			attrs = { ["data-kind"] = if t.archived then "restore" else "archive", ["data-row"] = "true" },
			actions = { click = "rarch=" .. t.id, dblclick = "tap=" .. t.id },
		}))
	end
	-- Keyboard deletion still needs a visible second-press confirmation when icons are off.
	if state.cfg.row_actions or armed then
		table.insert(actions, el("button", "hbtn", "r-delete", {
			text = if armed then "Delete?" else nil,
			aria = if armed then "Click again to delete permanently" else "Delete",
			title = if armed then "Click again to delete permanently" else "Delete",
			attrs = { ["data-kind"] = "delete", ["data-row"] = "true", ["data-confirm"] = if armed then "true" else "false" },
			actions = { click = "rdel=" .. t.id, dblclick = "tap=" .. t.id },
		}))
	end
	table.insert(actions, grip)
	table.insert(slot, el("div", "row-actions", "actions", nil, actions))
	table.insert(kids, el("div", "slot", "slot", {
		attrs = {
			["data-time"] = if label then "true" else "false",
			["data-actions"] = if state.cfg.row_actions or armed then "true" else "false",
			["data-active"] = if armed or (lifted and t.id == lifted.id) then "true" else "false",
		},
	}, slot))
	return el("div", "row", t.id, {
		attrs = {
			["data-state"] = if picked then "selected" else "idle",
			["data-multi"] = if multi then "true" else "false",
			["data-done"] = if t.done then "true" else "false",
			["data-archived"] = if t.archived then "true" else "false",
			["data-drop"] = drop,
		},
		mark = mark,
		title = tip,
		actions = { click = "sel=" .. t.id, dblclick = "open=" .. t.id },
	}, kids)
end

local function done_count(state: State): number
	local want = state.tab == "backlog"
	local n = 0
	for _, t in state.todos do
		if t.done and not t.archived and in_backlog(t) == want then
			n += 1
		end
	end
	return n
end

local function gear_button(): Node
	return el("button", "gear", "gear", {
		aria = "Settings",
		title = "Settings",
		actions = { click = "settings" },
	})
end


local function left_view(state: State): Node
	local open = open_count(state)
	local archived = archived_count(state)
	local in_tab = tab_count(state)
	local backlog_tab = state.tab == "backlog"
	local subtitle = if in_tab == 0
		then (if backlog_tab then "Backlog is empty" elseif archived > 0 then "All archived" else "No tasks yet")
		elseif open > 0 then open .. " open"
		else "All done"
	local picked_n = #multi_ids(state)
	if picked_n >= 2 then
		subtitle ..= " · " .. picked_n .. " selected"
	end
	local tabs = el("div", "tabs", "tabs", nil, {
		el("button", "tabbtn", "tab-tasks", {
			text = "Tasks",
			attrs = { ["data-active"] = if backlog_tab then "false" else "true" },
			actions = { click = "tab=tasks" },
		}),
		el("button", "tabbtn", "tab-backlog", {
			text = "Backlog (" .. backlog_count(state) .. ")",
			attrs = { ["data-active"] = if backlog_tab then "true" else "false" },
			actions = { click = "tab=backlog" },
		}),
	})
	local head = el("div", "head", "head", nil, {
		el("div", "heading", "heading", { text = if backlog_tab then "Backlog" else "Tasks" }),
		el("div", "subtitle", "subtitle", { text = subtitle }),
		tabs,
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
	for i, t in ordered(state.todos, state.tab, true, true) do
		pos[t.id] = i
	end
	local lifted: Todo? = nil
	for _, t in state.todos do
		if t.id == state.lift then
			lifted = t
		end
	end
	local rows: { Node } = {}
	for _, t in ordered(state.todos, state.tab, false, not state.cfg.done_group) do
		if not is_draft(state, t) then
			table.insert(rows, row_view(state, t, live, lifted, pos))
		end
	end
	local done_n = done_count(state)
	if state.cfg.done_group and done_n > 0 then
		table.insert(rows, el("button", "arch-head", "donehead", {
			text = "Done (" .. done_n .. ")",
			attrs = { ["data-open"] = if state.done_open then "true" else "false" },
			actions = { click = "donehead" },
		}))
		if state.done_open then
			for _, t in state.todos do
				if t.done and not t.archived and in_backlog(t) == (state.tab == "backlog") then
					table.insert(rows, row_view(state, t, live, lifted, pos))
				end
			end
		end
	end
	if archived > 0 and state.tab == "tasks" and state.cfg.archived then
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
			click_pill("worktree", if state.cfg.new_chat_worktree then "Worktree" else "Local", nil, "none", "worktree"),
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
			el("button", "close", "close", { aria = "Close", title = "Close", actions = { click = "close" } }),
		}),
	}
	if STATUS_LABEL[kind] then
		table.insert(head, el("div", "chiprow", "chiprow", nil, {
			el("span", "statuschip", "chip", { text = STATUS_LABEL[kind], attrs = { ["data-kind"] = kind } }),
		}))
	end
	local _, _, sentence = stamp_label(state, t)
	if state.cfg.time and sentence then
		table.insert(head, el("div", "stampline", "stamp", { text = sentence }))
	end
	table.insert(head, notes)
	table.insert(head, icons)
	table.insert(head, agent)
	table.insert(head, buttons)
	return el("div", "detail", "detail", {
		attrs = { ["data-focus"] = if state.focus == "notes" then "notes" else "none" },
	}, head)
end

-- The modifier keys held during a click, as a set (Tern lists shift/ctrl/alt/meta).
local function mods_of(ev: UiEvent): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local m = ev.mods
	if type(m) == "table" then
		for _, name in m do
			out[tostring(name)] = true
		end
		if out.cmd or out.super then
			out.meta = true
		end
	end
	return out
end

-- The card shown in place of the task card while two or more tasks are selected.
local function bulk_view(state: State, ids: { string }): Node
	local counts = { 0, 0, 0 }
	local all_done, all_archived = true, true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t then
			local g = group_of(t)
			counts[g] += 1
			if not t.done then
				all_done = false
			end
			if not t.archived then
				all_archived = false
			end
		end
	end
	local parts: { string } = {}
	for i, label in { "open", "done", "archived" } do
		if counts[i] > 0 then
			table.insert(parts, counts[i] .. " " .. label)
		end
	end
	local confirm = state.confirm_bulk
	return el("div", "detail", "bulk", { attrs = { ["data-focus"] = "none", ["data-bulk"] = "true" } }, {
		el("div", "bulk-title", "title", { text = #ids .. " tasks selected" }),
		el("div", "bulk-sub", "sub", { text = table.concat(parts, " · ") }),
		el("div", "bulk-buttons", "buttons", nil, {
			el("button", "pill", "backlog", {
				text = if bulk_all_backlog(state, ids) then "Back to tasks" else "To backlog",
				actions = { click = "bulk=backlog" },
			}),
			el("button", "pill", "archive", {
				text = if all_archived then "Restore" else "Archive",
				actions = { click = "bulk=archive" },
			}),
			el("button", "pill", "done", {
				text = if all_done then "Mark as not done" else "Mark done",
				actions = { click = "bulk=done" },
			}),
			el("button", "pill", "delete", {
				text = if confirm then "Delete " .. #ids .. "?" else "Delete",
				attrs = { ["data-confirm"] = if confirm then "true" else "false" },
				actions = { click = "bulk=delete" },
			}),
			el("button", "pill", "clear", { text = "Clear", actions = { click = "bulk=clear" } }),
		}),
	})
end

-- The settings sheet: Tern's picker sheet (as the project/model/chat popovers use) with one
-- card row per setting: label, switch badge, one-line description. No query, so no search.
local function settings_node(state: State): Node
	local items: { any } = {}
	local order: { any } = {}
	for _, s in SETTINGS do
		local on = state.cfg[s.id] == true
		table.insert(items, {
			id = s.id,
			label = s.label,
			detail = s.hint,
			badges = { { text = if on then "On" else "Off", tone = if on then "success" else "muted" } },
			tone = if on then "success" else "muted",
		})
		table.insert(order, s.id)
	end
	return ui.node("picker", {
		key = "settings",
		role = ROLE .. "settings",
		size = "md",
		layout = "cards",
		preview = "none",
		title = "Settings",
		noun = "settings",
		items = items,
		order = order,
		selected = SETTINGS[math.clamp(state.settings_sel, 1, #SETTINGS)].id,
		actions = {
			{ id = "settings-toggle", label = "Toggle", keys = { "space" } },
			{ id = "settings-close", label = "Close", keys = { "esc" }, primary = true },
		},
	})
end

-- Keys while the settings sheet is open: it owns them all (modified keys go to Tern).
local function settings_key(state: State, key: Key): boolean
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local k = key.text or key.name
	local n = #SETTINGS
	if key.name == "escape" or k == "," then
		state.settings_open = false
	elseif key.name == "up" or k == "k" then
		state.settings_sel = math.max(1, state.settings_sel - 1)
	elseif key.name == "down" or k == "j" then
		state.settings_sel = math.min(n, state.settings_sel + 1)
	elseif key.name == "home" then
		state.settings_sel = 1
	elseif key.name == "end" then
		state.settings_sel = n
	elseif key.name == "space" or k == " " or key.name == "enter" then
		toggle_setting(state, SETTINGS[math.clamp(state.settings_sel, 1, n)].id)
	end
	return true
end

local function task_path(args: { string }, saved: any): (string?, string?)
	if args[1] then
		return args[1], nil
	end
	if type(saved) == "table" and type(saved.path) == "string" and saved.path ~= "" then
		return saved.path, nil
	end
	local ok, last = pcall(tern.kv.get, "todo-proto.file")
	if not ok then
		return nil, "Cannot read the last task file setting: " .. tostring(last)
	end
	local path: string
	if type(last) == "string" and last ~= "" then
		path = last
	else
		local home = tern.getenv("HOME")
		if not home or home == "" then
			return nil, "HOME is not set on this host. Open an explicit task file or set HOME for the Tern daemon."
		end
		path = string.gsub(home, "/+$", "") .. "/todos.todo.json"
	end
	local exists_ok, exists = pcall(tern.fs.exists, path)
	if not exists_ok then
		return nil, "Cannot check task file " .. path .. ": " .. tostring(exists)
	end
	if not exists then
		local wrote, reason = pcall(tern.fs.write, path, tern.json.encode({ todos = tern.json.array() }, true) .. "\n")
		if not wrote then
			return nil, "Cannot create task file " .. path .. ": " .. tostring(reason)
		end
	end
	return path, nil
end

local function root(children: { Node }): Node
	local col = ui.col(children)
	local p: { [string]: any } = col.p or {}
	p.role = ROLE .. "main"
	col.p = p
	return col
end

tern.block.define("list", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local path, path_error = task_path(args, saved)
		local state: State = {
			cx = cx,
			path = path,
			todos = {},
			cursor = nil,
			error = path_error,
			timer = nil,
			focus = nil,
			detail_open = true,
			fresh = nil,
			add = new_field("", false, nil),
			notes = new_field("", true, nil),
			title = new_field("", false, TITLE_MAX),
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
			closed_panes = nil,
			st_timer = nil,
			since = {},
			nudge_seen = 0,
			launched = {},
			arch_open = false,
			done_open = false,
			tab = "tasks",
			confirm = nil,
			confirm_timer = nil,
			lift = nil,
			tap = nil,
			launching = {},
			sel = {},
			anchor = nil,
			confirm_bulk = false,
			closing = {},
			cfg = read_settings(),
			settings_open = false,
			settings_sel = 1,
			settings_tap = nil,
			settings_req = 0,
			sess_mtime = {},
			sess_path = {},
			sess_tried = {},
			sess_busy = false,
			fsw = false,
			tick = nil,
		}
		running[cx.pane] = state
		-- The add-omp-session command (window.luau) writes into the most recently opened file.
		if state.path and string.sub(state.path, 1, 1) == "/" then
			pcall(tern.kv.set, "todo-proto.file", state.path)
		end
		state.nudge_seen = nudge_n(state) or 0
		do
			local rok, req = pcall(tern.kv.get, SETTINGS_REQ_KEY)
			if rok and type(req) == "table" and type(req.n) == "number" then
				state.settings_req = req.n
			end
		end
		if state.path then
			load(state)
			poll(state)
			watch_files(state)
			scan_chats(state, nil)
			update_states(state)
			poll_states(state)
			poll_sessions(state)
			start_tick(state)
		end
		return state
	end,

	save = function(state: State): any
		return { path = state.path }
	end,

	features = { "edit", "undo" },
	title = function(state: State): string?
		return "Tasks (" .. open_count(state) .. ")"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if state.error then
			local card = ui.card({ ui.span("Could not load todos", "strong") }, { ui.md(state.error) })
			local p: { [string]: any } = card.p or {}
			p.tone = "error"
			card.p = p
			return { main = root({ card }) }
		end
		refresh_cfg(state)
		local cols: { Node } = { left_view(state) }
		local t = selected(state)
		local picked_ids = multi_ids(state)
		if #picked_ids >= 2 then
			table.insert(cols, bulk_view(state, picked_ids))
		elseif t and state.detail_open then
			table.insert(cols, detail_view(state, t))
		end
		local hint = el("div", "hint", "hint", {
				text = if state.focus == "picker"
					then "↑↓ PgUp PgDn choose  ·  Tab complete path  ·  ⏎ pick  ·  Esc close"
					elseif state.focus == "title"
					then "Enter save  ·  Esc cancel"
					elseif state.focus == "notes"
					then "Enter new line  ·  Tab save  ·  Esc cancel"
					elseif state.focus
					then "Enter " .. (if state.focus == "add" then "add task" else "new line") .. "  ·  Esc leave field"
					else if state.lift
						then "Click a task to move it there  ·  click the grip or Esc to cancel"
						elseif next(state.sel) ~= nil
						then "⇧↑↓ extend  ·  v mark  ·  ⌘A all  ·  space done  ·  b backlog  ·  z archive  ·  ⌫⌫ delete  ·  Esc clear  ·  , settings"
						else "j/k move  ·  space done  ·  ⏎ open  ·  Tab add  ·  e notes  ·  F2 rename  ·  p project  ·  b backlog  ·  B tab  ·  z archive  ·  ⌫ delete  ·  v select  ·  , settings",
		})
		local dockkids: { Node } = {}
		if state.cfg.hints then
			table.insert(dockkids, hint)
		end
		table.insert(dockkids, gear_button())
		local dock = ui.col({ el("div", "dockrow", "dockrow", nil, dockkids) })
		local dp: { [string]: any } = dock.p or {}
		dp.role = ROLE .. "dock"
		dock.p = dp
		local layer: Node? = nil
		local sheet = picker_node(state)
		if sheet then
			layer = ui.col({ sheet, pick_input(state) })
		elseif state.settings_open then
			layer = ui.col({ settings_node(state) })
		end
		return { main = root({ el("div", "ws", "ws", nil, cols) }), dock = dock, layer = layer }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if not state.path then
			return false
		end
		if state.settings_open then
			return settings_key(state, key)
		end
		if state.focus then
			return field_key(state, key)
		end
		if key.shift and not (key.ctrl or key.alt or key.meta) and (key.name == "up" or key.name == "down") then
			extend(state, if key.name == "up" then -1 else 1)
			return true
		end
		if (key.meta or key.ctrl) and not (key.alt or key.shift) and key.name == "a" then
			select_all(state)
			return true
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
		-- The card is hidden while several rows are selected, so keys that edit it do nothing.
		if #multi_ids(state) >= 2 and (k == "e" or k == "n" or k == "p" or key.name == "f2") then
			return true
		end
		if key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #state.todos)
		elseif key.name == "space" or k == " " or k == "x" then
			local ids = multi_ids(state)
			local t = selected(state)
			if #ids >= 2 then
				bulk_done(state, ids)
			elseif t then
				toggle_done(state, t.id)
			end
		elseif k == "v" then
			if state.cursor then
				toggle_mark(state, state.cursor)
			end
		elseif key.name == "enter" then
			local t = selected(state)
			if t then
				activate(state, t)
			end
		elseif key.name == "tab" or k == "a" then
			new_task(state)
		elseif k == "e" then
			set_focus(state, "notes")
		elseif key.name == "f2" or k == "n" then
			begin_rename(state)
		elseif k == "," then
			open_settings(state)
		elseif k == "p" then
			open_picker(state, "project")
		elseif k == "r" then
			refresh(state)
		elseif k == "z" then
			local t = selected(state)
			if t then
				archive_toggle(state, t)
			end
		elseif k == "b" then
			local t = selected(state)
			if t then
				backlog_toggle(state, t)
			end
		elseif k == "B" then
			switch_tab(state, if state.tab == "backlog" then "tasks" else "backlog")
		elseif k == "Z" then
			toggle_archived(state)
		elseif key.name == "delete" or key.name == "backspace" then
			delete_press(state)
		elseif key.name == "escape" and (state.confirm or state.confirm_bulk or state.lift or next(state.sel) ~= nil) then
			if state.lift or state.confirm or state.confirm_bulk then
				clear_confirm(state)
				state.lift = nil
			else
				clear_sel(state)
				state.anchor = nil
			end
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if state.settings_open then
			if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
				for i, s in SETTINGS do
					if s.id == ev.item then
						state.settings_sel = i
						local now = tern.now()
						local tap = state.settings_tap
						state.settings_tap = { id = s.id, at = now }
						-- A double click delivers select then activate: it flips once.
						if ev.ev == "select" or not (tap and tap.id == s.id and now - tap.at < TAP_MS) then
							toggle_setting(state, s.id)
						end
					end
				end
			elseif ev.ev == "action" then
				if ev.act == "settings-toggle" then
					toggle_setting(state, SETTINGS[math.clamp(state.settings_sel, 1, #SETTINGS)].id)
				elseif ev.act == "settings-close" or ev.act == "close" then
					state.settings_open = false
				end
			end
			return
		end
		if ev.ev == "focus" and type(ev.id) == "string" then
			local tail = string.match(ev.id, "%.(%a+)_?%d*$")
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
		if state.focus == "title" or state.focus == "notes" then
			set_focus(state, nil)
		end
		local t = selected(state)
		-- Anything but a row click, the grip or a row double click puts a picked-up task down.
		if state.lift and act ~= "sel" and act ~= "lift" and act ~= "open" and act ~= "tap" then
			state.lift = nil
		end
		if act == "worktree" then
			toggle_setting(state, "new_chat_worktree")
			return
		end
		if act == "sel" and type(value) == "string" then
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			local m = mods_of(ev)
			local carried = state.lift
			if m.meta or m.ctrl then
				toggle_mark(state, value)
			elseif m.shift then
				state.lift = nil
				state.cursor = value
				state.detail_open = true
				select_range(state, value)
			else
				if carried then
					-- The click drops the picked-up task here; it stays selected.
					state.lift = nil
					if carried ~= value then
						reorder(state, carried, value)
					end
					value = carried
				end
				clear_sel(state)
				state.anchor = value
				state.cursor = value
				state.detail_open = true
			end
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
				clear_sel(state)
			end
		elseif act == "open" and type(value) == "string" then
			-- Double click: select the row, open its card, then do what Enter does.
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			state.lift = nil
			clear_sel(state)
			if state.cursor ~= value then
				clear_confirm(state)
			end
			state.cursor = value
			state.detail_open = true
			refresh_cfg(state)
			if state.cfg.dblclick then
				for _, candidate in state.todos do
					if candidate.id == value then
						activate(state, candidate)
					end
				end
			end
		elseif (act == "rarch" or act == "rdel") and type(value) == "string" then
			-- A button on the row itself: it acts on that task alone, whatever is selected.
			if repeated(state, act .. "=" .. value) then
				return
			end
			local target: Todo? = nil
			for _, candidate in state.todos do
				if candidate.id == value then
					target = candidate
				end
			end
			if target then
				if act == "rarch" or next(state.sel) ~= nil then
					clear_sel(state)
				end
				if act == "rarch" then
					archive_toggle(state, target)
				else
					delete_one(state, target)
				end
			end
		elseif act == "settings" then
			open_settings(state)
		elseif act == "mv" then
			step(state, if value == "up" then -1 else 1)
		elseif act == "tap" then
			-- The double click on a glyph or grip: its clicks already ran, and having an
			-- action of its own keeps it from reaching the row's double click.
		elseif act == "toggle" and type(value) == "string" then
			toggle_done(state, value)
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
					toggle_done(state, value)
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
		elseif act == "tab" and (value == "tasks" or value == "backlog") then
			switch_tab(state, value)
		elseif act == "rdone" and type(value) == "string" then
			if repeated(state, "rdone=" .. value) then
				return
			end
			clear_sel(state)
			toggle_done(state, value)
		elseif act == "rback" and type(value) == "string" then
			if repeated(state, "rback=" .. value) then
				return
			end
			for _, candidate in state.todos do
				if candidate.id == value then
					clear_sel(state)
					backlog_toggle(state, candidate)
				end
			end
		elseif act == "donehead" then
			toggle_done_open(state)
		elseif act == "arch" then
			toggle_archived(state)
		elseif act == "bulk" then
			bulk_action(state, value)
		end
	end,
})
