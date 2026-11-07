--!strict
-- Tern Ports, window half: forwards localhost ports to ports on ssh hosts.
--
-- Every forward rides one OpenSSH control master per host (`lib/ssh.luau`),
-- so each action is a short `ssh -O …` command and the forwards stay up while
-- that master does, across windows and plugin reloads. The forwards the user
-- asked for live in `tern.kv` (shared by every window); what is actually up is
-- read back from ssh (`-O check`) and from this machine's listening sockets
-- (`lsof`), every TICK_MS. A forward whose master is up but whose port isn't
-- held (after a reconnect) is added again; the mux ignores duplicates, so two
-- windows doing it at once is harmless. Masters only start on a user action.
--
-- All of it runs here, not in the host half: the window half runs on this
-- machine, the host half wherever the panes run (possibly the remote itself).

local ssh = require("./lib/ssh")

type Forward = ssh.Forward
type Listener = ssh.Listener

local TITLE = "Ports"
local SHOW = "plugin." .. tern.plugin.id .. ".show"
local TICK_MS = 10000
-- A panel rescans a host's listening ports at most this often on its own.
local SCAN_EVERY_MS = 30000
-- How long "Connect in a terminal" waits for the master to come up.
local TERMINAL_WAIT_MS = 180000

local KV_FORWARDS = "forwards" -- { Forward }: what the user asked for
local KV_HOSTS = "hosts" -- { string }: hosts shown in the panel (connected through Ports)
local KV_RECENT = "recent" -- { string }: hosts picked lately, newest first
local RECENT_MAX = 8

type HostState = {
	state: "unknown" | "up" | "down" | "connecting",
	pid: number?,
	error: string?,
}
type FwdState = "unknown" | "up" | "down" | "restoring" | "conflict"
type Scan = { at: number, ports: { Listener }?, error: string? }

-- Runtime state of this window's VM; the truth is ssh's, this is its last reading.
local host_state: { [string]: HostState } = {}
local fwd_state: { [string]: FwdState } = {}
local fwd_error: { [string]: string } = {}
local scans: { [string]: Scan } = {}
-- Port → pids listening on it here; nil when lsof isn't available.
local local_ports: { [number]: { [number]: boolean } }? = nil
-- Callbacks waiting on a master being started, by host.
local starting: { [string]: { (ok: boolean, err: string?, cx: WindowCx) -> () } } = {}
local reconciling = false
local reconcile_started = 0

---------------------------------------------------------------------------
-- Stored state

local function key_of(f: Forward): string
	return f.host .. "|" .. tostring(f.lport)
end

local function list_of(key: string): { any }
	local ok, v = pcall(tern.kv.get, key)
	return if ok and type(v) == "table" then v else {}
end

local function store(key: string, list: { any })
	tern.kv.set(key, if #list == 0 then nil else tern.json.array(list))
end

local function forwards(): { Forward }
	local out: { Forward } = {}
	for _, f in list_of(KV_FORWARDS) do
		if type(f) == "table" and type(f.host) == "string" and ssh.valid_port(f.lport) and ssh.valid_port(f.rport) then
			table.insert(out, { host = f.host, lport = f.lport, rhost = tostring(f.rhost or "127.0.0.1"), rport = f.rport })
		end
	end
	return out
end

local function set_forwards(list: { Forward })
	store(KV_FORWARDS, list)
end

local function strings(key: string): { string }
	local out = {}
	for _, s in list_of(key) do
		if type(s) == "string" and ssh.valid_host(s) then
			table.insert(out, s)
		end
	end
	return out
end

local function remember_host(host: string)
	local hosts = strings(KV_HOSTS)
	if not table.find(hosts, host) then
		table.insert(hosts, host)
		store(KV_HOSTS, hosts)
	end
	local recent = { host }
	for _, h in strings(KV_RECENT) do
		if h ~= host and #recent < RECENT_MAX then
			table.insert(recent, h)
		end
	end
	store(KV_RECENT, recent)
end

local function forget_host(host: string)
	local hosts = {}
	for _, h in strings(KV_HOSTS) do
		if h ~= host then
			table.insert(hosts, h)
		end
	end
	store(KV_HOSTS, hosts)
	local kept = {}
	for _, f in forwards() do
		if f.host ~= host then
			table.insert(kept, f)
		end
	end
	set_forwards(kept)
	host_state[host] = nil
	scans[host] = nil
end

-- Hosts the panel shows: connected through Ports, or carrying a forward.
local function all_hosts(): { string }
	local out = strings(KV_HOSTS)
	for _, f in forwards() do
		if not table.find(out, f.host) then
			table.insert(out, f.host)
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Processes

type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }

