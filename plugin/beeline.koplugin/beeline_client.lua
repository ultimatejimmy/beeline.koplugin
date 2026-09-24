-- beeline_client.lua — HTTP client for Beeline Cloudflare Worker

local logger = require("logger")

local M = {}

local function getTransport()
    local ok_ssl, ssl_https = pcall(require, "ssl.https")
    local ok_http, socket_http = pcall(require, "socket.http")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")

    return {
        https = ok_ssl and ssl_https or nil,
        http = ok_http and socket_http or nil,
        ltn12 = ok_ltn and ltn12 or nil,
        socketutil = ok_su and socketutil or nil,
    }
end

local function executeRequest(req)
    local t = getTransport()
    local url = req.url
    local is_https = url:match("^https://") ~= nil
    local handler = is_https and t.https or t.http

    if not handler then
        return nil, (is_https and "HTTPS module unavailable" or "HTTP module unavailable")
    end

    local chunks = {}
    local sink = t.ltn12 and t.ltn12.sink.table(chunks)
    if t.socketutil and type(t.socketutil.table_sink) == "function" then
        sink = t.socketutil.table_sink(chunks)
    end

    local req_spec = {
        url = url,
        method = req.method or "GET",
        headers = req.headers or {},
        sink = sink,
        source = req.source,
        protocol = "any",
        verify = "none",
        options = "all",
    }

    if t.socketutil and type(t.socketutil.set_timeout) == "function" then
        t.socketutil:set_timeout(30, 60)
    end

    local ok, res, code, headers, status = pcall(handler.request, req_spec)

    if t.socketutil and type(t.socketutil.reset_timeout) == "function" then
        pcall(t.socketutil.reset_timeout, t.socketutil)
    end

    if not ok then
        return nil, "Network request error: " .. tostring(res)
    end

    if not res then
        return nil, tostring(code or "Connection failed")
    end

    local num_code = tonumber(code) or (res == 1 and 200)
    if not num_code then
        return nil, tostring(code or "Invalid response")
    end

    local body = table.concat(chunks)
    return {
        code = num_code,
        body = body,
        headers = headers or {},
        status = status,
    }
end

local function parseJson(raw)
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, data = pcall(rapidjson.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    return nil
end

--- Tests connectivity to the worker
function M.ping(worker_url)
    if not worker_url or worker_url == "" then
        return nil, "Worker URL is empty"
    end
    local url = worker_url .. "/api/ping"
    local resp, err = executeRequest({ url = url, method = "GET" })
    if not resp then return nil, err end
    if resp.code ~= 200 then
        return nil, "Server returned HTTP " .. tostring(resp.code)
    end
    local parsed = parseJson(resp.body)
    if parsed and parsed.ok then
        return true, parsed
    end
    return true
end

--- Registers this device as active/paired with the Cloudflare Worker
function M.registerPairing(worker_url, device_hash)
    if not worker_url or worker_url == "" then
        return nil, "Worker URL is not configured"
    end
    if not device_hash or device_hash == "" then
        return nil, "Invalid device hash"
    end

    local url = worker_url .. "/api/pair"
    local resp, err = executeRequest({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Device-Id"] = device_hash,
        },
    })
    if not resp then return nil, err end
    if resp.code ~= 200 and resp.code ~= 201 then
        return nil, "Pairing registration failed (HTTP " .. tostring(resp.code) .. ")"
    end

    local parsed = parseJson(resp.body)
    if parsed then
        return (parsed.ok == true), parsed
    end
    return true
end

--- Registers a single-use pairing code mapped to this device_id
function M.registerPairingCode(worker_url, code_hash, device_id)
    if not worker_url or worker_url == "" then
        return nil, "Worker URL is not configured"
    end
    if not code_hash or not device_id then
        return nil, "Invalid code hash or device ID"
    end

    local url = worker_url .. "/api/pair"
    local json_body = string.format('{"action":"register_code","codeHash":"%s","deviceId":"%s"}', code_hash, device_id)
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    local source = ok_ltn and ltn12 and ltn12.source.string(json_body) or nil

    local resp, err = executeRequest({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#json_body),
            ["X-Device-Id"] = device_id,
        },
        source = source,
    })
    if not resp then return nil, err end
    local parsed = parseJson(resp.body)
    return (resp.code == 200 or resp.code == 201), parsed
end

--- Checks whether a pairing code has been claimed by a browser
function M.checkPairingCode(worker_url, code_hash)
    if not worker_url or worker_url == "" or not code_hash then
        return nil, "Invalid arguments"
    end
    local url = worker_url .. "/api/pair"
    local json_body = string.format('{"action":"check_code","codeHash":"%s"}', code_hash)
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    local source = ok_ltn and ltn12 and ltn12.source.string(json_body) or nil

    local resp, err = executeRequest({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#json_body),
        },
        source = source,
    })
    if not resp then return nil, err end
    local parsed = parseJson(resp.body)
    return (resp.code == 200), parsed
end

--- Fetches list of uncollected files for the device
function M.fetchInbox(worker_url, device_hash)
    if not worker_url or worker_url == "" then
        return nil, "Worker URL is not configured"
    end
    if not device_hash or device_hash == "" then
        return nil, "Invalid device hash"
    end

    local url = worker_url .. "/api/inbox?device=" .. tostring(device_hash)
    local resp, err = executeRequest({ url = url, method = "GET" })
    if not resp then return nil, err end

    if resp.code ~= 200 then
        return nil, "Inbox check failed (HTTP " .. tostring(resp.code) .. ")"
    end

    local parsed = parseJson(resp.body)
    if not parsed or not parsed.ok then
        return nil, (parsed and parsed.error) or "Invalid server response"
    end

    return parsed.files or {}
end

--- Downloads encrypted binary envelope for a specific file
function M.downloadFile(worker_url, device_hash, file_id)
    if not worker_url or not device_hash or not file_id then
        return nil, "Missing download parameters"
    end

    local url = worker_url .. "/api/download?id=" .. tostring(file_id) .. "&device=" .. tostring(device_hash)
    local resp, err = executeRequest({ url = url, method = "GET" })
    if not resp then return nil, err end

    if resp.code ~= 200 then
        return nil, "Download failed (HTTP " .. tostring(resp.code) .. ")"
    end

    return resp.body
end

--- Deletes file from Cloudflare Worker upon successful receipt & decryption
function M.deleteRemoteFile(worker_url, device_hash, file_id)
    if not worker_url or not device_hash or not file_id then
        return false
    end

    local url = worker_url .. "/api/download?id=" .. tostring(file_id) .. "&device=" .. tostring(device_hash)
    local resp, err = executeRequest({ url = url, method = "DELETE" })
    return resp and resp.code == 200
end

--- Revokes / unpairs a device on the Cloudflare Worker
function M.unpairDevice(worker_url, device_id)
    if not worker_url or worker_url == "" or not device_id or device_id == "" then
        return false
    end

    local url = worker_url .. "/api/pair"
    local json_body = string.format('{"action":"unpair_device","deviceId":"%s"}', device_id)
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    local source = ok_ltn and ltn12 and ltn12.source.string(json_body) or nil

    local resp, err = executeRequest({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#json_body),
            ["X-Device-Id"] = device_id,
        },
        source = source,
    })
    return resp and (resp.code == 200 or resp.code == 204)
end

return M
