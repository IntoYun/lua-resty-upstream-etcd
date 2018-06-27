local _M = {}
local http = require "resty.http"
local json = require "cjson"

local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO

local ngx_time = ngx.time
local ngx_timer_at = ngx.timer.at
local ngx_worker_id = ngx.worker.id
local ngx_worker_exiting = ngx.worker.exiting
local ngx_sleep = ngx.sleep
local ngx_encode_base64 = ngx.encode_base64
local ngx_decode_base64 = ngx.decode_base64

local Auth= nil
local fFetch = false -- a full fetch from etcd
local noAuth = 3
local invalidAuth = 16
local tFetch = 2 -- time to wait response from fetch()
-- local tWatch = 3600
local tWatch = 1200 -- time to wait response from watch()


local function info(...)
    log(INFO, "syncer: ", ...)
end

local function warn(...)
    log(WARN, "syncer: ", ...)
end

local function errlog(...)
    log(ERR, "syncer: ", ...)
end

local function copyTab(st)
    local tab = {}
    for k, v in pairs(st or {}) do
        if type(v) ~= "table" then
            tab[k] = v
        else
            tab[k] = copyTab(v)
        end
    end
    return tab
end

local function indexOf(t, e)
    for i=1,#t do
        if t[i].host == e.host and t[i].port == e.port then
            return i
        end
    end
    return nil
end

