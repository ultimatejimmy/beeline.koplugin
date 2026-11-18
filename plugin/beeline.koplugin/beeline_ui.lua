-- beeline_ui.lua — User Interface for Beeline (Libbee Storefront Card Design)
-- Follows the Libbee UI style guide: high contrast, rounded geometry, e-ink optimized.

local UIManager       = require("ui/uimanager")
local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local _, BottomContainer = pcall(require, "ui/widget/container/bottomcontainer")
local _, LeftContainer   = pcall(require, "ui/widget/container/leftcontainer")
local _, RightContainer  = pcall(require, "ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local _, OverlapGroup    = pcall(require, "ui/widget/overlapgroup")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Button          = require("ui/widget/button")
local ImageWidget     = require("ui/widget/imagewidget")
local RectSpan        = require("ui/widget/rectspan")
local InputDialog     = require("ui/widget/inputdialog")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")

local plugin_path     = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_loc, Localization = pcall(require, plugin_path .. "localization_beeline")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "localization_beeline")
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end
local State           = require(plugin_path .. "beeline_state")
local Crypto          = require(plugin_path .. "beeline_crypto")
local Client          = require(plugin_path .. "beeline_client")
local theme           = require(plugin_path .. "beeline_theme")

local M = {}
local sc = theme.sc

local function isTouchDevice()
    if Device then
        if Device.isTouchDevice then
            return Device:isTouchDevice()
        elseif Device.isTouch then
            return Device:isTouch()
        end
    end
    return false
end

local function formatBytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    local k = 1024
    local sizes = { "B", "KB", "MB", "GB" }
    local i = math.floor(math.log(bytes) / math.log(k)) + 1
    if i > #sizes then i = #sizes end
    return string.format("%.1f %s", bytes / math.pow(k, i - 1), sizes[i])
end

local function sanitizeFilename(name)
    if type(name) ~= "string" or name == "" then return "received_book.bin" end
    return name:gsub('[/\\:*?"<>|]', "_")
end

local function ensureDir(dir)
    if not dir or dir == "" then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, dir)
    end
    local quoted = "'" .. tostring(dir):gsub("'", "'\\''") .. "'"
    pcall(os.execute, "mkdir -p " .. quoted .. " 2>/dev/null")
end

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local rel_path = dir .. "assets/" .. filename
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or ""
    local paths_to_try = {
        rel_path,
        (data_dir ~= "") and (data_dir .. "/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/beeline.koplugin/assets/" .. filename) or nil,
    }
    for _, p in ipairs(paths_to_try) do
        local f = io.open(p, "rb")
        if f then
            f:close()
            _asset_path_cache[filename] = p
            return p
        end
    end
    _asset_path_cache[filename] = rel_path
    return rel_path
end

-- ---------------------------------------------------------------------------
-- Component: Button (Libbee Storefront Style)
-- ---------------------------------------------------------------------------

