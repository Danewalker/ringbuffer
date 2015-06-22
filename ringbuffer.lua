
-- FIFO/LIFO ring buffers represented as (start, length, size) tuples.
-- Written by Cosmin Apreutesei. Public Domain.

if not ... then require'ringbuffer_test'; return end

local ffi --init on demand so that the module can be used without luajit
local assert, min, max, abs = assert, math.min, math.max, math.abs

--stateless ring buffer algorithm (counts from 1!)

local function normalize(i, size) --normalize i over (1, size) range
	return (i - 1) % size + 1 --NOTE: '%' is slow. try a while-inc/dec loop?
end

--the heart of the algorithm: sweep an arbitrary arc over a circle, returning
--one or two of the normalized arcs that map the input arc to the circle.
--the buffer segment (start, length) is the arc in this model, and a buffer
--ring (1, size) is the circle. `start` must be normalized to (1, size).
--`length` can be positive or negative and can't exceed `size`. the second
--output segment will have zero length if there's only one segment.
--the first output segment will have zero length if input length is zero.
local function segments(start, length, size)
	if length > 0 then
		local length1 = size + 1 - start
		return start, min(length, length1), 1, max(0, length - length1)
	else --zero or negative length: map the input segment backwards from `start`
		local length1 = -start
		return start, max(length, length1), size, min(0, length - length1)
	end
end

local function head(offset, start, length, size) --offset from head
	return normalize(start + offset, size)
end

local function tail(offset, start, length, size) --offset from tail+1
	return normalize(start + length + offset, size)
end

local function offset(offset, start, length, size) --offset from head or tail+1
	return offset < 0
		and tail(offset, start, length, size)
		 or head(offset, start, length, size)
end

local function push(len, start, length, size)
	assert(abs(len) <= size - length, 'buffer overflow')
	if len > 0 then --add len to tail
		local pushstart = tail(0, start, length, size)
		local i1, n1, i2, n2 = segments(pushstart, len, size)
		local newlength = length + n1 + n2
		return start, newlength, i1, n1, i2, n2
	elseif len < 0 then --add len to head
		local i1, n1, i2, n2 = segments(start, len, size)
		local newstart = head(len, start, length, size)
		local newlength = length - n1 - n2 --n1 and n2 are negative!
		return newstart, newlength, i1, n1, i2, n2
	else
		return start, length, 1, 0, 1, 0
	end
end

local function pull(len, start, length, size)
	assert(abs(len) <= length, 'buffer underflow')
	if len > 0 then --remove len from head
		local i1, n1, i2, n2 = segments(start, len, size)
		local newstart = head(len, start, length, size)
		local newlength = length - n1 - n2
		return newstart, newlength, i1, n1, i2, n2
	elseif len < 0 then --remove len from tail
		local tail = tail(-1, start, length, size)
		local i1, n1, i2, n2 = segments(tail, len, size)
		local newlength = length + n1 + n2 --n1 and n2 are negative!
		return start, newlength, i1, n1, i2, n2
	else
		return start, length, 1, 0, 1, 0
	end
end

local function cdatabuffer(b) --ring buffer for uniform cdata values
	ffi = ffi or require'ffi'
	b = b or {}
	assert(b.size, 'size expected')
	assert(b.data or b.ctype, 'data or ctype expected')
	b.start = b.start or 0
	b.length = b.length or 0 --assume empty
	assert(b.length >= 0 and b.length <= b.size, 'invalid length')
	b.data = b.data or ffi.new(ffi.typeof('$[?]', ffi.typeof(b.ctype)), b.size)

	local function normalize_segs(i1, n1, i2, n2)
		if n1 < 0 then --invert direction of negative-size segments
			i1, n1 = i1 + n1 + 1, -n1
			i2, n2 = i2 + n2 + 1, -n2
		end
		return i1 - 1, n1, i2 - 1, n2 --count from 0
	end

	function b:push(data, len)
		len = len or 1
		local start, length, i1, n1, i2, n2 = push(len, b.start + 1, b.length, b.size)
		b.start, b.length = start - 1, length --count from 0
		i1, n1, i2, n2 = normalize_segs(i1, n1, i2, n2)
		ffi.copy(b.data + i1, data,            n1)
		ffi.copy(b.data + i2, data + (n1 - 1), n2)
		return i1, n1, i2, n2
	end

	function b:pull(len, keep)
		len = len or 1
		local start, length, i1, n1, i2, n2 = pull(len, b.start + 1, b.length, b.size)
		if keep ~= 'keep' then
			b.start, b.length = start - 1, length --count from 0
		end
		i1, n1, i2, n2 = normalize_segs(i1, n1, i2, n2)
		if b.read then
			if n1 ~= 0 then b:read(b.data + i1, n1) end
			if n2 ~= 0 then b:read(b.data + i2, n2) end
		end
		return i1, n1, i2, n2
	end

	function b:offset(ofs)
		return offset(ofs or 0, b.start + 1, b.length, b.size) - 1
	end

	return b
end

local function valuebuffer(b) --ring buffer for arbitrary Lua values
	b = b or {}
	b.data = b.data or {}
	b.start = b.start or 1
	b.length = b.length or 0 --assume empty
	b.size = b.size or #b.data
	assert(b.length >= 0 and b.length <= b.size, 'invalid length')

	local function checksign(sign)
		sign = sign or 1
		assert(abs(sign) == 1, 'invalid sign')
		return sign
	end

	function b:push(val, sign)
		sign = checksign(sign)
		local i
		b.start, b.length, i = push(sign, b.start, b.length, b.size)
		b.data[i] = val
		return i
	end

	function b:pull(sign, keep)
		sign = checksign(sign)
		local start, length, i = pull(sign, b.start, b.length, b.size)
		local val = b.data[i]
		if keep ~= 'keep' then
			b.start, b.length = start, length
			b.data[i] = false --remove the value but keep the slot
		end
		return val, i
	end

	function b:offset(ofs)
		return offset(ofs or 0, b.start, b.length, b.size)
	end

	return b
end

return {
	--algorithm
	segments = segments,
	head     = head,
	tail     = tail,
	offset   = offset,
	push     = push,
	pull     = pull,
	--buffers
	cdatabuffer = cdatabuffer,
	valuebuffer = valuebuffer,
}
