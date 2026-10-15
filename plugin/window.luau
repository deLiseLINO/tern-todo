--!strict
local remote = require("./remote")
local BLOCK = "todo-proto.list"
local SAMPLE_MS = 200
local KEEPALIVE_MS = 4000
local SLICE_MS = 10
local SLICE_STEPS = 8
local CONTINUE_MS = 20
local PANE_MOD = 17592186044416

type Feed = { generation: string, previous: { [number]: string } }
type Delivery = { generation: string, signature: string, sent: number }
type Resolution = { generation: string, requested: number | string, target: number | string, id: number }
type Snapshot = { generation: string, signature: string, json: string, targets: { number }, destinations: { [number]: number | string } }
local feeds: { [number]: Feed } = {}
local deliveries: { [number]: Delivery } = {}
local resolutions: { [number]: Resolution } = {}
local snapshots: { [number]: Snapshot } = {}
local scan: thread? = nil
local delivery: thread? = nil
local deliver_next = false
local sample_cx: WindowCx
local next_sample = 0

-- Each resume performs at most one native read/write, or a small CPU-only chunk.
local function checkpoint()
	coroutine.yield()
end

local cpu_steps = 0
local function cpu_checkpoint()
	cpu_steps += 1
	if cpu_steps >= 32 then
		cpu_steps = 0
		checkpoint()
	end
end
local armed = false

