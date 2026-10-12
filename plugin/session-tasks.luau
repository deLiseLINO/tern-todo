--!strict
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

local function iso_now(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
end

local function is_text(v: any): boolean
	return type(v) == "string" and v ~= ""
end

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
			if touched then
				found.updated = iso_now()
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
		table.insert(list, 1, {
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
			created = iso_now(),
			updated = iso_now(),
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

return { edit_file = edit_file, find_task = find_task, add_task = add_task, strip_glyph = strip_glyph, iso_now = iso_now, is_text = is_text }
