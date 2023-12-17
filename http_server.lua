#!/usr/bin/env lua
local socket = require("socket")

--{{Options
---The port number for the HTTP server. Default is 80
PORT = 8080
---The parameter backlog specifies the number of client connections
-- that can be queued waiting for service. If the queue is full and
-- another client attempts connection, the connection is refused.
BACKLOG = 10
-- Этот параметр определяет, где сервер будет искать файлы.
ROOT_DIR = arg[1] or "."
--}}Options

local codes = {
	[200] = "OK",
	[404] = "Page not found",
	[500] = "Internal server error",
}

local ssl
local ssl_param
local cert_file = io.open(ROOT_DIR .. "/cert.pem")
if cert_file then
	local succ, ssll = pcall(require, "ssl")
	if succ then
		print("[INFO] OpneSSL loaded")
		ssl_param = {
			mode = "server",
			protocol = "sslv23",
			key = ROOT_DIR .. "/key.pem",
			certificate = ROOT_DIR .. "/cert.pem",
			verify = { "peer" },
			options = { "all" },
		}
		ssl = ssll
	elseif ssll then
		print("[WARN] OpennSSL loading error:", ssl)
	end
	cert_file:close()
else
	print("[INFO] SSL disable")
end

local rules = {}

local rules_file, err = loadfile(ROOT_DIR .. "/rules.lua", "t", {})
if rules_file then
	rules = rules_file()
	print("[INFO] Rules loaded")
elseif err then
	print("[ERROR]", err)
else
	print("[INFO] Rules not found.")
end

local function unescape(s)
	s = string.gsub(s, "+", " ")
	s = string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end)
	return s
end

local args_fmt = "([^&=?]+)=([^&=?]+)"
---Парсит аргументы формата www-form-urlencoded
---@param args_str string
---@return table
local function parse_args(args_str)
	local args = {}
	for key, value in string.gmatch(args_str,
		args_fmt) do
		args[key] = unescape(value)
	end
	return args
end

-- Делим ссылку на имя файла и аргументы
local function parse_uri(uri)
	local i = string.find(uri, "?")
	if i then
		local args_str = string.sub(uri, i + 1)
		local args = parse_args(args_str)
		return string.sub(uri, 1, i - 1), args
	else
		return uri, {}
	end
end

local start_line_fmt = "(%w+)%s+(%g+)%s+(%w+)/([%d%.]+)"
local function parse_start_line(start_line)
	local request = {startline = start_line}
	request.method, request.uri, request.protoname, request.protover = start_line:match(start_line_fmt)
	return request
end

local header_match = "(%g+): ([%g ]+)"
local function read_request(client)
	repeat
		local start_line, err = client:receive("*l")
		if start_line then
			local request = parse_start_line(start_line)
			local raw_headers = {}
			request.headers = {}

			local reading = true
			while reading do
				local header_line, err = client:receive("*l")
				reading = (header_line ~= "" and header_line ~= nil)
				if reading then
					table.insert(raw_headers, header_line)
					local key, value = string.match(header_line, header_match)
					if key then
						request.headers[key:lower()] = value
					end
				end
			end
			request.header = table.concat(raw_headers, "\n")
			request.filename, request.args = parse_uri(request.uri)
			return request
		elseif err == "timeout" then
			coroutine.yield()
		else
			io.stderr:write("[ERROR] Client " .. err .. "\n")
			return nil
		end
	until start_line
end

local startline_fmt = "HTTP/1.1 %d %s\n"
local function resp_startline(code, mess)
	return startline_fmt:format(code, mess)
end

local header_fmt = "%s: %s"
local function concat_headers(headers)
	local out = {}
	for i, k in pairs(headers) do
		local header = (header_fmt):format(i, k)
		table.insert(out, header)
	end
	return table.concat(out, "\n")
end

---@class Server
---@field closed boolean?
---@field startline_sended boolean?
---@field header_sended boolean?
---@field body_sended boolean?
---@field client table Socket.TCP клиент
---@field request table
---@field response table
---@field thread thread
local server_obj = {}

---Отсылает стартовую строку
function server_obj:sendstartline()
	if self.startline_sended then return end
	self.client:send(resp_startline(self.response.code, self.response.mess))
	self.startline_sended = true
end

---Отсылает, если надо, заголовки
function server_obj:sendheaders()
	local response = self.response
	if self.header_sended == true then return end
	local out = concat_headers(response.headers) .. "\n\n"
	self:sendstartline()
	self.client:send(out)
	self.header_sended = true
end

---Отсылает, если надо, тело, сохраненное в response.body, а перед этим headers
function server_obj:sendbody()
	local response = self.response
	if self.body_sended then return end

	local body, client = response.body, self.client
	if #body > 0 then
		local bodytext = table.concat(body)
		response.headers["Content-Length"] = #bodytext
		self:sendheaders()
		client:send(bodytext)
	else
		self:sendheaders()
	end

	self.body_sended = true
end

