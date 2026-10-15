--!strict
local session = require("./session")
local tern_bin = require("./executable").tern_bin
local session_tasks = require("./session-tasks")
local edit_file = session_tasks.edit_file
local add_task = session_tasks.add_task
local strip_glyph = session_tasks.strip_glyph
local iso_now = session_tasks.iso_now
local is_text = session_tasks.is_text

local AUTO_MS = 10000
local WATCH_FRESH_S = 15
local FILE_KEY = "todo-proto.file"
local NUDGE_KEY = "todo-proto.nudge"
local SEEN_KEY = "auto-seen"
local SEEN_MAX = 500
local armed = false
local busy = false

type Candidate = { pane: number, cwd: string, file: string, id: string, pane_title: string }

local function load_seen(): ({ [string]: boolean }, { string })
	local set: { [string]: boolean } = {}
	local order: { string } = {}
	local ok, saved = pcall(tern.kv.get, SEEN_KEY)
	if ok and type(saved) == "table" then
		for _, id in saved :: { any } do
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

local function omp_titles_on(): boolean
	local ok, settings = pcall(tern.kv.get, "settings")
	return ok and type(settings) == "table" and settings.omp_titles == true
end

local function wants_title(item: any, by_default: boolean): boolean
	if type(item) ~= "table" or type(item.links) ~= "table" or not is_text(item.links.omp_session) then
		return false
	end
	if type(item.auto_title) == "boolean" then
		return item.auto_title
	end
	return by_default
end

local function any_wants_title(path: string, by_default: boolean): boolean
	local found = false
	edit_file(path, function(list)
		for _, item in list do
			if wants_title(item, by_default) then
				found = true
				break
			end
		end
		return false
	end)
	return found
end

local function bump_nudge(path: string)
	local ok, old = pcall(tern.kv.get, NUDGE_KEY)
	local n = if ok and type(old) == "table" and type(old.n) == "number" then old.n + 1 else 1
	pcall(tern.kv.set, NUDGE_KEY, { path = path, n = n })
end

local function sync_titles(path: string, all: { Candidate }, index: number, titles: { [string]: string }, by_default: boolean)
	local candidate = all[index]
	if not candidate then
		busy = false
		if next(titles) == nil then
			return
		end
		local changed = edit_file(path, function(list)
			local touched = false
			for _, item in list do
				local links = if type(item) == "table" then item.links else nil
				local want = if wants_title(item, by_default) then titles[(links :: any).omp_session] else nil
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
	tern.process.run({ "/usr/bin/head", "-n", "2", "--", candidate.file }, { timeout_ms = 5000 }, function(head, _)
		if head.status == 0 then
			local title, id = session.read_head(head.stdout)
			title = strip_glyph((string.gsub(title, "%s+", " ")))
			if id == candidate.id and title ~= "" then
				titles[candidate.id] = title
			end
		end
		sync_titles(path, all, index + 1, titles, by_default)
	end)
end

local function import_next(path: string, queue: { Candidate }, index: number, all: { Candidate })
	local candidate = queue[index]
	if not candidate then
		local by_default = omp_titles_on()
		if #all > 0 and any_wants_title(path, by_default) then
			sync_titles(path, all, 1, {}, by_default)
		else
			busy = false
		end
		return
	end
	tern.process.run({ "/usr/bin/head", "-n", "2", "--", candidate.file }, { timeout_ms = 5000 }, function(head, _)
		local title, id = "", nil :: string?
		if head.status == 0 then
			title, id = session.read_head(head.stdout)
		end
		if id == candidate.id and not load_seen()[candidate.id] then
			if title == "" and candidate.pane_title ~= "omp" then
				title = candidate.pane_title
			end
			title = strip_glyph((string.gsub(title, "%s+", " ")))
			if title == "" then
				title = "omp session"
			end
			if title ~= "" then
				local outcome = add_task(path, {
					pane = candidate.pane,
					cwd = candidate.cwd,
					session = candidate.id,
					title = title,
				})
				if outcome then
					mark_seen(candidate.id)
					if outcome ~= "exists" then
						bump_nudge(path)
					end
				end
			end
		end
		import_next(path, queue, index + 1, all)
	end)
end

local function scan()
	if busy then
		return
	end
	local watch_ok, watch = pcall(tern.kv.get, "watch")
	if not watch_ok or type(watch) ~= "number" or os.time() - watch > WATCH_FRESH_S then
		return
	end
	local file_ok, path = pcall(tern.kv.get, FILE_KEY)
	if not file_ok or not is_text(path) then
		return
	end
	local exists_ok, exists = pcall(tern.fs.exists, path)
	if not exists_ok or not exists then
		return
	end
	busy = true
	local started = pcall(tern.process.run, { tern_bin(), "inspect", "--json" }, { timeout_ms = 8000 }, function(result, _)
		local decoded, doc = pcall(tern.json.decode, result.stdout)
		local queue: { Candidate } = {}
		local all: { Candidate } = {}
		if result.status == 0 and decoded and type(doc) == "table" and type(doc.panes) == "table" then
			local seen = load_seen()
			local queued: { [string]: boolean } = {}
			for _, pane in doc.panes do
				if type(pane) == "table" and type(pane.pane) == "number" and is_text(pane.omp_session_file) then
					local id = string.match(pane.omp_session_file, "_([%w%-]+)%.jsonl$")
					if id and not queued[id] then
						queued[id] = true
						local candidate: Candidate = {
							pane = pane.pane,
							cwd = if type(pane.cwd) == "string" then pane.cwd else "",
							file = pane.omp_session_file,
							id = id,
							pane_title = if type(pane.title) == "string" then strip_glyph(pane.title) else "",
						}
						table.insert(all, candidate)
						if not seen[id] then
							table.insert(queue, candidate)
						end
					end
				end
			end
		end
		import_next(path, queue, 1, all)
	end)
	if not started then
		busy = false
	end
end

local function arm()
	if armed then
		return
	end
	armed = true
	tern.timer(AUTO_MS, function(_cx)
		armed = false
		pcall(scan)
		arm()
	end)
end

return { arm = arm, suppress = mark_seen }
