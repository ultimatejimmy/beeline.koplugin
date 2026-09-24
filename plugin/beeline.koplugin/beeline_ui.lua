-- beeline_ui.lua — User Interface for Beeline (Libbee Storefront Card Design)
-- Follows the Libbee UI style guide: high contrast, rounded geometry, e-ink optimized.

local UIManager       = require("ui/uimanager")
local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Button          = require("ui/widget/button")
local ImageWidget     = require("ui/widget/imagewidget")
local InputDialog     = require("ui/widget/inputdialog")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")

local plugin_path     = ((...) or ""):match("(.-)[^%.]+$") or ""
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
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, dir)
    end
    pcall(os.execute, "mkdir -p " .. dir .. " 2>/dev/null")
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
    text = "",
    timeout = 3,
    dismissable = true,
}

function BeelineToastWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_toast_w = math.min(sw - sc(32), sc(440))

    local icon = ImageWidget:new{
        file = getAssetPath("info.svg"),
        width = sc(22),
        height = sc(22),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local label = TextBoxWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", theme.face_label_size or 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_toast_w - sc(70),
        alignment = "left",
    }
    self.label_widget = label

    local row = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = sc(12) },
        label,
    }

    local card = FrameContainer:new{
        padding = sc(12),
        padding_left = sc(16),
        padding_right = sc(16),
        radius = theme.radius_toast or sc(4),
        bordersize = theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        row,
    }

    self.dimen = Geom:new{ w = sw, h = sh }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        card,
    }

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

function M.showToast(msg, timeout)
    _dismissActiveToast()
    local toast = BeelineToastWidget:new{
        text = msg,
        timeout = timeout or 3,
    }
    _active_toast = toast
    UIManager:show(toast, "ui")
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
    local dialog_w = opts.width or math.min(sw - sc(20), sc(400))
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