local function createButton(opts)
    opts = opts or {}
    local is_primary = (opts.is_primary == true) or (opts.primary == true) or (opts.background ~= nil and opts.background == Blitbuffer.COLOR_BLACK)
    local is_focused = (opts.is_focused == true)
    local border_sz = opts.bordersize or (is_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)))
    local radius = opts.radius or (theme.radius_btn or sc(4))
    local text_color = is_primary and Blitbuffer.COLOR_WHITE or (opts.text_font_color or Blitbuffer.COLOR_BLACK)

    local btn_opts = {
        text = opts.text or "",
        text_font_size = opts.text_font_size or (theme.subtext_font_size or 15),
        text_font_bold = (opts.bold ~= false),
        bordersize = border_sz,
        radius = radius,
        width = opts.width,
        height = opts.height or sc(36),
        padding = opts.padding or 0,
        padding_h = opts.padding_h,
        callback = opts.callback,
    }

    if is_primary then
        btn_opts.background = Blitbuffer.COLOR_BLACK
        btn_opts.text_font_color = Blitbuffer.COLOR_WHITE
    elseif is_focused then
        btn_opts.background = theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY
        btn_opts.text_font_color = text_color
    else
        btn_opts.background = nil
        btn_opts.text_font_color = text_color
    end

    local btn = Button:new(btn_opts)
    if is_primary then
        if btn.label_widget then
            btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end
        local orig_setText = btn.setText
        btn.setText = function(self, text, width)
            if orig_setText then
                orig_setText(self, text, width or self.width)
            else
                self.text = text
            end
            if self.label_widget then
                self.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            end
        end
    end
    if opts.icon_file and btn.label_container then
        local icon_sz = opts.icon_size or sc(18)
        local icon_w = ImageWidget:new{
            file = opts.icon_file,
            width = icon_sz,
            height = icon_sz,
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local group = HorizontalGroup:new{
            align = "center",
            icon_w,
            HorizontalSpan:new{ width = sc(6) },
            btn.label_widget,
        }
        btn.label_container[1] = group
    end

    if btn.frame then
        btn.frame.color = Blitbuffer.COLOR_BLACK
        btn.frame.bordersize = border_sz
    end
    return btn
end

-- ---------------------------------------------------------------------------
-- Component: Beeline Toast Notification (Libbee Storefront Style)
-- ---------------------------------------------------------------------------

local _active_toast = nil

local BeelineToastWidget = InputContainer:extend{
    title = nil,
    text = "",
    icon_name = "bee",
    timeout = 3,
    dismissable = true,
    progress = nil,
}

function BeelineToastWidget:_buildCard()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_toast_w = math.min(sw - sc(32), sc(460))
    local has_progress = (self.progress ~= nil)
    local card_w = has_progress and max_toast_w or nil
    local text_w = max_toast_w - sc(72)

    local icon_file = getAssetPath("bee.png")
    if self.icon_name == "download" then
        icon_file = getAssetPath("download.svg")
    elseif self.icon_name == "check" then
        icon_file = getAssetPath("check.svg")
    elseif self.icon_name == "info" then
        icon_file = getAssetPath("info.svg")
    elseif self.icon_name == "x" or self.icon_name == "error" then
        icon_file = getAssetPath("x.svg")
    elseif self.icon_file then
        icon_file = self.icon_file
    end

    local icon = ImageWidget:new{
        file = icon_file,
        width = sc(24),
        height = sc(24),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local text_items = {}
    if self.title and self.title ~= "" then
        if has_progress then
            local pct = math.floor(math.max(0, math.min(1, self.progress)) * 100 + 0.5)
            local pct_str = string.format("%d%%", pct)
            local pct_widget = TextWidget:new{
                text = pct_str,
                face = Font:getFace("cfont", theme.face_label_size or 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local pct_w = (pct_widget.getSize and pct_widget:getSize().w) or sc(44)
            local title_widget = TextWidget:new{
                text = self.title,
                face = Font:getFace("cfont", theme.face_label_size or 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = math.max(sc(60), text_w - pct_w - sc(8)),
            }
            local title_w = (title_widget.getSize and title_widget:getSize().w) or sc(120)
            local gap_w = math.max(sc(8), text_w - title_w - pct_w)
            table.insert(text_items, HorizontalGroup:new{
                align = "center",
                title_widget,
                HorizontalSpan:new{ width = gap_w },
                pct_widget,
            })
        else
            table.insert(text_items, TextWidget:new{
                text = self.title,
                face = Font:getFace("cfont", theme.face_label_size or 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            })
        end
        table.insert(text_items, VerticalSpan:new{ width = sc(3) })
    end

    table.insert(text_items, TextBoxWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", (self.title and self.title ~= "") and ((theme.face_label_size or 16) - 2) or (theme.face_label_size or 16)),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = text_w,
        alignment = "left",
    })

    local row = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = sc(12) },
        VerticalGroup:new{
            align = "left",
            unpack(text_items)
        },
    }

    local card_body = row
    if has_progress then
        local clamped = math.max(0, math.min(1, self.progress))
        local bar_outer_w = max_toast_w - sc(36)
        local bar_inner_w = math.max(sc(40), bar_outer_w - sc(2))
        local bar_h = sc(10)
        local fill_w = math.floor(bar_inner_w * clamped + 0.5)
        local rem_w = bar_inner_w - fill_w

        local bar_segments = {}
        if fill_w > 0 then
            table.insert(bar_segments, LineWidget:new{
                dimen = Geom:new{ w = fill_w, h = bar_h },
                background = Blitbuffer.COLOR_BLACK,
            })
        end
        if rem_w > 0 then
            table.insert(bar_segments, LineWidget:new{
                dimen = Geom:new{ w = rem_w, h = bar_h },
                background = Blitbuffer.COLOR_WHITE,
            })
        end

        local bar_frame = FrameContainer:new{
            padding = 0,
            bordersize = sc(1),
            radius = sc(4),
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            HorizontalGroup:new(bar_segments),
        }

        card_body = VerticalGroup:new{
            align = "left",
            row,
            VerticalSpan:new{ width = sc(10) },
            bar_frame,
        }
    end

    local card = FrameContainer:new{
        padding = has_progress and sc(12) or sc(10),
        padding_left = sc(16),
        padding_right = sc(18),
        radius = theme.radius_toast or sc(8),
        bordersize = theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = card_w,
        card_body,
    }

    local toast_h = card:getSize().h
    local toast_y = math.max(0, math.floor((sh - toast_h) / 2))

    return VerticalGroup:new{
        align = "center",
        RectSpan:new{ width = sw, height = toast_y },
        card,
    }
end

function BeelineToastWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    if self.progress ~= nil then
        self.progress = math.max(0, math.min(1, tonumber(self.progress) or 0))
        self._last_rendered_pct = math.floor(self.progress * 100 + 0.5)
    end

    -- Full-screen container with centered alignment guarantees horizontal & vertical centering across all screen sizes
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = self:_buildCard()

    if self.dismissable ~= false then
        if Device and Device.hasKeys and Device:hasKeys() then
            self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
        end
        if Device and Device.isTouchDevice and Device:isTouchDevice() then
            self.ges_events = {
                TapDismiss = {
                    GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } }
                },
            }
        end
    end

    if self.timeout and self.timeout > 0 then
        self._timer = UIManager:scheduleIn(self.timeout, function()
            self:close()
        end)
    end
end

function BeelineToastWidget:updateProgress(fraction, text, title)
    if self._closed then return end
    local clamped = math.max(0, math.min(1, tonumber(fraction) or 0))
    local pct = math.floor(clamped * 100 + 0.5)
    local text_changed = (text ~= nil and text ~= self.text)
    local title_changed = (title ~= nil and title ~= self.title)

    if not text_changed and not title_changed and self._last_rendered_pct ~= nil then
        local delta = math.abs(pct - self._last_rendered_pct)
        if delta < 12 and pct < 100 and pct > 0 then
            self.progress = clamped
            return
        end
    end

    self.progress = clamped
    self._last_rendered_pct = pct
    if text ~= nil then self.text = text end
    if title ~= nil then self.title = title end

    self[1] = self:_buildCard()
    if UIManager then
        if UIManager.setDirty then
            UIManager:setDirty(self, "ui")
        end
        if UIManager.forceRePaint then
            pcall(function() UIManager:forceRePaint() end)
        end
    end
end

function BeelineToastWidget:onTapDismiss()
    if self.dismissable ~= false then
        self:close()
        return true
    end
end

function BeelineToastWidget:onAnyKeyPressed()
    if self.dismissable ~= false then
        self:close()
        return true
    end
end

function BeelineToastWidget:onTap()
    return self:onTapDismiss()
end

function BeelineToastWidget:close()
    if self._closed then return end
    self._closed = true
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    if _active_toast == self then
        _active_toast = nil
    end
    UIManager:close(self, "ui")
end

local function _dismissActiveToast()
    if _active_toast then
        local t = _active_toast
        _active_toast = nil
        t:close()
    end
end

function M.showToast(msg, timeout, icon_name, title)
    _dismissActiveToast()
    local toast = BeelineToastWidget:new{
        title = title,
        text = msg,
        icon_name = icon_name or "bee",
        timeout = timeout or 3,
    }
    _active_toast = toast
    UIManager:show(toast, "ui")
    return toast
end

function M.showProgressToast(title, text, icon_name, initial_progress)
    _dismissActiveToast()
    local toast = BeelineToastWidget:new{
        title = title,
        text = text or "",
        icon_name = icon_name or "download",
        timeout = 0,
        dismissable = false,
        progress = initial_progress or 0,
    }
    _active_toast = toast
    UIManager:show(toast, "ui")
    if UIManager and UIManager.forceRePaint then
        pcall(function() UIManager:forceRePaint() end)
    end
    return toast
end

-- ---------------------------------------------------------------------------
-- Component: Card Dialog (Libbee Clean Modal Dialog)
-- ---------------------------------------------------------------------------

function M.showCardDialog(opts)
    _dismissActiveToast()
    opts = opts or {}
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local card_padding = sc(14)
    local card_border = theme.border_window or sc(2)
    local dialog_w = opts.width or math.min(sw - sc(20), sc(480))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local overlay
    local function closeDialog(callback)
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if callback then callback() end
    end

    local buttons = opts.buttons or { { text = "OK", is_primary = true } }
    local focused_button_idx = 1
    for i, b in ipairs(buttons) do
        if b.is_primary then
            focused_button_idx = i
            break
        end
    end

    local buildCardWidget = function()
        local content_items = {}

        if opts.title and opts.title ~= "" then
            local title_label = TextWidget:new{
                text = opts.title,
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local close_icon = ImageWidget:new{
                file = getAssetPath("x.svg"),
                width = sc(18),
                height = sc(18),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }
            local close_frame = FrameContainer:new{
                padding = sc(4),
                padding_h = sc(6),
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                close_icon,
            }
            local close_header_btn = InputContainer:new{ close_frame }
            local close_btn_dim = Geom:new{ w = sc(30), h = sc(30) }
            close_header_btn.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = close_header_btn.dimen or close_btn_dim
                            return Geom:new{ x = dim.x or 0, y = dim.y or 0, w = dim.w or sc(30), h = dim.h or sc(30) }
                        end
                    }
                }
            }
            close_header_btn.onTap = function()
                closeDialog(opts.on_close or opts.cancel_callback)
                return true
            end

            local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(160)
            local close_btn_w = sc(30)
            local title_row = HorizontalGroup:new{
                title_label,
                HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_left_w - close_btn_w) },
                close_header_btn,
            }

            table.insert(content_items, title_row)
            table.insert(content_items, VerticalSpan:new{ width = sc(6) })
            table.insert(content_items, LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            })
            table.insert(content_items, VerticalSpan:new{ width = sc(10) })
        end

        if opts.body_widget then
            table.insert(content_items, opts.body_widget)
            table.insert(content_items, VerticalSpan:new{ width = sc(10) })
        elseif opts.body_text and opts.body_text ~= "" then
            local body_box = TextBoxWidget:new{
                text = opts.body_text,
                face = Font:getFace("cfont", theme.face_label_size or 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = opts.body_align or "left",
            }
            table.insert(content_items, body_box)
            table.insert(content_items, VerticalSpan:new{ width = sc(14) })
        end

        local btn_widgets = {}
        local num_btns = #buttons
        local btn_gap = sc(8)
        local btn_w = math.floor((inner_w - (btn_gap * (num_btns - 1))) / num_btns)
        local btn_h = sc(36)

        for i, b in ipairs(buttons) do
            if i > 1 then
                table.insert(btn_widgets, HorizontalSpan:new{ width = btn_gap })
            end

            local is_pri = (b.is_primary == true)
            local is_focused = (i == focused_button_idx)
            local btn = createButton{
                text = b.text,
                text_font_size = theme.subtext_font_size or 15,
                bold = is_pri or b.bold or is_focused,
                is_primary = is_pri,
                is_focused = is_focused,
                bordersize = is_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
                radius = theme.radius_btn or sc(4),
                width = btn_w,
                height = btn_h,
                callback = function()
                    closeDialog(b.callback)
                end,
            }
            table.insert(btn_widgets, btn)
        end

        table.insert(content_items, HorizontalGroup:new(btn_widgets))

        return FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                unpack(content_items)
            }
        }
    end

    local key_events = {
        Close = { { "Back" }, { "Escape" } },
        PrevBtn = { { "Left" }, { "Up" } },
        NextBtn = { { "Right" }, { "Down" } },
        Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
    }
    if Device and Device.input and Device.input.group then
        if Device.input.group.Back then table.insert(key_events.Close, { Device.input.group.Back }) end
        if Device.input.group.Left then table.insert(key_events.PrevBtn, { Device.input.group.Left }) end
        if Device.input.group.Up then table.insert(key_events.PrevBtn, { Device.input.group.Up }) end
        if Device.input.group.Right then table.insert(key_events.NextBtn, { Device.input.group.Right }) end
        if Device.input.group.Down then table.insert(key_events.NextBtn, { Device.input.group.Down }) end
        if Device.input.group.Press then table.insert(key_events.Press, { Device.input.group.Press }) end
        if Device.input.group.Enter then table.insert(key_events.Press, { Device.input.group.Enter }) end
    end

    overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        key_events = key_events,
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            buildCardWidget(),
        }
    }

    local function refreshCard()
        if overlay and overlay[1] then
            overlay[1][1] = buildCardWidget()
            UIManager:setDirty(overlay, "ui")
        end
    end

    overlay.onPrevBtn = function()
        if #buttons > 1 then
            focused_button_idx = (focused_button_idx > 1) and (focused_button_idx - 1) or #buttons
            refreshCard()
            return true
        end
    end

    overlay.onNextBtn = function()
        if #buttons > 1 then
            focused_button_idx = (focused_button_idx < #buttons) and (focused_button_idx + 1) or 1
            refreshCard()
            return true
        end
    end

    overlay.onPress = function()
        if buttons[focused_button_idx] then
            closeDialog(buttons[focused_button_idx].callback)
            return true
        end
    end

    overlay.onClose = function()
        closeDialog(opts.on_close or opts.cancel_callback)
        return true
    end

    UIManager:show(overlay, "ui")
    return overlay
end

-- ---------------------------------------------------------------------------
-- Component: Pairing QR Code Dialog (Libbee Clean Modal)
-- ---------------------------------------------------------------------------

local function registerCodeOnWorker(worker_url, code, device_id)
    if not code or code == "" or not worker_url or worker_url == "" or not device_id or device_id == "" then
        return false, false
    end
    local code_hash = Crypto.getCodeHash(code)
    local registered_ok = false
    local was_claimed = false
    if code_hash then
        local ok, success, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
        if ok and success and type(parsed) == "table" then
            registered_ok = true
            was_claimed = (parsed.claimed == true)
        end
    end
    pcall(Client.registerPairing, worker_url, device_id)
    return registered_ok, was_claimed
end

function M.showQRCodeDialog(pairing_code, worker_url, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    pairing_code = pairing_code or State.getPairingCode() or ""
    worker_url = worker_url or s.worker_url or State.DEFAULT_WORKER_URL

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(14)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    local qr_size = sc(170)

    local overlay
    local refresh_qr
    local qr_poll_timer = nil
    local last_registered_code = nil

    local function cancelQrPoll()
        if qr_poll_timer then
            UIManager:unschedule(qr_poll_timer)
            qr_poll_timer = nil
        end
    end

    local function getPairUrl(code)
        local base = (worker_url or ""):gsub("/+$", "")
        return base .. "/?code=" .. (code or "")
    end

    local function closeDialog()
        cancelQrPoll()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_close_cb then on_close_cb() end
    end

    refresh_qr = function(current_code)
        cancelQrPoll()
        current_code = current_code or pairing_code
        local pair_url = getPairUrl(current_code)
        local device_id = State.getDeviceId()

        if current_code ~= "" and worker_url ~= "" and device_id ~= "" then
            local reg_ok, was_claimed = registerCodeOnWorker(worker_url, current_code, device_id)
            if was_claimed then
                -- Already claimed! Persist pairing and rotate right now
                if State.markPairingClaimed then
                    State.markPairingClaimed(current_code)
                else
                    State.addPairedBrowser(current_code)
                end
                local fresh = State.regeneratePairingCode()
                refresh_qr(fresh)
                return
            end
            if reg_ok then
                last_registered_code = current_code
            elseif last_registered_code ~= current_code then
                last_registered_code = nil
            end
        end

        local content_items = {}

        -- Title
        local title_label = TextWidget:new{
            text = _("Scan to Pair"),
            face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local close_icon = ImageWidget:new{
            file = getAssetPath("x.svg"),
            width = sc(18),
            height = sc(18),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local close_frame = FrameContainer:new{
            padding = sc(4),
            padding_h = sc(6),
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            close_icon,
        }
        local close_header_btn = InputContainer:new{ close_frame }
        local close_btn_dim = Geom:new{ w = sc(30), h = sc(30) }
        close_header_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = close_header_btn.dimen or close_btn_dim
                        return Geom:new{ x = dim.x or 0, y = dim.y or 0, w = dim.w or sc(30), h = dim.h or sc(30) }
                    end
                }
            }
        }
        close_header_btn.onTap = function()
            closeDialog()
            return true
        end

        local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(140)
        local close_btn_w = sc(30)
        local title_row = HorizontalGroup:new{
            title_label,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_left_w - close_btn_w) },
            close_header_btn,
        }

        table.insert(content_items, title_row)
        table.insert(content_items, VerticalSpan:new{ width = sc(4) })
        table.insert(content_items, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(content_items, VerticalSpan:new{ width = sc(10) })

        -- QR Code Widget
        local qr_widget = nil
        if ok_qr and QRWidget then
            pcall(function()
                qr_widget = QRWidget:new{
                    text = pair_url,
                    width = qr_size,
                    height = qr_size,
                }
            end)
        end

        if qr_widget then
            local qr_frame = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                padding = sc(8),
                bordersize = sc(1),
                color = Blitbuffer.COLOR_BLACK,
                radius = theme.radius_btn or sc(4),
                qr_widget,
            }
            table.insert(content_items, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = qr_size + sc(18) },
                qr_frame,
            })
            table.insert(content_items, VerticalSpan:new{ width = sc(6) })
        else
            table.insert(content_items, TextBoxWidget:new{
                text = _("QR code unavailable.\nPlease open in browser:\n") .. pair_url,
                face = Font:getFace("cfont", 14),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = "center",
            })
            table.insert(content_items, VerticalSpan:new{ width = sc(8) })
        end

        -- Pairing Code Label
        table.insert(content_items, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = sc(26) },
            TextWidget:new{
                text = _("Code: %s", current_code),
                face = Font:getFace("cfont", 18),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        })
        table.insert(content_items, VerticalSpan:new{ width = sc(2) })

        local sec_left = State.getCodeSecondsRemaining()
        local min_left = math.ceil(sec_left / 60)
        local time_str = (sec_left > 0) and _("Code valid for %d min • Once paired, stays connected", min_left) or _("Code expired — tap New Code")

        -- Instruction text
        table.insert(content_items, TextBoxWidget:new{
            text = _("Scan with your phone camera to pair instantly.\n%s", time_str),
            face = Font:getFace("cfont", theme.subtext_font_size or 13),
            fgcolor = theme.color_label_dim,
            width = inner_w,
            alignment = "center",
        })
        table.insert(content_items, VerticalSpan:new{ width = sc(10) })

        -- Buttons
        local btn_gap = sc(8)
        local btn_w = math.floor((inner_w - btn_gap) / 2)
        local btn_h = sc(36)

        local gen_new_btn = createButton{
            text = _("↻  New Code"),
            text_font_size = theme.subtext_font_size or 14,
            bold = false,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            width = btn_w,
            height = btn_h,
            callback = function()
                local new_code = State.regeneratePairingCode()
                local device_id = State.getDeviceId()
                if worker_url ~= "" and device_id ~= "" then
                    local code_hash = Crypto.getCodeHash(new_code)
                    if code_hash then
                        pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
                    end
                    pcall(Client.registerPairing, worker_url, device_id)
                end
                M.showToast(_("New pairing code: %s", new_code), 2)
                refresh_qr(new_code)
            end,
        }

        local close_btn = createButton{
            text = _("Close"),
            text_font_size = theme.subtext_font_size or 14,
            bold = true,
            is_primary = true,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            width = btn_w,
            height = btn_h,
            callback = closeDialog,
        }

        table.insert(content_items, HorizontalGroup:new{
            align = "center",
            gen_new_btn,
            HorizontalSpan:new{ width = btn_gap },
            close_btn,
        })

        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "center",
                unpack(content_items),
            }
        }

        if overlay and overlay[1] then
            overlay[1][1] = card
            UIManager:setDirty(overlay, "ui")
        else
            local key_events = {
                Close = { { "Back" }, { "Escape" } },
                Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
            }
            if Device and Device.input and Device.input.group then
                if Device.input.group.Back then table.insert(key_events.Close, { Device.input.group.Back }) end
                if Device.input.group.Press then table.insert(key_events.Press, { Device.input.group.Press }) end
                if Device.input.group.Enter then table.insert(key_events.Press, { Device.input.group.Enter }) end
            end

            overlay = InputContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                key_events = key_events,
                CenterContainer:new{
                    dimen = Geom:new{ w = sw, h = sh },
                    card,
                }
            }
            overlay.onClose = function()
                closeDialog()
                return true
            end
            overlay.onPress = function()
                closeDialog()
                return true
            end
            UIManager:show(overlay, "ui")
        end

        -- Live poll while QR dialog is open to detect when claimed or expired
        local checkClaimed
        checkClaimed = function()
            if not overlay then return end
            if M._receive_in_progress then
                qr_poll_timer = UIManager:scheduleIn(2.5, checkClaimed)
                return
            end
            if State.isCodeExpired() then
                local fresh = State.regeneratePairingCode()
                refresh_qr(fresh)
                return
            end
            local device_id = State.getDeviceId()
            if current_code ~= "" and worker_url ~= "" and device_id ~= "" and last_registered_code ~= current_code then
                local reg_ok, was_claimed = registerCodeOnWorker(worker_url, current_code, device_id)
                if was_claimed then
                    State.addPairedBrowser(current_code)
                    M.showToast(_("✓ Browser paired! Code used."), 3)
                    local fresh = State.regeneratePairingCode()
                    refresh_qr(fresh)
                    return
                end
                if reg_ok then
                    last_registered_code = current_code
                end
            end
            if current_code ~= "" and worker_url ~= "" then
                local c_hash = Crypto.getCodeHash(current_code)
                if c_hash then
                    local ok, success, parsed = pcall(Client.checkPairingCode, worker_url, c_hash)
                    if ok and success and type(parsed) == "table" then
                        if parsed.claimed then
                            State.addPairedBrowser(current_code)
                            M.showToast(_("✓ Browser paired! Code used."), 3)
                            local fresh = State.regeneratePairingCode()
                            refresh_qr(fresh)
                            return
                        elseif parsed.expired then
                            local fresh = State.regeneratePairingCode()
                            refresh_qr(fresh)
                            return
                        end
                    elseif ok and not success and type(parsed) == "table" and parsed.found == false then
                        last_registered_code = nil
                        if device_id ~= "" then
                            local reg_ok = registerCodeOnWorker(worker_url, current_code, device_id)
                            if reg_ok then last_registered_code = current_code end
                        end
                    end
                end
            end
            if overlay then
                qr_poll_timer = UIManager:scheduleIn(2.5, checkClaimed)
            end
        end
        qr_poll_timer = UIManager:scheduleIn(2.5, checkClaimed)
    end

    refresh_qr(pairing_code)
end

-- ---------------------------------------------------------------------------
-- Component: Icon Button (Feather Icon Button with e-ink focus support)
-- ---------------------------------------------------------------------------

