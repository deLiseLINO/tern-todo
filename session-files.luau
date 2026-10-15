--!strict
local function stat_argv(paths: { string }): { string }
	local argv = if tern.runtime.os == "macos"
		then { "/usr/bin/stat", "-f", "%m %N" }
		else { "/usr/bin/stat", "-c", "%Y %n" }
	for _, path in paths do
		table.insert(argv, path)
	end
	return argv
end

local function find_argv(root: string, ids: { string }?): { string }
	local argv = { "/usr/bin/find", root, "-maxdepth", "2" }
	if ids == nil then
		table.insert(argv, "-name")
		table.insert(argv, "*.jsonl")
	elseif #ids == 0 then
		table.insert(argv, "-name")
		table.insert(argv, "")
	else
		table.insert(argv, "(")
		for i, id in ids do
			assert(string.match(id, "^[%w%-]+$"), "Invalid omp session id")
			if i > 1 then
				table.insert(argv, "-o")
			end
			local escaped = string.gsub(id, "([%[%]%*%?\\])", "\\%1")
			table.insert(argv, "-name")
			table.insert(argv, "*_" .. escaped .. ".jsonl")
		end
		table.insert(argv, ")")
	end
	table.insert(argv, "-exec")
	for _, arg in stat_argv({ "{}", "+" }) do
		table.insert(argv, arg)
	end
	return argv
end

return { stat_argv = stat_argv, find_argv = find_argv }
