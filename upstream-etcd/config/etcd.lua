-- @author zhongjin
-- @date 20171016

return {
    etcd_host = "192.168.0.46",
    etcd_port = 2379,
    etcd_path = "/v1/testing/services/", -- for ETCDCTL_API=2

    storage    = ngx.shared["syncer"],
    username   = "root",
    password   = "26554422",
    srv_prefix = "intoyun/",
}

