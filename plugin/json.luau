--!strict

local function collect_strings(value: any, strings: { [string]: boolean })
	if type(value) == "string" then
		strings[value] = true
	elseif type(value) == "table" then
		for _, v in value do
			collect_strings(v, strings)
		end
	end
end

local function mark_nulls(text: string, marker: string): string
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
				table.insert(out, '"' .. marker .. '"')
				from = e + 1
				i = e
			end
		end
		i += 1
	end
	table.insert(out, string.sub(text, from))
	return table.concat(out)
end

local function restore_nulls(value: any, marker: string): any
	if value == marker then
		return tern.json.null
	elseif type(value) == "table" then
		for k, v in value do
			value[k] = restore_nulls(v, marker)
		end
	end
	return value
end

local function decode(text: string): any
	local plain = tern.json.decode(text)
	local strings: { [string]: boolean } = {}
	collect_strings(plain, strings)
	local marker = "__todo_proto_null__"
	while strings[marker] do
		marker ..= "_"
	end
	-- Only object nulls need marking. Native decoding preserves array nulls and array tags.
	return restore_nulls(tern.json.decode(mark_nulls(text, marker)), marker)
end

return { decode = decode }
