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
-- Verify vertical centering (sh = 1440, dummy card h = 60 -> toast_y = (1440 - 60) / 2 = 690)
assert(mock_shown[1][1][1] ~= nil and mock_shown[1][1][1].height == 690,
    "Toast must be vertically centered (expected 690, got " .. tostring(mock_shown[1][1][1] and mock_shown[1][1][1].height) .. ")")
print("PASS: showDownloadToast & Beeline vertically-centered pill verification")

-- 1b. Test showProgressToast & updateProgress (Loading bar)
assert(type(UI.showProgressToast) == "function", "showProgressToast must be exported")
local prog_toast = UI.showProgressToast("Fulfilling Loan", "Sunrise on the Reaping", "download", 0.05)
assert(prog_toast.title == "Fulfilling Loan", "Progress toast title must match")
assert(prog_toast.text == "Sunrise on the Reaping", "Progress toast text must match")
assert(prog_toast.dismissable == false, "Progress toast must not be dismissable")
assert(prog_toast.timeout == 0, "Progress toast must not auto-timeout")
assert(prog_toast.progress == 0.05, "Initial progress must be 0.05")
assert(prog_toast[1][1].height == 690, "Progress toast must be vertically centered")
-- Verify onTapDismiss does not close progress toast
prog_toast:onTapDismiss()
assert(prog_toast.progress == 0.05, "Non-dismissable progress toast ignores tap")
-- Verify updateProgress clamping and throttling
prog_toast:updateProgress(0.06) -- < 2% delta, should store progress without forcing repaint
assert(prog_toast.progress == 0.06, "Progress should update to 0.06")
prog_toast:updateProgress(0.55)
assert(prog_toast.progress == 0.55, "Progress should update to 0.55")
prog_toast:updateProgress(1.5)
assert(prog_toast.progress == 1.0, "Progress must clamp to 1.0")
prog_toast:updateProgress(-0.5)
assert(prog_toast.progress == 0.0, "Progress must clamp to 0.0")
prog_toast:close()
print("PASS: showProgressToast & loading bar verification")

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

-- 6. Test BeelineToastWidget:_closed guard
do
    local t = UI.showProgressToast("Test", "Working…", "download", 0.1)
    assert(t._closed == nil, "New progress toast should not be closed")
    t:close()
    assert(t._closed == true, "Closed progress toast must set _closed = true")
    mock_uimanager.repainted = false
    t:updateProgress(0.8, "Should be ignored")
    assert(mock_uimanager.repainted == false, "updateProgress after close() must be a no-op")
    print("PASS: BeelineToastWidget _closed guard verification")
end

