--!strict
local tasks = require("./session-tasks")
local session = require("./session")
local TERN = require("./executable").tern_bin()

type Target = { pane: number, cwd: string, session: string, title: string }
type State = { cx: BlockCx, path: string?, target: Target?, reply: any, closed: boolean }

local function reply(state: State, value: any)
	if state.closed then
		return
	end
	state.reply = value
	state.cx:render()
end

local function fail(state: State, message: string)
	reply(state, { phase = "error", error = message })
end

tern.block.define("session-import", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local state: State = { cx = cx, reply = { phase = "loading" }, closed = false }
		if saved then
			state.reply = { phase = "error", error = "The plugin reloaded during session import. Run the command again." }
			return state
		end
		local pane = tonumber(args[1])
		if not pane then
			state.reply = { phase = "error", error = "No source pane was provided." }
			return state
		end
		local source_key = pane % 17592186044416
		tern.process.run({ TERN, "inspect", "--json" }, { timeout_ms = 8000 }, function(result)
			if state.closed then
				return
			end
			if result.status ~= 0 then
				fail(state, "Cannot inspect this host's panes: " .. result.stderr)
				return
			end
			local ok, catalog = pcall(tern.json.decode, result.stdout)
			local source = nil
			if ok and type(catalog) == "table" and type(catalog.panes) == "table" then
				for _, item in catalog.panes do
					if item.pane % 17592186044416 == source_key then
						if source then
							fail(state, "This Tern version returned an ambiguous pane id. Restart Tern and run the command again.")
							return
						end
						source = item
					end
				end
			end
			if not source or not tasks.is_text(source.omp_session_file) then
				fail(state, "This pane is not running omp. Focus the omp pane and run the command again.")
				return
			end
			pane = source.pane
			local file = source.omp_session_file
			local id = string.match(file, "_([%w%-]+)%.jsonl$")
			if not id then
				fail(state, "Unrecognized omp session file: " .. file)
				return
			end
			local path_ok, path = pcall(tern.kv.get, "todo-proto.file")
			if not path_ok or not tasks.is_text(path) then
				fail(state, "Open the Tasks block once on this host before adding a session.")
				return
			end
			state.path = path
			tern.process.run({ "/usr/bin/head", "-n", "2", "--", file }, { timeout_ms = 5000 }, function(head)
				if state.closed then
					return
				end
				if head.status ~= 0 then
					fail(state, "The omp session is not saved yet. Send a message in omp first.")
					return
				end
				local title, found_id = session.read_head(head.stdout)
				if found_id ~= id then
					fail(state, "Cannot read the omp session id: " .. file)
					return
				end
				if title == "" and source.title ~= "omp" then
					title = source.title
				end
				title = tasks.strip_glyph((string.gsub(title, "%s+", " ")))
				state.target = { pane = pane, cwd = source.cwd or "", session = id, title = title }
				local known = false
				local _, err = tasks.edit_file(path, function(list)
					known = tasks.find_task(list, pane, id) ~= nil
					return false
				end)
				if err then
					fail(state, err)
				else
					reply(state, { phase = "ready", title = title, known = known })
				end
			end)
		end)
		return state
	end,
	view = function(state: State): BlockView
		return { main = tern.ui.col({ tern.ui.text(tern.json.encode(state.reply)) }) }
	end,
	title = function(): string
		return "Add omp session"
	end,
	save = function(): any
		return { pending = true }
	end,
	event = function(state: State, ev: UiEvent)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "cancel" then
			state.closed = true
			state.cx:exit(0)
		elseif ev.act == "commit" and state.reply.phase == "ready" and state.path and state.target then
			local title = if type(ev.title) == "string" then tasks.strip_glyph((string.gsub(ev.title, "%s+", " "))) else ""
			if title == "" and not state.reply.known then
				fail(state, "A task title is required.")
				return
			end
			state.target.title = title
			local outcome, shown, err = tasks.add_task(state.path, state.target)
			if not outcome then
				fail(state, err or "Could not add the task.")
				return
			end
			if outcome ~= "exists" then
				local ok, old = pcall(tern.kv.get, "todo-proto.nudge")
				local n = if ok and type(old) == "table" and type(old.n) == "number" then old.n + 1 else 1
				pcall(tern.kv.set, "todo-proto.nudge", { path = state.path, n = n })
			end
			reply(state, { phase = "done", outcome = outcome, title = shown })
		end
	end,
})

return true
