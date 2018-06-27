-- @author zhongjin
-- @date 2017-10-16

local etcdConf = loadMod("config.etcd")

local syncer   = loadMod("resty.dyups.syncer")
syncer.init(etcdConf)

-- local picker   = loadMod("resty.dyups.picker")
-- picker.init(etcdConf.storage)