-- tern.process.run with a fresh cx always; a spawn failure (no ssh, no lsof)
-- arrives as a failed result instead of raising in the caller.
local function run(argv: { string }, timeout_ms: number, cb: (res: Result, cx: WindowCx) -> ())
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = timeout_ms }, function(res: ProcessResult, cx: WindowCx?)
		cb(res, cx :: WindowCx)
	end)
	if not ok then
		-- No cx to hand back synchronously: deliver on the next turn.
		tern.timer(0, function(cx: WindowCx?)
			cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }, cx :: WindowCx)
		end)
	end
end

local function refresh_local(cb: (cx: WindowCx) -> ())
	run(ssh.LOCAL_LISTENERS, 5000, function(res, cx)
		-- lsof exits 1 when nothing listens; -1 means it isn't installed.
		local_ports = if res.status >= 0 then ssh.parse_local(res.stdout) else nil
		cb(cx)
	end)
end

local function check(host: string, cb: (cx: WindowCx) -> ())
	run(ssh.check(host), 5000, function(res, cx)
		local pid = ssh.master_pid(res.stderr .. res.stdout)
		if pid then
			host_state[host] = { state = "up", pid = pid }
		elseif not starting[host] then
			local prev = host_state[host]
			host_state[host] = { state = "down", error = prev and prev.error }
		end
		cb(cx)
	end)
end

---------------------------------------------------------------------------
-- View

local span = tern.ui.span

local FWD_STATUS: { [string]: { text: string, dot: string } } = {
	unknown = { text = "Checking", dot = "muted" },
	up = { text = "Forwarding", dot = "success" },
	restoring = { text = "Restoring", dot = "pending" },
	down = { text = "Host disconnected", dot = "error" },
	conflict = { text = "Port taken here", dot = "warning" },
}

local function remote_label(f: Forward): string
	local rhost = if string.find(f.rhost, ":", 1, true) then "[" .. f.rhost .. "]" else f.rhost
	return rhost .. ":" .. f.rport
end

local function forward_of(host: string, rhost: string, rport: number): Forward?
	for _, f in forwards() do
		if f.host == host and f.rhost == rhost and f.rport == rport then
			return f
		end
	end
	return nil
end

