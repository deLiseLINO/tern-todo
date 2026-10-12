--!strict
local cached: string? = nil

local function tern_bin(): string
	if cached then
		return cached
	end
	local override = tern.getenv("TERN_BIN")
	if override and override ~= "" then
		cached = override
		return override
	end
	local candidates = { "/opt/homebrew/bin/tern", "/usr/local/bin/tern", "/usr/bin/tern" }
	local home = tern.getenv("HOME")
	if home and home ~= "" then
		table.insert(candidates, 1, string.gsub(home, "/+$", "") .. "/.local/bin/tern")
	end
	for _, path in candidates do
		if tern.fs.exists(path) then
			cached = path
			return path
		end
	end
	cached = "tern"
	return cached
end

return { tern_bin = tern_bin }