local function createIconButton(opts)
    opts = opts or {}
    local icon_file = opts.icon_file
    local is_focused = (opts.is_focused == true)
    local w = opts.width or sc(32)
    local h = opts.height or sc(32)
    local icon_size = opts.icon_size or sc(18)

    local img = ImageWidget:new{
        file = icon_file,
        width = icon_size,
        height = icon_size,
        is_icon = true,
        alpha = true,
    }

    local frame = FrameContainer:new{
        padding = opts.padding or sc(4),
        padding_h = opts.padding_h or sc(4),
        bordersize = is_focused and (theme.border_focus or sc(2)) or (opts.bordersize or 0),
        color = Blitbuffer.COLOR_BLACK,
        background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or (opts.background or Blitbuffer.COLOR_WHITE),
        radius = opts.radius or (theme.radius_btn or sc(4)),
        img,
    }

    local container = InputContainer:new{ frame }
    local btn_dim = Geom:new{ w = w, h = h }
    container.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local dim = container.dimen or btn_dim
                    return Geom:new{ x = dim.x or 0, y = dim.y or 0, w = dim.w or w, h = dim.h or h }
                end,
            }
        }
    }
    container.onTap = function()
        if opts.callback then opts.callback() end
        return true
    end
    return container
end

-- ---------------------------------------------------------------------------
-- Main Pairing & Connection Screen (Libbee Clean Dialog with Embedded QR)
-- ---------------------------------------------------------------------------

local _getActiveLoans

function M.showMainDialog(plugin_instance, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    local pairing_code = State.getPairingCode()
    local worker_url = s.worker_url or State.DEFAULT_WORKER_URL
    local device_id = State.getDeviceId()
    local last_registered_code = nil

    -- Register pairing code and device in background
    if pairing_code ~= "" and worker_url ~= "" and device_id ~= "" then
        local reg_ok, was_claimed = registerCodeOnWorker(worker_url, pairing_code, device_id)
        if was_claimed then
            if State.markPairingClaimed then
                State.markPairingClaimed(pairing_code)
            else
                State.addPairedBrowser(pairing_code)
            end
            pairing_code = State.regeneratePairingCode()
            local new_reg_ok = registerCodeOnWorker(worker_url, pairing_code, device_id)
            if new_reg_ok then last_registered_code = pairing_code end
        elseif reg_ok then
            last_registered_code = pairing_code
        end
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(420))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = theme.face_label_size or 16
    local is_touch = isTouchDevice()
    local focus_visible = not is_touch

    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}
    local poll_timer = nil

    local function cancelPoll()
        if poll_timer then
            UIManager:unschedule(poll_timer)
            poll_timer = nil
        end
    end

    local function close_cb()
        cancelPoll()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        if on_close_cb then on_close_cb() end
    end

    refresh = function()
        cancelPoll()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}
        s = State.loadSettings()
        local current_code = State.getPairingCode()
        worker_url = s.worker_url or State.DEFAULT_WORKER_URL
        device_id = State.getDeviceId()

        -- Ensure any rotated or previously unregistered code is registered with the worker
        if current_code ~= "" and worker_url ~= "" and device_id ~= "" and last_registered_code ~= current_code then
            local reg_ok, was_claimed = registerCodeOnWorker(worker_url, current_code, device_id)
            if was_claimed then
                if State.markPairingClaimed then
                    State.markPairingClaimed(current_code)
                else
                    State.addPairedBrowser(current_code)
                end
                current_code = State.regeneratePairingCode()
                local new_reg_ok = registerCodeOnWorker(worker_url, current_code, device_id)
                if new_reg_ok then last_registered_code = current_code end
            elseif reg_ok then
                last_registered_code = current_code
            end
        end

        -- Title Header with Bee Icon, Settings and Close Feather Icons
        local bee_icon = ImageWidget:new{
            file = getAssetPath("bee.png"),
            width = sc(28),
            height = sc(28),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local title_label = TextWidget:new{
            text = _("Beeline"),
            face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local header_title = HorizontalGroup:new{
            align = "center",
            bee_icon,
            HorizontalSpan:new{ width = sc(8) },
            title_label,
        }

        local settings_header_btn = createIconButton{
            icon_file = getAssetPath("settings.svg"),
            width = sc(32),
            height = sc(32),
            icon_size = sc(20),
            callback = function()
                close_cb()
                M.showSettingsDialog(plugin_instance, function()
                    M.showMainDialog(plugin_instance, on_close_cb)
                end)
            end,
        }

        local close_header_btn = createIconButton{
            icon_file = getAssetPath("x.svg"),
            width = sc(32),
            height = sc(32),
            icon_size = sc(20),
            callback = close_cb,
        }

        local title_left_w = (header_title.getSize and header_title:getSize().w) or sc(136)
        local icons_w = sc(74)
        local title_row = HorizontalGroup:new{
            align = "center",
            header_title,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_left_w - icons_w) },
            settings_header_btn,
            HorizontalSpan:new{ width = sc(6) },
            close_header_btn,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_row,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(6) },
        }

        -- Action Button: Check for Files (Solid black button, centered primary CTA)
        local check_btn_idx = #interactive_items + 1
        local is_check_focused = (focus_visible and focused_row_idx == check_btn_idx)
        local check_btn_w = math.min(inner_w - sc(48), sc(270))
        local check_btn = createButton{
            text = _("Check for Incoming Files"),
            text_font_size = ui_font_size,
            bold = true,
            is_primary = true,
            is_focused = is_check_focused,
            bordersize = is_check_focused and (theme.border_focus or sc(3)) or 0,
            radius = theme.radius_btn or sc(4),
            width = check_btn_w,
            height = sc(36),
            callback = function()
                M.receiveFiles(plugin_instance, false, function(opened_reader)
                    if opened_reader and overlay then
                        cancelPoll()
                        UIManager:close(overlay, "ui")
                        overlay = nil
                    end
                end)
            end,
        }
        table.insert(interactive_items, { callback = check_btn.callback })
        table.insert(content_vg, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = sc(38) },
            check_btn,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        -- Action Button: Active Loans
        local active_loans = _getActiveLoans()
        local loans_btn_text = (#active_loans > 0) and _("Active Loans (%d)", #active_loans) or _("Active Loans")
        local loans_btn_idx = #interactive_items + 1
        local is_loans_focused = (focus_visible and focused_row_idx == loans_btn_idx)
        local loans_btn = createButton{
            text = loans_btn_text,
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_loans_focused,
            bordersize = is_loans_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = check_btn_w,
            height = sc(34),
            callback = function()
                cancelPoll()
                if overlay then
                    local ov = overlay
                    overlay = nil
                    ov.onClose = nil
                    UIManager:close(ov, "ui")
                end
                M.showActiveLoansDialog(plugin_instance, function()
                    M.showMainDialog(plugin_instance, on_close_cb)
                end)
            end,
        }
        table.insert(interactive_items, { callback = loans_btn.callback })
        table.insert(content_vg, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = sc(36) },
            loans_btn,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Section Header Builder
        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(3),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        table.insert(content_vg, create_section_header(_("Device Pairing")))
        table.insert(content_vg, VerticalSpan:new{ width = sc(4) })

        -- Step 1 & 2 Instructions
        local display_url = worker_url:gsub("^https?://", ""):gsub("/+$", "")
        local step1_box = VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = _("1. On phone/PC browser open:"),
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                fgcolor = theme.color_label_dim,
                width = inner_w,
            },
            VerticalSpan:new{ width = sc(2) },
            TextWidget:new{
                text = display_url,
                face = Font:getFace("cfont", 15),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = sc(4) },
            TextBoxWidget:new{
                text = _("2. Scan QR code or enter code:"),
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                fgcolor = theme.color_label_dim,
                width = inner_w,
            },
        }
        table.insert(content_vg, step1_box)
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        -- Embedded QR Code
        local pair_url = worker_url .. "/?code=" .. current_code
        local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
        local qr_size = sc(130)
        local qr_widget = nil
        if ok_qr and QRWidget then
            pcall(function()
                qr_widget = QRWidget:new{
                    text = pair_url,
                    width = qr_size,
                    height = qr_size,
                }
            end)
        end

        if qr_widget then
            local qr_frame = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_LIGHT_GRAY,
                bordersize = sc(1),
                padding = sc(4),
                radius = theme.radius_btn or sc(4),
                qr_widget,
            }
            table.insert(content_vg, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = qr_size + sc(10) },
                qr_frame,
            })
            table.insert(content_vg, VerticalSpan:new{ width = sc(6) })
        end

        -- Pairing Code Pill Box
        local sec_left = State.getCodeSecondsRemaining()
        local min_left = math.ceil(sec_left / 60)
        local time_str = (sec_left > 0) and _("Valid for %d min • Browsers stay paired permanently", min_left) or _("Code expired — tap below to regenerate")

        local code_box_frame = FrameContainer:new{
            padding = sc(6),
            bordersize = sc(1),
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w - sc(16), h = sc(32) },
                TextWidget:new{
                    text = current_code,
                    face = Font:getFace("cfont", 22),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            }
        }
        table.insert(content_vg, code_box_frame)
        table.insert(content_vg, VerticalSpan:new{ width = sc(3) })

        local validity_label = TextBoxWidget:new{
            text = time_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 13),
            fgcolor = theme.color_label_dim,
            width = inner_w,
            alignment = "center",
        }
        table.insert(content_vg, validity_label)
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        -- Action Row: Generate New Code & Browser Count
        local paired_count = State.getPairedBrowserCount()
        local browser_str = (paired_count > 0) and _("%d browser(s) paired", paired_count) or _("No browsers paired")

        local gen_btn_idx = #interactive_items + 1
        local is_gen_focused = (focus_visible and focused_row_idx == gen_btn_idx)
        local gen_btn = createButton{
            text = _("Generate New Code"),
            icon_file = getAssetPath("refresh-cw.svg"),
            icon_size = sc(16),
            text_font_size = theme.subtext_font_size or 14,
            bold = true,
            is_focused = is_gen_focused,
            bordersize = is_gen_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = math.floor((inner_w - sc(8)) / 2) + sc(14),
            height = sc(32),
            callback = function()
                local new_code = State.regeneratePairingCode()
                local dev_id = State.getDeviceId()
                if s.worker_url ~= "" and dev_id ~= "" then
                    local code_hash = Crypto.getCodeHash(new_code)
                    if code_hash then
                        pcall(Client.registerPairingCode, s.worker_url, code_hash, dev_id)
                    end
                    pcall(Client.registerPairing, s.worker_url, dev_id)
                end
                M.showToast(_("New pairing code: %s", new_code), 2)
                refresh()
            end,
        }
        table.insert(interactive_items, { callback = gen_btn.callback })

        local count_label = TextWidget:new{
            text = browser_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        table.insert(content_vg, HorizontalGroup:new{
            align = "center",
            gen_btn,
            HorizontalSpan:new{ width = sc(8) },
            CenterContainer:new{
                dimen = Geom:new{ w = math.floor((inner_w - sc(8)) / 2) - sc(14), h = sc(32) },
                count_label,
            }
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Footer: Settings and Close
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        local half_btn_w = math.floor((inner_w - sc(8)) / 2)

        local settings_btn_idx = #interactive_items + 1
        local is_settings_focused = (focus_visible and focused_row_idx == settings_btn_idx)
        local settings_btn = createButton{
            text = _("Settings"),
            icon_file = getAssetPath("settings.svg"),
            icon_size = sc(16),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_settings_focused,
            bordersize = is_settings_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(34),
            callback = function()
                close_cb()
                M.showSettingsDialog(plugin_instance, function()
                    M.showMainDialog(plugin_instance, on_close_cb)
                end)
            end,
        }
        table.insert(interactive_items, { callback = settings_btn.callback })

        local close_btn_idx = #interactive_items + 1
        local is_close_focused = (focus_visible and focused_row_idx == close_btn_idx)
        local close_btn = createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_close_focused,
            bordersize = is_close_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(34),
            callback = close_cb,
        }
        table.insert(interactive_items, { callback = close_btn.callback })

        table.insert(content_vg, HorizontalGroup:new{
            align = "center",
            settings_btn,
            HorizontalSpan:new{ width = sc(8) },
            close_btn,
        })

        -- Modal Container Card
        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card,
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if focused_row_idx and interactive_items[focused_row_idx] then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            close_cb()
            return true
        end

        -- Live background polling for claim, retry registration, or auto-rotate on expiry
        local checkClaimed
        checkClaimed = function()
            if not overlay then return end
            if M._receive_in_progress then
                poll_timer = UIManager:scheduleIn(3, checkClaimed)
                return
            end
            if State.isCodeExpired() then
                local fresh = State.regeneratePairingCode()
                local new_reg_ok = registerCodeOnWorker(worker_url, fresh, device_id)
                if new_reg_ok then last_registered_code = fresh end
                refresh()
                return
            end
            if current_code ~= "" and worker_url ~= "" and device_id ~= "" and last_registered_code ~= current_code then
                local reg_ok, was_claimed = registerCodeOnWorker(worker_url, current_code, device_id)
                if was_claimed then
                    if State.markPairingClaimed then
                        State.markPairingClaimed(current_code)
                    else
                        State.addPairedBrowser(current_code)
                    end
                    M.showToast(_("✓ Browser paired! Code used."), 3)
                    local fresh = State.regeneratePairingCode()
                    local new_reg_ok = registerCodeOnWorker(worker_url, fresh, device_id)
                    if new_reg_ok then last_registered_code = fresh end
                    refresh()
                    return
                elseif reg_ok then
                    last_registered_code = current_code
                end
            end
            if current_code ~= "" and worker_url ~= "" then
                local c_hash = Crypto.getCodeHash(current_code)
                if c_hash then
                    local ok, success, parsed = pcall(Client.checkPairingCode, worker_url, c_hash)
                    if ok and success and type(parsed) == "table" then
                        if parsed.claimed then
                            if State.markPairingClaimed then
                                State.markPairingClaimed(current_code)
                            else
                                State.addPairedBrowser(current_code)
                            end
                            M.showToast(_("✓ Browser paired! Code used."), 3)
                            local fresh = State.regeneratePairingCode()
                            local new_reg_ok = registerCodeOnWorker(worker_url, fresh, device_id)
                            if new_reg_ok then last_registered_code = fresh end
                            refresh()
                            return
                        elseif parsed.expired then
                            local fresh = State.regeneratePairingCode()
                            local new_reg_ok = registerCodeOnWorker(worker_url, fresh, device_id)
                            if new_reg_ok then last_registered_code = fresh end
                            refresh()
                            return
                        end
                    elseif ok and not success and type(parsed) == "table" and parsed.found == false then
                        last_registered_code = nil
                        if device_id ~= "" then
                            local reg_ok = registerCodeOnWorker(worker_url, current_code, device_id)
                            if reg_ok then last_registered_code = current_code end
                        end
                    end
                end
            end
            if overlay then
                poll_timer = UIManager:scheduleIn(3, checkClaimed)
            end
        end
        poll_timer = UIManager:scheduleIn(3, checkClaimed)

        UIManager:show(overlay, "ui")
    end

    refresh()
end

-- ---------------------------------------------------------------------------
-- Active Loans Shelf Browser (Libbee Cover & List Views)
-- ---------------------------------------------------------------------------

local active_loans_overlay = nil

local function _parseExpiryTimestamp(expires)
    if type(expires) == "number" then
        return expires
    end
    if type(expires) == "string" then
        local y, m, d, h, min, sec = expires:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
        if y then
            return os.time({
                year = tonumber(y),
                month = tonumber(m),
                day = tonumber(d),
                hour = tonumber(h),
                min = tonumber(min),
                sec = tonumber(sec),
            })
        end
        local dy, dm, dd = expires:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if dy then
            return os.time({
                year = tonumber(dy),
                month = tonumber(dm),
                day = tonumber(dd),
                hour = 23,
                min = 59,
                sec = 59,
            })
        end
    end
    return nil
end

_getActiveLoans = function()
    local tracked = State.getTrackedBooks() or {}
    local loans = {}
    local now_ts = os.time()

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    for _, item in ipairs(tracked) do
        if item and item.path and item.expires ~= nil then
            local exp_ts = _parseExpiryTimestamp(item.expires)
            if exp_ts then
                local exists = false
                if ok_lfs and lfs and lfs.attributes then
                    exists = (lfs.attributes(item.path, "mode") == "file")
                else
                    local f = io.open(item.path, "rb")
                    if f then f:close(); exists = true end
                end
                if exists then
                    local diff_sec = exp_ts - now_ts
                    local days_remaining = math.ceil(diff_sec / 86400)
                    if diff_sec <= 0 then
                        days_remaining = math.floor(diff_sec / 86400)
                    end
                    local fname = item.path:match("([^/\\]+)$") or item.path
                    local fallback_title = fname:gsub("%.[^%.]+$", ""):gsub("_", " ")
                    local title = (item.title and item.title ~= "") and item.title or fallback_title
                    table.insert(loans, {
                        path = item.path,
                        title = title,
                        author = item.author or "",
                        format = item.format or (item.path:lower():match("%.pdf$") and "pdf" or "epub"),
                        expires_ts = exp_ts,
                        due_date = os.date("%Y-%m-%d", exp_ts),
                        days_remaining = days_remaining,
                        is_adept = (item.is_adept == true),
                    })
                end
            end
        end
    end

    table.sort(loans, function(a, b)
        if a.expires_ts ~= b.expires_ts then
            return a.expires_ts < b.expires_ts
        end
        return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
    end)

    return loans
end

local function _fmtLoanDays(days)
    if not days then return "" end
    if days < 0 then return _("Expired") end
    if days == 0 then return _("Expires today") end
    if days == 1 then return _("1 day left") end
    return _("%d days left", days)
end

local function _createLoanBadge(text, is_urgent)
    if not text or text == "" then return nil end
    local bg = is_urgent and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = is_urgent and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 14),
        bold = is_urgent,
        fgcolor = fg,
    }
    return FrameContainer:new{
        padding_top = sc(2),
        padding_bottom = sc(2),
        padding_left = sc(7),
        padding_right = sc(7),
        bordersize = is_urgent and 0 or sc(1),
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        radius = theme.radius_badge or sc(8),
        label,
    }
