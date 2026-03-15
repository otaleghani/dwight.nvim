# LuaKit

A lightweight HTTP toolkit for Lua.

## Usage

```lua
local luakit = require("init")
luakit.setup({ timeout = 10 })

local res = luakit.get("http://example.com/api/users")
print(res.status, res.body)
```

## Modules

- `http` - HTTP client with GET/POST/PUT/DELETE
- `config` - Configuration loading and validation
- `utils` - URL parsing and encoding utilities
- `parser` - Response parsing (JSON, headers, content-type)
