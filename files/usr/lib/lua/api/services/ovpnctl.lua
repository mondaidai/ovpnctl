local socket = require("socket")
local ubus = require("ubus")
local uloop = require("uloop")
local uci = require("uci")
local FunctionService = require("api/FunctionService")
local Service = nil

if not socket then
	io.stderr:write("[ERROR] failed to load socket module")
	os.exit(1);
end
if not ubus then
	io.stderr:write("[ERROR] failed to load ubus module")
	os.exit(1)
end
if not uloop then
	io.stderr:write("[ERROR] failed to load uloop module")
	os.exit(1)
end
if not uci then
	io.stderr:write("[ERROR] failed to load uci module")
	os.exit(1)
end
if not FunctionService then
	io.stderr:write("[ERROR] failed to load FunctionService module")
	os.exit(1)
end

-- get active servers with enabled management interface
local function get_server_list(cursor)
	local active_servers = {}
		
	cursor:foreach("openvpn", nil, function(section)
		if not section["extra"] then
			return
		end
		local ip = nil
		local port = nil
		local password = nil
		for i, value in ipairs(section["extra"]) do
			if value:match("management") then
				ip, port, password = value:match("management%s+(%S+)%s+(%d+)%s*(%S*)")
				port = tonumber(port)
				break
			end
		end

		if ip and
		   port and 
		   section["enable"] == "1" and
		   section["mode"] == "server" 
		   then
			table.insert(active_servers, {
				sec_id = section[".name"],
				name = section["name"],
				mode = section["mode"],
				ip = ip,
				port = port,
				password = password
			})
		end
	end)
		
	return active_servers
end

local function fetch_clients(ip, port, password)
	local clients = {}
	local sock = socket.tcp()
		
	sock:settimeout(5)
	local ok, err = sock:connect(ip, tonumber(port))
	if not ok then
		return nil, "Connection failed: " .. tostring(err)
	end

	if password and password ~= "" then
		local pass = password
		local file = io.open(password, "r")
		if file then
			pass = file:read("*line")
			file:close()
			pass = pass:gsub("%s+", "")
		end 
		sock:send(pass .. "\n")
		local auth_response = sock:receive("*l")
		if not auth_response or not auth_response:match("SUCCESS") then
			sock:close()
			return nil, "Authentication failed"
		end
	end
	sock:send("status 2\r\n")
	while true do
		local line = sock:receive("*l")
		if not line then break end
		
		line = line:gsub("\r", "")
		
		if line:find("^CLIENT_LIST,") then
		local common_name, real_addr, virtual_addr, virtual_ipv6,
			bytes_recv, bytes_sent, connected_since, connected_since_t,
			username, client_id, peer_id, cipher = 
			line:match("CLIENT_LIST,([^,]+),([^,]+),([^,]*),([^,]*),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]*)")
		
		table.insert(clients, {
			common_name = common_name,
			real_address = real_addr,
			virtual_address = virtual_addr,
			virtual_ipv6 = virtual_ipv6,
			bytes_received = tonumber(bytes_recv) or 0,
			bytes_sent = tonumber(bytes_sent) or 0,
			connected_since = connected_since,
			connected_since_time_t = tonumber(connected_since_t) or 0,
			username = username,
			client_id = tonumber(client_id) or 0,
			peer_id = tonumber(peer_id) or 0,
			cipher = cipher or "unknown"
		})
		end
		
		if line == "END" then
			break
		end
	end
		
	sock:close()
	return clients
end

local function kick_client(ip, port, password, cn_list)
	local sock = socket.tcp()
	sock:settimeout(5)
	local ok, err = sock:connect(ip, tonumber(port))
	if not ok then
		return false, "Connection failed: " .. tostring(err)
	end

	if password and password ~= "" then
		local pass = password
		local file = io.open(password, "r")
		if file then
			pass = file:read("*line")
			file:close()
			pass = pass:gsub("%s+", "")
		end 
		sock:send(pass .. "\n")
		local auth_response = sock:receive("*l")
		if not auth_response or not auth_response:match("SUCCESS") then
			sock:close()
			return false, "Authentication failed"
		end
	end
	local response = nil
	local rerr = nil
	
	-- discard data in receive buffer
	sock:settimeout(0)
	local info = sock:receive(2048)
	sock:settimeout(5)

	for _, cn in ipairs(cn_list) do
		sock:send("kill " .. cn .. "\r\n")
		response, rerr = sock:receive("*l")
	end
	
	sock:close()

	if not response then 
		return false, rerr or "No response"
	end
		
	if response:match("^SUCCESS") then
		return true, response
	end
		
	return false, response
