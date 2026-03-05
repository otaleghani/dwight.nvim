-- dwight/utf8.lua
-- Byte-level UTF-8 validation and sanitization.
-- Used by skills.lua and agentic.lua to ensure API payloads are valid UTF-8.

local M = {}

--- Validate and sanitize a string to ensure it contains only valid UTF-8.
--- Replaces any invalid byte sequences with '?' (U+003F).
---
--- Covers the full UTF-8 spec:
---   - Surrogates (U+D800-U+DFFF) → rejected
---   - Overlong encodings (C0-C1 leader bytes) → rejected
---   - Codepoints above U+10FFFF (F4 90+ or F5+ leader) → rejected
---   - Truncated multi-byte sequences → rejected
---   - Lone continuation bytes (80-BF without leader) → rejected
---   - Null bytes (0x00) → replaced with '?'
---
--- @param s string  Input string (arbitrary bytes)
--- @return string   Valid UTF-8 string
function M.sanitize(s)
	if not s or s == "" then
		return s
	end

	local result = {}
	local i = 1
	local len = #s

	while i <= len do
		local b = s:byte(i)

		if b <= 0x7F then
			-- ASCII: valid single byte (but replace null bytes)
			if b == 0 then
				result[#result + 1] = "?"
			else
				result[#result + 1] = s:sub(i, i)
			end
			i = i + 1
		elseif b >= 0xC2 and b <= 0xDF then
			-- 2-byte sequence: C2-DF + 80-BF
			if i + 1 <= len then
				local b2 = s:byte(i + 1)
				if b2 >= 0x80 and b2 <= 0xBF then
					result[#result + 1] = s:sub(i, i + 1)
					i = i + 2
				else
					result[#result + 1] = "?"
					i = i + 1
				end
			else
				result[#result + 1] = "?"
				i = i + 1
			end
		elseif b >= 0xE0 and b <= 0xEF then
			-- 3-byte sequence
			if i + 2 <= len then
				local b2, b3 = s:byte(i + 1), s:byte(i + 2)
				local valid = false

				if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
					if b == 0xE0 and b2 >= 0xA0 then
						valid = true -- prevent overlong
					elseif b == 0xED and b2 <= 0x9F then
						valid = true -- prevent surrogates (U+D800-U+DFFF)
					elseif b >= 0xE1 and b <= 0xEC then
						valid = true
					elseif b >= 0xEE and b <= 0xEF then
						valid = true
					end
				end

				if valid then
					result[#result + 1] = s:sub(i, i + 2)
					i = i + 3
				else
					result[#result + 1] = "?"
					i = i + 1
				end
			else
				result[#result + 1] = "?"
				i = i + 1
			end
		elseif b >= 0xF0 and b <= 0xF4 then
			-- 4-byte sequence
			if i + 3 <= len then
				local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
				local valid = false

				if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
					if b == 0xF0 and b2 >= 0x90 then
						valid = true -- prevent overlong
					elseif b >= 0xF1 and b <= 0xF3 then
						valid = true
					elseif b == 0xF4 and b2 <= 0x8F then
						valid = true -- prevent > U+10FFFF
					end
				end

				if valid then
					result[#result + 1] = s:sub(i, i + 3)
					i = i + 4
				else
					result[#result + 1] = "?"
					i = i + 1
				end
			else
				result[#result + 1] = "?"
				i = i + 1
			end
		else
			-- Invalid leader byte: C0, C1, F5-FF, or lone continuation byte (80-BF)
			result[#result + 1] = "?"
			i = i + 1
		end
	end

	return table.concat(result)
end

return M
