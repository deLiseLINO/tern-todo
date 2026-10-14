--!strict
local remote = require("./remote")
local BLOCK = "todo-proto.list"
local SAMPLE_MS = 200
local KEEPALIVE_MS = 4000
local PANE_MOD = 17592186044416

type Feed = { generation: string, previous: { [number]: string } }
type Delivery = { generation: string, signature: string, sent: number }
local feeds: { [number]: Feed } = {}
local deliveries: { [number]: Delivery } = {}
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

local function ask_open(cx: WindowCx, pane: number | string): boolean
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", root = "e", depth = 3, nodes = 40 })
	end)
	return ok and type(tree) == "table" and has_ask(tree.main)
end

local function agent_state(cx: WindowCx, agent: any, pane: number | string): string?
	local state = agent.state
	if state ~= "working" and state ~= "waiting_input" and state ~= "idle" and state ~= "exited" then
		return nil
	end
	if state == "working" and agent.busy == false then
		state = "idle"
	end
	if state == "waiting_input" then
		local ok, tree = pcall(function()
			return cx.session:surface(pane, { as = "table", root = "layer", depth = 1, nodes = 16 })
		end)
		if ok and type(tree) == "table" and tree.surface
			and tree.surface.role == "omp.session" and tree.main
			and tree.main.id == "layer" and not tree.main.more
			and (tree.main.c == nil or #tree.main.c == 0)
			and not ask_open(cx, pane) then
			state = if agent.busy == false then "idle" else "working"
		end
	end
	return state
end

local function sample(cx: WindowCx)
	local hosts_ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	local panes_ok, panes = pcall(function()
		return cx.session:panes()
	end)
	if not hosts_ok or type(hosts) ~= "table" or not panes_ok or type(panes) ~= "table" then
		feeds = {}
		deliveries = {}
		return
	end
	local connected: { [number]: any } = {}
	local membership: { [number]: number } = {}
	for _, host in hosts do
		if type(host) == "table" and type(host.id) == "number" and host.state == "connected"
			and type(host.panes) == "table" then
			connected[host.id] = host
			for _, pane in host.panes do
				if type(pane) == "number" then
					membership[pane] = host.id
				end
			end
		end
	end
	local blocks: { [number]: { number } } = {}
	local destinations: { [number]: number | string } = {}
	local live: { [number]: boolean } = {}
	local block_panes: { [number]: boolean } = {}
	for _, pane in panes do
		if type(pane) == "table" and type(pane.pane) == "number" then
			local info = cx.session:pane(pane.pane)
			local target: number | string = pane.pane
			if info == nil then
				target = tostring(pane.pane)
				info = cx.session:pane(target)
			end
			local id = if info then info.pane else pane.pane
			destinations[id] = target
			live[id] = true
			local host = membership[id]
			if host ~= nil and pane.block == BLOCK then
				if blocks[host] == nil then
					blocks[host] = {}
				end
				table.insert(blocks[host], id)
				block_panes[id] = true
			end
		end
	end
	for host in feeds do
		if blocks[host] == nil then
			feeds[host] = nil
		end
	end
	for pane in deliveries do
		if not block_panes[pane] then
			deliveries[pane] = nil
		end
	end
	if next(blocks) == nil then
		return
	end
	local agents_ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if not agents_ok or type(agents) ~= "table" then
		feeds = {}
		return
	end
	local now = tern.now()
	for host_id, targets in blocks do
		local gen = generation(connected[host_id])
		local feed = feeds[host_id]
		if feed == nil or feed.generation ~= gen then
			feed = { generation = gen, previous = {} }
			feeds[host_id] = feed
		end
		local states: { [number]: string } = {}
		local observed: { [number]: boolean } = {}
		for _, agent in agents do
			if type(agent) == "table" and type(agent.pane) == "number"
				and (agent.host == host_id or (agent.host == nil and membership[agent.pane] == host_id)) then
				local pane = (agent.pane % PANE_MOD) + host_id * PANE_MOD
				observed[pane] = true
				local state = agent_state(cx, agent, destinations[pane] or agent.pane)
				if state then
					states[pane] = state
				end
			end
		end
		for pane in feed.previous do
			if not observed[pane] and live[pane] and membership[pane] == host_id then
				states[pane] = "exited"
			end
		end
		feed.previous = states
		local keys: { number } = {}
		for pane in states do
			table.insert(keys, pane)
		end
		table.sort(keys)
		local signature: { string } = {}
		local transported: { [string]: string } = {}
		for _, pane in keys do
			table.insert(signature, tostring(pane) .. "=" .. states[pane])
			transported[tostring(pane % PANE_MOD)] = states[pane]
		end
		local sig = table.concat(signature, "\n")
		local json = tern.json.encode({ states = transported })
		for _, pane in targets do
			local last = deliveries[pane]
			if last == nil or last.generation ~= gen or last.signature ~= sig or now - last.sent >= KEEPALIVE_MS then
				local sent = pcall(function()
					cx.session:event(destinations[pane], { ev = "action", act = "todo.states", json = json })
				end)
				if sent then
					deliveries[pane] = { generation = gen, signature = sig, sent = now }
				end
			end
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
