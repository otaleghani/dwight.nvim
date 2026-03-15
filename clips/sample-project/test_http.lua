-- Tests for HTTP utilities

local utils = require("utils")

local function test_parse_url()
  local parsed = utils.parse_url("http://example.com/api/users")
  assert(parsed.host == "example.com")
  assert(parsed.port == 80)
  assert(parsed.path == "/api/users")
  assert(parsed.protocol == "http")
  print("PASS: test_parse_url")
end

local function test_parse_url_with_port()
  local parsed = utils.parse_url("http://localhost:8080/health")
  assert(parsed.host == "localhost")
  assert(parsed.port == 8080)
  assert(parsed.path == "/health")
  print("PASS: test_parse_url_with_port")
end

local function test_parse_url_https()
  local parsed = utils.parse_url("https://api.example.com/v2")
  assert(parsed.port == 443)
  assert(parsed.protocol == "https")
  print("PASS: test_parse_url_https")
end

local function test_encode_query()
  local q = utils.encode_query({ page = 1, q = "hello world" })
  assert(q:find("page=1"))
  assert(q:find("q=hello%20world"))
  print("PASS: test_encode_query")
end

local function test_url_encode_special()
  assert(utils.url_encode("a b") == "a%20b")
  assert(utils.url_encode("foo@bar") == "foo%40bar")
  print("PASS: test_url_encode_special")
end

test_parse_url()
test_parse_url_with_port()
test_parse_url_https()
test_encode_query()
test_url_encode_special()
print("\nAll tests passed!")
