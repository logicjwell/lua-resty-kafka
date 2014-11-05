-- Copyright (C) Dejiang Zhu(doujiang24)


local buffer = require "resty.kafka.buffer"
local producer = require "resty.kafka.producer"


local setmetatable = setmetatable
local timer_at = ngx.timer.at
local ngx_log = ngx.log
local DEBUG = ngx.DEBUG
local ERR = ngx.ERR
local ALERT = ngx.ALERT
local debug = ngx.config.debug
local is_exiting = ngx.worker.exiting


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end


local _M = new_tab(0, 4)
_M._VERSION = '0.01'


local cluster_inited = {}


local mt = { __index = _M }


local function _flush_lock(self)
    if not self.flushing then
        if debug then
            ngx_log(DEBUG, "flush lock accquired")
        end
        self.flushing = true
        return true
    end
    return false
end


local function _flush_unlock(self)
    if debug then
        ngx_log(DEBUG, "flush lock released")
    end
    self.flushing = false
end


local function _flush(premature, self, force)
    if not _flush_lock(self) then
        if debug then
            ngx_log(DEBUG, "previous flush not finished")
        end

        if not force then
            return true
        end

        repeat
            if debug then
                ngx_log(DEBUG, "last flush require lock")
            end
            ngx_sleep(1)
        until _flush_lock(self)
    end

    for topic, buffers in pairs(self.buffers) do
        local accept_buffer = buffers.accept_buffer
        local send_buffer = buffers.send_buffer

        if force or accept_buffer:need_flush() then
            -- exchange
            buffers.accept_buffer, buffers.send_buffer = send_buffer, accept_buffer

            -- get data
            local data, index = accept_buffer:flush()

            -- send data
            if index > 0 then
                local p = self.producer
                if not p:send(topic, data, index) then
                    self.error_handle(topic, data, index)
                end
            end
        end
    end

    _flush_unlock(self)
end


local function _flush_buffer(self)
    local ok, err = timer_at(0, _flush, self)
    if not ok then
        ngx_log(ERR, "failed to create timer at _flush_buffer, err: ", err)
    end
end


local _timer_flush
_timer_flush = function (premature, self, time)
    _flush(nil, self)

    if is_exiting() then
        _flush(nil, self, true)
        return
    end

    local ok, err = timer_at(time, _timer_flush, self, time)
    if not ok then
        ngx_log(ALERT, "failed to create timer at _timer_flush, err: ", err)
    end
end


function _M.init(self, broker_list, producer_opts, buffer_opts, cluster_name)
    local cluster_name = cluster_name or "default"
    local bp = cluster_inited[cluster_name]
    if bp then
        return bp
    end

    local error_handle = buffer_opts and buffer_opts.error_handle
                         or function (...) return nil end

    local p = producer:new(broker_list, producer_opts)
    local bp = setmetatable({
                producer = p,
                buffer_opts = buffer_opts,
                buffers = {},
                error_handle = error_handle,
            }, mt)

    cluster_inited[cluster_name] = bp
    _timer_flush(nil, bp, 1)
    return bp
end


function _M.send(self, topic, messages)
    if not self.buffers[topic] then
        self.buffers[topic] = {
            send_buffer = buffer:new(self.buffer_opts),
            accept_buffer = buffer:new(self.buffer_opts),
        }
    end

    local accept_buffer = self.buffers[topic].accept_buffer

    local ok, err = accept_buffer:add(messages)
    if not ok then
        self.error_handle(topic, messages)
    end

    if is_exiting() or accept_buffer:need_flush() then
        _flush_buffer(self)
        return true, "sending"
    end

    return true, "buffered"
end


return _M
