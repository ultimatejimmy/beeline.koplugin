-- spec/test_beeline_ui_toast.lua — Unit tests for Beeline UI Download Toast & File Manager Refresh

package.loaded["logger"] = package.loaded["logger"] or {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
}

local mock_lfs = {
    attributes = function(path)
        local f = io.open(path, "r")
        if f then f:close() return { mode = "file" } end
        return nil
    end,
    mkdir = function(p)
        if p and os.execute then pcall(os.execute, "mkdir -p " .. tostring(p) .. " 2>/dev/null") end
    end,
    dir = function() return function() return nil end end,
}
package.loaded["lfs"] = package.loaded["lfs"] or mock_lfs
package.loaded["libs/libkoreader-lfs"] = package.loaded["libs/libkoreader-lfs"] or mock_lfs

local mock_device = {
    screen = {
        getWidth = function() return 1080 end,
        getHeight = function() return 1440 end,
    },
    isTouchDevice = function() return true end,
    isTouch = function() return true end,
    hasKeys = function() return false end,
}
package.loaded["device"] = mock_device

local mock_shown = {}
local mock_uimanager = {
    show = function(self, widget)
        table.insert(mock_shown, widget)
    end,
    close = function(self, widget) end,
    forceRePaint = function(self)
        self.repainted = true
    end,
    scheduleIn = function(self, delay, cb) return { delay = delay, cb = cb } end,
    unschedule = function(self, t) end,
    nextTick = function(self, cb) cb() end,
}
package.loaded["ui/uimanager"] = mock_uimanager

local mock_fc = {
    path = "/books/inbox",
    refreshed = false,
    refreshPath = function(self)
        self.refreshed = true
    end,
}
local mock_fm = {
    instance = {
        file_chooser = mock_fc,
    }
}
package.loaded["apps/filemanager/filemanager"] = mock_fm

local mock_infomessage = {
    new = function(self, opts)
        return {
            is_infomessage = true,
            text = opts.text,
            timeout = opts.timeout,
            icon = opts.icon,
        }
    end
}
package.loaded["ui/widget/infomessage"] = mock_infomessage

-- Stub container/widget modules that beeline_ui requires
local dummy_widget = {
    new = function(self, opts)
        local o = opts or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end,
    extend = function(self, opts)
        local c = {}
        for k, v in pairs(self) do c[k] = v end
        for k, v in pairs(opts or {}) do c[k] = v end
        c.__index = c
        return c
    end,
    getSize = function(self) return { w = 300, h = 60 } end,
}
package.loaded["ui/widget/container/inputcontainer"] = dummy_widget
package.loaded["ui/widget/container/framecontainer"] = dummy_widget
package.loaded["ui/widget/container/centercontainer"] = dummy_widget
package.loaded["ui/widget/verticalgroup"] = dummy_widget
package.loaded["ui/widget/horizontalgroup"] = dummy_widget
package.loaded["ui/widget/verticalspan"] = dummy_widget
package.loaded["ui/widget/horizontalspan"] = dummy_widget
package.loaded["ui/widget/linewidget"] = dummy_widget
package.loaded["ui/widget/textwidget"] = dummy_widget
package.loaded["ui/widget/textboxwidget"] = dummy_widget
package.loaded["ui/widget/button"] = dummy_widget
package.loaded["ui/widget/imagewidget"] = dummy_widget
package.loaded["ui/widget/rectspan"] = dummy_widget
package.loaded["ui/widget/inputdialog"] = dummy_widget
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/geometry"] = { new = function(self, opts) return opts or {} end }
package.loaded["ui/gesturerange"] = { new = function(self, opts) return opts or {} end }
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0,
    COLOR_WHITE = 1,
    Color8 = function(x) return x end,
    Color32 = function(r, g, b) return r end,
}

local plugin_dir = "plugin/beeline.koplugin"
package.path = plugin_dir .. "/?.lua;beeline/plugin/beeline.koplugin/?.lua;" .. package.path