local function splitAddr(s)
    if not s then
        return "127.0.0.1", 0, "nil args"
    end
    host, port = s:match("(.*):([0-9]+)")

    -- verify the port
    local p = tonumber(port)
    if p == nil then
        return "127.0.0.1", 0, "port invalid"
    elseif p < 1 or p > 65535 then
        return "127.0.0.1", 0, "port invalid"
    end

    -- verify the ip addr
    local chunks = {host:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")}
    if (#chunks == 4) then
        for _,v in pairs(chunks) do
            if (tonumber(v) < 0 or tonumber(v) > 255) then
                return "127.0.0.1", 0, "host invalid"
            end
        end
    else
        return "127.0.0.1", 0, "host invalid"
    end

    -- verify pass
    return host, port, nil
end

local function genPrefixBody()
    local key = _M.conf.srv_prefix
    local range_end = table.concat({key:sub(1, -2), string.char(key:byte(-1) + 1)})
    return {key=ngx.encode_base64(key), range_end=ngx.encode_base64(range_end)}
end

local function getLock()
    -- only the worker who get the 'lock' can sync from etcd.
    info("===> getLock() _M.lock: ", _M.lock)
    if _M.lock == true then
        return true
    end

    -- for the first time, try to mark a 'lock' flag
    local ok, err = _M.conf.storage:add("lock", true, tFetch*2)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("GET LOCK: failed to add key \"lock\": " .. err)
        return nil
    end

    -- we got the lock. mark it.
    _M.lock = true
    return true
end

local function refreshLock()
    local ok, err = _M.conf.storage:set("lock", true, tWatch+1) -- set unconditionaly
    if not ok then
        errlog("REFRESH LOCK: failed to set \"lock\"" .. err)
        return nil
    end
    return true
end

local function releaseLock()
    _M.conf.storage:delete("lock")
    _M.lock = nil
    return true
end

local function newPeer(key, value)
    info("===> newPeer() key: ", key)
    info("===> newPeer() value: ", value)
    local name, ipport = key:match('/([^/]+)/([^/]+)$')
    info("===> newPeer() name: ", name)
    info("===> newPeer() ipport: ", ipport)
    local h, p, err = splitAddr(ipport)
    if err then
        return {}, name, err
    end

    local cfg = (not value) and {} or json.decode(value)

    local w, s, c, t, a = 1, "up", "/", 0, ngx.time()
    if type(cfg.Metadata) == "table" then
        w = cfg.Metadata.weight     or w
        s = cfg.Metadata.status     or s
        c = cfg.Metadata.check_url  or c
        t = cfg.Metadata.slow_start or t
        a = cfg.Metadata.start_at   or a
    end

    return { host   = h,
             port   = tonumber(p),
             weight = w,
             status = s,
             check_url  = c,
             slow_start = t,
             start_at   = a,
             params     = cfg.Params or {}
         }, name, nil
end

local function save(name)
    local dict = _M.conf.storage

    -- when save the data, picker should not update
    dict:set("picker_lock", true, 1)

    -- no name means save all
    if not name then
        for name, upstream in pairs(_M.data) do
            if name ~= "_version" then
                dict:set(name .. "|peers", json.encode(upstream.peers))
                dict:set(name .. "|version", upstream.version)
            end
        end
    else
        -- remove the deleted upstream
        if not _M.data[name] then
            dict:delete(name .. "|peers")
            dict:delete(name .. "|version")
        -- save the updated upstream
        else
            dict:set(name .. "|peers", json.encode(_M.data[name].peers))
            dict:set(name .. "|version", _M.data[name].version)
        end
    end

    local allname = {}
    for name, _ in pairs(_M.data) do
        if name ~= "_version" then
           allname[#allname+1] = name
        end
    end

    dict:set("_allname", table.concat(allname, "|"))
    dict:set("_version", _M.data._version)

    -- remove the lock, picker can update now
    dict:delete("picker_lock")

    return
end

local function updatePeer(data)
    local events = data.result.events
    for _,event in ipairs(events) do
        local peer, name, err = newPeer(ngx_decode_base64(event.kv.key),
            (event.kv.value and ngx_decode_base64(event.kv.value)))
        if event.type and event.type == "DELETE" then
            table.remove(_M.data[name].peers, indexOf(_M.data[name].peers, peer))
            _M.data[name].version = event.kv.mod_revision
            if 0 == #_M.data[name].peers then
                _M.data[name] = nil
            end
            errlog("DELETE [".. name .. "]: " .. peer.host .. ":" .. peer.port)
        else
            if not _M.data[name] then
                _M.data[name] = {version=tonumber(event.kv.mod_revision), peers={peer}}
                errlog("CREATE [" .. name .. "]: " .. peer.host ..":".. peer.port)
            else
                local index = indexOf(_M.data[name].peers, peer)
                if index == nil then
                    errlog("ADD [" .. name .. "]: " .. peer.host ..":".. peer.port)
                    peer.start_at = ngx_time()
                    table.insert(_M.data[name].peers, peer)
                else
                    errlog("MODIFY [" .. name .. "]: " .. peer.host ..":".. peer.port)
                    _M.data[name].peers[index] = peer
                end
                _M.data[name].version = tonumber(event.kv.mod_revision)
            end
        end
        _M.data._version = tonumber(event.kv.mod_revision)
        save(name)
    end
    info("===> _M.data: ", json.encode(_M.data))
end

local function auth()
    if not _M.conf.username or not _M.conf.password then
        return "missing username or password"
    end

    local client = http:new()
    client:set_timeout(tFetch*1000)
    local ok, err = client:connect(_M.conf.etcd_host, _M.conf.etcd_port)
    info("===> auth() connect ok: ", ok)
    info("===> auth() connect err: ", err)

    local body = json.encode({name=_M.conf.username, password=_M.conf.password})
    info("===> auth() body: ", body)
    local res, err = client:request({
        path="/v3alpha/auth/authenticate",
        method="POST",
        body=body,
    })
    info("===> auth() request err: ", err)
    if err then
        return err
    end

    info("===> auth() type(res): ", type(res))
    local body, err = res:read_body()
    if err then
        return err
    end

    local ok, data = pcall(json.decode, body)
    if not ok then
        return data
    else
        Auth = data.token
    end

    local ok, err = client:close()
    if not ok then
        return err
    end
end

local function fetch(path, body)
    info("===> fetch() start ")
    info("===> fetch() running_count: ", ngx.timer.running_count())
    info("===> fetch() pending_count: ", ngx.timer.pending_count())

    local client = http:new()
    client:set_timeout(tFetch*1000)
    local ok, err = client:connect(_M.conf.etcd_host, _M.conf.etcd_port)
    info("===> fetch() connect ok: ", ok)
    info("===> fetch() connect err: ", err)
    if err then
        ngx_sleep(10)
        return nil, err
    end


    local params = {path=path, method="POST"}
    params.body  = json.encode(body)

    ::again::
    params.headers = {Authorization = Auth}
    local res, err = client:request(params)
    info("===> fetch() pramas: ", json.encode(params))
    if err then
        ngx_sleep(10)
        return nil, err
    end

    local body, err = res:read_body()
    info("===> fetch() read_body: ", json.encode(body))
    info("===> fetch() err: ", json.encode(err))
    if err then
        return nil, err
    end

    local ok, data = pcall(json.decode, body)
    info("===> fetch() decode body ok: ", ok)
    if not ok then
        return nil, data
    elseif (res.status == ngx.HTTP_BAD_REQUEST and data.code == noAuth) or
        (res.status == ngx.HTTP_UNAUTHORIZED and data.code == invalidAuth) then
        info("===> fetch() call auth ")
        local err = auth()
        if err then
            return nil, err
        end
        info("===> fetch() goto again ")
        goto again
    end

    local ok, err = client:set_keepalive(2000, 1)
    if not ok then
        return nil, err
    end

    return data, nil
end

local function watch()
    info("===> watch() start... ")
    info("===> watch() running_count: ", ngx.timer.running_count())
    info("===> watch() pending_count: ", ngx.timer.pending_count())

    local client = http:new()
    client:set_timeout(tWatch*1000)
    local ok, err = client:connect(_M.conf.etcd_host, _M.conf.etcd_port)
    info("===> watch() connect ok: ", ok)
    info("===> watch() connect err: ", err)
    if err then
        errlog("===> watch() connect err: ", err)
        fFetch = true
        ngx_sleep(10)
        return
    end

    local params = {path="/v3alpha/watch", method="POST"}
    params.body  = json.encode({create_request = genPrefixBody()})

    local timeout = false

    ::again::
    if ngx_worker_exiting() then
        info("===> watch() will exit ")
        info("===> watch() worker_exiting_signal: ", ngx_worker_exiting())
        -- we CAN'T release the lock here
        -- releaseLock()
        return
    end

    if timeout then
        local ok, err = client:connect(_M.conf.etcd_host, _M.conf.etcd_port)
        info("===> watch() connect ok: ", ok)
        info("===> watch() connect err: ", err)
        if err then
            errlog("===> watch() connect err: ", err)
            fFetch = true
            ngx_sleep(10)
            return
        end
    end
    info("===> watch() timeout: ", timeout)

    params.headers = {Authorization = Auth}
    local res, err = client:request(params)
    info("===> watch() pramas: ", json.encode(params))
    if err then
        errlog("===> watch() request err: ", err)
        fFetch = true
        ngx_sleep(10)
        return
    end

    local reader = res.body_reader
    repeat
        -- If got the lock, then keep refreshing it,
        -- thus we can hold the lock all the time.
        info("===> watch() refreshLock for another ", tWatch+1)
        refreshLock()

        local chunk, err = reader()
        if err then
            if err == "timeout" then
                timeout = true
                goto again
            else
                errlog("read chunk error: "..err)
                return
            end
        else
            info("===> watch() chunk: ", chunk)
            local ok, data = pcall(json.decode, chunk)
            if not ok then
                errlog("decode chunk error: "..err)
                return
            elseif data.error then
                errlog("etcd-server error: "..chunk)
                return
            elseif data.result.canceled then
                local reason = data.result.cancel_reason
                local nAuth = reason:find("code = PermissionDenied")
                info("===> watch() nAuth: ", nAuth)
                if nAuth then
                    info("===> watch() call auth ")
                    local err = auth()
                    if err then
                        errlog("auth error: "..err)
                        return
                    else
                        info("===> watch() goto again ")
                        local ok, err = client:close()
                        errlog("===> watch() set_keepalive ok: ", ok)
                        errlog("===> watch() set_keepalive err: ", err)
                        timeout = true
                        goto again
                    end
                else
                    errlog("watch error: "..reason)
                    fFetch = true
                    return
                end
            elseif data.result.events then
                updatePeer(data)
            end
        end
    until not chunk
end

local function cycle(premature)
    info("===> cycle() start ")
    info("===> cycle() running_count: ", ngx.timer.running_count())
    info("===> cycle() pending_count: ", ngx.timer.pending_count())

    if premature or ngx_worker_exiting() then
        info("===> cycle() will exit ")
        info("===> cycle() premature: ", premature)
        info("===> cycle() worker_exiting_signal: ", ngx_worker_exiting())
        releaseLock()
        return
    end

    -- If we cannot acquire the lock, wait 1 second
    -- for the lock to expire, which is setted by pre-worker(
    -- killed by reload-signal or light-thread start by last ngx.timer.at())
    if not getLock() then
        info("===> cycle() miss the lock")
        info("===> cycle() Waiting for pre-worker to exit...")
        local ok, err = ngx_timer_at(2, cycle)
        if not ok then
            errlog("Error start cycle: ", err)
        end
        return
    else
        info("===> cycle() got the lock")
    end

    if not fFetch then
        local dict = _M.conf.storage
        local allname = dict:get("_allname")
        local version = dict:get("_version")

        -- synced before, or restart after reload signal
        -- Load data from shm
        info("===> cycle() allname: ", allname)
        info("===> cycle() version: ", version)
        if allname and version then
            info("===> cycle() sync from sharedDict...")

            _M.data = {_version = version}
            for name in allname:gmatch("[^|]+") do
                upst = dict:get(name .. "|peers")
                vers = dict:get(name .. "|version")

                local ok, data = pcall(json.decode, upst)
                if ok then
                    _M.data[name] = {version = vers, peers = data}
                else
                    _M.data = nil
                    break
                end
            end
        end
    end

    -- First time to fetch all the upstreams.
    info("===> cycle() judge _M.data: ", _M.data and "exists" or "nil")
    if not _M.data then
        _M.data = {}
        info("===> cycle() do full fetch first ")
        local path = "/v3alpha/kv/range"
        local body = genPrefixBody()
        local upstreamList, err = fetch(path, body)

        if err then
            errlog("When fetch from etcd: " .. err)
            ngx_sleep(1)
            goto continue
        end

        if upstreamList.code then
            errlog("When fetch from etcd: " .. upstreamList.error)
            ngx_sleep(1)
            goto continue
        end

        if upstreamList.kvs then
            local revision = tonumber(upstreamList.header.revision)
            for _, s in pairs(upstreamList.kvs) do
                local peer, name, err = newPeer(ngx_decode_base64(s.key), ngx_decode_base64(s.value))
                info("===> cycle() name: ", name)
                if not err then
                    if not _M.data[name] then
                        _M.data[name] = {version=revision, peers={}}
                    end
                    table.insert(_M.data[name].peers, peer)
                end
            end
            _M.data._version = revision

            -- save upstreams and set 'ready' flag
            save()
            _M.conf.storage:set("ready", true)
        end
        info("===> cycle() _M.data: ", json.encode(_M.data))
        fFetch = false
    end

    -- Watch the change and update the data.
    info("===> cycle() now, watch for updates... ")
    watch() -- will spin until error
    info("===> cycle() now, watch stop to spinning... ")

    -- Start the update cycle.
    ::continue::
    info("===> cycle() start cycle in a new light-thread ")
    _M.data = nil
    local ok, err = ngx_timer_at(0, cycle)
    if not ok then
        errlog("Error start cycle: ", err)
    end
end

function _M.init(conf)
    -- Only one worker start the syncer, here will use worker_id == 0
    if ngx_worker_id() ~= 0 then
        return
    end
    info("===> init2() start ... ")
    _M.conf = conf

    -- Start the etcd cycle
    info("===> init() call ngx_timer_at() ...")
    local ok, err = ngx_timer_at(0, cycle)
    if not ok then
        errlog("Error start watch: " .. err)
    end
end

return _M
