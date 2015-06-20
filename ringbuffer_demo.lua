local rb = require'ringbuffer'
local ffi = require'ffi'
local rand = math.random

local b = rb.cdatabuffer(50, 'char', function() end)

local function randstr(n)
	return string.char(rand(('A'):byte(), ('Z'):byte())):rep(n)
end

math.randomseed(os.time())

for i = 1, 1000 do

	local n = math.floor(rand(-b:length(), b:size() - b:length()) / rand(16))
	if rand() > 0.9 then --hit full
		n = b:size() - b:length()
	elseif rand() < 0.1 then --hit empty
		n = -b:length()
	end
	if n > 0 then
		b:push(randstr(n), n)
	elseif n < 0 then
		b:pop(n * (rand() > .5 and 1 or -1), function() end)
	end

	local i1, n1 = b:next_segment()
	local i2, n2 = b:next_segment(i1)
	local s = ffi.string(b:data(), b:size())
	if n2 then
		print(s:sub(1, n2)..('.'):rep(b:size() - n1 - n2)..s:sub(i1, i1 + n1 - 1),
			string.format('%2d-%2d, %2d-%2d', i1, i1 + n1 - 1, i2, i2 + n2 - 1))
	elseif n1 then
		print(('.'):rep(i1 - 1)..s:sub(i1, i1 + n1 - 1)..('.'):rep(b:size() - (i1 + n1) + 1),
			string.format('%2d-%2d', i1, i1 + n1 - 1))
	end

end