end

local function _getLoanCoverPath(loan)
    if not loan or not loan.path then return nil end
    local sidecar_dir = nil
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and type(DocSettings.getSidecarDir) == "function" then
        local ok_sd, sd = pcall(DocSettings.getSidecarDir, DocSettings, loan.path, "doc")
        if ok_sd and type(sd) == "string" and sd ~= "" then
            sidecar_dir = sd
        end
    end
    if not sidecar_dir then
        sidecar_dir = loan.path:gsub("%.[^%.]+$", "") .. ".sdr"
    end

    local exts = { "jpg", "jpeg", "png", "webp", "gif" }
    for _, ext in ipairs(exts) do
        local candidate = sidecar_dir .. "/cover." .. ext
        local f = io.open(candidate, "rb")
        if f then
            f:close()
            return candidate
        end
    end
    return nil
end

local _loan_cover_cache = {}

local function _createLoanCoverImageWidget(file_path, target_w, target_h)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage or not file_path or not target_w or not target_h then
        return nil
    end

    local cache_key = string.format("%s|%dx%d", file_path, target_w, target_h)
    local cached_bb = _loan_cover_cache[cache_key]
    if cached_bb then
        return ImageWidget:new{
            image = cached_bb,
            image_disposable = false,
            width = target_w,
            height = target_h,
        }
    end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)
    if not ok or not orig_bb then return nil end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()
    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then pcall(function() orig_bb:free() end) end
        return nil
    end

    -- Scale with aspect fit (entire cover visible, centered inside target box)
    local scale = math.min(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.max(1, math.min(target_w, math.floor(orig_w * scale)))
    local scaled_h = math.max(1, math.min(target_h, math.floor(orig_h * scale)))

    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(orig_bb, scaled_w, scaled_h, false)
    end)
    if orig_bb.free then pcall(function() orig_bb:free() end) end
    if not ok_scale or not scaled_bb then return nil end

    local sw_actual = scaled_bb:getWidth()
    local sh_actual = scaled_bb:getHeight()
    local dest_x = math.max(0, math.floor((target_w - sw_actual) / 2))
    local dest_y = math.max(0, math.floor((target_h - sh_actual) / 2))

    local bb_type = (scaled_bb.getType and scaled_bb:getType()) or Blitbuffer.TYPE_BPP24
    local dest_bb = Blitbuffer.new(target_w, target_h, bb_type)
    pcall(function() dest_bb:fill(Blitbuffer.COLOR_WHITE) end)
    pcall(function()
        dest_bb:blitFrom(scaled_bb, dest_x, dest_y, 0, 0, sw_actual, sh_actual)
    end)
    if scaled_bb.free then pcall(function() scaled_bb:free() end) end

    _loan_cover_cache[cache_key] = dest_bb

    return ImageWidget:new{
        image = dest_bb,
        image_disposable = false,
        width = target_w,
        height = target_h,
    }
end

local function _createLoanPlaceholderWidget(target_w, target_h)
    local icon_w = TextWidget:new{
        text = "📖",
        face = Font:getFace("cfont", 24),
    }
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width = target_w,
        height = target_h,
        CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            VerticalGroup:new{
                align = "center",
                icon_w,
            }
        }
    }
end

local function _makeLoanTapItem(frame, callback)
    local item = InputContainer:new{ frame }
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local dim = item.dimen
                    if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                    local fsize = (frame and frame.getSize and frame:getSize()) or {}
                    return Geom:new{
                        x = dim.x or 0,
                        y = dim.y or 0,
                        w = dim.w or fsize.w or 0,
                        h = dim.h or fsize.h or 0,
                    }
                end
            }
        }
    }
    item.onTap = function()
        if callback then pcall(callback) end
        return true
    end
    return item
end

function M.showLoanDetailsDialog(loan, on_open_book)
    if not loan then return end
    local days_str = _fmtLoanDays(loan.days_remaining)
    local fmt_str = (loan.format and loan.format:upper()) or "EPUB"
    local lines = {
        string.format("%s:  %s", _("Title"), loan.title or _("Unknown Title")),
    }
    if loan.author and loan.author ~= "" then
        table.insert(lines, string.format("%s: %s", _("Author"), loan.author))
    end
    table.insert(lines, string.format("%s: %s", _("Format"), fmt_str))
    table.insert(lines, string.format("%s: %s", _("Due Date"), loan.due_date or ""))
    if days_str ~= "" then
        table.insert(lines, string.format("%s: %s", _("Loan"), days_str))
    end

    M.showCardDialog{
        title = _("Loan Details"),
        body_text = table.concat(lines, "\n"),
        buttons = {
            {
                text = _("Open Book"),
                is_primary = true,
                callback = function()
                    if on_open_book then on_open_book() end
                    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
                    if ok_rui and ReaderUI and ReaderUI.showReader then
                        ReaderUI:showReader(loan.path)
                    end
                end,
            },
            {
                text = _("Close"),
                is_primary = false,
            },
        },
    }
end

