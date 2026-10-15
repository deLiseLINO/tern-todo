--!strict
-- omp's fixed-width title slot and session header fit in the first two lines.
local function read_head(stdout: string): (string, string?)
	local title, id = "", nil
	for line in string.gmatch(stdout, "[^\n]+") do
		local ok, entry = pcall(tern.json.decode, line)
		if ok and type(entry) == "table" then
			if entry.type == "title" and type(entry.title) == "string" then
				title = entry.title
			elseif entry.type == "session" then
				if type(entry.id) == "string" then
					id = entry.id
				end
				if title == "" and type(entry.title) == "string" then
					title = entry.title
				end
			end
		end
	end
	return title, id
end

return { read_head = read_head }