---Отсылает, если надо, заголовки и тело страницы, и закрывает соединение
function server_obj:closecon()
	if self.closed then return end
	self:sendbody()
	self.client:close()
	self.closed = true
end

---Отправляет ошибку и закрывает соединение
---@param code number
---@param text string
function server_obj:error(code, text)
	local response = self.response
	local err_mess = codes[code]
	response.code = code
	response.mess = err_mess
	if text then
		text = text:gsub("\n", "<br>")
	else
		text = ""
	end
	table.insert(response.body,
		("<!DOCTYPE html><html lang='en'><body><h1>%s</h1><br><p>%s</p></body></html>"):format(err_mess, text))
end

server_obj.__index = server_obj
server_obj.ROOT_DIR = ROOT_DIR

server_obj.parseurlargs = parse_args

local env_mt = { __index = _G }
---@param threaddata Server
---@return function?
local function thread_func(threaddata)
	local client = threaddata.client
	local response = threaddata.response
	local request = read_request(client)
	
	if request then
		for _, rule in ipairs(rules) do
			if request.filename:match(rule.regex) then
				rule.func(request, response)
			end
		end
		threaddata.request = request
		
		local filename = threaddata.request.filename
		local is_script = string.find(filename, ".lua") and true

		coroutine.yield()
		if is_script then -- если обратились к lua фалу
			local threadenv = setmetatable({
				server = threaddata,
				request = request,
				response = response,
				client = threaddata.client,
				echo = function(...)
					local args = table.pack(...)
					for i = 1, args.n do
						table.insert(threaddata.response.body, tostring(args[i]))
					end
				end
			}, env_mt)

			local script_func, err = loadfile(
				ROOT_DIR .. filename, "bt", threadenv) -- загрузка скрипта

			if script_func then
				local ret, err = xpcall(script_func, debug.traceback)
				if not ret then
					io.stderr:write("[ERROR] " .. err .. "\n")
					threaddata:error(500, err)
				end
			else
				io.stderr:write("[ERROR] " .. err .. "\n")
				threaddata:error(500, err)
			end
		else
			local f = io.open(ROOT_DIR .. request.filename, "rb")

			if f then
				local data_lenghth = f:seek("end"); f:seek("set")
				response.headers["Content-Length"] =
					tostring(data_lenghth)
				threaddata:sendheaders()
				for d in f:lines(1024 * 1024) do
					client:send(d)
					coroutine.yield()
				end

				f:close()
			else
				print("[ERROR] Page not found", request.filename)
				threaddata:error(500, "File "
					.. request.filename .. " not found.")
			end
		end
	end
end

---@type Server[]
local threads = {}
local last_thread = 0

-- create a TCP socket and bind it to the local host, at any port
local server = assert(socket.tcp())
server:setoption("reuseaddr", true)
server:settimeout(0)
assert(server:bind("0.0.0.0", PORT))
server:listen(BACKLOG)

-- Print IP and port
local ip, port = server:getsockname()
print("Listening on IP=" .. ip .. ", PORT=" .. port .. "...")

while true do
	local client, err = server:accept()

	if client then
		if ssl and ssl_param then
			local ssl_client, err = ssl.wrap(client, ssl_param)
			if ssl_client then
				local suc, err = ssl_client:dohandshake()
				if suc then
					client = ssl_client
				else
					print("[ERROR] HANDSHAKE", err)
				end
			else
				print("[ERROR] SSL_WRAP", err)
			end
		end
		client:settimeout(0)
		local newth = coroutine.create(thread_func)
		local threaddata = setmetatable({
			client = client,
			thread = newth,
			response = {
				headers = {
					["Content-Type"] = "text/html; charset=utf-8", -- По дефолту отправляем html, utf-8
					["Date"] = os.date("!%c GMT"),
					["Connection"] = "close",
				},
				body = {},
				code = 200,
				mess = "OK",
			}
		}, server_obj)
		
		local state, err = coroutine.resume(newth, threaddata)
		local thstatus = coroutine.status(newth)
		if state and thstatus == "dead" then
			threaddata:closecon()
		elseif not state then
			io.stderr:write("[PROCESSOR] Script error without adding to pool: " .. err)
			threaddata:error(500, err)
		else
			table.insert(threads, threaddata)
			if last_thread == 0 then last_thread = 1 end
		end
	elseif err == "timeout" then
		if last_thread > 0 then
			local t = threads[last_thread]
			if t then
				local cr = t.thread
				local status, error = coroutine.resume(cr)
				local crstatus = coroutine.status(cr)
				if status and crstatus == "dead" then
					t:closecon()
					table.remove(threads, last_thread)
				elseif status == false then
					io.stderr:write("[ERROR] " .. error .. " in " .. last_thread .. "\n")
					t:error(500, err)
					table.remove(threads, last_thread)
				end

				last_thread = last_thread - 1
				if last_thread < 1 and #threads > 0 then
					last_thread = #threads
				end
			else
				last_thread = last_thread - 1
				if last_thread < 1 then last_thread = #threads end
			end
		end
	else
		print("Error happened while getting the connection.nError: " .. err)
	end
end
