"""
Offline harness for the pure-Luau world planners.

Bundles every ModuleScript under src/ into a virtual DataModel (using the same
mapping as default.project.json), then runs an entry chunk with the Luau CLI.
Modules see `script`, `game:GetService`, `require` and a small `Color3` shim,
so planners written for Studio run unchanged.

    python tools/harness/run_luau.py tools/harness/entries/building.luau > out.json
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LUAU = os.environ.get("LUAU_BIN", "luau")


def collect(project: dict) -> dict[str, str]:
    """Return {"Service/Path/Module": source} for every Lua file mapped by the project."""
    out: dict[str, str] = {}

    def walk_fs(fs_path: str, inst_path: str) -> None:
        if os.path.isdir(fs_path):
            init = None
            for cand in ("init.lua", "init.luau"):
                if os.path.exists(os.path.join(fs_path, cand)):
                    init = os.path.join(fs_path, cand)
            if init:
                out[inst_path] = open(init, encoding="utf-8").read()
            for name in sorted(os.listdir(fs_path)):
                if name.startswith("init."):
                    continue
                full = os.path.join(fs_path, name)
                if os.path.isdir(full):
                    walk_fs(full, inst_path + "/" + name)
                elif name.endswith((".lua", ".luau")):
                    base = name.rsplit(".", 1)[0]
                    if base.endswith(".server") or base.endswith(".client"):
                        continue
                    out[inst_path + "/" + base] = open(full, encoding="utf-8").read()

    def walk_tree(node: dict, inst_path: str) -> None:
        if "$path" in node:
            walk_fs(os.path.join(REPO, node["$path"]), inst_path)
        for k, v in node.items():
            if k.startswith("$") or not isinstance(v, dict):
                continue
            walk_tree(v, (inst_path + "/" if inst_path else "") + k)

    walk_tree(project["tree"], "")
    return out


def lua_long(s: str) -> str:
    level = 0
    while ("]" + "=" * level + "]") in s:
        level += 1
    eq = "=" * (level + 1)
    return f"[{eq}[{s}]{eq}]"


PRELUDE = r"""
local SOURCES = __SOURCES__
local cache = {}
local nodes = {}

local function makeNode(path)
	if nodes[path] then return nodes[path] end
	local name = string.match(path, "([^/]+)$") or path
	local parentPath = string.match(path, "^(.*)/[^/]+$")
	local node = {}
	nodes[path] = node
	local meta = {}
	meta.__index = function(_, key)
		if key == "Name" then return name end
		if key == "Parent" then return parentPath and makeNode(parentPath) or nil end
		if key == "WaitForChild" or key == "FindFirstChild" then
			return function(_, child) return makeNode(path .. "/" .. child) end
		end
		if key == "__path" then return path end
		return makeNode(path .. "/" .. key)
	end
	meta.__tostring = function() return path end
	setmetatable(node, meta)
	return node
end

local game = { GetService = function(_, name) return makeNode(name) end }
game.Workspace = makeNode("Workspace")

local Color3 = {
	fromHex = function(h) return { hex = h } end,
	fromRGB = function(r, g, b) return { r = r / 255, g = g / 255, b = b / 255 } end,
	new = function(r, g, b) return { r = r, g = g, b = b } end,
}

local function harnessRequire(target)
	local path = rawget(target, "__p") or tostring(target)
	if cache[path] ~= nil then return cache[path] end
	local src = SOURCES[path]
	assert(src, "harness: no module at " .. path)
	local fn, err = loadstring(src, "=" .. path)
	assert(fn, err)
	local env = setmetatable({ script = makeNode(path), game = game, require = harnessRequire, Color3 = Color3 }, { __index = _G })
	setfenv(fn, env)
	local result = fn()
	cache[path] = result
	return result
end

local function encode(v, out)
	local t = type(v)
	if t == "table" then
		if #v > 0 or next(v) == nil then
			table.insert(out, "[")
			for i, x in ipairs(v) do
				if i > 1 then table.insert(out, ",") end
				encode(x, out)
			end
			table.insert(out, "]")
		else
			table.insert(out, "{")
			local first = true
			local keys = {}
			for k in pairs(v) do table.insert(keys, tostring(k)) end
			table.sort(keys)
			for _, k in ipairs(keys) do
				if not first then table.insert(out, ",") end
				first = false
				table.insert(out, string.format("%q:", k))
				encode(v[k], out)
			end
			table.insert(out, "}")
		end
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then table.insert(out, "null")
		elseif v == math.floor(v) and math.abs(v) < 1e15 then table.insert(out, string.format("%d", v))
		else table.insert(out, string.format("%.4f", v)) end
	elseif t == "string" then
		table.insert(out, string.format("%q", v))
	elseif t == "boolean" then
		table.insert(out, tostring(v))
	else
		table.insert(out, "null")
	end
end

local function toJson(v)
	local out = {}
	encode(v, out)
	return table.concat(out)
end

local HARNESS = { require = function(path) return harnessRequire(makeNode(path)) end, json = toJson }
"""


def main() -> None:
    entry = sys.argv[1]
    project = json.load(open(os.path.join(REPO, "default.project.json"), encoding="utf-8"))
    sources = collect(project)
    src_table = "{\n" + ",\n".join(f'["{k}"] = {lua_long(v)}' for k, v in sources.items()) + "\n}"
    bundle = PRELUDE.replace("__SOURCES__", src_table)
    # string-keyed nodes: make tostring(node) resolve to the path
    bundle += "\n" + open(entry, encoding="utf-8").read()
    tmp = os.path.join(os.environ.get("HARNESS_TMP", "/tmp/claude-0"), "harness_bundle.luau")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(bundle)
    extra = ["-a"] + sys.argv[2:] if len(sys.argv) > 2 else []
    res = subprocess.run([LUAU, tmp] + extra, capture_output=True, text=True)
    sys.stdout.write(res.stdout)
    if res.returncode != 0 or res.stderr:
        sys.stderr.write(res.stderr)
    sys.exit(res.returncode)


if __name__ == "__main__":
    main()
