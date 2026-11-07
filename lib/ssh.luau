--!strict
-- OpenSSH plumbing for the window half: one control master per host, kept on
-- a control socket, carries every forward. Each step is a short `ssh -O …`
-- command, so nothing the plugin starts outlives it except the master, which
-- `ssh -O exit` ends. Pure functions here: argv builders and parsers.

local M = {}

-- A forward the user asked for: localhost:lport → rhost:rport as seen from host.
export type Forward = { host: string, lport: number, rhost: string, rport: number }

-- A TCP port listening on the remote host.
export type Listener = {
	port: number,
	-- Addresses it listens on, as the remote reports them (`0.0.0.0`, `[::]`, `127.0.0.1`).
	addrs: { string },
	-- The owning program, when the remote tells us.
	process: string?,
	-- Where a forward should connect to on the remote side.
	target: string,
}

-- Hosts are passed to ssh as one argv element after `--`; reject what ssh
-- would read differently (options, whitespace) and our action separator.
function M.valid_host(host: string): boolean
	return host ~= "" and string.find(host, "^[%w%._@%-%[%]:/]+$") ~= nil and string.sub(host, 1, 1) ~= "-"
end

function M.valid_port(n: number?): boolean
	return n ~= nil and n >= 1 and n <= 65535 and n == math.floor(n)
end