end

local current_objects = {}

local function refresh_objects(conn, servers)
	local new_objects = {}
	for _, srv in ipairs(servers) do
		local obj_name = "openvpn." .. srv.name
		
		new_objects[obj_name] = {
			list = {
				function(req, msg)
					local clients, err = fetch_clients(srv.ip, srv.port, srv.password)
					
					if not clients then
						conn:reply(req, {
							success = false,
							error = err or "Unknown error",
							clients = {}
						})
					else
						conn:reply(req, {
							success = true,
							clients = clients
						})
					end
				end,
				{}
			},
			
			kick = {
				function(req, msg)
					local clients_to_kick = msg.clients or msg.ip_addrs or {msg.ip_addr}
					
					if type(clients_to_kick) == "string" then
						clients_to_kick = {clients_to_kick}
					end
					
					if not clients_to_kick or #clients_to_kick == 0 then
						conn:reply(req, {
							success = false,
							message = "No clients specified"
						})
						return
					end
					
					local ok, err = kick_client(srv.ip, srv.port, srv.password, clients_to_kick)
					
					conn:reply(req, {
						success = ok,
						message = err or (ok and "Clients kicked" or "Failed to kick")
					})
				end,
				{ clients = ubus.ARRAY }
			}
		}
	end
		
	local to_remove = {}
	for old_name in pairs(current_objects) do
		if not new_objects[old_name] then
			to_remove[old_name] = {}
		end
	end
		
	local to_add = {}
	for new_name, new_obj in pairs(new_objects) do
		if not current_objects[new_name] then
			to_add[new_name] = new_obj
		end
	end
		
	if next(to_remove) then
		conn:remove(to_remove)
	end
		
	if next(to_add) then
		conn:add(to_add)
	end
		
	current_objects = new_objects
	return #servers
end

-- run this from init script
if arg and arg[1] == "--ubus" then
	uloop.init()
	local conn = ubus.connect()

	if not conn then
		io.stderr:write("[ERROR] Failed to connect to ubus")
		os.exit(2)
	end
	local cursor = uci.cursor()

	local servers = get_server_list(cursor)
	if #servers == 0 then
		os.exit(0)
	end
	refresh_objects(conn, servers)

	local refresh_timer
	refresh_timer = uloop.timer(function()
		cursor:unload("openvpn")
		cursor:load("openvpn")
		local servers = get_server_list(cursor)
		if #servers == 0 then
			os.exit(0)
		end
		refresh_objects(conn, servers)
		refresh_timer:set(10000)
	end, 10000)

	uloop.run()

	conn:close()
	return
end

Service = FunctionService:new()

-- GET /api/ovpnctl/servers
function Service:GET_TYPE_servers()
	local cursor = uci.cursor()
	local servers = {}

	for _, server in ipairs(get_server_list(cursor)) do
		table.insert(servers, {
			sec_id = server.sec_id,
			name = server.name,
			mode = server.mode,
			ip = server.ip,
			port = server.port
		})
	end

	return self:ResponseOK(servers)
end

-- GET /api/ovpnctl/list/{server_name}
function Service:GET_TYPE_list()
	local server_name = self.sid
		
	local conn = ubus.connect()
	if not conn then
		return self:ResponseError("Cannot connect to ubus")
	end
		
	local result = conn:call("openvpn." .. server_name, "list", {})
	conn:close()
		
	if result then
		return self:ResponseOK(result)
	else
		return self:ResponseNotFound("Server not found")
	end
end

-- POST /api/ovpnctl/actions/kick
function Service:kickClient()
	local server_name = self.arguments.data.server
	local clients = self.arguments.data.clients
		
	local conn = ubus.connect()
	if not conn then
		return self:ResponseError("Cannot connect to ubus")
	end
		
	local result = conn:call("openvpn." .. server_name, "kick", {
		clients = clients
	})
	conn:close()
	
	if result and result.success then
		return self:ResponseOK(result)
	else
		return self:ResponseError(result or {success = false})
	end
end

local kick_action = Service:action("kick", Service.kickClient)

local clients_option = kick_action:option("clients")
clients_option.require = true
clients_option.list = true

local server_option = kick_action:option("server")
server_option.require = true

return Service