local function button(text: string, act: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.actions = { click = act }
	return tern.ui.button(text, p)
end

local function head_row(left: Node, right: { Node }): Node
	return tern.ui.node("row", { justify = "between", align = "center" }, {
		left,
		tern.ui.node("buttons", nil, right),
	})
end

local function forwards_table(list: { Forward }): Node
	local rows = {}
	for _, f in list do
		local k = key_of(f)
		local st = FWD_STATUS[fwd_state[k] or "unknown"]
		table.insert(rows, {
			id = k,
			title = fwd_error[k],
			cells = {
				span("localhost:" .. f.lport, "mono"),
				span(remote_label(f), "mono"),
				f.host,
				{ text = st.text, dot = st.dot },
				{ button = { text = "Open", act = "open:" .. f.lport, icon = "globe", variant = "quiet" } },
				{ button = { text = "Stop", act = "stop:" .. k, icon = "stop", variant = "quiet" } },
			},
		})
	end
	local t = tern.ui.table({
		{ id = "local", head = "Local", mono = true },
		{ id = "remote", head = "Remote", mono = true, grow = 1, truncate = "middle" },
		{ id = "host", head = "Host", priority = -2 },
		{ id = "status", head = "Status" },
		{ id = "open", head = "", align = "end", priority = -1 },
		{ id = "stop", head = "", align = "end" },
	}, rows)
	t.p = t.p or {}
	;(t.p :: any).key = "forwards"
	return t
end

local function host_block(host: string): Node
	local st = host_state[host] or { state = "unknown" }
	local meta, buttons
	if st.state == "up" then
		meta = span("  connected", "muted")
		buttons = {
			button("Rescan", "scan:" .. host, { icon = "search", variant = "quiet", size = "sm" }),
			button("Disconnect", "disconnect:" .. host, { icon = "log-out", variant = "quiet", size = "sm" }),
		}
	elseif st.state == "connecting" then
		meta = span("  connecting…", "muted")
		buttons = { button("Connect", "connect:" .. host, { busy = true, size = "sm" }) }
	elseif st.state == "down" then
		meta = span("  " .. (st.error or "not connected"), "error")
		buttons = {
			button("Connect", "connect:" .. host, { icon = "log-in", size = "sm" }),
			button("In a terminal", "terminal:" .. host, { icon = "terminal", variant = "quiet", size = "sm" }),
			button("Forget", "disconnect:" .. host, { icon = "x", variant = "quiet", size = "sm" }),
		}
	else
		meta = span("  checking…", "muted")
		buttons = {}
	end
	local children = { head_row(tern.ui.text({ span(host, "strong"), meta }), buttons) }
	local scan = scans[host]
	if st.state == "up" and scan then
		if scan.error then
			table.insert(children, tern.ui.text(span("Couldn't list listening ports: " .. scan.error, "error")))
		elseif scan.ports then
			local rows = {}
			for _, l in scan.ports do
				local f = forward_of(host, l.target, l.port)
				table.insert(rows, {
					id = host .. "|" .. l.port,
					cells = {
						span(tostring(l.port), "mono"),
						span(table.concat(l.addrs, " "), "mono muted"),
						l.process or "",
						if f
							-- Green (ports.css) and opens like a link: Tern's "Open links in" setting picks the browser.
							then { button = { text = "localhost:" .. f.lport, act = "open:" .. f.lport, icon = "globe" } }
							else { button = { text = "Forward", act = "fwd:" .. host .. "|" .. l.target .. "|" .. l.port, icon = "swap", variant = "quiet" } },
					},
				})
			end
			local t = tern.ui.table({
				{ id = "port", head = "Port", align = "end", mono = true },
				{ id = "addr", head = "Listening on", mono = true, grow = 1, truncate = "end", priority = -1 },
				{ id = "proc", head = "Program", align = "center" },
				{ id = "act", head = "", align = "center" },
			}, rows, { empty = "Nothing listens on TCP there" })
			t.p = t.p or {}
			;(t.p :: any).key = "scan:" .. host
			;(t.p :: any).role = "ports.listening"
			table.insert(children, t)
		end
	end
	-- 10px between the host's head row and its ports.
	return tern.ui.node("col", { key = "host:" .. host, gap = "md" }, children)
end

local function view(): Node
	local list = forwards()
	local hosts = all_hosts()
	local up = 0
	for _, f in list do
		if fwd_state[key_of(f)] == "up" then
			up += 1
		end
	end
	local meta = if #list == 0
		then "no forwards"
		else string.format("%d forwarded%s", #list, if up < #list then string.format(", %d up", up) else "")
	local children: { Node } = {
		head_row(tern.ui.text({ span(meta, "muted") }), {
			button("Forward port…", "add", { icon = "plus", variant = "primary" }),
			button("Refresh", "refresh", { icon = "repeat", variant = "quiet" }),
		}),
	}
	if #list == 0 and #hosts == 0 then
		table.insert(children, tern.ui.node("empty", {
			icon = "swap",
			title = "No ports forwarded",
			text = "Forward a port on a host you reach with ssh to localhost here.",
		}, { button("Forward port…", "add", { icon = "plus" }) }))
		return tern.ui.node("col", { gap = "lg" }, children)
	end
	if #list > 0 then
		table.insert(children, forwards_table(list))
	end
	for _, host in hosts do
		table.insert(children, host_block(host))
	end
	-- 16px between the head row, the forwards and each host.
	return tern.ui.node("col", { gap = "lg" }, children)
end

local function panels(cx: WindowCx): { number }
	local out = {}
	for _, c in cx.canvas:list() do
		if c.owner == tern.plugin.id and c.title == TITLE then
			table.insert(out, c.pane)
		end
	end
	return out
end

local function render(cx: WindowCx)
	local panes = panels(cx)
	if #panes > 0 then
		local v = view()
		for _, pane in panes do
			local ok, err = pcall(cx.canvas.set, cx.canvas, pane, { view = v })
			if not ok then
				tern.log.warn("ports: canvas update failed", err)
			end
		end
	end
	tern.chrome.refresh()
end

---------------------------------------------------------------------------
-- Masters

local function finish_start(host: string, ok: boolean, err: string?, cx: WindowCx)
	local waiting = starting[host] or {}
	starting[host] = nil
	for _, cb in waiting do
		cb(ok, err, cx)
	end
end

-- Calls cb(true) once host's master runs, starting one (without prompts) if needed.
local function ensure_master(host: string, cb: (ok: boolean, err: string?, cx: WindowCx) -> ())
	if starting[host] then
		table.insert(starting[host], cb)
		return
	end
	starting[host] = { cb }
	run(ssh.check(host), 5000, function(res, cx)
		local pid = ssh.master_pid(res.stderr .. res.stdout)
		if pid then
			host_state[host] = { state = "up", pid = pid }
			finish_start(host, true, nil, cx)
			return
		end
		host_state[host] = { state = "connecting" }
		render(cx)
		-- No master answered, so a socket file left there is stale and would
		-- make the new master give up multiplexing.
		local sock = ssh.socket(host)
		if tern.fs.exists(sock) then
			pcall(tern.fs.remove, sock)
		end
		run(ssh.master(host), 25000, function(res2, cx2)
			if res2.status ~= 0 then
				local err = if res2.timed_out then "timed out connecting" else ssh.error_line(res2.stderr)
				host_state[host] = { state = "down", error = err }
				render(cx2)
				finish_start(host, false, err, cx2)
				return
			end
			remember_host(host)
			run(ssh.check(host), 5000, function(res3, cx3)
				local pid3 = ssh.master_pid(res3.stderr .. res3.stdout)
				if pid3 then
					host_state[host] = { state = "up", pid = pid3 }
					finish_start(host, true, nil, cx3)
				else
					local err = ssh.error_line(res3.stderr)
					host_state[host] = { state = "down", error = err }
					finish_start(host, false, err, cx3)
				end
				render(cx3)
			end)
		end)
	end)
end

local forward_flow: (cx: WindowCx, host: string?) -> ()

-- Opens a local terminal running the master, where ssh can prompt; polls
-- until it is up, then runs `after`.
local function connect_in_terminal(cx: WindowCx, host: string, after: ((cx: WindowCx) -> ())?)
	local command = ssh.master_shell(host)
	local ok = pcall(cx.hosts.terminal, cx.hosts, "local", { command = command })
	if not ok then
		cx.layout:new_tab({ command = command })
	end
	remember_host(host)
	host_state[host] = { state = "connecting" }
	render(cx)
	local deadline = tern.now() + TERMINAL_WAIT_MS
	local function poll()
		tern.timer(2000, function(tcx: WindowCx?)
			run(ssh.check(host), 5000, function(res, pcx)
				local pid = ssh.master_pid(res.stderr .. res.stdout)
				if pid then
					host_state[host] = { state = "up", pid = pid }
					pcx:toast("success", "Connected to " .. host)
					render(pcx)
					if after then
						after(pcx)
					end
				elseif tern.now() < deadline then
					poll()
				else
					host_state[host] = { state = "down", error = "not connected" }
					render(pcx)
				end
			end)
		end)
	end
	poll()
end

local function connect_failed(cx: WindowCx, host: string, err: string?, after: ((cx: WindowCx) -> ())?)
	cx:pick({
		placeholder = "Couldn't connect to " .. host,
		icon = "warn",
		action = "connect",
		items = {
			{
				label = "Connect in a terminal",
				detail = (err or "ssh failed") .. ": ssh can ask for a password, passphrase or host key there",
				icon = "terminal",
			},
		},
	}):next(function(item, _err, cx2)
		if item and cx2 then
			connect_in_terminal(cx2, host, after)
		end
	end)
end

---------------------------------------------------------------------------
-- Forwards

-- Local ports to try for remote port rport: the same one, else (privileged
-- or taken) +10000, else the next few.
local function candidates(rport: number): { number }
	local out = {}
	local function add(p: number)
		if ssh.valid_port(p) and not table.find(out, p) then
			table.insert(out, p)
		end
	end
	if rport >= 1024 then
		add(rport)
	end
	add(rport + 10000)
	for i = 1, 20 do
		add(rport + i)
	end
	return out
end

local function taken(port: number): boolean
	if local_ports and local_ports[port] then
		return true
	end
	for _, f in forwards() do
		if f.lport == port then
			return true
		end
	end
	return false
end

local function add_forward(cx: WindowCx, host: string, rhost: string, rport: number, lport: number?)
	local existing = forward_of(host, rhost, rport)
	if existing and (lport == nil or existing.lport == lport) then
		cx:toast("info", string.format("Already forwarded at localhost:%d", existing.lport), host .. " " .. remote_label(existing))
		return
	end
	ensure_master(host, function(ok, err, cx1)
		if not ok then
			connect_failed(cx1, host, err, function(cx2)
				add_forward(cx2, host, rhost, rport, lport)
			end)
			return
		end
		refresh_local(function(cx2)
			local tries: { number }
			if lport then
				if taken(lport) then
					cx2:toast("error", string.format("localhost:%d is already in use", lport), "Pick another local port")
					return
				end
				tries = { lport }
			else
				tries = {}
				for _, p in candidates(rport) do
					if not taken(p) then
						table.insert(tries, p)
					end
				end
			end
			local function try(i: number, last_err: string?, cx3: WindowCx)
				local p = tries[i]
				if not p then
					cx3:toast("error", "Couldn't forward " .. host .. " " .. rhost .. ":" .. rport, last_err or "no free local port")
					return
				end
				local f: Forward = { host = host, lport = p, rhost = rhost, rport = rport }
				run(ssh.forward(f), 8000, function(res, cx4)
					if res.status ~= 0 then
						try(i + 1, ssh.error_line(res.stderr), cx4)
						return
					end
					local list = forwards()
					table.insert(list, f)
					set_forwards(list)
					remember_host(host)
					fwd_state[key_of(f)] = "up"
					fwd_error[key_of(f)] = nil
					cx4:toast("success", string.format("localhost:%d → %s %s", p, host, remote_label(f)))
					render(cx4)
				end)
			end
			try(1, nil, cx2)
		end)
	end)
end

local function find_forward(k: string): Forward?
	for _, f in forwards() do
		if key_of(f) == k then
			return f
		end
	end
	return nil
end

local function stop_forward(k: string)
	local f = find_forward(k)
	if not f then
		return
	end
	local fwd = f :: Forward
	run(ssh.cancel(fwd), 8000, function(res, cx)
		local kept = {}
		for _, g in forwards() do
			if key_of(g) ~= k then
				table.insert(kept, g)
			end
		end
		set_forwards(kept)
		fwd_state[k] = nil
		fwd_error[k] = nil
		local up = host_state[fwd.host]
		if res.status ~= 0 and up and up.state == "up" then
			cx:toast("error", "ssh didn't confirm stopping localhost:" .. fwd.lport, ssh.error_line(res.stderr))
		else
			cx:toast("success", "Stopped forwarding localhost:" .. fwd.lport)
		end
		render(cx)
	end)
end

local function disconnect(host: string)
	run(ssh.exit(host), 8000, function(_res, cx)
		forget_host(host)
		pcall(tern.fs.remove, ssh.socket(host))
		cx:toast("success", "Disconnected " .. host)
		render(cx)
	end)
end

local function scan(host: string, cb: (cx: WindowCx) -> ())
	run(ssh.scan(host), 15000, function(res, cx)
		if res.status == 0 then
			scans[host] = { at = tern.now(), ports = ssh.parse_scan(res.stdout) }
		else
			scans[host] = { at = tern.now(), error = if res.timed_out then "timed out" else ssh.error_line(res.stderr) }
		end
		cb(cx)
	end)
end

-- Reads back what is up, restores forwards whose master is up but whose port
-- isn't held, rescans hosts when asked, then renders.
local function reconcile(opts: { scan: boolean, force: boolean? })
	-- Every process has a timeout, so a reading finishes; the age check only
	-- recovers from a callback that raised halfway.
	if reconciling and tern.now() - reconcile_started < 60000 then
		return
	end
	reconciling = true
	reconcile_started = tern.now()
	local hosts = all_hosts()
	local pending = #hosts + 1

	local function apply(cx: WindowCx)
		reconciling = false
		for _, f in forwards() do
			local k = key_of(f)
			local hs = host_state[f.host]
			if not hs or hs.state ~= "up" then
				fwd_state[k] = if hs and hs.state == "connecting" then "unknown" else "down"
			elseif local_ports == nil then
				fwd_state[k] = "up"
			else
				-- Up only when the master alone holds the port: ssh binds 127.0.0.1
				-- and ::1 and succeeds if either binds, so another program can
				-- hold the other one and catch the connections.
				local holders = (local_ports :: any)[f.lport]
				local others = {}
				for pid in holders or {} do
					if pid ~= hs.pid then
						table.insert(others, tostring(pid))
					end
				end
				if #others > 0 then
					fwd_state[k] = "conflict"
					fwd_error[k] = "localhost:" .. f.lport .. " is also held by pid " .. table.concat(others, ", ")
				elseif holders then
					fwd_state[k] = "up"
					fwd_error[k] = nil
				elseif fwd_state[k] ~= "restoring" then
					fwd_state[k] = "restoring"
					run(ssh.forward(f), 8000, function(res, rcx)
						if res.status == 0 then
							fwd_state[k] = "up"
							fwd_error[k] = nil
						else
							fwd_state[k] = "down"
							fwd_error[k] = ssh.error_line(res.stderr)
						end
						render(rcx)
					end)
				end
			end
		end
		render(cx)
	end

	local function done(cx: WindowCx)
		pending -= 1
		if pending == 0 then
			apply(cx)
		end
	end

	refresh_local(done)
	for _, host in hosts do
		if starting[host] then
			pending -= 1
		else
			check(host, function(cx)
				local hs = host_state[host]
				local last = scans[host]
				if opts.scan and hs and hs.state == "up" and (opts.force or not last or tern.now() - last.at >= SCAN_EVERY_MS) then
					scan(host, done)
				else
					done(cx)
				end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Pickers

local function home(): string
	return tern.getenv("HOME") or ""
end

local function ssh_config_hosts(): { string }
	local found: { string } = {}
	local seen: { [string]: boolean } = {}
	local function read(path: string, depth: number)
		if depth > 4 or seen[path] then
			return
		end
		seen[path] = true
		local ok, text = pcall(tern.fs.read, path, 1024 * 1024)
		if not ok then
			return
		end
		for _, h in ssh.parse_config(text, function(inc: string)
			if string.sub(inc, 1, 2) == "~/" then
				inc = home() .. string.sub(inc, 2)
			elseif string.sub(inc, 1, 1) ~= "/" then
				inc = home() .. "/.ssh/" .. inc
			end
			local dir, name = string.match(inc, "^(.*)/([^/]*)$")
			if dir and name and string.find(name, "[%*%?]") then
				local pattern = "^" .. string.gsub(string.gsub(name, "[%^%$%(%)%%%.%[%]%+%-]", "%%%0"), "[%*%?]", { ["*"] = ".*", ["?"] = "." }) .. "$"
				local lok, entries = pcall(tern.fs.list, dir)
				if lok then
					for _, e in entries do
						if string.find(e, pattern) then
							read(dir .. "/" .. e, depth + 1)
						end
					end
				end
			else
				read(inc, depth + 1)
			end
		end) do
			table.insert(found, h)
		end
	end
	read(home() .. "/.ssh/config", 0)
	return found
end

local function pick_host(cx: WindowCx, cb: (host: string, cx: WindowCx) -> ())
	local items = {}
	local seen: { [string]: boolean } = {}
	local function add(host: string, group: string, detail: string?, icon: string)
		if seen[host] or not ssh.valid_host(host) then
			return
		end
		seen[host] = true
		local hs = host_state[host]
		table.insert(items, {
			label = host,
			detail = if hs and hs.state == "up" then "connected" else detail,
			group = group,
			icon = icon,
			host = host,
			current = hs ~= nil and hs.state == "up",
		})
	end
	for _, h in strings(KV_RECENT) do
		add(h, "Recent", nil, "history")
	end
	local ok, hosts = pcall(cx.hosts.list, cx.hosts)
	if ok then
		for _, h in hosts do
			if h.kind == "remote" and h.address then
				add(ssh.from_tern_address(h.address), "Tern hosts", h.name, "server")
			end
		end
	end
	for _, h in ssh_config_hosts() do
		add(h, "~/.ssh/config", nil, "server")
	end
	table.insert(items, { label = "Another host…", detail = "user@host, an ssh alias or ssh://user@host:port", icon = "plus", other = true })
	cx:pick({ items = items, placeholder = "Forward a port from which host?", icon = "swap", action = "choose" })
		:next(function(item, _err, cx2)
			if not item or not cx2 then
				return
			end
			if not item.other then
				cb(item.host, cx2)
				return
			end
			cx2:prompt({ placeholder = "user@host", icon = "server", action = "connect" }):next(function(text, _e, cx3)
				if not text or not cx3 then
					return
				end
				local host = string.gsub(text, "^%s*(.-)%s*$", "%1")
				if not ssh.valid_host(host) then
					cx3:toast("error", "Not an ssh destination: " .. host)
					return
				end
				cb(host, cx3)
			end)
		end)
end

local function pick_port(cx: WindowCx, host: string)
	local items = {}
	local s = scans[host]
	for _, l in (s and s.ports) or {} do
		local f = forward_of(host, l.target, l.port)
		if not f then
			table.insert(items, {
				label = tostring(l.port),
				detail = (l.process or "") .. "  " .. table.concat(l.addrs, " "),
				group = "Listening on " .. host,
				icon = "plug",
				listener = l,
			})
		end
	end
	table.insert(items, {
		label = "Another port…",
		detail = "8080, local:remote (3000:8080) or [local:]host:port (5432:db:5432)",
		group = if s and s.error then "Couldn't list ports: " .. s.error else "Other",
		icon = "pen",
		other = true,
	})
	cx:pick({ items = items, placeholder = "Forward which port on " .. host .. "?", icon = "swap", action = "forward" })
		:next(function(item, _err, cx2)
			if not item or not cx2 then
				return
			end
			if not item.other then
				add_forward(cx2, host, item.listener.target, item.listener.port, nil)
				return
			end
			cx2:prompt({ placeholder = "Port on " .. host .. " (8080, 3000:8080, 5432:db:5432)", icon = "swap", action = "forward" })
				:next(function(text, _e, cx3)
					if not text or not cx3 then
						return
					end
					local spec, perr = ssh.parse_spec(text)
					if not spec then
						cx3:toast("error", perr or "Not a port")
						return
					end
					add_forward(cx3, host, spec.rhost or "127.0.0.1", spec.rport, spec.lport)
				end)
		end)
end

forward_flow = function(cx: WindowCx, host: string?)
	if not host then
		pick_host(cx, function(h, cx2)
			forward_flow(cx2, h)
		end)
		return
	end
	local h = host :: string
	ensure_master(h, function(ok, err, cx2)
		if not ok then
			connect_failed(cx2, h, err, function(cx3)
				forward_flow(cx3, h)
			end)
			return
		end
		render(cx2)
		scan(h, function(cx3)
			pick_port(cx3, h)
		end)
	end)
end

local function pick_forward(cx: WindowCx, placeholder: string, icon: string, cb: (f: Forward, cx: WindowCx) -> ())
	local items = {}
	for _, f in forwards() do
		local st = FWD_STATUS[fwd_state[key_of(f)] or "unknown"]
		table.insert(items, {
			label = "localhost:" .. f.lport,
			detail = f.host .. " " .. remote_label(f) .. " · " .. st.text,
			icon = "swap",
			fkey = key_of(f),
		})
	end
	if #items == 0 then
		cx:toast("info", "No ports are forwarded")
		return
	end
	cx:pick({ items = items, placeholder = placeholder, icon = icon }):next(function(item, _err, cx2)
		local f = item and find_forward(item.fkey)
		if f and cx2 then
			cb(f, cx2)
		end
	end)
end

---------------------------------------------------------------------------
-- Commands

local function show(cx: WindowCx)
	local panes = panels(cx)
	if #panes > 0 then
		cx.layout:focus(panes[1])
	else
		local pane, err = cx.canvas:open({
			title = TITLE,
			about = "Ports forwarded from ssh hosts to localhost. Forward port… adds one, Stop ends one, "
				.. "Open shows it in the browser, Forward on a listening port forwards it.",
			view = view(),
			how = "beside",
			ratio = 0.42,
		})
		if not pane then
			cx:toast("error", "Ports panel not opened", err)
			return
		end
	end
	reconcile({ scan = true, force = true })
end

-- cx:open follows the `link_target` setting (Settings › "Where web links
-- open"): the system's default browser for "Browser", a Tern browser block
-- for "Tern".
local function open_port(cx: WindowCx, lport: number)
	cx:open("http://localhost:" .. lport)
end

-- The green forwarded-port buttons; scoped by the table's data-role.
tern.css("ports", tern.fs.read("ports.css"))

local function has_forwards(_cx: WindowCx): boolean
	return #forwards() > 0
end

tern.command({
	id = "show",
	title = "Show forwarded ports",
	icon = "swap",
	run = show,
})

tern.command({
	id = "forward",
	title = "Forward a port from an ssh host…",
	icon = "swap",
	run = function(cx: WindowCx)
		forward_flow(cx, nil)
	end,
})

tern.command({
	id = "stop",
	title = "Stop forwarding a port…",
	icon = "stop",
	available = has_forwards,
	run = function(cx: WindowCx)
		pick_forward(cx, "Stop forwarding which port?", "stop", function(f)
			stop_forward(key_of(f))
		end)
	end,
})

tern.command({
	id = "open",
	title = "Open a forwarded port in the browser…",
	icon = "globe",
	available = has_forwards,
	run = function(cx: WindowCx)
		pick_forward(cx, "Open which port?", "globe", function(f, cx2)
			open_port(cx2, f.lport)
		end)
	end,
})

tern.command({
	id = "disconnect",
	title = "Disconnect an ssh host from Ports…",
	icon = "log-out",
	available = function(_cx: WindowCx): boolean
		return #all_hosts() > 0
	end,
	run = function(cx: WindowCx)
		local items = {}
		for _, h in all_hosts() do
			local n = 0
			for _, f in forwards() do
				if f.host == h then
					n += 1
				end
			end
			table.insert(items, { label = h, detail = string.format("%d forward%s", n, if n == 1 then "" else "s"), icon = "server", host = h })
		end
		cx:pick({ items = items, placeholder = "Disconnect which host? Its forwards stop.", icon = "log-out", action = "disconnect" })
			:next(function(item, _err, _cx2)
				if item then
					disconnect(item.host)
				end
			end)
	end,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	local act, arg = string.match(ev.act, "^(%a+):?(.*)$")
	if act == "add" then
		forward_flow(cx, nil)
	elseif act == "refresh" then
		reconcile({ scan = true, force = true })
	elseif act == "open" then
		open_port(cx, tonumber(arg) :: number)
	elseif act == "stop" then
		stop_forward(arg :: string)
	elseif act == "fwd" then
		local host, rhost, rport = string.match(arg :: string, "^([^|]+)|([^|]+)|(%d+)$")
		if host then
			add_forward(cx, host, rhost :: string, tonumber(rport) :: number, nil)
		end
	elseif act == "scan" then
		scan(arg :: string, render)
	elseif act == "connect" then
		local host = arg :: string
		ensure_master(host, function(ok, err, cx2)
			if ok then
				reconcile({ scan = true, force = true })
			else
				connect_failed(cx2, host, err, nil)
			end
		end)
	elseif act == "terminal" then
		connect_in_terminal(cx, arg :: string, nil)
	elseif act == "disconnect" then
		disconnect(arg :: string)
	else
		return false
	end
	return true
end)

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local list = forwards()
	if #list == 0 then
		return nil
	end
	local bad = 0
	for _, f in list do
		local st = fwd_state[key_of(f)]
		if st == "down" or st == "conflict" then
			bad += 1
		end
	end
	local text = if #list == 1 then "localhost:" .. list[1].lport else string.format("%d ports", #list)
	if bad > 0 then
		text ..= string.format(" · %d down", bad)
	end
	return { { text = text, icon = "swap", tone = if bad > 0 then "error" else "muted", command = SHOW } }
end)

---------------------------------------------------------------------------
-- Ticking

local function tick()
	tern.timer(TICK_MS, function(cx: WindowCx?)
		local open = cx ~= nil and #panels(cx :: WindowCx) > 0
		if open or #all_hosts() > 0 then
			reconcile({ scan = open })
		end
		tick()
	end)
end

-- First reading right after load (a reload runs no window_start), then every TICK_MS.
tern.timer(0, function(cx: WindowCx?)
	if cx and #all_hosts() > 0 then
		reconcile({ scan = #panels(cx :: WindowCx) > 0 })
	end
end)
tick()
