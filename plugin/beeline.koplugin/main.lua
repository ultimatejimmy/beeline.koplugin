-- main.lua — Beeline KOReader Plugin
-- Zero-trust, end-to-end encrypted wireless file transfer to KOReader.

local logger = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

local ok_wc, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
local ok_ui, UIManager       = pcall(require, "ui/uimanager")

if not ok_wc or not WidgetContainer then
    logger.err("beeline: WidgetContainer unavailable, plugin disabled")
    return
end

local BeelinePlugin = WidgetContainer:extend{
    name        = "beeline",
    is_doc_only = false,   -- Available in file manager AND reader
}

local _poll_timer = nil
local _is_polling = false
local _is_suspended = false

local function _ui()
    local ok, BeelineUI = pcall(require, plugin_path .. "beeline_ui")
    if not ok then
        logger.err("beeline: could not load beeline_ui: " .. tostring(BeelineUI))
        return nil
    end
    return BeelineUI
end

local function _isNetworkConnected()
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected then
        local connected = NetworkMgr:isConnected()
        if connected ~= nil then return connected end
    end
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.hasNetwork then
        return Device:hasNetwork()
    end
    return true
end

function BeelinePlugin:stopBackgroundSync()
    if _poll_timer and ok_ui and UIManager then
        UIManager:unschedule(_poll_timer)
        _poll_timer = nil
    end
end

function BeelinePlugin:startBackgroundSync(delay)
    self:stopBackgroundSync()
    if _is_suspended then return end

    local ok_state, State = pcall(require, plugin_path .. "beeline_state")
    if not ok_state or not State or not State.getBackgroundSync() then
        return
    end

    delay = delay or 30

    local scheduleNext
    scheduleNext = function()
        if _is_suspended or not ok_ui or not UIManager then return end
        local ok_st, St = pcall(require, plugin_path .. "beeline_state")
        if not ok_st or not St or not St.getBackgroundSync() then return end

        _poll_timer = UIManager:scheduleIn(30, function()
            _poll_timer = nil
            if _is_suspended then return end
            if not _isNetworkConnected() then
                scheduleNext()
                return
            end

            if _is_polling then
                scheduleNext()
                return
            end

            _is_polling = true
            local ui = _ui()
            if ui then
                ui.receiveFiles(self, true, function()
                    _is_polling = false
                    scheduleNext()
                end)
            else
                _is_polling = false
                scheduleNext()
            end
        end)
    end

    if ok_ui and UIManager then
        _poll_timer = UIManager:scheduleIn(delay, function()
            _poll_timer = nil
            if _is_suspended then return end
            if _isNetworkConnected() and not _is_polling then
                _is_polling = true
                local ui = _ui()
                if ui then
                    ui.receiveFiles(self, true, function()
                        _is_polling = false
                        scheduleNext()
                    end)
                else
                    _is_polling = false
                    scheduleNext()
                end
            else
                scheduleNext()
            end
        end)
    end
end

function BeelinePlugin:updateSyncSchedule()
    local ok_state, State = pcall(require, plugin_path .. "beeline_state")
    if ok_state and State and State.getBackgroundSync() then
        self:startBackgroundSync(5)
    else
        self:stopBackgroundSync()
    end
end

function BeelinePlugin:init()
    if self.path then
        local p = self.path
        local extra = { p .. "/?.lua" }
        for _, ep in ipairs(extra) do
            if not package.path:find(ep, 1, true) then
                package.path = ep .. ";" .. package.path
            end
        end
    end

    self:onDispatcherRegisterActions()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    self:startBackgroundSync(10)

    logger.info("beeline: plugin initialized")
end

function BeelinePlugin:addToMainMenu(menu_items)
    local icon_path = self.path .. "/assets/bee.png"
    menu_items.beeline = {
        text         = "Beeline",
        sorting_hint = "tools",
        icon         = icon_path,
        callback     = function()
            local ui = _ui()
            if ui then ui.showMainMenu(self) end
        end,
    }
end

function BeelinePlugin:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher then return end

    pcall(function()
        Dispatcher:registerAction("beeline_check_inbox", {
            category = "none",
            event    = "BeelineCheckInbox",
            title    = "Beeline: Check for Files",
            general  = true,
        })
        Dispatcher:registerAction("beeline_menu", {
            category = "none",
            event    = "BeelineMenu",
            title    = "Beeline: Open Menu",
            general  = true,
        })
        Dispatcher:registerAction("beeline_qr_code", {
            category = "none",
            event    = "BeelineQRCode",
            title    = "Beeline: Scan to Pair (QR Code)",
            general  = true,
        })
    end)
end

function BeelinePlugin:onBeelineCheckInbox()
    local ui = _ui()
    if ui then ui.receiveFiles(self, false) end
    return true
end

function BeelinePlugin:onBeelineMenu()
    local ui = _ui()
    if ui then ui.showMainMenu(self) end
    return true
end

function BeelinePlugin:onBeelineQRCode()
    local ui = _ui()
    if ui then ui.showQRCodeDialog() end
    return true
end

function BeelinePlugin:onSuspend()
    _is_suspended = true
    self:stopBackgroundSync()
end

function BeelinePlugin:onResume()
    _is_suspended = false
    self:startBackgroundSync(5)
end

function BeelinePlugin:onNetworkDisconnected()
    self:stopBackgroundSync()
end

function BeelinePlugin:onCloseWidget()
    self:stopBackgroundSync()
end

function BeelinePlugin:onNetworkConnected()
    local ok_state, State = pcall(require, plugin_path .. "beeline_state")
    if not ok_state or not State then return end

    local pairing_code = State.getPairingCode()
    local worker_url = State.getWorkerUrl()
    local device_id = State.getDeviceId()

    if pairing_code ~= "" and worker_url ~= "" and device_id ~= "" then
        local ok_crypto, Crypto = pcall(require, plugin_path .. "beeline_crypto")
        local ok_client, Client = pcall(require, plugin_path .. "beeline_client")
        if ok_crypto and ok_client then
            local code_hash = Crypto.getCodeHash(pairing_code)
            if code_hash then
                local ok_reg, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
                if ok_reg and parsed and parsed.claimed then
                    pairing_code = State.regeneratePairingCode()
                    local new_hash = Crypto.getCodeHash(pairing_code)
                    if new_hash then
                        pcall(Client.registerPairingCode, worker_url, new_hash, device_id)
                    end
                end
            end
            pcall(Client.registerPairing, worker_url, device_id)
        end
    end

    if State.getAutoCheckWifi and State.getAutoCheckWifi() then
        self:startBackgroundSync(3)
    end
end

return BeelinePlugin