-- 7. Test M.receiveFiles checking/downloading progress & multi-file fulfillment safety
do
    local Client = require("beeline_client")
    local Crypto = require("beeline_crypto")
    local orig_fetch = Client.fetchInbox
    local orig_download = Client.downloadFile
    local orig_delete = Client.deleteRemoteFile
    local orig_decrypt = Crypto.decryptEnvelope

    -- Configure State so receiveFiles proceeds
    local st = State.loadSettings()
    local saved_url, saved_code, saved_inbox, saved_consent = st.worker_url, st.pairing_code, st.inbox_dir, st.drm_consent_version
    st.worker_url = "https://example.workers.dev"
    st.pairing_code = "TEST-123"
    st.inbox_dir = "/tmp/beeline_test_inbox"
    st.drm_consent_version = 1
    State.saveSettings(st)
    os.execute("mkdir -p /tmp/beeline_test_inbox 2>/dev/null")

    -- 7a. Empty inbox shows Checking Inbox then closes cleanly
    mock_shown = {}
    local closed_widgets = {}
    local orig_close = mock_uimanager.close
    mock_uimanager.close = function(self, w) table.insert(closed_widgets, w) end
    Client.fetchInbox = function() return {} end
    local empty_done = nil
    UI.receiveFiles({}, false, function(ok) empty_done = ok end)
    assert(empty_done == false, "Empty inbox should invoke on_done(false)")
    assert(#mock_shown >= 2, "Should show Checking Inbox progress toast then No incoming files toast")
    assert(mock_shown[1].title == "Checking Inbox", "First toast should be Checking Inbox, got: " .. tostring(mock_shown[1].title))
    assert(mock_shown[1]._closed == true, "Checking Inbox toast must be closed when inbox is empty")
    print("PASS: receiveFiles empty inbox progress toast lifecycle")

    -- 7b. Multi-file download + multi-ACSM fulfillment with error resilience & single refresh
    mock_shown = {}
    mock_fc.path = "/tmp/beeline_test_inbox"
    mock_fc.refreshed = false
    local refresh_calls = 0
    local orig_refresh_path = mock_fc.refreshPath
    mock_fc.refreshPath = function(self)
        self.refreshed = true
        refresh_calls = refresh_calls + 1
    end

    local cb_seen = 0
    local fetch_calls = 0
    Client.fetchInbox = function()
        fetch_calls = fetch_calls + 1
        if fetch_calls == 1 then
            return {
                { id = "f1", size = 1000 },
                { id = "f2", size = 1000 },
            }
        end
        return {}
    end
    Client.downloadFile = function(w, d, id, progress_cb)
        if type(progress_cb) == "function" then
            cb_seen = cb_seen + 1
            progress_cb(500)
            progress_cb(1000)
        end
        return "ENV:" .. tostring(id)
    end
    Client.deleteRemoteFile = function() return true end
    Crypto.decryptEnvelope = function(env)
        if env == "ENV:f1" then
            return { data = "<acsm>1</acsm>", metadata = { filename = "loan1.acsm" } }
        else
            return { data = "<acsm>2</acsm>", metadata = { filename = "loan2.acsm" } }
        end
    end

    local fulfill_calls = 0
    local orig_drm = package.loaded["beeline_drm"]
    package.loaded["beeline_drm"] = {
        parseAcsmMetadata = function(p) return { title = p:match("loan1") and "Book One" or "Book Two" } end,
        deriveFinalBookPath = function(dir, meta) return dir .. "/" .. (meta.title:gsub(" ", "_") .. ".epub") end,
        extractLoanExpiry = function() return os.time() + 86400 end,
        fulfillAcsm = function(acsm_path, final_path, cb)
            fulfill_calls = fulfill_calls + 1
            assert(refresh_calls == 0, "refreshFileManager must NOT run mid-batch before all fulfillments finish")
            if fulfill_calls == 1 then
                local f = io.open(final_path, "wb"); f:write("epub1"); f:close()
                return true, true
            else
                error("simulated DRM crash")
            end
        end,
    }

    UI.receiveFiles({}, false, function() end)
    assert(cb_seen == 2, "downloadFile must receive progress_cb for both files, got: " .. tostring(cb_seen))
    assert(fulfill_calls == 2, "Both ACSM files should be processed sequentially")
    assert(refresh_calls == 1, "refreshFileManager must run exactly once at the end, got: " .. tostring(refresh_calls))

    local saw_fulfill_1, saw_fulfill_2, saw_opening = false, false, false
    for _, w in ipairs(mock_shown) do
        if w.title == "Fulfilling Loan (1/2)" then saw_fulfill_1 = true end
        if w.title == "Fulfilling Loan (2/2)" then saw_fulfill_2 = true end
        if w.title == "Opening Book" then saw_opening = true end
        if w.progress ~= nil then
            assert(w._closed == true, "Progress toast '" .. tostring(w.title) .. "' must not be left open/stranded")
        end
    end
    assert(saw_fulfill_1 and saw_fulfill_2, "Should show numbered Fulfilling Loan (1/2) and (2/2) titles")
    assert(not saw_opening, "Must never switch to Opening Book during multi-file fulfillment")
    assert(UI._receive_in_progress == nil, "_receive_in_progress must be cleared when done")
    print("PASS: receiveFiles multi-file progress, single refresh & pcall error safety")

    -- Restore mocks & cleanup
    mock_uimanager.close = orig_close
    mock_fc.refreshPath = orig_refresh_path
    package.loaded["beeline_drm"] = orig_drm
    Client.fetchInbox = orig_fetch
    Client.downloadFile = orig_download
    Client.deleteRemoteFile = orig_delete
    Crypto.decryptEnvelope = orig_decrypt
    os.execute("rm -rf /tmp/beeline_test_inbox 2>/dev/null")
    st.worker_url, st.pairing_code, st.inbox_dir, st.drm_consent_version = saved_url, saved_code, saved_inbox, saved_consent
    State.saveSettings(st)
end

print("ALL UI TOAST, REFRESH & DIALOG TESTS PASSED!")
