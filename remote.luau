--!strict
local AUTO_KEY = "remote-auto-install"
local SAMPLE_MS = 2000
local SCRIPT_LIMIT = 32768
local SETTLE_MS = 120000
local CATALOG_TRIES = 4
local BLOCK = "todo-proto.list"

type PendingOpen = { host: number, session: number? }
type Job = {
	host: any,
	generation: string,
	phase: "idle" | "starting" | "waiting-prompt" | "running" | "ready" | "failed",
	connected: boolean,
	pending: PendingOpen?,
	pane: number?,
	command: string?,
	touched: boolean?,
}

local jobs: { [string]: Job } = {}
local armed = false
local script: string? = nil
local unsupported_notified = false
local arm: () -> ()

local function enabled(): boolean
	local ok, value = pcall(tern.kv.get, AUTO_KEY)
	return ok and value == true
end

local function host_key(host: any): string
	local parts = { tostring(host.address or host.name) }
	if type(host.identity) == "table" and type(host.identity.hops) == "table" then
		for _, hop in host.identity.hops do
			if type(hop) == "table" then
				table.insert(parts, tostring(hop.principal))
				table.insert(parts, tostring(hop.user))
				table.insert(parts, tostring(hop.host))
			end
		end
	end
	return table.concat(parts, "\n")
end

local function generation(host: any): string
	local parts = { tostring(host.id) }
	if type(host.identity) == "table" and type(host.identity.hops) == "table" then
		for _, hop in host.identity.hops do
			if type(hop) == "table" then
				table.insert(parts, tostring(hop.from))
			end
		end
	end
	return table.concat(parts, "\n")
end

local function current_host(cx: WindowCx): any
	local ok, host = pcall(function()
		return cx.hosts:current()
	end)
	return if ok and type(host) == "table" then host else nil
end

local function current_session(cx: WindowCx): number?
	local ok, value = pcall(function()
		return cx.sessions:current()
	end)
	return if ok and type(value) == "table" then value.id else nil
end

local function same_target(cx: WindowCx, pending: PendingOpen): boolean
	local host = current_host(cx)
	return host ~= nil and host.id == pending.host and host.state == "connected"
		and (pending.session == nil or current_session(cx) == pending.session)
end

local function notice(cx: WindowCx, job: Job, level: "info" | "error", text: string, detail: string?)
	cx:toast(level, "Todo on " .. tostring(job.host.name) .. ": " .. text, detail)
end

local function unsupported(cx: WindowCx)
	cx:toast("error", "Automatic remote installation is unavailable", "This Tern window needs native host terminals and pane inspection APIs. Install Todo manually on the host.")
end

local function try_open(cx: WindowCx): (boolean, any)
	return pcall(function()
		return cx:new_block(BLOCK, {})
	end)
end

local function queued_open(cx: WindowCx, job: Job, remaining: number)
	local pending = job.pending
	if pending == nil then
		return
	end
	if not same_target(cx, pending) then
		job.pending = nil
		notice(cx, job, "info", "ready", "Return to this host and run Todo: open tasks.")
		return
	end
	local ok, pane = try_open(cx)
	if ok and pane then
		job.pending = nil
		return
	end
	if not ok or remaining <= 1 then
		job.pending = nil
		notice(cx, job, "error", "installed but the block is not ready", if ok then "Run Todo: open tasks again after the host catalog refreshes." else tostring(pane))
		return
	end
	tern.timer(300, function(fresh)
		if fresh and job.phase == "ready" then
			queued_open(fresh, job, remaining - 1)
		end
	end)
end

local function status_marker(text: string): string?
	local found = nil
	for line in string.gmatch(text, "[^\n]+") do
		local clean = string.gsub(line, "\r$", "")
		local status = string.match(clean, "^TERN_TODO_REMOTE ([a-z]+)$")
		if status == "present" or status == "installed" or status == "disabled"
			or status == "failed" or status == "error" or status == "busy" then
			found = status
		end
	end
	return found