tern.route.open(function(req, _cx)
	if string.match(req.path, "%.todo%.json$") then
		return { block = BLOCK, args = { req.path } }
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

local function ask_open(pane: number | string): boolean
	checkpoint()
	local ok, tree = pcall(function()
		return sample_cx.session:surface(pane, { as = "table", root = "e", depth = 3, nodes = 40 })
	end)
	return ok and type(tree) == "table" and has_ask(tree.main)
end

local function agent_state(agent: any, pane: number | string): string?
	local state = agent.state
	if state ~= "working" and state ~= "waiting_input" and state ~= "idle" and state ~= "exited" then
		return nil
	end
	if state == "working" and agent.busy == false then
		state = "idle"
	end
	if state == "waiting_input" then
		checkpoint()
		local ok, tree = pcall(function()
			return sample_cx.session:surface(pane, { as = "table", root = "layer", depth = 1, nodes = 16 })
		end)
		if ok and type(tree) == "table" and tree.surface
			and tree.surface.role == "omp.session" and tree.main
			and tree.main.id == "layer" and not tree.main.more
			and (tree.main.c == nil or #tree.main.c == 0)
			and not ask_open(pane) then
			state = if agent.busy == false then "idle" else "working"
		end
	end
	return state
end

local function collect()
	checkpoint()
	local hosts_ok, hosts = pcall(function()
		return sample_cx.hosts:list()
	end)
	checkpoint()
	local panes_ok, panes = pcall(function()
		return sample_cx.session:panes()
	end)
	if not hosts_ok or type(hosts) ~= "table" or not panes_ok or type(panes) ~= "table" then
		feeds = {}
		deliveries = {}
		snapshots = {}
		resolutions = {}
		return
	end
	local connected: { [number]: any } = {}
	local membership: { [number]: number } = {}
	for _, host in hosts do
		cpu_checkpoint()
		if type(host) == "table" and type(host.id) == "number" and host.state == "connected"
			and type(host.panes) == "table" then
			connected[host.id] = host
			for _, pane in host.panes do
				if type(pane) == "number" then
					cpu_checkpoint()
					membership[pane] = host.id
				end
			end
		end
	end
	local blocks: { [number]: { number } } = {}
	checkpoint()
	local ids_ok, local_ids = pcall(tern.kv.get, "todo-proto.pane_ids")
	local destinations: { [number]: number | string } = {}
	local live: { [number]: boolean } = {}
	local block_panes: { [number]: boolean } = {}
	local descriptors: { [number]: any } = {}
	local seen: { [number]: boolean } = {}
	local function resolve(pane: any): (number, number | string)
		local host = membership[pane.pane]
		local gen = if host ~= nil then generation(connected[host]) else ""
		local target: number | string = pane.pane
		local local_id = if ids_ok and type(local_ids) == "table" and host == 0
			then local_ids[tostring(pane.pane % PANE_MOD)] else nil
		if type(local_id) == "number" then
			target = tostring(local_id)
		end
		local requested = target
		local cached = resolutions[pane.pane]
		if cached and cached.generation == gen and cached.requested == requested then
			return cached.id, cached.target
		end
		checkpoint()
		local info = sample_cx.session:pane(target)
		if info == nil and type(target) == "number" then
			target = tostring(pane.pane)
			checkpoint()
			info = sample_cx.session:pane(target)
		end
		local id = if info then info.pane else pane.pane
		-- Do not retain a failed lookup; a newly opened pane can become available later.
		if info then
			resolutions[pane.pane] = { generation = gen, requested = requested, target = target, id = id }
		end
		return id, target
	end
	for _, pane in panes do
		cpu_checkpoint()
		if type(pane) == "table" and type(pane.pane) == "number" then
			seen[pane.pane] = true
			descriptors[pane.pane] = pane
			local cached = resolutions[pane.pane]
			local id = if cached then cached.id else pane.pane
			live[id] = true
			if pane.block == BLOCK then
				local target: number | string
				id, target = resolve(pane)
				destinations[id] = target
				live[id] = true
				local host = membership[id]
				if host ~= nil then
					if blocks[host] == nil then
						blocks[host] = {}
					end
					table.insert(blocks[host], id)
					block_panes[id] = true
				end
			end
		end
	end
	for pane in resolutions do
		cpu_checkpoint()
		if not seen[pane] then
			resolutions[pane] = nil
		end
	end
	for host in feeds do
		cpu_checkpoint()
		if blocks[host] == nil then
			feeds[host] = nil
			snapshots[host] = nil
		end
	end
	for pane in deliveries do
		cpu_checkpoint()
		if not block_panes[pane] then
			deliveries[pane] = nil
		end
	end
	if next(blocks) == nil then
		return
	end
	checkpoint()
	local agents_ok, agents = pcall(function()
		return sample_cx.agents:list()
	end)
	if not agents_ok or type(agents) ~= "table" then
		feeds = {}
		snapshots = {}
		return
	end
	-- Build each complete host feed before publishing it. Partial scans never imply exit.
	for host_id, targets in blocks do
		cpu_checkpoint()
		local gen = generation(connected[host_id])
		local feed = feeds[host_id]
		if feed == nil or feed.generation ~= gen then
			feed = { generation = gen, previous = {} }
			feeds[host_id] = feed
		end
		local states: { [number]: string } = {}
		local observed: { [number]: boolean } = {}
		for _, agent in agents do
			cpu_checkpoint()
			if type(agent) == "table" and type(agent.pane) == "number"
				and (agent.host == host_id or (agent.host == nil and membership[agent.pane] == host_id)) then
				local pane = (agent.pane % PANE_MOD) + host_id * PANE_MOD
				observed[pane] = true
				local descriptor = descriptors[pane] or descriptors[agent.pane]
				if descriptor then
					local id, target = resolve(descriptor)
					destinations[id] = target
					live[id] = true
				end
				local state = agent_state(agent, destinations[pane] or agent.pane)
				if state then
					states[pane] = state
				end
			end
		end
		for pane in feed.previous do
			cpu_checkpoint()
			if not observed[pane] and live[pane] and membership[pane] == host_id then
				states[pane] = "exited"
			end
		end
		feed.previous = states
		local keys: { number } = {}
		for pane in states do
			cpu_checkpoint()
			table.insert(keys, pane)
		end
		table.sort(keys)
		local signature: { string } = {}
		local transported: { [string]: string } = {}
		for _, pane in keys do
			cpu_checkpoint()
			table.insert(signature, tostring(pane) .. "=" .. states[pane])
			transported[tostring(pane % PANE_MOD)] = states[pane]
		end
		local sig = table.concat(signature, "\n")
		local json = tern.json.encode({ states = transported })
		checkpoint()
		snapshots[host_id] = { generation = gen, signature = sig, json = json, targets = targets, destinations = destinations }
	end
end

local function deliver()
	while true do
		for host, snapshot in snapshots do
			for _, pane in snapshot.targets do
				checkpoint()
				local now = tern.now()
				local last = deliveries[pane]
				if snapshots[host] == snapshot and (last == nil or last.generation ~= snapshot.generation or last.signature ~= snapshot.signature
					or now - last.sent >= KEEPALIVE_MS) then
					local sent = pcall(function()
						sample_cx.session:event(snapshot.destinations[pane], { ev = "action", act = "todo.states", json = snapshot.json })
					end)
					if sent then
						deliveries[pane] = { generation = snapshot.generation, signature = snapshot.signature, sent = now }
					end
				end
			end
		end
		checkpoint()
	end
end

local function sample(cx: WindowCx): number
	sample_cx = cx
	local started = tern.now()
	if scan == nil and started >= next_sample then
		scan = coroutine.create(collect)
		next_sample = started + SAMPLE_MS
	end
	if delivery == nil then
		delivery = coroutine.create(deliver)
	end
	for _step = 1, SLICE_STEPS do
		if tern.now() - started >= SLICE_MS then
			break
		end
		-- Keepalives continue while a large scan is in progress.
		local worker = if deliver_next or scan == nil then delivery else scan
		deliver_next = not deliver_next
		local ok = coroutine.resume(worker :: thread)
		if not ok or coroutine.status(worker :: thread) == "dead" then
			if worker == scan then
				scan = nil
			else
				delivery = nil
				break
			end
		end
	end
	return CONTINUE_MS
end

local function arm(delay: number?)
	if armed then
		return
	end
	armed = true
	tern.timer(delay or SAMPLE_MS, function(cx)
		armed = false
		local delay = SAMPLE_MS
		if cx then
			local ok, next_delay = pcall(sample, cx)
			if ok then
				delay = next_delay
			end
		end
		arm(delay)
	end)
end

tern.on("window_start", function(_cx)
	arm()
end)

-- Reloading into an existing window does not deliver window_start.
tern.timer(300, function(_cx)
	arm()
end)

tern.command({
	id = "add-omp-session",
	title = "Todo: add this omp session to tasks",
	group = "Todo",
	icon = "check",
	run = require("./session-command").add,
})

local function open_settings(cx: WindowCx)
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane("@focused") else nil
	if not pane or not info or info.block ~= BLOCK then
		cx:toast("error", "Focus a Todos block first")
		return
	end
	local sent, err = pcall(function()
		cx.session:event(pane, { ev = "action", act = "todo.settings" })
	end)
	if not sent then
		cx:toast("error", "Could not open Todo settings", tostring(err))
	end
end

tern.command({
	id = "settings",
	title = "Todo: settings",
	group = "Todo",
	icon = "check",
	run = open_settings,
})