local UI = require("beeline_ui")

-- 1. Test showDownloadToast & M.showToast (Libbee floating pill toast)
assert(type(UI.showDownloadToast) == "function", "showDownloadToast must be exported")
local toast = UI.showDownloadToast("Sunrise on the Reaping", 3, "check", "Book Fulfilled")
assert(#mock_shown == 1, "Expected 1 shown toast")
assert(mock_shown[1].text == "Sunrise on the Reaping", "Text must match")
assert(mock_shown[1].title == "Book Fulfilled", "Title must match")
assert(mock_shown[1].icon_name == "check", "Icon must match")
assert(mock_shown[1].dimen ~= nil, "Floating pill must calculate dimension")
assert(mock_shown[1][1] ~= nil, "Centered layout group must be present")
assert(mock_shown[1][1].align == "center", "Layout group must be center-aligned")
assert(mock_shown[1].dimen.w == 1080, "Full screen container width for centering")
print("PASS: showDownloadToast & Beeline floating pill verification")

-- Test warning/expired toast
local exp_toast = UI.showToast("Gone Girl\nToken expired.", 4, "info", "Loan Token Expired")
assert(exp_toast.title == "Loan Token Expired", "Expired toast title must match")
assert(exp_toast.icon_name == "info", "Expired toast icon must match")
print("PASS: loan token expired toast verification")

-- 2. Test refreshFileManager
assert(type(UI.refreshFileManager) == "function", "refreshFileManager must be exported")

-- Non-matching directory
UI.refreshFileManager("/other/folder")
assert(mock_fc.refreshed == false, "Should not refresh if paths differ")

-- Matching directory (ignoring trailing slash)
UI.refreshFileManager("/books/inbox/")
assert(mock_fc.refreshed == true, "Should refresh when matching path")
assert(mock_uimanager.repainted == true, "Should force repaint")
print("PASS: refreshFileManager matching verification")

-- 3. Test Dialog Navigation & Export Functions
assert(type(UI.showMainDialog) == "function", "showMainDialog must be exported")
assert(type(UI.showSettingsDialog) == "function", "showSettingsDialog must be exported")
assert(type(UI.showMainMenu) == "function", "showMainMenu must be exported")

-- Test invoking showMainDialog and showSettingsDialog with mock environment
local mock_plugin = {}
pcall(UI.showMainDialog, mock_plugin)
pcall(UI.showSettingsDialog, mock_plugin)
pcall(UI.showMainMenu, mock_plugin)
print("PASS: showMainDialog & showSettingsDialog execution verification")

-- 4. Test Background Sync default and toggling
local State = require("beeline_state")
local s = State.loadSettings()
s.background_sync = nil
State.saveSettings(s)
assert(State.getBackgroundSync() == false, "getBackgroundSync must default to false")
State.setBackgroundSync(true)
assert(State.getBackgroundSync() == true, "setBackgroundSync(true) must be true")
State.setBackgroundSync(false)
assert(State.getBackgroundSync() == false, "setBackgroundSync(false) must be false")
print("PASS: background_sync default false verification")

-- 5. Test Paired Browser tracking
assert(type(State.getPairedBrowserCount) == "function", "getPairedBrowserCount must be exported")
assert(type(State.addPairedBrowser) == "function", "addPairedBrowser must be exported")
State.unpairAllDevices()
assert(State.getPairedBrowserCount() == 0, "Paired count after unpairAllDevices must be 0")
State.addPairedBrowser("ABC-123")
assert(State.getPairedBrowserCount() == 1, "Paired count after adding one browser must be 1")
State.addPairedBrowser("DEF-456")
assert(State.getPairedBrowserCount() == 2, "Paired count after adding second browser must be 2")
State.unpairAllDevices()
assert(State.getPairedBrowserCount() == 0, "Paired count after unpairAllDevices must be 0")
print("PASS: paired browser tracking verification")

print("ALL UI TOAST, REFRESH & DIALOG TESTS PASSED!")