function M.showQRCodeDialog(pairing_code, worker_url, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    pairing_code = pairing_code or s.pairing_code or ""
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
            local code_hash = Crypto.getCodeHash(current_code)
            if code_hash then
                local ok, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
                if ok and parsed and parsed.claimed then
                    -- Already claimed! Rotate right now
                    local fresh = State.regeneratePairingCode()
                    refresh_qr(fresh)
                    return
                end
            end
            pcall(Client.registerPairing, worker_url, device_id)
        end

        local content_items = {}

        -- Title
        local title_label = TextWidget:new{
            text = "Scan to Pair",
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
                text = "QR code unavailable.\nPlease open in browser:\n" .. pair_url,
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
                text = "Code: " .. current_code,
                face = Font:getFace("cfont", 18),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        })
        table.insert(content_items, VerticalSpan:new{ width = sc(2) })

        local sec_left = State.getCodeSecondsRemaining()
        local min_left = math.ceil(sec_left / 60)
        local time_str = (sec_left > 0) and string.format("Code valid for %d min • Once paired, stays connected", min_left) or "Code expired — tap New Code"

        -- Instruction text
        table.insert(content_items, TextBoxWidget:new{
            text = "Scan with your phone camera to pair instantly.\n" .. time_str,
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
            text = "↻  New Code",
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
                M.showToast("New pairing code: " .. new_code, 2)
                refresh_qr(new_code)
            end,
        }

        local close_btn = createButton{
            text = "Close",
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

        -- Live poll while QR dialog is open to detect when claimed by browser
        local checkClaimed
        checkClaimed = function()
            if not overlay then return end
            if current_code ~= "" and worker_url ~= "" then
                local c_hash = Crypto.getCodeHash(current_code)
                if c_hash then
                    local ok, parsed = pcall(Client.checkPairingCode, worker_url, c_hash)
                    if ok and parsed and parsed.claimed then
                        M.showToast("✓ Browser paired! Code used.", 3)
                        local fresh = State.regeneratePairingCode()
                        refresh_qr(fresh)
                        return
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
-- Main Settings Card (Libbee Storefront Single-View Dialog)
-- ---------------------------------------------------------------------------

function M.showSettingsDialog(plugin_instance, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    local pairing_code = State.getPairingCode()
    local worker_url = s.worker_url or State.DEFAULT_WORKER_URL
    local device_id = State.getDeviceId()

    -- Register pairing code and device in background
    if pairing_code ~= "" and worker_url ~= "" and device_id ~= "" then
        local code_hash = Crypto.getCodeHash(pairing_code)
        if code_hash then
            local ok, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
            if ok and parsed and parsed.claimed then
                pairing_code = State.regeneratePairingCode()
                local new_h = Crypto.getCodeHash(pairing_code)
                if new_h then
                    pcall(Client.registerPairingCode, worker_url, new_h, device_id)
                end
            end
        end
        pcall(Client.registerPairing, worker_url, device_id)
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(400))
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

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}
        s = State.loadSettings()

        local close_cb = function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            if on_close_cb then on_close_cb() end
        end

        -- Title Header with Feather Icon x.svg
        local title_label = TextWidget:new{
            text = "Beeline Settings",
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
            close_cb()
            return true
        end

        local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(160)
        local close_btn_w = sc(30)
        local title_row = HorizontalGroup:new{
            title_label,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_left_w - close_btn_w) },
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

        -- Top Action: Check for Files
        local check_btn_idx = #interactive_items + 1
        local is_check_focused = (focus_visible and focused_row_idx == check_btn_idx)
        local check_btn = createButton{
            text = "Check for Incoming Files",
            text_font_size = ui_font_size,
            bold = true,
            is_primary = true,
            is_focused = is_check_focused,
            bordersize = is_check_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(38),
            callback = function()
                M.receiveFiles(plugin_instance, false, function(opened_reader)
                    if opened_reader and overlay then
                        UIManager:close(overlay, "ui")
                        overlay = nil
                    end
                end)
            end,
        }
        table.insert(interactive_items, { callback = check_btn.callback })
        table.insert(content_vg, check_btn)
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
        -- SECTION 1: PAIRING CODE (Auto-generated, Not Editable)
        -- ===================================================================
        table.insert(content_vg, create_section_header("Device Pairing"))
        table.insert(content_vg, VerticalSpan:new{ width = sc(3) })

        local sec_left = State.getCodeSecondsRemaining()
        local min_left = math.ceil(sec_left / 60)
        local time_str = (sec_left > 0) and string.format("Valid for %d min • Browsers stay paired permanently", min_left) or "Code expired — generate new code"

        local code_instr = TextBoxWidget:new{
            text = "Enter code on phone/PC (hyphen optional):\n" .. time_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
            width = inner_w,
        }
        table.insert(content_vg, code_instr)
        table.insert(content_vg, VerticalSpan:new{ width = sc(5) })

        -- Styled Code Box (Storefront Card style, tap to open QR Code)
        local code_box_frame = FrameContainer:new{
            padding = sc(8),
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w - sc(20), h = sc(38) },
                TextWidget:new{
                    text = s.pairing_code or "[NONE]",
                    face = Font:getFace("cfont", 24),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            }
        }

        local code_box_item = InputContainer:new{ code_box_frame }
        code_box_item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = code_box_item.dimen or { x = 0, y = 0, w = inner_w, h = sc(54) }
                        return Geom:new{
                            x = dim.x or 0,
                            y = dim.y or 0,
                            w = (dim.w and dim.w > 0 and dim.w) or inner_w,
                            h = (dim.h and dim.h > 0 and dim.h) or sc(54),
                        }
                    end
                }
            }
        }
        code_box_item.onTap = function()
            M.showQRCodeDialog(s.pairing_code, s.worker_url, refresh)
            return true
        end
        table.insert(content_vg, code_box_item)
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        -- Buttons: Show QR Code & Generate New Code
        local btn_gap = sc(8)
        local half_btn_w = math.floor((inner_w - btn_gap) / 2)

        local qr_btn_idx = #interactive_items + 1
        local is_qr_focused = (focus_visible and focused_row_idx == qr_btn_idx)
        local qr_btn = createButton{
            text = "⛶  Show QR Code",
            text_font_size = theme.subtext_font_size or 14,
            bold = true,
            is_focused = is_qr_focused,
            bordersize = is_qr_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(32),
            callback = function()
                M.showQRCodeDialog(s.pairing_code, s.worker_url, refresh)
            end,
        }
        table.insert(interactive_items, { callback = qr_btn.callback })

        local gen_btn_idx = #interactive_items + 1
        local is_gen_focused = (focus_visible and focused_row_idx == gen_btn_idx)
        local gen_btn = createButton{
            text = "↻  Generate New",
            text_font_size = theme.subtext_font_size or 14,
            bold = false,
            is_focused = is_gen_focused,
            bordersize = is_gen_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = half_btn_w,
            height = sc(32),
            callback = function()
                local new_code = State.regeneratePairingCode()
                local device_id = State.getDeviceId()
                if s.worker_url ~= "" and device_id ~= "" then
                    local code_hash = Crypto.getCodeHash(new_code)
                    if code_hash then
                        pcall(Client.registerPairingCode, s.worker_url, code_hash, device_id)
                    end
                    pcall(Client.registerPairing, s.worker_url, device_id)
                end
                M.showToast("New pairing code generated: " .. new_code, 2)
                refresh()
            end,
        }
        table.insert(interactive_items, { callback = gen_btn.callback })

        table.insert(content_vg, HorizontalGroup:new{
            align = "center",
            qr_btn,
            HorizontalSpan:new{ width = btn_gap },
            gen_btn,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })

        -- Button: Disconnect All Browsers
        local active_count = #(State.getActiveCodes())
        local unpair_text = "Disconnect All Browsers"
        if active_count > 1 then
            unpair_text = string.format("Disconnect All Browsers (%d)", active_count)
        end
        local unpair_btn_idx = #interactive_items + 1
        local is_unpair_focused = (focus_visible and focused_row_idx == unpair_btn_idx)
        local unpair_btn = createButton{
            text = unpair_text,
            text_font_size = theme.subtext_font_size or 13,
            bold = false,
            is_focused = is_unpair_focused,
            bordersize = is_unpair_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(28),
            callback = function()
                M.showCardDialog{
                    title = "Disconnect All Browsers?",
                    body_text = "This will revoke all currently connected phones and computers. They will need a new pairing code to send books.",
                    buttons = {
                        {
                            text = "Cancel",
                            is_primary = false,
                        },
                        {
                            text = "Disconnect All",
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
                                M.showToast("All browsers disconnected. New code: " .. new_code, 3)
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

        -- ===================================================================
        -- SECTION 2: RELAY & STORAGE
        -- ===================================================================
        table.insert(content_vg, create_section_header("Relay & Storage"))

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
        table.insert(content_vg, create_setting_row("Worker URL", worker_right, function()
            local dialog
            dialog = InputDialog:new{
                title = "Cloudflare Worker URL",
                input = s.worker_url or "",
                description = "Enter full HTTPS endpoint of your Beeline Worker:",
                buttons = {
                    {
                        {
                            text = "Cancel",
                            id = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = "Test & Save",
                            is_primary = true,
                            is_enter_default = true,
                            callback = function()
                                local val = dialog:getInputText():gsub("[\r\n\t ]+", ""):gsub("/+$", "")
                                local ok, res = Client.ping(val)
                                if ok then
                                    State.setWorkerUrl(val)
                                    UIManager:close(dialog)
                                    M.showToast("Worker connection verified!", 3)
                                    refresh()
                                else
                                    M.showToast("Connection failed: " .. tostring(res), 4)
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
        end))

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
                        title = "Select Inbox Folder",
                        initial_path = s.inbox_dir,
                        fallback_path = G_reader_settings and G_reader_settings:readSetting("home_dir"),
                        on_confirm = function(chosen_path)
                            if chosen_path and chosen_path ~= "" then
                                State.setInboxDir(chosen_path)
                                M.showToast("Inbox folder set to " .. chosen_path, 2)
                            end
                            UIManager:nextTick(function()
                                M.showSettingsDialog(plugin_instance)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                M.showSettingsDialog(plugin_instance)
                            end)
                        end,
                    }
                end)
                if not ok then
                    logger.err("openFolderPicker error: " .. tostring(err))
                    M.showSettingsDialog(plugin_instance)
                end
            end)
        end
        table.insert(content_vg, create_setting_row("Destination Inbox", inbox_right, openFolderPicker))

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
        table.insert(content_vg, create_setting_row("Auto-Check on Wi-Fi", check_icon, function()
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
        table.insert(content_vg, create_setting_row("Background Sync (30s)", bg_check_icon, function()
            State.setBackgroundSync(not bg_enabled)
            if plugin_instance and plugin_instance.updateSyncSchedule then
                plugin_instance:updateSyncSchedule()
            end
            refresh()
        end))

        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Bottom Close Button
        local close_btn_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = close_cb })
        local is_close_focused = (focus_visible and focused_row_idx == close_btn_idx)

        local close_btn = createButton{
            text = "Close",
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_close_focused,
            bordersize = is_close_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = close_cb,
        }
        table.insert(content_vg, close_btn)

        -- Build Bounded Modal Card
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

--- Alias showMainMenu directly to the clean Beeline Settings Card
function M.showMainMenu(plugin_instance)
    return M.showSettingsDialog(plugin_instance)
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
                title = "Configuration Required",
                body_text = "Please configure your Pairing Code and Worker URL in Beeline Settings before checking for files.",
                buttons = {
                    {
                        text = "OK",
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

    local status_toast = nil
    if not is_background then
        status_toast = M.showToast("🐝 Checking Beeline inbox…", 0)
    end

    local dismissStatus = function()
        if status_toast then
            status_toast:close()
            status_toast = nil
        end
    end

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
    for _, dev_id in ipairs(query_ids) do
        local files, err = Client.fetchInbox(worker_url, dev_id)
        if files then
            for _, f in ipairs(files) do
                table.insert(all_files, { meta = f, device_id = dev_id })
            end
        else
            fetch_err = err
        end
    end

    dismissStatus()

    if #all_files == 0 and fetch_err and not is_background then
        M.showToast("Inbox check failed: " .. tostring(fetch_err), 4)
        if on_done then on_done(false) end
        return
    end

    if #all_files == 0 then
        if not is_background then
            M.showToast("No incoming files found.", 3)
        end
        if on_done then on_done(false) end
        return
    end

    ensureDir(inbox_dir)

    local received_items = {}
    local failed_count = 0

    for _, item_info in ipairs(all_files) do
        local file_meta = item_info.meta
        local dev_id = item_info.device_id
        local envelope = Client.downloadFile(worker_url, dev_id, file_meta.id)
        if envelope then
            local decrypted = nil
            local dec_err = nil
            for _, code_cand in ipairs(active_codes) do
                local dec, err = Crypto.decryptEnvelope(envelope, code_cand)
                if dec and dec.data then
                    decrypted = dec
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
                    out_f:write(decrypted.data)
                    out_f:close()

                    -- Delete remote copy
                    Client.deleteRemoteFile(worker_url, dev_id, file_meta.id)

                    table.insert(received_items, {
                        path = target_path,
                        filename = filename,
                        size = #decrypted.data,
                    })
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
    end

    if #received_items > 0 then
        -- Automatically rotate pairing code so the used pairing code cannot be claimed or displayed again
        local new_code = State.regeneratePairingCode()
        local dev_id = State.getDeviceId()
        if worker_url ~= "" and dev_id ~= "" then
            local new_hash = Crypto.getCodeHash(new_code)
            if new_hash then
                pcall(Client.registerPairingCode, worker_url, new_hash, dev_id)
            end
        end
    end

    if #received_items == 1 then
        local item = received_items[1]
        local is_acsm = (item.filename or ""):lower():match("%.acsm$") ~= nil
        local action_text = is_acsm and "Open Folder" or "Open Now"
        local prompt_str = is_acsm and "Would you like to open the destination folder?" or "Would you like to open it now?"
        M.showCardDialog{
            title = "File Received!",
            body_text = string.format("Book: %s\nSize: %s\nSaved to: %s\n\n%s",
                item.filename,
                formatBytes(item.size),
                inbox_dir,
                prompt_str
            ),
            buttons = {
                {
                    text = "Keep in Inbox",
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
                        if is_acsm then
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
    elseif #received_items > 1 then
        local names = {}
        for _, it in ipairs(received_items) do
            table.insert(names, "• " .. it.filename .. " (" .. formatBytes(it.size) .. ")")
        end
        M.showCardDialog{
            title = string.format("Received %d Files!", #received_items),
            body_text = string.format("Saved to: %s\n\n%s", inbox_dir, table.concat(names, "\n")),
            buttons = {
                {
                    text = "Keep in Inbox",
                    is_primary = false,
                    callback = function()
                        if on_done then on_done(false) end
                    end,
                },
                {
                    text = "Open Folder",
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
            title = "Decryption Failed",
            body_text = string.format("Could not decrypt %d file(s).\nPlease make sure your pairing code matches the one entered on your phone or PC.", failed_count),
            buttons = {
                {
                    text = "OK",
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

return M
