--!strict
-- OpenSSH plumbing for the window half. Pure functions here: argv builders
-- and parsers. Two ways to hold forwards, by what this machine's ssh can do:
--
-- * Multiplexed (macOS, Linux): one control master per host, kept on a
--   control socket, carries every forward. Each step is a short `ssh -O …`
--   command, so nothing the plugin starts outlives it except the master,
--   which `ssh -O exit` ends.
-- * Direct (Windows): Win32-OpenSSH has no control sockets (`ControlMaster`
--   fails with "getsockname failed: Not a socket"), so each forward is its
--   own `ssh -N -L …` process, ended with taskkill.

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

-- Whether this machine's ssh shares one connection per host (see the top).
M.MULTIPLEX = tern.runtime.os ~= "windows"

-- `ssh [-o ControlPath=…] <options> -- <host> [<remote command>]`; no
-- ControlPath in direct mode, where ssh would try the socket and fail.
local function argv(host: string, options: { string }, command: string?): { string }
	local out = { "ssh" }
	if M.MULTIPLEX then
		table.insert(out, "-o")
		table.insert(out, "ControlPath=" .. M.socket(host))
	else
		table.insert(out, "-o")
		table.insert(out, "ControlMaster=no")
		table.insert(out, "-o")
		table.insert(out, "ControlPath=none")
	end
	table.move(options, 1, #options, #out + 1, out)
	table.insert(out, "--")
	table.insert(out, host)
	if command then
		table.insert(out, command)
	end
	return out
end

-- A command line from argv for a terminal pane on this machine: no shell
-- syntax, so sh, zsh, fish, cmd and PowerShell run it the same way. Plain
-- words stay bare; others (a socket dir with spaces) get double quotes,
-- which every one of those shells reads.
local function command_line(args: { string }): string
	local parts = {}
	for _, a in args do
		table.insert(parts, if string.find(a, "^[%w%._@/=:%-%[%]]+$") then a else '"' .. a .. '"')
	end
	return table.concat(parts, " ")
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

-- The master in a terminal pane on this machine, where ssh can ask for
-- passwords, passphrases and unknown host keys; `-f` backgrounds it once
-- authenticated, so the pane's command ends and the master stays.
function M.master_shell(host: string): string
	return command_line(argv(host, MASTER_OPTS))
end

-- Direct mode: whether host lets us in without prompts (keys, an agent, a
-- known host key); every forward process logs in the same way.
function M.probe(host: string): { string }
	return argv(host, { "-o", "BatchMode=yes", "-o", "ConnectTimeout=10" }, "exit")
end

-- Direct mode, in a terminal pane: one login where ssh can ask (above all,
-- to accept a new host key), then out. Passwords don't carry over: each
-- forward logs in again, without prompts.
function M.probe_shell(host: string): string
	return command_line(argv(host, { "-o", "ConnectTimeout=10" }, "exit"))
end

-- Direct mode: one forward as its own process, up while it runs. It exits
-- when the port can't be bound (ExitOnForwardFailure) or the link dies.
function M.tunnel(f: Forward): { string }
	return argv(f.host, {
		"-N", "-n",
		"-o", "BatchMode=yes",
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-L", M.spec(f),
	})
end

-- Direct mode: ends a forward process.
function M.kill(pid: number): { string }
	return { "taskkill", "/PID", tostring(pid), "/F" }
end

-- Whether a program name from parse_local is ssh (`ssh`, `ssh.exe`).
function M.is_ssh(name: string?): boolean
	local n = name and string.lower(name)
	return n == "ssh" or n == "ssh.exe"
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

-- This machine's listening TCP sockets with their pids and program names:
-- `lsof -F` fields (`p<pid>`, `c<command>`, `n<addr>` lines), or on Windows
-- netstat and tasklist as the remote Windows scan runs them.
M.LOCAL_LISTENERS = if tern.runtime.os == "windows"
	then { "cmd", "/c", "netstat -ano -p TCP & tasklist /fo csv /nh" }
	else { "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn" }

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

local function split_addr(s: string, sep: string): (string?, number?)
	local addr, port = string.match(s, "^(.*)" .. sep .. "(%d+)$")
	if not addr then
		return nil, nil
	end
	addr = string.gsub(addr, "%%.*$", "") -- `127.0.0.53%lo` → `127.0.0.53`
	return addr, tonumber(port)
end

type WindowsRow = { addr: string, port: number, pid: number }

-- Listeners in Windows `netstat -ano` output, and the program names that
-- `tasklist /fo csv /nh` rows (`"name.exe","1234",…`) give their pids.
-- Rows read `TCP 0.0.0.0:135 0.0.0.0:0 LISTENING 1012`; the state word is
-- localized, so a listener is what has no foreign port.
local function windows_listeners(out: string): ({ WindowsRow }, { [number]: string })
	local names: { [number]: string } = {}
	for name, pid in string.gmatch(out, '\n"([^"]*)","(%d+)"') do
		names[tonumber(pid) :: number] = name
	end
	local rows: { WindowsRow } = {}
	for line in string.gmatch(out, "[^\r\n]+") do
		local proto, laddr, faddr, pid = string.match(line, "^%s*(%u+)%s+(%S+)%s+(%S+)%s+%S+%s+(%d+)%s*$")
		if proto == "TCP" and string.find(faddr :: string, ":0$") then
			local addr, port = split_addr(laddr :: string, ":")
			if addr and port then
				table.insert(rows, { addr = addr, port = port, pid = tonumber(pid) :: number })
			end
		end
	end
	return rows, names
end

export type LocalPorts = { [number]: { [number]: boolean } }

-- Port → set of pids, and pid → program name, from LOCAL_LISTENERS' output.
function M.parse_local(out: string): (LocalPorts, { [number]: string })
	local ports: LocalPorts = {}
	local function add(port: number, pid: number)
		ports[port] = ports[port] or {}
		ports[port][pid] = true
	end
	if tern.runtime.os == "windows" then
		local rows, names = windows_listeners(out)
		for _, r in rows do
			add(r.port, r.pid)
		end
		return ports, names
	end
	local names: { [number]: string } = {}
	local pid: number? = nil
	for line in string.gmatch(out, "[^\n]+") do
		local tag, rest = string.sub(line, 1, 1), string.sub(line, 2)
		if tag == "p" then
			pid = tonumber(rest)
		elseif tag == "c" and pid then
			names[pid] = rest
		elseif tag == "n" and pid then
			local port = tonumber(string.match(rest, ":(%d+)$") or "")
			if port then
				add(port, pid)
			end
		end
	end
	return ports, names
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
	local rows, names = windows_listeners(out)
	for _, r in rows do
		add(r.addr, r.port, names[r.pid])
	end
	for line in string.gmatch(out, "[^\r\n]+") do
		local f = {}
		for w in string.gmatch(line, "%S+") do
			table.insert(f, w)
		end
		if tool == "ss" and f[1] == "LISTEN" and f[4] then
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

-- What ssh makes of host without connecting: `ssh -G` applies the config
-- (aliases, `User`, `HostName`, `Port`, `HostKeyAlias`) and prints the result.
function M.resolve(host: string): { string }
	return { "ssh", "-G", "--", host }
end

-- From `ssh -G` output: the login user, the address as `host` or
-- `[host]:port`, the name its host keys are filed under in known_hosts,
-- and the known_hosts files ssh reads.
export type Resolved = { user: string, addr: string, keyname: string, known_hosts: { string } }

function M.parse_resolved(out: string): Resolved?
	local opts: { [string]: string } = {}
	for line in string.gmatch(out, "[^\r\n]+") do
		local key, value = string.match(line, "^(%S+)%s+(.-)%s*$")
		if key and value and opts[string.lower(key)] == nil then
			opts[string.lower(key)] = value
		end
	end
	local port = tonumber(opts.port or "22")
	if not opts.user or not opts.hostname or not port then
		return nil
	end
	local addr = if port == 22 then opts.hostname else "[" .. opts.hostname .. "]:" .. port
	local files = {}
	for _, key in { "userknownhostsfile", "globalknownhostsfile" } do
		for path in string.gmatch(opts[key] or "", "%S+") do
			if path ~= "none" then
				table.insert(files, path)
			end
		end
	end
	return { user = opts.user, addr = string.lower(addr), keyname = opts.hostkeyalias or addr, known_hosts = files }
end

-- The keys file holds for name (hashed entries included); exits 1 when none.
function M.known_keys(name: string, file: string): { string }
	return { "ssh-keygen", "-F", name, "-f", file }
end

-- The key blobs in `ssh-keygen -F` output: `<hosts> <type> <base64>` lines,
-- skipping its `# Host … found` comments and `@cert-authority`/`@revoked` lines.
function M.parse_known_keys(out: string): { string }
	local keys = {}
	for line in string.gmatch(out, "[^\r\n]+") do
		local blob = string.match(line, "^[^#@%s]%S*%s+%S+%s+(%S+)")
		if blob and not table.find(keys, blob) then
			table.insert(keys, blob)
		end
	end
	return keys
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
