# lua-resty-upstream-etcd
```
!!!This module is under heavy development, do not use in  production environment.!!!

A lua module for OpenResty, can dynamically update the upstreams from etcd.
```

## DEPENDENCE
- openresty-1.9.11.1 and higher
- balancer_by_lua
- ngx.worker.id()
- lua-resty-http
- cjson

## SYNOPSIS
- syncer: fetch from etcd and watch etcd changes, save upstreams in shared.dict.syncer
- picker: sync upstreams from shared.dict.syncer(which syncer writes), run balancer alg to select upstream. REQUIRE: syncer
- logger: record the upstream response status and time cost in shared.dict.logger, and generate reports. OPTIONAL REQUIRE: syncer
- health: read the logger data, set down peers that not work. Run health check

### data structure of _M.data in syncer:
```
{
  "recpKfkWorkers": {
    "version": 1025,
    "peers": [
      {
        "host": "10.161.133.29",
        "weight": 1,
        "start_at": 1530064475,
        "params": [ ],
        "status": "up",
        "slow_start": 0,
        "check_url": "\/",
        "port": 10100
      }
    ]
  },
  "_version": 1025
}
```

## USAGE
- tested under `etcd v3.2.5`
- assume etcd is listenning at `192.168.0.46:2379`
- directory 'conf.d' and 'upstream-etcd' are used to build/test docker image
- if build new docker image on top of it, you need to set 'init_worker_by_lua_file' in your openresty.conf

### Prepare data in etcd:
- start etcd:
```
etcd --debug --listen-client-urls 'http://192.168.0.46:2379' --advertise-client-urls 'http://192.168.0.46:2379'
```

- pretending service registration
```
ETCDCTL_API=2 etcdctl --endpoints=http://192.168.0.46:2379 set /v1/testing/services/my_test_service/10.1.1.3:8080 '{"weight": 3, "slow_start": 30, "checkurl": "/health"}'
ETCDCTL_API=2 etcdctl --endpoints=http://192.168.0.46:2379 set /v1/testing/services/my_test_service/10.1.1.3:8080 '{"weight": 4, "status": "down"}'
ETCDCTL_API=2 etcdctl --endpoints=http://192.168.0.46:2379 set /v1/testing/services/my_test_service/10.1.1.3:8080 '{"weight": 5}'

The default weight is 1, if not set in ETCD, or json parse error and so on.
```

### Init the module:
```
lua_socket_log_errors off; # recommend
lua_shared_dict lreu-upstream 1m; # for storeage of upstreams
init_worker_by_lua_block {
    local syncer = require "lreu.syncer"
    syncer.init({
        etcd_host = "127.0.0.1",
        etcd_port = 2379,
        etcd_path = "/v1/testing/services/",
        storage = ngx.shared.lreu-upstream
    })

    -- init the picker with the shared storage(read only)
    local picker = require "lreu.picker"
    picker.init(ngx.shared.lreu-upstream)
}
```
### Get a server in upstream:
```
upstream test {
    server 127.0.0.1:2222; # fake server

    balancer_by_lua_block {
        local balancer = require "ngx.balancer"
        local u = require "lreu.picker"
        local s, err = u.rr("my_test_service")
        if not s then
            ngx.log(ngx.ERR, err)
            return ngx.exit(500)
        end
        local ok, err = balancer.set_current_peer(s.host, s.port)
        if not ok then
            ngx.log(ngx.ERR, "failed to set current peer: " .. err)
            return ngx.exit(500)
        end
    }
}
```

### entire configuration:
- copy `lua-resty-http` lua files to `/usr/local/openresty/lualib/resty/`
- copy `lua-resty-upstream-etcd` lua files to `/usr/local/openresty/lualib/resty/dyups/`

```
$ sudo cp conf.d/openresty.conf /etc/openresty/
$ sudo mkdir -p /usr/local/openresty/app/upstream-etcd/
$ sudo cp upstream-etcd/*.lua /usr/local/openresty/app/upstream-etcd/
```

## Functions
### picker.rr(service_name)
### picker.show(service_name)

## Todo
- Etcd cluster support.
- Add more load-balance-alg.
- ~~Upstream peers weight support.~~
- Upstream health check support.

## License
```
I have not thought about it yet.
```

