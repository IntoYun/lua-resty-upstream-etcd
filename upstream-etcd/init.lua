-- @author zhongjin
-- @date 20170817

local syncer = require "resty.dyups.syncer"
local picker = require "resty.dyups.picker"

local conf = {
    etcd_host = "192.168.0.46",
    etcd_port = 2379,
    etcd_path = "/v1/testing/services/",
    storage = ngx.shared["syncer"],
}

syncer.init(conf)
picker.init(conf.storage)
