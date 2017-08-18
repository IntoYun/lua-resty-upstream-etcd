-- @author zhongjin
-- @date 20170817

local picker = require "resty.dyups.picker"
local json = require "cjson"

-- we need to set 'lua_code_cache on;' if comment the lines below
-- local conf = {
--     etcd_host = "192.168.0.46",
--     etcd_port = 2379,
--     etcd_path = "/v1/testing/services/",
--     storage = ngx.shared["syncer"],
-- }
-- picker.init(conf.storage)


local name = ngx.var.arg_svcname
local svc = picker.rr(name)
local all = picker.show(name)

ngx.log(ngx.DEBUG, "===> name: ", name)
ngx.log(ngx.DEBUG, "===> svc: ", json.encode(svc))
ngx.log(ngx.DEBUG, "===> all: ", json.encode(all))

ngx.say(json.encode(all))