end

local function close_completed(cx: WindowCx, job: Job)
	if job.pane == nil or job.command == nil or job.touched then
		return
	end
	local ok, pane = pcall(function()
		return cx.session:pane(job.pane :: number)
	end)
	if not ok or type(pane) ~= "table" or pane.at_prompt ~= true or pane.busy ~= false or pane.running ~= nil
		or type(pane.last) ~= "table" or pane.last.line ~= job.command or pane.last.status ~= 0 then
		return
	end
	local focus_ok, focused = pcall(function()
		return cx.session:focused()
	end)
	if focus_ok and focused ~= job.pane then
		pcall(function()
			cx.layout:close(job.pane :: number)
		end)
	end
end

local function completed(cx: WindowCx, job: Job, output: string?, err: string?)
	local status = if type(output) == "string" then status_marker(output) else nil
	if err == nil and (status == "present" or status == "installed") then
		local read_ok, state = pcall(function()
			return cx.session:pane(job.pane :: number)
		end)
		if not read_ok or type(state) ~= "table" or state.at_prompt ~= true or state.busy ~= false
			or state.running ~= nil or type(state.last) ~= "table" or state.last.line ~= job.command or state.last.status ~= 0 then
			err = "The dedicated terminal did not confirm completion of its own installation command. It has been left open."
		end
	end
	if err ~= nil or (status ~= "present" and status ~= "installed") then
		job.phase = "failed"
		job.pending = nil
		local detail = if err ~= nil then err
			elseif status == "disabled" then "Todo is disabled on this host. Enable it manually; automatic installation does not change plugin settings."
			elseif status == "busy" then "Another window is checking or installing Todo. Run Todo: open tasks to retry after it finishes."
			elseif status == "failed" then "An existing Todo package failed to load. Check tern plugin list on this host; it was not replaced."
			else "The installation did not confirm success. Inspect its dedicated terminal; run Todo: open tasks to retry."
		notice(cx, job, "error", "not ready", detail)
		return
	end
	if not job.connected then
		job.phase = "failed"
		job.pending = nil
		return
	end
	job.phase = "ready"
	close_completed(cx, job)
	if job.pending ~= nil then
		queued_open(cx, job, CATALOG_TRIES)
	elseif status == "installed" then
		notice(cx, job, "info", "installed", "Todo is ready on this host.")
	end
end
local function watch_completion(cx: WindowCx, job: Job, remaining: number)
	if job.phase ~= "running" then
		return
	end
	local read_ok, info = pcall(function()
		return cx.session:pane(job.pane :: number)
	end)
	if not read_ok or not info then
		completed(cx, job, nil, "The installation terminal is no longer available.")
		return
	end
	if info.at_prompt == true and info.busy == false and info.running == nil and type(info.last) == "table" then
		if info.last.line ~= job.command then
			completed(cx, job, nil, "Another command ran in the installation terminal. It has been left open.")
			return
		end
		local output_ok, output = pcall(function()
			return cx.session:read(job.pane :: number, { as = "text", lines = 200, max_chars = 64000 })
		end)
		completed(cx, job, if output_ok and type(output) == "string" then output else nil, if output_ok then nil else tostring(output))
		return
	end
	if remaining <= 1 then
		completed(cx, job, nil, "Installation did not finish within two minutes. Its terminal has been left open.")
		return
	end
	tern.timer(200, function(fresh)
		if fresh then
			watch_completion(fresh, job, remaining - 1)
		end
	end)
end