-- FNV-1a, 32 bits, as 8 hex digits: a short stable name per host, so the
-- socket path stays under the 104-byte limit of macOS Unix sockets.
local function fnv(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- h * 16777619 (2^24 + 403) mod 2^32, without leaving exact doubles.
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

local function socket_dir(): string
	for _, var in { "XDG_RUNTIME_DIR", "TMPDIR" } do
		local dir = tern.getenv(var)
		if dir and dir ~= "" then
			return (string.gsub(dir, "/+$", ""))
		end
	end
	return "/tmp"
end

function M.socket(host: string): string
	return socket_dir() .. "/tern-ports-" .. fnv(host) .. ".sock"
end

local function control(host: string): { string }
	return { "-o", "ControlPath=" .. M.socket(host) }
end

-- `ssh -o ControlPath=… <options> -- <host> [<remote command>]`.
local function argv(host: string, options: { string }, command: string?): { string }
	local out = { "ssh" }
	table.move(control(host), 1, 2, #out + 1, out)
	table.move(options, 1, #options, #out + 1, out)
	table.insert(out, "--")
	table.insert(out, host)
	if command then
		table.insert(out, command)
	end
	return out
end

-- Options of the master: no prompts (a terminal handles those, see
-- `master_shell`), dead links noticed within ~45 s, forwards that fail to
-- bind reported to the `-O forward` that asked instead of killing the master.
local MASTER_OPTS = {
	"-o", "ControlMaster=yes",
	"-o", "ControlPersist=no",
	"-o", "ConnectTimeout=10",
	"-o", "ServerAliveInterval=15",
	"-o", "ServerAliveCountMax=3",
	"-o", "ExitOnForwardFailure=no",
	"-f", "-N",
}

function M.master(host: string): { string }
	local opts = { "-o", "BatchMode=yes" }
	table.move(MASTER_OPTS, 1, #MASTER_OPTS, #opts + 1, opts)
	return argv(host, opts)
end

local function shell_quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- The master as a shell command line for a terminal pane, where ssh can ask
-- for passwords, passphrases and unknown host keys; `-f` backgrounds it once
-- authenticated, so the pane's command ends and the master stays.
function M.master_shell(host: string): string
	local parts = {}
	for _, a in argv(host, MASTER_OPTS) do
		table.insert(parts, if string.find(a, "^[%w%._@/=:%-]+$") then a else shell_quote(a))
	end
	return table.concat(parts, " ") .. " && echo 'Connected: Tern Ports can forward through " .. host .. " now.'"
end

function M.check(host: string): { string }
	return argv(host, { "-O", "check" })
end

function M.exit(host: string): { string }
	return argv(host, { "-O", "exit" })
end

local function bracket(addr: string): string
	if string.find(addr, ":", 1, true) and string.sub(addr, 1, 1) ~= "[" then
		return "[" .. addr .. "]"
	end
	return addr
end

function M.spec(f: Forward): string
	return string.format("%d:%s:%d", f.lport, bracket(f.rhost), f.rport)
end

function M.forward(f: Forward): { string }
	return argv(f.host, { "-O", "forward", "-L", M.spec(f) })
end

function M.cancel(f: Forward): { string }
	return argv(f.host, { "-O", "cancel", "-L", M.spec(f) })
end

-- The remote's listening TCP sockets, through the master, in two flavors
-- since ssh hands the command to the remote's login shell. A marker line
-- names the tool used, and parse_scan reads any of them.
--
-- POSIX: one sh script, whatever the login shell (bash, zsh, fish…).
local SCAN_POSIX = "if command -v ss >/dev/null 2>&1; then echo @ss; ss -ltnpH; "
	.. "elif command -v lsof >/dev/null 2>&1; then echo @lsof; lsof -nP -iTCP -sTCP:LISTEN; "
	.. "else echo @netstat; netstat -an; fi"
-- Windows: OpenSSH's default shell there is cmd or PowerShell; both run
-- `cmd /c "…"` the same way, and `&` chains inside cmd. tasklist maps the
-- pids netstat prints to program names.
local SCAN_WINDOWS = 'cmd /c "echo @win& netstat -ano & tasklist /fo csv /nh"'

export type ScanKind = "posix" | "windows"

function M.scan(host: string, kind: ScanKind): { string }
	local command = if kind == "windows" then SCAN_WINDOWS else "sh -c " .. shell_quote(SCAN_POSIX)
	return argv(host, { "-o", "ControlMaster=no", "-o", "BatchMode=yes" }, command)
end

-- Whether a scan's output came from a script that ran (it may list no ports).
-- A shell that didn't understand the command prints no marker line.
function M.scanned(out: string): boolean
	return string.find(out, "^@%a+") ~= nil or string.find(out, "\n@%a+") ~= nil
end

-- This machine's listening TCP sockets, `-F` fields: `p<pid>` then `n<addr>` lines.
M.LOCAL_LISTENERS = { "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn" }

-- `Master running (pid=N)` from `-O check`; nil when no master answers.
function M.master_pid(out: string): number?
	local pid = string.match(out, "Master running %(pid=(%d+)%)")
	return if pid then tonumber(pid) else nil
end

-- The last line ssh printed, without its `mux_client_…:` prefixes.
function M.error_line(stderr: string): string
	local last = ""
	for line in string.gmatch(stderr, "[^\r\n]+") do
		if not string.find(line, "^%s*$") then
			last = line
		end
	end
	last = string.gsub(last, "^[%w_]+: ", "")
	return if last == "" then "ssh failed" else last
end

-- Port → set of pids from `lsof -Fpn`.
function M.parse_local(out: string): { [number]: { [number]: boolean } }
	local ports: { [number]: { [number]: boolean } } = {}
	local pid: number? = nil
	for line in string.gmatch(out, "[^\n]+") do
		local tag, rest = string.sub(line, 1, 1), string.sub(line, 2)
		if tag == "p" then
			pid = tonumber(rest)
		elseif tag == "n" and pid then
			local port = tonumber(string.match(rest, ":(%d+)$") or "")
			if port then
				ports[port] = ports[port] or {}
				ports[port][pid] = true
			end
		end
	end
	return ports
end

local function split_addr(s: string, sep: string): (string?, number?)
	local addr, port = string.match(s, "^(.*)" .. sep .. "(%d+)$")
	if not addr then
		return nil, nil
	end
	addr = string.gsub(addr, "%%.*$", "") -- `127.0.0.53%lo` → `127.0.0.53`
	return addr, tonumber(port)
end

local WILDCARD = { ["0.0.0.0"] = true, ["*"] = true, ["::"] = true, ["[::]"] = true }

local function target_of(addrs: { string }): string
	local v6loop = false
	for _, a in addrs do
		if WILDCARD[a] or a == "127.0.0.1" then
			return "127.0.0.1"
		end
		v6loop = v6loop or a == "::1" or a == "[::1]"
	end
	if v6loop then
		return "::1"
	end
	return (string.gsub(addrs[1], "^%[(.*)%]$", "%1"))
end

-- Listeners from the scan script's output, one per port, sorted by port.
function M.parse_scan(out: string): { Listener }
	local tool = string.match(out, "@(%a+)")
	local byport: { [number]: Listener } = {}
	local function add(addr: string?, port: number?, process: string?)
		if not addr or not port then
			return
		end
		local l = byport[port]
		if not l then
			l = { port = port, addrs = {}, process = process, target = "" }
			byport[port] = l
		end
		if not table.find(l.addrs, addr) then
			table.insert(l.addrs, addr)
		end
		l.process = l.process or process
	end
	-- Windows tasklist CSV rows: `"name.exe","1234",…`.
	local names: { [string]: string } = {}
	for name, pid in string.gmatch(out, '\n"([^"]*)","(%d+)"') do
		names[pid] = name
	end
	for line in string.gmatch(out, "[^\r\n]+") do
		local f = {}
		for w in string.gmatch(line, "%S+") do
			table.insert(f, w)
		end
		if f[1] == "TCP" and f[3] and string.find(f[3], ":0$") then
			-- Windows netstat: `TCP 0.0.0.0:135 0.0.0.0:0 LISTENING 1012`. The
			-- state word is localized; a listener is what has no foreign port.
			local addr, port = split_addr(f[2], ":")
			add(addr, port, f[5] and names[f[5]])
		elseif tool == "ss" and f[1] == "LISTEN" and f[4] then
			local addr, port = split_addr(f[4], ":")
			add(addr, port, string.match(line, 'users:%(%("([^"]+)"'))
		elseif tool == "lsof" and string.find(line, "%(LISTEN%)%s*$") and #f >= 3 then
			local addr, port = split_addr(f[#f - 1], ":")
			add(addr, port, f[1])
		elseif tool == "netstat" and string.find(f[1] or "", "^tcp") and string.find(line, "LISTEN") and f[4] then
			-- Linux writes `0.0.0.0:22`, BSD and macOS `*.22` / `127.0.0.1.631`.
			local addr, port = split_addr(f[4], ":")
			if not addr then
				addr, port = split_addr(f[4], "%.")
			end
			add(addr, port, nil)
		end
	end
	local list: { Listener } = {}
	for _, l in byport do
		l.target = target_of(l.addrs)
		table.insert(list, l)
	end
	table.sort(list, function(a, b)
		return a.port < b.port
	end)
	return list
end

-- A typed forward: `8080`, `3000:8080` (local:remote), `db.internal:5432`
-- (remote host:port) or `3000:db.internal:5432`; IPv6 hosts in brackets.
-- lport and rhost are nil when the user left them to us.
function M.parse_spec(s: string): ({ lport: number?, rhost: string?, rport: number }?, string?)
	s = string.gsub(s, "^%s*(.-)%s*$", "%1")
	local parts = {}
	local rest = s
	while rest ~= "" do
		local part, after
		if string.sub(rest, 1, 1) == "[" then
			part, after = string.match(rest, "^%[([^%]]*)%]:?(.*)$")
		else
			part, after = string.match(rest, "^([^:]*):?(.*)$")
		end
		if part == nil then
			return nil, "Unbalanced [ in " .. s
		end
		table.insert(parts, part)
		rest = after
	end
	local function port(p: string?): number?
		local n = tonumber(p or "")
		return if M.valid_port(n) then n else nil
	end
	local lport, rhost, rport
	if #parts == 1 then
		rport = port(parts[1])
	elseif #parts == 2 then
		lport = port(parts[1])
		if lport then
			rport = port(parts[2])
		else
			rhost, rport = parts[1], port(parts[2])
		end
	elseif #parts == 3 then
		lport, rhost, rport = port(parts[1]), parts[2], port(parts[3])
		if not lport then
			return nil, "Not a local port: " .. parts[1]
		end
	end
	if not rport then
		return nil, "Write a port (8080), local:remote (3000:8080) or [local:]host:port"
	end
	if rhost == "" then
		rhost = nil
	end
	if rhost and not string.find(rhost, "^[%w%._:%-]+$") then
		return nil, "Not a host name: " .. rhost
	end
	return { lport = lport, rhost = rhost, rport = rport }, nil
end

-- `Host` names in an ssh config text, without patterns; `Include` lines go
-- to `include` (expanded by the caller, which can read files).
function M.parse_config(text: string, include: (string) -> ()): { string }
	local hosts = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local key, value = string.match(line, "^%s*(%a+)%s*=?%s*(.-)%s*$")
		key = key and string.lower(key)
		if key == "host" and value then
			for name in string.gmatch(value, "%S+") do
				if not string.find(name, "[%*%?!]") then
					table.insert(hosts, name)
				end
			end
		elseif key == "include" and value then
			for path in string.gmatch(value, "%S+") do
				include(path)
			end
		end
	end
	return hosts
end

-- The ssh destination behind a Tern remote host's address: Tern's own port
-- is not ssh's, so `user@host:port` becomes `user@host`.
function M.from_tern_address(address: string): string
	local base = string.match(address, "^(.-):%d+$")
	if base and not string.find(base, ":", 1, true) then
		return base
	end
	return address
end

return M