function M.showActiveLoansDialog(plugin_instance, on_close_cb)
    _dismissActiveToast()
    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device
    local current_page = 1
    local focused_loan_idx = 1
    local focused_header_idx = 1
    local focus_zone = "items" -- "items" or "header"

    local function closeLoansBrowser(run_cb)
        if active_loans_overlay then
            local ov = active_loans_overlay
            active_loans_overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if run_cb and on_close_cb then on_close_cb() end
    end

    local function renderLoans()
        if active_loans_overlay then
            local ov = active_loans_overlay
            active_loans_overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local view_mode = State.getLoansViewMode()
        local loans = _getActiveLoans()
        local loan_count = #loans

        if loan_count == 0 then
            focus_zone = "header"
        end

        local is_hdr = (focus_zone == "header")
        local view_toggle_icon = (view_mode == "cover") and "list.svg" or "grid.svg"
        local view_toggle_btn = createIconButton{
            icon_file = getAssetPath(view_toggle_icon),
            width = sc(40),
            height = sc(40),
            icon_size = sc(32),
            padding = sc(4),
            padding_h = sc(4),
            is_focused = (focus_visible and is_hdr and focused_header_idx == 1),
            callback = function()
                focus_zone = "header"
                focused_header_idx = 1
                local next_mode = (view_mode == "cover") and "list" or "cover"
                State.setLoansViewMode(next_mode)
                current_page = 1
                focused_loan_idx = 1
                renderLoans()
            end,
        }

        local close_btn = createIconButton{
            icon_file = getAssetPath("x.svg"),
            width = sc(40),
            height = sc(40),
            icon_size = sc(32),
            padding = sc(4),
            padding_h = sc(4),
            is_focused = (focus_visible and is_hdr and focused_header_idx == 2),
            callback = function()
                closeLoansBrowser(true)
            end,
        }

        local header_actions = HorizontalGroup:new{
            view_toggle_btn,
            HorizontalSpan:new{ width = sc(12) },
            close_btn,
        }

        local bee_icon = ImageWidget:new{
            file = getAssetPath("bee.png"),
            width = sc(34),
            height = sc(34),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local header_title = HorizontalGroup:new{
            align = "center",
            bee_icon,
            HorizontalSpan:new{ width = sc(8) },
            TextWidget:new{
                text = _("Beeline · Loans"),
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        }

        local count_str = string.format("%d %s", loan_count, loan_count == 1 and _("loan") or _("loans"))
        local actions_w = (header_actions.getSize and header_actions:getSize().w) or sc(80)
        local header_avail_w = sw - sc(24)
        local header_top_row = HorizontalGroup:new{
            header_title,
            HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - ((header_title.getSize and header_title:getSize().w) or sc(160)) - actions_w) },
            header_actions,
        }
        local header_sub = TextWidget:new{
            text = count_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 15),
            fgcolor = theme.color_label_dim,
            max_width = header_avail_w,
        }
        local header_frame = FrameContainer:new{
            padding = sc(10),
            padding_left = sc(12),
            padding_right = sc(12),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            VerticalGroup:new{
                align = "left",
                header_top_row,
                VerticalSpan:new{ width = sc(2) },
                header_sub,
            },
        }
        local header_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }

        local header_h = ((header_frame.getSize and header_frame:getSize().h) or sc(72)) + sc(2)
        local footer_h = sc(48)
        local top_margin = sc(6)
        local safety_margin = sc(20)
        local avail_h = sh - header_h - footer_h - top_margin - safety_margin

        local COLS = 3
        local grid_gap = sc(10)
        local border_w = theme.border_preview or sc(2)
        local target_margin_h = sc(14)
        local avail_grid_w = sw - (target_margin_h * 2)
        local cell_w = math.floor((avail_grid_w - (grid_gap * (COLS - 1))) / COLS)
        local row_total_w = (cell_w * COLS) + (grid_gap * (COLS - 1))
        local margin_h = math.floor((sw - row_total_w) / 2)
        local content_w = row_total_w
        local content_inner = content_w - sc(16)

        local tile_extra_h = (border_w * 2) + sc(4) + sc(56) + sc(4) + sc(26)
        local grid_gap_v = sc(8)
        local cover_inner_w, cover_inner_h, cover_row_h

        if view_mode == "cover" then
            local max_cover_w_by_cell = cell_w - (border_w * 2)
            local ideal_cover_h = math.floor(max_cover_w_by_cell * 1.38)
            local max_row_h_3 = math.floor((avail_h - (grid_gap_v * 2)) / 3)
            local max_cover_h_3 = max_row_h_3 - tile_extra_h
            local max_row_h_2 = math.floor((avail_h - grid_gap_v) / 2)
            local max_cover_h_2 = max_row_h_2 - tile_extra_h

            local num_rows
            if max_cover_h_3 >= math.floor(ideal_cover_h * 0.90) then
                num_rows = 3
            elseif max_cover_h_2 >= sc(70) then
                num_rows = 2
            else
                num_rows = 1
            end

            local max_row_h = math.floor((avail_h - (grid_gap_v * (num_rows - 1))) / num_rows)
            local max_cover_h = math.max(sc(45), max_row_h - tile_extra_h)
            local max_cover_w_by_h = math.floor(max_cover_h / 1.38)
            cover_inner_w = math.max(sc(40), math.min(max_cover_w_by_cell, max_cover_w_by_h))
            cover_inner_h = math.floor(cover_inner_w * 1.38)
            cover_row_h = cover_inner_h + tile_extra_h
        end

        local pages = {}
        if loan_count > 0 then
            if view_mode == "cover" then
                local rows_per_page = math.max(1, math.floor((avail_h + grid_gap_v) / (cover_row_h + grid_gap_v)))
                local per_page = rows_per_page * COLS
                for i = 1, loan_count, per_page do
                    local chunk = {}
                    for k = i, math.min(loan_count, i + per_page - 1) do
                        table.insert(chunk, loans[k])
                    end
                    table.insert(pages, chunk)
                end
            else
                local list_row_h = sc(92)
                local per_page = math.max(1, math.floor(avail_h / list_row_h))
                for i = 1, loan_count, per_page do
                    local chunk = {}
                    for k = i, math.min(loan_count, i + per_page - 1) do
                        table.insert(chunk, loans[k])
                    end
                    table.insert(pages, chunk)
                end
            end
        end

        local total_pages = math.max(1, #pages)
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        local cur_page_loans = pages[current_page] or {}
        if focused_loan_idx > #cur_page_loans and #cur_page_loans > 0 then
            focused_loan_idx = #cur_page_loans
        elseif focused_loan_idx < 1 then
            focused_loan_idx = 1
        end

        local page_content_vg = VerticalGroup:new{ align = "left" }

        local function openLoan(loan, idx)
            focus_zone = "items"
            focused_loan_idx = idx
            if is_touch_device then focus_visible = false end
            M.showLoanDetailsDialog(loan, function()
                closeLoansBrowser(false)
            end)
        end

        if loan_count == 0 then
            local empty_text = TextBoxWidget:new{
                text = _("No active library loans.\n\nFulfilled library loans with an expiration date will appear here. Purchased books do not expire."),
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = sw - sc(48),
                alignment = "center",
            }
            table.insert(page_content_vg, FrameContainer:new{
                padding = sc(30),
                bordersize = 0,
                width = sw,
                CenterContainer:new{
                    dimen = Geom:new{ w = sw - sc(48), h = sh - sc(200) },
                    empty_text,
                }
            })
        elseif view_mode == "list" then
            for idx, loan in ipairs(cur_page_loans) do
                local is_focused = (focus_visible and focus_zone == "items" and idx == focused_loan_idx)
                local badge_w = _createLoanBadge(_fmtLoanDays(loan.days_remaining), (loan.days_remaining and loan.days_remaining <= 2) or is_focused)
                local badge_reserve = badge_w and (((badge_w.getSize and badge_w:getSize().w) or sc(90)) + sc(8)) or 0
                local thumb_w_size = sc(54)
                local thumb_h_size = sc(76)
                local thumb_reserve = thumb_w_size + sc(10)
                local text_w = content_inner - badge_reserve - thumb_reserve

                local cover_path = _getLoanCoverPath(loan)
                local thumb_widget = cover_path and _createLoanCoverImageWidget(cover_path, thumb_w_size, thumb_h_size)
                if not thumb_widget then
                    thumb_widget = _createLoanPlaceholderWidget(thumb_w_size, thumb_h_size)
                end

                local thumb_frame = FrameContainer:new{
                    bordersize = 0,
                    padding = 0,
                    width = thumb_w_size,
                    height = thumb_h_size,
                    thumb_widget,
                }

                local title_w = TextWidget:new{
                    text = loan.title,
                    face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 20),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = text_w,
                }

                local meta_parts = {}
                if loan.author and loan.author ~= "" then table.insert(meta_parts, loan.author) end
                table.insert(meta_parts, _("Due %s", loan.due_date))
                local meta_w = TextWidget:new{
                    text = table.concat(meta_parts, "  ·  "),
                    face = Font:getFace("cfont", theme.subtext_font_size or 16),
                    fgcolor = theme.color_label_dim,
                    max_width = text_w,
                }

                local row_left = HorizontalGroup:new{
                    thumb_frame,
                    HorizontalSpan:new{ width = sc(10) },
                    VerticalGroup:new{
                        align = "left",
                        title_w,
                        VerticalSpan:new{ width = sc(2) },
                        meta_w,
                    },
                }

                local total_h = math.max((row_left.getSize and row_left:getSize().h) or thumb_h_size, (badge_w and badge_w.getSize and badge_w:getSize().h) or 0)
                local row_overlap
                if badge_w and OverlapGroup and LeftContainer and RightContainer then
                    row_overlap = OverlapGroup:new{
                        dimen = Geom:new{ w = content_inner, h = total_h },
                        LeftContainer:new{
                            dimen = Geom:new{ w = content_inner, h = total_h },
                            row_left,
                        },
                        RightContainer:new{
                            dimen = Geom:new{ w = content_inner, h = total_h },
                            badge_w,
                        },
                    }
                else
                    row_overlap = row_left
                end

                local row_frame = FrameContainer:new{
                    padding = sc(8),
                    bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                    color = Blitbuffer.COLOR_BLACK,
                    background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                    radius = is_focused and (theme.radius_focus or sc(6)) or 0,
                    width = content_w,
                    row_overlap,
                }

                local row_tap = _makeLoanTapItem(row_frame, function()
                    openLoan(loan, idx)
                end)

                table.insert(page_content_vg, HorizontalGroup:new{
                    HorizontalSpan:new{ width = margin_h },
                    row_tap,
                    HorizontalSpan:new{ width = margin_h },
                })
                table.insert(page_content_vg, HorizontalGroup:new{
                    HorizontalSpan:new{ width = margin_h },
                    LineWidget:new{
                        dimen = Geom:new{ w = content_w, h = sc(1) },
                        background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
                    },
                    HorizontalSpan:new{ width = margin_h },
                })
            end
        else
            local current_row_widgets = {}
            for idx, loan in ipairs(cur_page_loans) do
                local is_focused = (focus_visible and focus_zone == "items" and idx == focused_loan_idx)
                local cover_path = _getLoanCoverPath(loan)
                local cover_img = cover_path and _createLoanCoverImageWidget(cover_path, cover_inner_w, cover_inner_h)
                if not cover_img then
                    cover_img = _createLoanPlaceholderWidget(cover_inner_w, cover_inner_h)
                end

                local cover_frame = FrameContainer:new{
                    bordersize = is_focused and (theme.border_focus or sc(3)) or 0,
                    color = Blitbuffer.COLOR_BLACK,
                    padding = is_focused and sc(3) or 0,
                    background = is_focused and Blitbuffer.COLOR_WHITE or nil,
                    radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                    cover_img,
                }

                local title_w = TextWidget:new{
                    text = loan.title,
                    face = Font:getFace("NotoSerif-Regular.ttf", 15),
                    bold = true,
                    max_width = cell_w - sc(4),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local date_w = TextWidget:new{
                    text = loan.due_date,
                    face = Font:getFace("cfont", 13),
                    max_width = cell_w - sc(4),
                    fgcolor = theme.color_label_dim,
                }
                local badge_widget = _createLoanBadge(_fmtLoanDays(loan.days_remaining), (loan.days_remaining and loan.days_remaining <= 2) or is_focused)

                local cell_content = VerticalGroup:new{
                    align = "center",
                    cover_frame,
                    VerticalSpan:new{ width = sc(6) },
                    title_w,
                    VerticalSpan:new{ width = sc(2) },
                    date_w,
                    VerticalSpan:new{ width = sc(4) },
                    badge_widget or VerticalSpan:new{ width = 0 },
                }

                local cell_tap = _makeLoanTapItem(cell_content, function()
                    openLoan(loan, idx)
                end)
                table.insert(current_row_widgets, cell_tap)

                if #current_row_widgets == COLS or idx == #cur_page_loans then
                    local row_group_items = { HorizontalSpan:new{ width = margin_h } }
                    for col_i, cell in ipairs(current_row_widgets) do
                        if col_i > 1 then
                            table.insert(row_group_items, HorizontalSpan:new{ width = grid_gap })
                        end
                        table.insert(row_group_items, cell)
                    end
                    table.insert(row_group_items, HorizontalSpan:new{ width = margin_h })
                    local row_group = HorizontalGroup:new(row_group_items)
                    row_group.align = "top"
                    table.insert(page_content_vg, row_group)
                    table.insert(page_content_vg, VerticalSpan:new{ width = grid_gap_v })
                    current_row_widgets = {}
                end
            end
        end

        local page_content_frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            width = sw,
            page_content_vg,
        }

        local prev_btn = createButton{
            text = _("‹ Prev"),
            text_font_size = 16,
            bold = true,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            padding = sc(4),
            padding_h = sc(12),
            callback = function()
                if current_page > 1 then
                    current_page = current_page - 1
                    focused_loan_idx = 1
                    renderLoans()
                end
            end,
        }
        local next_btn = createButton{
            text = _("Next ›"),
            text_font_size = 16,
            bold = true,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            padding = sc(4),
            padding_h = sc(12),
            callback = function()
                if current_page < total_pages then
                    current_page = current_page + 1
                    focused_loan_idx = 1
                    renderLoans()
                end
            end,
        }
        local page_label = TextWidget:new{
            text = string.format("%d / %d", current_page, total_pages),
            face = Font:getFace("cfont", 16),
            fgcolor = theme.color_label_dim,
        }

        local prev_w = (prev_btn.getSize and prev_btn:getSize().w) or sc(80)
        local next_w = (next_btn.getSize and next_btn:getSize().w) or sc(80)
        local label_w = (page_label.getSize and page_label:getSize().w) or sc(40)
        local footer_inner_w = sw - sc(40)
        local mid_spacer = math.max(sc(8), (footer_inner_w - prev_w - next_w - label_w) / 2)

        local footer_widgets = HorizontalGroup:new{
            current_page > 1 and prev_btn or HorizontalSpan:new{ width = prev_w },
            HorizontalSpan:new{ width = mid_spacer },
            page_label,
            HorizontalSpan:new{ width = mid_spacer },
            current_page < total_pages and next_btn or HorizontalSpan:new{ width = next_w },
        }

        local footer_frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(6),
            padding_left = sc(10),
            padding_right = sc(10),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = footer_h,
            CenterContainer:new{
                dimen = Geom:new{ w = sw - sc(20), h = footer_h - sc(10) },
                footer_widgets,
            }
        }

        local top_vg = VerticalGroup:new{
            align = "left",
            header_frame,
            header_divider,
            VerticalSpan:new{ width = top_margin },
            page_content_frame,
        }

        local main_container
        if BottomContainer and OverlapGroup then
            main_container = OverlapGroup:new{
                dimen = Geom:new{ w = sw, h = sh },
                top_vg,
                BottomContainer:new{
                    dimen = Geom:new{ w = sw, h = sh },
                    footer_frame,
                },
            }
        else
            main_container = top_vg
        end

        local bg_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = sh,
            main_container,
        }

        local loans_key_events = {
            Close = { { "Back" }, { "Escape" } },
            PrevPage = { { "PgUp" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } },
            NextPage = { { "PgDn" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } },
            Up = { { "Up" } },
            Down = { { "Down" } },
            Left = { { "Left" } },
            Right = { { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
            ViewToggleKey = { { "v" }, { "V" } },
            Num1 = { { "1" } },
            Num2 = { { "2" } },
            Num3 = { { "3" } },
            Num4 = { { "4" } },
            Num5 = { { "5" } },
            Num6 = { { "6" } },
            Num7 = { { "7" } },
            Num8 = { { "8" } },
            Num9 = { { "9" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(loans_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.PgBack then table.insert(loans_key_events.PrevPage, { Device.input.group.PgBack }) end
            if Device.input.group.PgFwd then table.insert(loans_key_events.NextPage, { Device.input.group.PgFwd }) end
            if Device.input.group.Up then table.insert(loans_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(loans_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(loans_key_events.Left, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(loans_key_events.Right, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(loans_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(loans_key_events.Press, { Device.input.group.Enter }) end
        end

        active_loans_overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = loans_key_events,
            ges_events = {
                Swipe = {
                    GestureRange:new{
                        ges = "swipe",
                        range = function() return Geom:new{ x = 0, y = 0, w = sw, h = sh } end,
                    },
                },
            },
            bg_frame,
        }

        local function activateLoanAtIndex(idx)
            if cur_page_loans[idx] then
                openLoan(cur_page_loans[idx], idx)
                return true
            end
        end

        active_loans_overlay.onPrevPage = function()
            if current_page > 1 then
                current_page = current_page - 1
                focused_loan_idx = 1
                renderLoans()
                return true
            end
        end
        active_loans_overlay.onNextPage = function()
            if current_page < total_pages then
                current_page = current_page + 1
                focused_loan_idx = 1
                renderLoans()
                return true
            end
        end

        local function ensureFocusVisible()
            if not focus_visible then
                focus_visible = true
                renderLoans()
                return true
            end
            return false
        end

        active_loans_overlay.onUp = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then return true end
            if view_mode == "list" then
                if focused_loan_idx > 1 then
                    focused_loan_idx = focused_loan_idx - 1
                else
                    focus_zone = "header"
                    focused_header_idx = 1
                end
            else
                if focused_loan_idx > COLS then
                    focused_loan_idx = focused_loan_idx - COLS
                else
                    focus_zone = "header"
                    focused_header_idx = 1
                end
            end
            renderLoans()
            return true
        end

        active_loans_overlay.onDown = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                if #cur_page_loans > 0 then
                    focus_zone = "items"
                    focused_loan_idx = 1
                    renderLoans()
                end
                return true
            end
            local count = #cur_page_loans
            if count == 0 then return true end
            if view_mode == "list" then
                if focused_loan_idx < count then
                    focused_loan_idx = focused_loan_idx + 1
                    renderLoans()
                end
            else
                if focused_loan_idx + COLS <= count then
                    focused_loan_idx = focused_loan_idx + COLS
                    renderLoans()
                elseif focused_loan_idx < count and focused_loan_idx <= math.floor((count - 1) / COLS) * COLS then
                    focused_loan_idx = count
                    renderLoans()
                end
            end
            return true
        end

        active_loans_overlay.onLeft = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                if focused_header_idx > 1 then
                    focused_header_idx = focused_header_idx - 1
                    renderLoans()
                elseif current_page > 1 then
                    return active_loans_overlay:onPrevPage()
                end
                return true
            end
            if view_mode == "list" then
                return active_loans_overlay:onPrevPage()
            elseif focused_loan_idx > 1 then
                focused_loan_idx = focused_loan_idx - 1
                renderLoans()
                return true
            elseif current_page > 1 then
                return active_loans_overlay:onPrevPage()
            end
        end

        active_loans_overlay.onRight = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                if focused_header_idx < 2 then
                    focused_header_idx = focused_header_idx + 1
                    renderLoans()
                elseif current_page < total_pages then
                    return active_loans_overlay:onNextPage()
                end
                return true
            end
            if view_mode == "list" then
                return active_loans_overlay:onNextPage()
            elseif focused_loan_idx < #cur_page_loans then
                focused_loan_idx = focused_loan_idx + 1
                renderLoans()
                return true
            elseif current_page < total_pages then
                return active_loans_overlay:onNextPage()
            end
        end

        active_loans_overlay.onPress = function()
            if focus_zone == "header" then
                if focused_header_idx == 1 then
                    local next_mode = (view_mode == "cover") and "list" or "cover"
                    State.setLoansViewMode(next_mode)
                    current_page = 1
                    focused_loan_idx = 1
                    renderLoans()
                else
                    closeLoansBrowser(true)
                end
                return true
            end
            return activateLoanAtIndex(focused_loan_idx)
        end

        active_loans_overlay.onViewToggleKey = function()
            local next_mode = (view_mode == "cover") and "list" or "cover"
            State.setLoansViewMode(next_mode)
            current_page = 1
            focused_loan_idx = 1
            renderLoans()
            return true
        end

        active_loans_overlay.onNum1 = function() return activateLoanAtIndex(1) end
        active_loans_overlay.onNum2 = function() return activateLoanAtIndex(2) end
        active_loans_overlay.onNum3 = function() return activateLoanAtIndex(3) end
        active_loans_overlay.onNum4 = function() return activateLoanAtIndex(4) end
        active_loans_overlay.onNum5 = function() return activateLoanAtIndex(5) end
        active_loans_overlay.onNum6 = function() return activateLoanAtIndex(6) end
        active_loans_overlay.onNum7 = function() return activateLoanAtIndex(7) end
        active_loans_overlay.onNum8 = function() return activateLoanAtIndex(8) end
        active_loans_overlay.onNum9 = function() return activateLoanAtIndex(9) end

        active_loans_overlay.onSwipe = function(self, arg, ges)
            if is_touch_device then focus_visible = false end
            if ges and (ges.direction == "west" or ges.direction == "south") then
                if current_page < total_pages then
                    current_page = current_page + 1
                    focused_loan_idx = 1
                    renderLoans()
                    return true
                end
            elseif ges and (ges.direction == "east" or ges.direction == "north") then
                if current_page > 1 then
                    current_page = current_page - 1
                    focused_loan_idx = 1
                    renderLoans()
                    return true
                end
            end
        end

        active_loans_overlay.onClose = function()
            closeLoansBrowser(true)
            return true
        end

        UIManager:show(active_loans_overlay, "ui")
    end

    renderLoans()
end

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Beeline Settings Dialog (Secondary Config Screen)
-- ---------------------------------------------------------------------------

function M.showSettingsDialog(plugin_instance, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    local worker_url = s.worker_url or State.DEFAULT_WORKER_URL

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(440))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = theme.face_label_size or 16
    local is_touch = isTouchDevice()
    local focus_visible = not is_touch

    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    local function close_cb()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        if on_close_cb then on_close_cb() end
    end

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}
        s = State.loadSettings()

        -- Title Header with Feather Icons: Back (chevron-left.svg) and Close (x.svg)
        local back_btn = createIconButton{
            icon_file = getAssetPath("chevron-left.svg"),
            width = sc(32),
            height = sc(32),
            icon_size = sc(20),
            callback = close_cb,
        }

        local title_label = TextWidget:new{
            text = _("Beeline Settings"),
            face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 20),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local close_btn_icon = createIconButton{
            icon_file = getAssetPath("x.svg"),
            width = sc(32),
            height = sc(32),
            icon_size = sc(20),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
            end,
        }

        local title_w = (title_label.getSize and title_label:getSize().w) or sc(140)
        local title_row = HorizontalGroup:new{
            back_btn,
            HorizontalSpan:new{ width = sc(8) },
            title_label,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_w - sc(74)) },
            close_btn_icon,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_row,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(6) },
        }

        -- Section Header Builder
        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(3),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        -- Row Builder
        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(5)
            local avail_w = inner_w - (frame_padding * 2)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(60)) or 0
            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then max_left_w = sc(60) end

            local left_w = TextWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = max_left_w,
            }

            local left_used_w = (left_w.getSize and left_w:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { left_w, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then table.insert(row_elements, right_widget) end

            local is_focused = false
            local item_idx = nil
            if callback then
                item_idx = #interactive_items + 1
                table.insert(interactive_items, { callback = callback })
                is_focused = (focus_visible and focused_row_idx == item_idx)
            end

            local frame = FrameContainer:new{
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                padding = frame_padding,
                width = inner_w,
                HorizontalGroup:new(row_elements),
            }

            if not callback then return frame end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = inner_w, h = sc(28) }
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or inner_w,
                                h = (dim.h and dim.h > 0 and dim.h) or row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                if item_idx then focused_row_idx = item_idx end
                if is_touch then focus_visible = false end
                callback()
                return true
            end
            return item
        end

        -- ===================================================================
        -- SECTION 1: RELAY & STORAGE
        -- ===================================================================
        table.insert(content_vg, create_section_header(_("Relay & Storage")))

        -- Destination Inbox Row (Libbee Folder Picker)
        local display_inbox = s.inbox_dir or ""
        if #display_inbox > 24 then
            display_inbox = "…" .. display_inbox:sub(-22)
        end
        local inbox_right = TextWidget:new{
            text = display_inbox .. " ›",
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        local function openFolderPicker()
            UIManager:nextTick(function()
                local ok, err = pcall(function()
                    if overlay then
                        local ov = overlay
                        overlay = nil
                        ov.onClose = nil
                        UIManager:close(ov, "ui")
                    end
                    local FolderPicker = require(plugin_path .. "beeline_folder_picker")
                    FolderPicker.show{
                        title = _("Select Inbox Folder"),
                        initial_path = s.inbox_dir,
                        fallback_path = G_reader_settings and G_reader_settings:readSetting("home_dir"),
                        on_confirm = function(chosen_path)
                            if chosen_path and chosen_path ~= "" then
                                State.setInboxDir(chosen_path)
                                M.showToast(_("Inbox folder set to %s", chosen_path), 2)
                            end
                            UIManager:nextTick(function()
                                M.showSettingsDialog(plugin_instance, on_close_cb)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                M.showSettingsDialog(plugin_instance, on_close_cb)
                            end)
                        end,
                    }
                end)
                if not ok then
                    logger.err("openFolderPicker error: " .. tostring(err))
                    M.showSettingsDialog(plugin_instance, on_close_cb)
                end
            end)
        end
        table.insert(content_vg, create_setting_row(_("Destination Inbox"), inbox_right, openFolderPicker))

        -- Auto-Check on Wi-Fi Row (Feather Icon Checkbox)
        local wifi_enabled = State.getAutoCheckWifi()
        local icon_file = wifi_enabled and "check-square.svg" or "square.svg"
        local check_icon = ImageWidget:new{
            file = getAssetPath(icon_file),
            width = sc(20),
            height = sc(20),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        table.insert(content_vg, create_setting_row(_("Auto-Check on Wi-Fi"), check_icon, function()
            State.setAutoCheckWifi(not wifi_enabled)
            refresh()
        end))

        -- Background Sync (30s) Row (Feather Icon Checkbox)
        local bg_enabled = State.getBackgroundSync()
        local bg_icon_file = bg_enabled and "check-square.svg" or "square.svg"
        local bg_check_icon = ImageWidget:new{
            file = getAssetPath(bg_icon_file),
            width = sc(20),
            height = sc(20),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        table.insert(content_vg, create_setting_row(_("Background Sync (30s)"), bg_check_icon, function()
            local new_val = not bg_enabled
            State.setBackgroundSync(new_val)
            if plugin_instance and plugin_instance.updateSyncSchedule then
                plugin_instance:updateSyncSchedule()
            end
            if new_val then
                M.showToast(_("Background sync enabled.\nWarning: Keeps Wi-Fi active and will increase battery drain."), 3, "info", _("Battery Drain Warning"))
            end
            refresh()
        end))

        -- Battery drain warning note (Feather info.svg)
        local bg_warn_icon = ImageWidget:new{
            file = getAssetPath("info.svg"),
            width = sc(13),
            height = sc(13),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local bg_warn_text = TextBoxWidget:new{
            text = _("Keeps Wi-Fi active every 30s; will noticeably increase battery drain."),
            face = Font:getFace("cfont", math.max(11, (theme.subtext_font_size or 14) - 2)),
            fgcolor = theme.color_label_dim,
            width = inner_w - sc(36),
        }
        table.insert(content_vg, FrameContainer:new{
            padding_left = sc(6),
            padding_right = sc(6),
            padding_top = sc(1),
            padding_bottom = sc(4),
            bordersize = 0,
            width = inner_w,
            HorizontalGroup:new{
                align = "top",
                bg_warn_icon,
                HorizontalSpan:new{ width = sc(6) },
                bg_warn_text,
            },
        })

        -- ===================================================================
        -- SECTION 2: LIBRARY LOANS (ACSM & Expiry)
        -- ===================================================================
        table.insert(content_vg, VerticalSpan:new{ width = sc(3) })
        table.insert(content_vg, create_section_header(_("Library Loans")))

        local acct_info = State.getDrmAccountInfo()
        local mode_label = acct_info.mode == "bytebooks" and ("ByteBooks (" .. (acct_info.email or "") .. ")") or _("Anonymous (Default)")

        local mode_right = TextWidget:new{
            text = mode_label .. " ›",
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }

        local function showDrmAccountDialog()
            local drm_dialog
            local is_bytebooks = (acct_info.mode == "bytebooks" and acct_info.activated)

            local buttons = {}
            if is_bytebooks then
                table.insert(buttons, {
                    text = _("Deauthorize"),
                    is_primary = false,
                    callback = function()
                        local ok_drm, DRM = pcall(require, plugin_path .. "beeline_drm")
                        if ok_drm and DRM then
                            DRM.deauthorize()
                            M.showToast(_("Deauthorized ByteBooks account"), 2)
                        end
                        UIManager:close(drm_dialog)
                        refresh()
                    end
                })
            else
                table.insert(buttons, {
                    text = _("Sign in to ByteBooks"),
                    is_primary = true,
                    callback = function()
                        UIManager:close(drm_dialog)
                        local email_dlg
                        email_dlg = InputDialog:new{
                            title = _("ByteBooks Email"),
                            description = _("Sign in with your ByteBooks account (https://dtsbytebooks.com). Legacy Adobe IDs must be migrated or registered at dtsbytebooks.com first."),
                            input = acct_info.email or "",
                            allow_newline = false,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function() UIManager:close(email_dlg) end,
                                    },
                                    {
                                        text = _("Next"),
                                        is_primary = true,
                                        is_enter_default = true,
                                        callback = function()
                                            local email = email_dlg:getInputText():gsub("^%s*(.-)%s*$", "%1")
                                            UIManager:close(email_dlg)
                                            if email == "" then return end

                                            local pass_dlg
                                            pass_dlg = InputDialog:new{
                                                title = _("ByteBooks Password"),
                                                input = "",
                                                text_type = "password",
                                                allow_newline = false,
                                                buttons = {
                                                    {
                                                        {
                                                            text = _("Cancel"),
                                                            id = "close",
                                                            callback = function() UIManager:close(pass_dlg) end,
                                                        },
                                                        {
                                                            text = _("Sign In"),
                                                            is_primary = true,
                                                            is_enter_default = true,
                                                            callback = function()
                                                                local pass = pass_dlg:getInputText()
                                                                UIManager:close(pass_dlg)
                                                                M.showToast(_("Authorizing ByteBooks account..."), 2)

                                                                UIManager:nextTick(function()
                                                                    local ok_drm, DRM = pcall(require, plugin_path .. "beeline_drm")
                                                                    if ok_drm and DRM then
                                                                        local res, err = DRM.authorizeByteBooks(email, pass)
                                                                        if res then
                                                                            M.showToast(_("ByteBooks activation successful!"), 3)
                                                                        else
                                                                            local err_str = tostring(err or ""):gsub("%%(%x%x)", function(h)
                                                                                return string.char(tonumber(h, 16))
                                                                            end)
                                                                            local err_lower = err_str:lower()
                                                                            if err_lower:find("user does not exist", 1, true) or err_lower:find("e_adept_reset_pw_required", 1, true) then
                                                                                err_str = err_str .. "\n\n" .. _("Make sure you have registered or migrated your Adobe ID at https://dtsbytebooks.com/transition-help using the exact same lowercase email.")
                                                                            end
                                                                            M.showCardDialog{
                                                                                title = _("Authorization Failed"),
                                                                                body_text = _("Could not activate ByteBooks account:\n%s", err_str),
                                                                                buttons = {
                                                                                    { text = _("OK"), is_primary = true, callback = function() end }
                                                                                }
                                                                            }
                                                                        end
                                                                        refresh()
                                                                    end
                                                                end)
                                                            end,
                                                        },
                                                    },
                                                },
                                            }
                                            UIManager:show(pass_dlg)
                                            pass_dlg:onShowKeyboard()
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(email_dlg)
                        email_dlg:onShowKeyboard()
                    end
                })
            end

            table.insert(buttons, {
                text = _("Close"),
                is_primary = not is_bytebooks,
                callback = function()
                    UIManager:close(drm_dialog)
                end
            })

            drm_dialog = M.showCardDialog{
                title = _("ACSM Fulfillment Account"),
                body_text = string.format("Account Mode: %s\nEmail: %s\nDevice Serial: %s\n\n• Anonymous mode: Fulfills loans bound to this device only.\n• ByteBooks mode: Links fulfillment to your account so the same .acsm file can be read on multiple devices.\n\nPasswords are never saved on the device.",
                    acct_info.mode:upper(),
                    acct_info.email ~= "" and acct_info.email or "(none)",
                    acct_info.serial ~= "" and acct_info.serial or "(generated on first loan)"
                ),
                buttons = buttons
            }
        end

        table.insert(content_vg, create_setting_row(_("ACSM Account Mode"), mode_right, showDrmAccountDialog))

        local acsm_hint_text = TextBoxWidget:new{
            text = _("ByteBooks allows the same .acsm file to be read on multiple devices."),
            face = Font:getFace("cfont", math.max(11, (theme.subtext_font_size or 14) - 2)),
            fgcolor = theme.color_label_dim,
            width = inner_w - sc(12),
        }
        table.insert(content_vg, FrameContainer:new{
            padding_left = sc(6),
            padding_right = sc(6),
            padding_top = sc(1),
            padding_bottom = sc(4),
            bordersize = 0,
            width = inner_w,
            acsm_hint_text,
        })

        -- ===================================================================
        -- SECTION 3: CONNECTION & BROWSERS
        -- ===================================================================
        table.insert(content_vg, VerticalSpan:new{ width = sc(3) })
        table.insert(content_vg, create_section_header(_("Connection")))

        -- Worker URL Row
        local display_worker = s.worker_url:gsub("^https?://", "")
        if #display_worker > 22 then
            display_worker = display_worker:sub(1, 20) .. "…"
        end
        local worker_right = TextWidget:new{
            text = display_worker .. " ›",
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Worker URL"), worker_right, function()
            local dialog
            dialog = InputDialog:new{
                title = _("Cloudflare Worker URL"),
                input = s.worker_url or "",
                description = _("Enter full HTTPS endpoint of your Beeline Worker:"),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("Test & Save"),
                            is_primary = true,
                            is_enter_default = true,
                            callback = function()
                                local val = dialog:getInputText():gsub("[%s]+", ""):gsub("/+$", "")
                                local ok, res = Client.ping(val)
                                if ok then
                                    State.setWorkerUrl(val)
                                    UIManager:close(dialog)
                                    M.showToast(_("Worker connection verified!"), 3)
                                    refresh()
                                else
                                    M.showToast(_("Connection failed: %s", tostring(res)), 4)
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
        end))

        -- Disconnect All Browsers Row
        local paired_count = State.getPairedBrowserCount()
        local unpair_text = (paired_count > 0) and _("Disconnect All Browsers (%d)", paired_count) or _("Disconnect All Browsers")
        local unpair_btn_idx = #interactive_items + 1
        local is_unpair_focused = (focus_visible and focused_row_idx == unpair_btn_idx)
        local unpair_btn = createButton{
            text = unpair_text,
            text_font_size = theme.subtext_font_size or 13,
            bold = true,
            is_focused = is_unpair_focused,
            bordersize = is_unpair_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(28),
            callback = function()
                M.showCardDialog{
                    title = _("Disconnect All Browsers?"),
                    body_text = _("This will revoke all currently connected phones and computers. They will need a new pairing code to send books."),
                    buttons = {
                        {
                            text = _("Cancel"),
                            is_primary = false,
                        },
                        {
                            text = _("Disconnect All"),
                            is_primary = true,
                            callback = function()
                                local old_dev, new_code = State.unpairAllDevices()
                                local dev_id = State.getDeviceId()
                                if s.worker_url and s.worker_url ~= "" and old_dev ~= "" then
                                    pcall(Client.unpairDevice, s.worker_url, old_dev)
                                    local code_h = Crypto.getCodeHash(new_code)
                                    if code_h then
                                        pcall(Client.registerPairingCode, s.worker_url, code_h, dev_id)
                                    end
                                    pcall(Client.registerPairing, s.worker_url, dev_id)
                                end
                                M.showToast(_("All browsers disconnected. New code: %s", new_code), 3)
                                refresh()
                            end,
                        },
                    },
                }
            end,
        }
        table.insert(interactive_items, { callback = unpair_btn.callback })
        table.insert(content_vg, unpair_btn)
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Footer: Back & Close
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        local half_btn_w = math.floor((inner_w - sc(8)) / 2)

        local back_btn_idx = #interactive_items + 1
        local is_back_focused = (focus_visible and focused_row_idx == back_btn_idx)
        local footer_back_btn = createButton{
            text = _("Back"),
            icon_file = getAssetPath("chevron-left.svg"),
            icon_size = sc(16),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_back_focused,
            bordersize = is_back_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(34),
            callback = close_cb,
        }
        table.insert(interactive_items, { callback = footer_back_btn.callback })

        local close_btn_idx = #interactive_items + 1
        local is_close_focused = (focus_visible and focused_row_idx == close_btn_idx)
        local footer_close_btn = createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_close_focused,
            bordersize = is_close_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(34),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
            end,
        }
        table.insert(interactive_items, { callback = footer_close_btn.callback })

        table.insert(content_vg, HorizontalGroup:new{
            align = "center",
            footer_back_btn,
            HorizontalSpan:new{ width = sc(8) },
            footer_close_btn,
        })

        -- Modal Container Card
        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card,
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if focused_row_idx and interactive_items[focused_row_idx] then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            close_cb()
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

--- Alias showMainMenu directly to the clean Beeline Main Screen
function M.showMainMenu(plugin_instance)
    return M.showMainDialog(plugin_instance)
end

local function openFolderLocation(folder_path, focused_file)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return false end
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance then
        pcall(function() ReaderUI.instance:onClose() end)
    end
    if FileManager.instance then
        if FileManager.instance.file_chooser and FileManager.instance.file_chooser.changeToPath then
            FileManager.instance.file_chooser:changeToPath(folder_path, focused_file)
        end
        UIManager:setDirty(FileManager.instance, "ui")
    else
        FileManager:showFiles(folder_path, focused_file)
    end
    return true
end

local _failed_acsm_paths = {}

local function findUnfulfilledAcsmFiles(inbox_dir)
    local unfulfilled = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs or not lfs.dir then return unfulfilled end

    local ok_drm, DRM = pcall(require, plugin_path .. "beeline_drm")

    pcall(function()
        for entry in lfs.dir(inbox_dir) do
            if entry ~= "." and entry ~= ".." and entry:lower():match("%.acsm$") then
                local full_path = inbox_dir .. "/" .. entry
                if not _failed_acsm_paths[full_path] then
                    local attr = lfs.attributes(full_path)
                    if attr and attr.mode == "file" then
                        local should_fulfill = true
                        if not State.getDrmDeleteAcsmAfter() and ok_drm and DRM and DRM.parseAcsmMetadata and DRM.deriveFinalBookPath then
                            local meta = DRM.parseAcsmMetadata(full_path)
                            if meta then
                                local book_path = DRM.deriveFinalBookPath(inbox_dir, meta)
                                local bf = io.open(book_path, "r")
                                if bf then
                                    bf:close()
                                    should_fulfill = false
                                end
                            end
                        end

                        if should_fulfill then
                            table.insert(unfulfilled, {
                                path = full_path,
                                filename = entry,
                                size = attr.size or 0,
                                is_existing_acsm = true,
                            })
                        end
                    end
                end
            end
        end
    end)
    return unfulfilled
end

-- ---------------------------------------------------------------------------
-- File Manager & Download Notification Helpers
-- ---------------------------------------------------------------------------

-- Update the KOReader File Manager view if currently browsing the inbox folder.
local function refreshFileManager(inbox_dir)
    if not inbox_dir or inbox_dir == "" then return end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager or not FileManager.instance then return end
    local fc = FileManager.instance.file_chooser
    if not fc or not fc.path then return end

    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    local function norm(p)
        if not p then return "" end
        p = (ok_fu and ffiUtil and ffiUtil.realpath and ffiUtil.realpath(p)) or p
        return (p:gsub("/+$", ""))
    end

    if norm(fc.path) == norm(inbox_dir) then
        pcall(function() fc:refreshPath() end)
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager then
            pcall(function() UIManager:forceRePaint() end)
        end
    end
end
M.refreshFileManager = refreshFileManager

-- Show a brief, nicely styled toast matching Libbee card & pill UX.
local function showDownloadToast(msg, timeout, icon, title)
    return M.showToast(msg, timeout or 3, icon or "download", title)
end
M.showDownloadToast = showDownloadToast

-- ---------------------------------------------------------------------------
-- File Retrieval Routine
-- ---------------------------------------------------------------------------

function M.receiveFiles(plugin_instance, is_background, on_done)
    local pairing_code = State.getPairingCode()
    local worker_url = State.getWorkerUrl()
    local inbox_dir = State.getInboxDir()
    local device_id = State.getDeviceId()
    local active_codes = State.getActiveCodes()

    if pairing_code == "" or worker_url == "" then
        if not is_background then
            M.showCardDialog{
                title = _("Configuration Required"),
                body_text = _("Please configure your Pairing Code and Worker URL in Beeline Settings before checking for files."),
                buttons = {
                    {
                        text = _("OK"),
                        is_primary = true,
                        callback = function()
                            if on_done then on_done(false) end
                        end,
                    },
                },
                on_close = function()
                    if on_done then on_done(false) end
                end,
            }
        else
            if on_done then on_done(false) end
        end
        return
    end

    M._receive_in_progress = true

    local prog_toast = nil
    if not is_background then
        prog_toast = M.showProgressToast(_("Checking Inbox"), _("Connecting to Beeline…"), "download", 0.05)
    end

    local function closeProgToast()
        if prog_toast then
            prog_toast:close()
            prog_toast = nil
        end
    end

    local function runReceiveBody()
        local query_ids = {}
        if device_id ~= "" then
            table.insert(query_ids, device_id)
        end
        local legacy_hash = Crypto.getDeviceHash(pairing_code)
        if legacy_hash and legacy_hash ~= device_id then
            table.insert(query_ids, legacy_hash)
        end

        local all_files = {}
        local fetch_err = nil
        for idx, dev_id in ipairs(query_ids) do
            local files, err = Client.fetchInbox(worker_url, dev_id)
            if files then
                for _, f in ipairs(files) do
                    table.insert(all_files, { meta = f, device_id = dev_id })
                end
            else
                fetch_err = err
            end
            if prog_toast then
                prog_toast:updateProgress(0.05 + 0.10 * (idx / math.max(1, #query_ids)))
            end
        end

        local pending_acsm = findUnfulfilledAcsmFiles(inbox_dir)

        if #all_files == 0 and #pending_acsm == 0 and fetch_err and not is_background then
            closeProgToast()
            M._receive_in_progress = nil
            M.showToast(_("Inbox check failed: %s", tostring(fetch_err)), 4)
            if on_done then on_done(false) end
            return
        end

        if #all_files == 0 and #pending_acsm == 0 then
            closeProgToast()
            M._receive_in_progress = nil
            if not is_background then
                M.showToast(_("No incoming files found."), 3)
            end
            if on_done then on_done(false) end
            return
        end

        ensureDir(inbox_dir)

        local received_items = {}
        local failed_count = 0

        for i, item_info in ipairs(all_files) do
            local file_meta = item_info.meta
            local dev_id = item_info.device_id
            local slice_start = 0.15 + 0.80 * ((i - 1) / #all_files)
            local slice_end = 0.15 + 0.80 * (i / #all_files)
            local slice_span = slice_end - slice_start

            local progress_cb = nil
            if prog_toast then
                local dl_msg = (#all_files > 1)
                    and _("Downloading file %d of %d…", i, #all_files)
                    or _("Downloading file…")
                prog_toast:updateProgress(slice_start, dl_msg, _("Downloading Files"))
                local expected_size = tonumber(file_meta.size) or 0
                progress_cb = function(bytes)
                    if not prog_toast then return end
                    local dl_frac
                    if expected_size > 0 then
                        dl_frac = math.min(1, bytes / expected_size)
                    else
                        dl_frac = bytes / (bytes + 1024 * 1024)
                    end
                    prog_toast:updateProgress(slice_start + (0.85 * slice_span * dl_frac))
                end
            end

            local envelope = Client.downloadFile(worker_url, dev_id, file_meta.id, progress_cb)
            if envelope then
                if prog_toast then
                    local dec_msg = (#all_files > 1)
                        and _("Decrypting file %d of %d…", i, #all_files)
                        or _("Decrypting file…")
                    prog_toast:updateProgress(slice_start + (0.85 * slice_span), dec_msg)
                end
                local decrypted = nil
                local dec_err = nil
                for _, code_cand in ipairs(active_codes) do
                    local dec, err = Crypto.decryptEnvelope(envelope, code_cand)
                    if dec and dec.data then
                        decrypted = dec
                        State.addPairedBrowser(code_cand)
                        break
                    else
                        dec_err = err
                    end
                end

                if decrypted and decrypted.data then
                    local filename = sanitizeFilename(decrypted.metadata.filename)
                    local target_path = inbox_dir .. "/" .. filename

                    -- Avoid overwrite by appending counter if needed
                    local counter = 1
                    while true do
                        local f = io.open(target_path, "r")
                        if not f then break end
                        f:close()
                        local base, ext = filename:match("^(.+)(%..+)$")
                        base = base or filename
                        ext = ext or ""
                        target_path = string.format("%s/%s (%d)%s", inbox_dir, base, counter, ext)
                        counter = counter + 1
                    end

                    local out_f = io.open(target_path, "wb")
                    if out_f then
                        local write_ok = out_f:write(decrypted.data)
                        if write_ok and out_f.flush then
                            local fl_ok = out_f:flush()
                            if fl_ok == false then write_ok = false end
                        end
                        local close_ok = out_f:close()
                        if close_ok == false then write_ok = false end
                        if not write_ok then
                            pcall(os.remove, target_path)
                            failed_count = failed_count + 1
                        else
                            -- Delete remote copy only after verified local write
                            Client.deleteRemoteFile(worker_url, dev_id, file_meta.id)

                            local is_acsm_file = (filename:lower():match("%.acsm$") ~= nil)
                            table.insert(received_items, {
                                path = target_path,
                                filename = filename,
                                size = #decrypted.data,
                                is_book = not is_acsm_file,
                            })

                            -- If receiving multiple files in background, show progress toast like Calibre
                            if is_background and #all_files > 1 then
                                showDownloadToast(_("Received file %d of %d:\n%s", #received_items, #all_files, filename), 2, "download", _("Incoming Transfer"))
                            end
                        end
                    else
                        failed_count = failed_count + 1
                    end
                else
                    logger.warn("Beeline: decryption error: " .. tostring(dec_err))
                    failed_count = failed_count + 1
                end
            else
                failed_count = failed_count + 1
            end

            if prog_toast then
                prog_toast:updateProgress(slice_end)
            end
        end

    -- Also process any unfulfilled .acsm files present in the inbox
    local seen_paths = {}
    for _, it in ipairs(received_items) do
        seen_paths[it.path] = true
    end
    for _, p_item in ipairs(pending_acsm) do
        if not seen_paths[p_item.path] then
            table.insert(received_items, p_item)
            seen_paths[p_item.path] = true
        end
    end

    if #received_items > 0 then
        -- Run autoclean pass whenever files are processed
        pcall(function()
            local ok_clean, Autoclean = pcall(require, plugin_path .. "beeline_autoclean")
            if ok_clean and Autoclean then
                Autoclean.cleanExpiredBooks()
            end
        end)
    end

    local acsm_total = 0
    for _, it in ipairs(received_items) do
        if (it.filename or ""):lower():match("%.acsm$") then
            acsm_total = acsm_total + 1
        end
    end

    if acsm_total == 0 and prog_toast then
        prog_toast:updateProgress(1.0)
    end
    closeProgToast()

    -- Process ACSM fulfillments
    local CURRENT_CONSENT_VERSION = 1
    local consent_version = State.getDrmConsentVersion() or 0
    local has_consent = (consent_version >= CURRENT_CONSENT_VERSION)

    local function handleFulfillment(item, on_item_done, acsm_idx)
        local is_acsm = (item.filename or ""):lower():match("%.acsm$") ~= nil
        if not is_acsm then
            return on_item_done(item)
        end

        local ok_drm, DRM = pcall(require, plugin_path .. "beeline_drm")
        if not ok_drm or not DRM then
            return on_item_done(item)
        end

        local meta = DRM.parseAcsmMetadata(item.path)
        local final_path = DRM.deriveFinalBookPath(inbox_dir, meta)

        local function doFulfill()
            local book_label = (meta and meta.title and meta.title ~= "" and meta.title) or item.filename
            local fulfill_title = (acsm_total > 1)
                and _("Fulfilling Loan (%d/%d)", acsm_idx or 1, acsm_total)
                or _("Fulfilling Loan")
            local fulfill_toast = M.showProgressToast(fulfill_title, book_label, "download", 0.05)

            local function onFulfillProgress(stage_or_bytes)
                if not fulfill_toast then return true end
                if type(stage_or_bytes) == "string" then
                    if stage_or_bytes == "auth" then
                        fulfill_toast:updateProgress(0.15)
                    elseif stage_or_bytes == "license" then
                        fulfill_toast:updateProgress(0.25)
                    elseif stage_or_bytes == "fulfill" then
                        fulfill_toast:updateProgress(0.35)
                    elseif stage_or_bytes == "decrypt" then
                        fulfill_toast:updateProgress(0.90)
                    elseif stage_or_bytes == "finalize" then
                        fulfill_toast:updateProgress(0.96)
                    end
                elseif type(stage_or_bytes) == "number" then
                    -- Map downloaded bytes smoothly across 35% -> 85%
                    local dl_frac = stage_or_bytes / (stage_or_bytes + 2 * 1024 * 1024)
                    fulfill_toast:updateProgress(0.35 + (0.50 * dl_frac))
                end
                return true
            end

            UIManager:nextTick(function()
                local call_ok, ok_f, fulfill_res, extra_tracked = pcall(DRM.fulfillAcsm, item.path, final_path, onFulfillProgress)
                if not call_ok then
                    logger.warn("Beeline: DRM.fulfillAcsm error: " .. tostring(ok_f))
                    fulfill_res = tostring(ok_f)
                    ok_f = false
                end
                if fulfill_toast then
                    fulfill_toast:updateProgress(1.0)
                    fulfill_toast:close()
                    fulfill_toast = nil
                end
                if ok_f and fulfill_res then
                    local exp = DRM.extractLoanExpiry(meta or item.path, extra_tracked and extra_tracked.license_token_xml)
                    if meta and meta.creator and meta.creator ~= "" then
                        extra_tracked = extra_tracked or {}
                        extra_tracked.author = meta.creator
                    end
                    State.trackBook(final_path, exp, meta and meta.title, extra_tracked)

                    if State.getDrmDeleteAcsmAfter() then
                        pcall(os.remove, item.path)
                    end

                    local fulfilled_item = {
                        path = final_path,
                        filename = final_path:match("[^/]+$") or item.filename,
                        size = 0,
                        is_fulfilled = true,
                    }
                    local f = io.open(final_path, "rb")
                    if f then
                        fulfilled_item.size = f:seek("end") or 0
                        f:close()
                    end

                    if is_background then
                        local book_title = (meta and meta.title) or fulfilled_item.filename
                        showDownloadToast(book_title, 3, "check", _("Book Fulfilled"))
                    end
                    on_item_done(fulfilled_item)
                else
                    _failed_acsm_paths[item.path] = true
                    local is_expired = type(fulfill_res) == "string" and fulfill_res:find("E_ADEPT_REQUEST_EXPIRED") ~= nil
                    if fulfill_res == "ALREADY_FULFILLED" then
                        if State.getDrmDeleteAcsmAfter() then
                            pcall(os.remove, item.path)
                        else
                            pcall(os.rename, item.path, item.path .. ".consumed")
                        end

                        if not is_background then
                            M.showCardDialog{
                                title = _("ACSM Already Fulfilled"),
                                body_text = _("This loan was already fulfilled by another user or device.\n(E_LIC_ALREADY_FULFILLED_BY_ANOTHER_USER)\n\nThe single-use token has been consumed and will not be re-checked."),
                                buttons = { { text = _("OK"), is_primary = true, callback = function() end } }
                            }
                        else
                            showDownloadToast(_("Token was already fulfilled on another device."), 4, "info", _("ACSM Already Claimed"))
                        end
                        item.is_error = "ALREADY_FULFILLED"
                    elseif is_expired then
                        pcall(os.rename, item.path, item.path .. ".expired")
                        local title_str = (meta and meta.title) or item.filename
                        if not is_background then
                            M.showCardDialog{
                                title = _("Loan Token Expired"),
                                body_text = _("The loan token for '%s' has expired.\n\nPlease open Libby or your library website and click 'Download EPUB' again to generate a fresh token.", title_str),
                                buttons = { { text = _("OK"), is_primary = true, callback = function() end } }
                            }
                        else
                            showDownloadToast(_("%s\nPlease download fresh token from Libby.", title_str), 5, "info", _("Loan Token Expired"))
                        end
                        item.is_error = "EXPIRED"
                    else
                        logger.warn("ACSM fulfillment error: " .. tostring(fulfill_res))
                        local title_str = (meta and meta.title) or item.filename
                        if not is_background then
                            M.showCardDialog{
                                title = _("ACSM Fulfillment Failed"),
                                body_text = _("Could not fulfill loan book:\n%s", tostring(fulfill_res)),
                                buttons = { { text = _("OK"), is_primary = true, callback = function() end } }
                            }
                        else
                            showDownloadToast(_("%s\n%s", title_str, tostring(fulfill_res):sub(1, 80)), 4, "x", _("Fulfillment Failed"))
                        end
                        item.is_error = "FAILED"
                    end
                    on_item_done(item)
                end
            end)
        end

        if not has_consent then
            if is_background then
                -- Defer fulfillment until consent is given in UI
                M.showToast(_("Loan token received. Open Beeline in Tools menu to fulfill."), 4)
                return on_item_done(item)
            end

            M.showCardDialog{
                title = _("ACSM Book Fulfillment"),
                body_text = _("Beeline can fulfill your library loans and purchased books on-device into EPUB or PDF.\n\n• For your personal use and your own loans/purchases only.\n• Fulfills directly on-device using Adobe / ByteBooks ADEPT protocols.\n• Expired loans are automatically cleaned up 1 day after expiry.\n\nDo you want to enable on-device ACSM fulfillment?"),
                buttons = {
                    {
                        text = _("Decline"),
                        is_primary = false,
                        callback = function()
                            on_item_done(item)
                        end,
                    },
                    {
                        text = _("Accept"),
                        is_primary = true,
                        callback = function()
                            State.setDrmConsentVersion(CURRENT_CONSENT_VERSION)
                            has_consent = true
                            doFulfill()
                        end,
                    },
                },
                on_close = function()
                    on_item_done(item)
                end,
            }
        else
            doFulfill()
        end
    end

    local finishReceiveUi
    finishReceiveUi = function(items_to_show)
        M._receive_in_progress = nil
        -- Separate successful books from unfulfilled tokens and errors
        local successful_books = {}
        for _, it in ipairs(items_to_show) do
            local is_acsm = (it.filename or ""):lower():match("%.acsm$") ~= nil
            if it.is_fulfilled or (not is_acsm and not it.is_error) then
                table.insert(successful_books, it)
            end
        end

        -- Ensure file manager shows latest changes if any books were received
        if #successful_books > 0 then
            refreshFileManager(inbox_dir)
        end

        if is_background then
            if #successful_books == 1 then
                local item = successful_books[1]
                local clean_name = item.title or item.filename:gsub("%.%w+$", "")
                if not item.is_fulfilled then
                    showDownloadToast(clean_name, 3, "download", _("Downloaded to Library"))
                end
            elseif #successful_books > 1 then
                showDownloadToast(_("%d books added to your library", #successful_books), 3.5, "download", _("Downloaded to Library"))
            end
            if on_done then on_done(false) end
            return
        end

        if #successful_books == 1 then
            local item = successful_books[1]
            local is_acsm = (item.filename or ""):lower():match("%.acsm$") ~= nil
            local action_text = (is_acsm and not item.is_fulfilled) and _("Open Folder") or _("Open Now")
            local prompt_str = (is_acsm and not item.is_fulfilled) and _("Would you like to open the destination folder?") or _("Would you like to open it now?")
            local title_str = item.is_fulfilled and _("Book Fulfilled!") or _("File Received!")
            M.showCardDialog{
                title = title_str,
                body_text = string.format("Book: %s\nSize: %s\nSaved to: %s\n\n%s",
                    item.title or item.filename,
                    formatBytes(item.size),
                    inbox_dir,
                    prompt_str
                ),
                buttons = {
                    {
                        text = _("Keep in Inbox"),
                        is_primary = false,
                        callback = function()
                            if on_done then on_done(false) end
                        end,
                    },
                    {
                        text = action_text,
                        is_primary = true,
                        callback = function()
                            if on_done then on_done(true) end
                            if is_acsm and not item.is_fulfilled then
                                openFolderLocation(inbox_dir, item.filename)
                            else
                                local ReaderUI = require("apps/reader/readerui")
                                if ReaderUI and ReaderUI.showReader then
                                    ReaderUI:showReader(item.path)
                                end
                            end
                        end,
                    },
                },
                on_close = function()
                    if on_done then on_done(false) end
                end,
            }
        elseif #successful_books > 1 then
            local names = {}
            for _, it in ipairs(successful_books) do
                table.insert(names, "• " .. (it.title or it.filename) .. " (" .. formatBytes(it.size) .. ")")
            end
            M.showCardDialog{
                title = _("Received %d Books!", #successful_books),
                body_text = string.format("Saved to: %s\n\n%s", inbox_dir, table.concat(names, "\n")),
                buttons = {
                    {
                        text = _("Keep in Inbox"),
                        is_primary = false,
                        callback = function()
                            if on_done then on_done(false) end
                        end,
                    },
                    {
                        text = _("Open Folder"),
                        is_primary = true,
                        callback = function()
                            if on_done then on_done(true) end
                            openFolderLocation(inbox_dir)
                        end,
                    },
                },
                on_close = function()
                    if on_done then on_done(false) end
                end,
            }
        elseif failed_count > 0 and not is_background then
            M.showCardDialog{
                title = _("Decryption Failed"),
                body_text = _("Could not decrypt %d file(s).\nPlease make sure your pairing code matches the one entered on your phone or PC.", failed_count),
                buttons = {
                    {
                        text = _("OK"),
                        is_primary = true,
                        callback = function()
                            if on_done then on_done(false) end
                        end,
                    },
                },
                on_close = function()
                    if on_done then on_done(false) end
                end,
            }
        else
            if on_done then on_done(false) end
        end
    end

    local acsm_seen = 0
    local function processNextItem(idx, processed_list)
        if idx > #received_items then
            -- Done processing all items
            return finishReceiveUi(processed_list)
        end
        local item = received_items[idx]
        local is_acsm = (item.filename or ""):lower():match("%.acsm$") ~= nil
        if is_acsm then
            acsm_seen = acsm_seen + 1
        end
        handleFulfillment(item, function(res_item)
            table.insert(processed_list, res_item)
            processNextItem(idx + 1, processed_list)
        end, acsm_seen)
    end

    return processNextItem(1, {})
    end

    if not is_background and UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            local ok_body, body_err = pcall(runReceiveBody)
            if not ok_body then
                logger.warn("Beeline: receiveFiles error: " .. tostring(body_err))
                closeProgToast()
                M._receive_in_progress = nil
                M.showToast(_("Inbox check failed: %s", tostring(body_err)), 4)
                if on_done then on_done(false) end
            end
        end)
    else
        local ok_body, body_err = pcall(runReceiveBody)
        if not ok_body then
            logger.warn("Beeline: receiveFiles error: " .. tostring(body_err))
            closeProgToast()
            M._receive_in_progress = nil
            if not is_background then
                M.showToast(_("Inbox check failed: %s", tostring(body_err)), 4)
            end
            if on_done then on_done(false) end
        end
    end
end

return M