local function start(cx: WindowCx, job: Job)
	if job.pane ~= nil then
		local read_ok, state = pcall(function()
			return cx.session:pane(job.pane :: number)
		end)
		if not read_ok or (type(state) == "table" and state.exited == nil and state.at_prompt ~= true) then
			job.phase = "failed"
			job.pending = nil
			notice(cx, job, "error", "previous installation has not finished", "Inspect its dedicated terminal before retrying. No second command was started.")
			return
		end
	end
	local supported = pcall(function()
		assert(cx.hosts.terminal and cx.session.read and cx.session.pane and cx.session.focused and cx.layout.focus and cx.layout.close and cx.run)
	end)
	if not supported then
		job.phase = "failed"
		job.pending = nil
		unsupported(cx)
		return
	end
	job.phase = "starting"
	local ok, result = pcall(function()
		if script == nil then
			local text = tern.fs.read("remote-install.sh", SCRIPT_LIMIT)
			assert(#text > 0 and #text <= SCRIPT_LIMIT, "remote installer is empty or too large")
			script = text
		end
		-- printf decodes only the bundled text; keeping input on one line also preserves OSC command identity.
		local encoded = string.gsub(script :: string, "\\", "\\\\")
		encoded = string.gsub(encoded, "\n", "\\n")
		encoded = string.gsub(encoded, "\r", "\\r")
		encoded = string.gsub(encoded, "'", "'\\''")
		local wrapper = "exec /bin/sh -c \"$(printf '%b' '" .. encoded .. "')\" tern-todo-remote"
		return "/bin/sh -c '" .. string.gsub(wrapper, "'", "'\\''") .. "'"
	end)
	if not ok then
		job.phase = "failed"
		job.pending = nil
		notice(cx, job, "error", "cannot start automatic installation", tostring(result))
		return
	end
	job.command = result
	local before = current_host(cx)
	local previous_session = current_session(cx)
	local focus_ok, previous = pcall(function()
		return cx.session:focused()
	end)
	local terminal_ok, pane = pcall(function()
		return cx.hosts:terminal(job.host.id, {})
	end)
	-- terminal focuses its new shell. Restore the original workspace immediately, not in a later callback.
	if before ~= nil then
		pcall(function()
			if focus_ok and previous ~= nil then
				cx.layout:focus(previous)
			elseif previous_session ~= nil then
				cx.sessions:switch(previous_session)
			else
				cx.hosts:switch(before.id)
			end
		end)
	end
	if not terminal_ok or type(pane) ~= "number" then
		job.phase = "failed"
		job.pending = nil
		notice(cx, job, "error", "cannot create installation terminal", tostring(pane))
		return
	end
	job.pane = pane
	job.touched = false
	job.phase = "waiting-prompt"
	local function send(fresh: WindowCx, remaining: number)
		if job.phase ~= "waiting-prompt" then
			return
		end
		if job.touched then
			job.phase = "failed"
			job.pending = nil
			notice(fresh, job, "error", "installation terminal was opened for inspection", "No command was sent. Run Todo: open tasks to retry.")
			return
		end
		if not enabled() or not job.connected then
			job.phase = "failed"
			job.pending = nil
			return
		end
		local read_ok, state = pcall(function()
			return fresh.session:pane(pane)
		end)
		if not read_ok or type(state) ~= "table" or state.last ~= nil or state.running ~= nil or state.busy == true then
			job.phase = "failed"
			job.pending = nil
			notice(fresh, job, "error", "installation terminal is no longer idle", "No command was sent. The pane has been left open.")
			return
		end
		if state.at_prompt ~= true then
			if remaining <= 1 then
				job.phase = "failed"
				job.pending = nil
				notice(fresh, job, "error", "installation terminal did not reach its prompt", "No command was sent. The pane has been left open.")
			else
				tern.timer(100, function(next_cx)
					if next_cx then
						send(next_cx, remaining - 1)
					end
				end)
			end
			return
		end
		local send_ok, send_err = pcall(function()
			assert(fresh.session:focused() ~= pane, "installation pane is focused by the user")
			fresh:run(pane, (job.command :: string) .. "\r")
			job.phase = "running"
			tern.timer(200, function(next_cx)
				if next_cx then
					watch_completion(next_cx, job, SETTLE_MS / 200)
				end
			end)
		end)
		if not send_ok then
			job.phase = "failed"
			job.pending = nil
			notice(fresh, job, "error", "cannot run or await installation", tostring(send_err))
		end
	end
	send(cx, 20)
end

local function job_for(host: any): Job
	local key = host_key(host)
	local job = jobs[key]
	local connection = generation(host)
	if job == nil or not job.connected or job.generation ~= connection then
		local previous_pane = if job then job.pane else nil
		if job then
			job.connected = false
			job.phase = "failed"
			job.pending = nil
		end
		job = { host = host, generation = connection, phase = "idle", connected = true, pane = previous_pane }
		jobs[key] = job
	else
		job.host = host
	end
	return job
end

local function sample(cx: WindowCx)
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if not ok or type(hosts) ~= "table" then
		if not unsupported_notified then
			unsupported_notified = true
			unsupported(cx)
		end
		return
	end
	local seen: { [string]: boolean } = {}
	for _, host in hosts do
		if type(host) == "table" and host.kind == "remote" and host.state == "connected" then
			seen[host_key(host)] = true
			local job = job_for(host)
			if job.phase == "idle" then
				start(cx, job)
			end
		end
	end
	for key, job in jobs do
		if not seen[key] then
			job.connected = false
			job.phase = "failed"
			job.pending = nil
		end
	end
end

arm = function()
	if armed then
		return
	end
	armed = true
	tern.timer(SAMPLE_MS, function(cx)
		armed = false
		if enabled() and cx then
			pcall(sample, cx)
		end
		arm()
	end)
end

local function open(cx: WindowCx)
	local ok, pane = try_open(cx)
	if ok and pane then
		local host = current_host(cx)
		if host then
			local job = jobs[host_key(host)]
			if job and job.pending and same_target(cx, job.pending) then
				job.pending = nil
			end
		end
		return
	end
	if not ok then
		cx:toast("error", "Cannot open Todo on this host", "The host plugin failed: " .. tostring(pane))
		return
	end
	local host = current_host(cx)
	if not enabled() or (host ~= nil and host.kind == "local") then
		cx:toast("error", "Todo plugin is not ready on this host", "Install github.com/deLiseLINO/tern-todo on this host, or enable Todo: automatic installation on remote hosts.")
		return
	end
	if host == nil then
		unsupported(cx)
		return
	end
	if host.state ~= "connected" then
		cx:toast("error", "Todo host is not connected", "Reconnect this host before opening Todo.")
		return
	end
	local job = job_for(host)
	job.pending = { host = host.id, session = current_session(cx) }
	if job.phase == "ready" then
		queued_open(cx, job, CATALOG_TRIES)
	elseif job.phase ~= "running" and job.phase ~= "starting" and job.phase ~= "waiting-prompt" then
		start(cx, job)
	end
	arm()
end

tern.command({
	id = "remote-auto-install",
	title = "Todo: automatic installation on remote hosts",
	group = "Todo",
	icon = "check",
	run = function(cx: WindowCx)
		local value = not enabled()
		local ok, err = pcall(tern.kv.set, AUTO_KEY, value)
		if not ok then
			cx:toast("error", "Cannot save remote installation setting", tostring(err))
			return
		end
		cx:toast("info", "Automatic Todo installation on remote hosts " .. (if value then "enabled" else "disabled"), if value then "Connected remote hosts are checked automatically. Existing or disabled packages are never replaced." else "New remote installations will not start.")
		if value then
			arm()
		else
			for _, job in jobs do
				job.pending = nil
			end
		end
	end,
})

tern.on("focus", function(ev, cx)
	if type(ev) ~= "table" or cx == nil then
		return
	end
	local ok, focused = pcall(function()
		return cx.session:focused()
	end)
	if not ok or focused ~= ev.pane then
		return
	end
	for _, job in jobs do
		if job.pane == ev.pane then
			job.touched = true
		end
	end
end)

tern.on("window_start", function(_cx)
	arm()
end)
tern.timer(300, function(_cx)
	arm()
end)

return { open = open }
