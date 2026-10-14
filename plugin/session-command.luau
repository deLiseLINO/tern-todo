--!strict
local busy: { [number]: boolean } = {}

local function add(cx: WindowCx)
	local source = cx.session:focused()
	local info = if source then cx.session:pane("@focused") else nil
	if not source or not info then
		cx:toast("error", "No focused pane")
		return
	end
	if info.kind ~= "terminal" and info.kind ~= "agent" then
		cx:toast("error", "Focus the pane running omp", "This pane is not a terminal")
		return
	end
	if busy[source] then
		return
	end
	local host = cx.hosts:current().id
	local pane = cx:new_block("todo-proto.session-import", { tostring(source) }, "tab", { focus = false })
	if not pane then
		cx:toast("error", "Session import is unavailable on this host", "Update Todo on this host with tern plugin install github.com/deLiseLINO/tern-todo/plugin --force.")
		return
	end
	busy[source] = true
	local committing = false
	local function close(fresh: WindowCx)
		busy[source] = nil
		pcall(function()
			fresh.session:event(pane, { ev = "action", act = "cancel" })
		end)
		pcall(function()
			fresh.layout:close(pane)
		end)
	end
	local function failed(fresh: WindowCx, message: string)
		close(fresh)
		fresh:toast("error", "Could not add the omp session", message)
	end
	local function watch(fresh: WindowCx, remaining: number)
		local ok, result = pcall(function()
			return fresh.session:surface(pane, { as = "table", root = "main", depth = 4, nodes = 16 })
		end)
		if not ok or not result then
			failed(fresh, "The session import block is no longer available.")
			return
		end
		local decoded, reply = pcall(function()
			return tern.json.decode(result.main.c[1].p.spans[1].t)
		end)
		if decoded and type(reply) == "table" then
			if reply.phase == "error" then
				failed(fresh, tostring(reply.error))
				return
			elseif reply.phase == "done" then
				close(fresh)
				fresh:toast(if reply.outcome == "added" then "success" else "info", if reply.outcome == "added" then "Added to tasks" else "Already in tasks", reply.title)
				return
			elseif reply.phase == "ready" and not committing then
				local function commit(next_cx: WindowCx, title: string)
					committing = true
					local sent, err = pcall(function()
						next_cx.session:event(pane, { ev = "action", act = "commit", title = title })
					end)
					if not sent then
						failed(next_cx, "The session import block is no longer available: " .. tostring(err))
						return
					end
					tern.timer(100, function(after)
						if after then
							watch(after, 100)
						end
					end)
				end
				if reply.known then
					commit(fresh, reply.title or "")
				elseif fresh.hosts:current().id ~= host or fresh.session:focused() ~= source then
					failed(fresh, "The focused pane changed. Run the command again on the omp pane.")
				else
					fresh:prompt({ value = reply.title or "", placeholder = "Task title", action = "add" }):next(function(title, _err, after)
						if not after then
							busy[source] = nil
							return
						end
						if type(title) == "string" and string.match(title, "%S") then
							commit(after, title)
						else
							close(after)
						end
					end)
				end
				return
			end
		end
		if remaining <= 1 then
			failed(fresh, "This host did not finish session import. Check its connection and retry.")
			return
		end
		tern.timer(100, function(after)
			if after then
				watch(after, remaining - 1)
			end
		end)
	end
	tern.timer(100, function(fresh)
		if fresh then
			watch(fresh, 150)
		end
	end)
end

return { add = add }
