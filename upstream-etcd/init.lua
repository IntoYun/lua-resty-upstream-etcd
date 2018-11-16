-- @author zhongjin
-- @date 2017-10-16

_G.NULL = ngx.null

local __loaded_mods = {}

-- as we could not use ngx.var.SERVER_DIR, so set it here.
local __SERVER_DIR = "app/upstream-etcd"


_G.saveMod = function(namespace, model)
    package.loaded[table.concat({__SERVER_DIR, ".", namespace})] = model
end


--@param string: module name
--@return table: module
_G.loadMod = function(namespace)

    -- try to find system module
    local module = __loaded_mods[namespace]
    if module then
        return module
    end

    -- try to find project module
    local proj_namespace = table.concat({__SERVER_DIR, ".", namespace})
    local module = __loaded_mods[proj_namespace]
    if module then
        return module
    end

    -- try to load system module
    local ok, module = pcall(require, namespace)
    if ok then
        __loaded_mods[namespace] = module
        return module
    end

    -- try to load project module
    local ok, module = pcall(require, proj_namespace)
    if ok then
        __loaded_mods[proj_namespace] = module
        return module
    end

    ngx.log(ngx.ERR, "===> loadMod() failed to load module: ", namespace)
    error("===> loadMod() failed to load module: "..namespace, 2)
end
