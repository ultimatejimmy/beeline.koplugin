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
}

function BeelineToastWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_toast_w = math.min(sw - sc(32), sc(460))

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
        table.insert(text_items, TextWidget:new{
            text = self.title,
            face = Font:getFace("cfont", theme.face_label_size or 16),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_toast_w - sc(72),
        })
        table.insert(text_items, VerticalSpan:new{ width = sc(3) })
    end

    table.insert(text_items, TextBoxWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", (self.title and self.title ~= "") and ((theme.face_label_size or 16) - 2) or (theme.face_label_size or 16)),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_toast_w - sc(72),
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

    local card = FrameContainer:new{
        padding = sc(10),
        padding_left = sc(16),
        padding_right = sc(18),
        radius = theme.radius_toast or sc(8),
        bordersize = theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        row,
    }

    local toast_w = math.min(card:getSize().w, max_toast_w)
    local toast_h = card:getSize().h
    local toast_y = sc(24)

    -- Full-screen container with centered alignment guarantees horizontal centering across all screen sizes
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = VerticalGroup:new{
        align = "center",
        RectSpan:new{ width = sw, height = toast_y },
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
                local ok, success, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
                if ok and success and type(parsed) == "table" and parsed.claimed then
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

        -- Live poll while QR dialog is open to detect when claimed by browser
        local checkClaimed
        checkClaimed = function()
            if not overlay then return end
            if current_code ~= "" and worker_url ~= "" then
                local c_hash = Crypto.getCodeHash(current_code)
                if c_hash then
                    local ok, success, parsed = pcall(Client.checkPairingCode, worker_url, c_hash)
                    if ok and success and type(parsed) == "table" and parsed.claimed then
                        State.addPairedBrowser(current_code)
                        M.showToast(_("✓ Browser paired! Code used."), 3)
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
        scale_factor = 0,
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

function M.showMainDialog(plugin_instance, on_close_cb)
    _dismissActiveToast()
    local s = State.loadSettings()
    local pairing_code = State.getPairingCode()
    local worker_url = s.worker_url or State.DEFAULT_WORKER_URL
    local device_id = State.getDeviceId()

    -- Register pairing code and device in background
    if pairing_code ~= "" and worker_url ~= "" and device_id ~= "" then
        local code_hash = Crypto.getCodeHash(pairing_code)
        if code_hash then
            local ok, success, parsed = pcall(Client.registerPairingCode, worker_url, code_hash, device_id)
            if ok and success and type(parsed) == "table" and parsed.claimed then
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

        -- Title Header with Settings and Close Feather Icons
        local title_label = TextWidget:new{
            text = _("Beeline"),
            face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
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

        local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(100)
        local icons_w = sc(74)
        local title_row = HorizontalGroup:new{
            title_label,
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

        -- Live background polling for claim
        local checkClaimed
        checkClaimed = function()
            if not overlay then return end
            if current_code ~= "" and worker_url ~= "" then
                local c_hash = Crypto.getCodeHash(current_code)
                if c_hash then
                    local ok, success, parsed = pcall(Client.checkPairingCode, worker_url, c_hash)
                    if ok and success and type(parsed) == "table" and parsed.claimed then
                        M.showToast(_("✓ Browser paired! Code used."), 3)
                        local fresh = State.regeneratePairingCode()
                        local dev_id = State.getDeviceId()
                        local fresh_hash = Crypto.getCodeHash(fresh)
                        if fresh_hash and dev_id ~= "" then
                            pcall(Client.registerPairingCode, worker_url, fresh_hash, dev_id)
                        end
                        refresh()
                        return
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
                            input = acct_info.email or "",
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
                                        callback = function()
                                            local email = email_dlg:getInputText():gsub("^%s*(.-)%s*$", "%1")
                                            UIManager:close(email_dlg)
                                            if email == "" then return end

                                            local pass_dlg
                                            pass_dlg = InputDialog:new{
                                                title = _("ByteBooks Password"),
                                                input = "",
                                                type = "password",
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
                                                                            M.showCardDialog{
                                                                                title = _("Authorization Failed"),
                                                                                body_text = _("Could not activate ByteBooks account:\n%s", tostring(err)),
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
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(email_dlg)
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
                body_text = string.format("Account Mode: %s\nEmail: %s\nDevice Serial: %s\n\nAnonymous mode fulfills loans using a unique on-device ADEPT identity.\nByteBooks mode allows using your ByteBooks / Adobe ID credentials (passwords are never saved).",
                    acct_info.mode:upper(),
                    acct_info.email ~= "" and acct_info.email or "(none)",
                    acct_info.serial ~= "" and acct_info.serial or "(generated on first loan)"
                ),
                buttons = buttons
            }
        end

        table.insert(content_vg, create_setting_row(_("ACSM Account Mode"), mode_right, showDrmAccountDialog))

        -- Default Loan Days Row
        local loan_days = State.getDrmDefaultLoanDays()
        local loan_days_right = TextWidget:new{
            text = _("%d days ›", loan_days),
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Default Loan Expiry"), loan_days_right, function()
            local days_dlg
            days_dlg = InputDialog:new{
                title = _("Default Loan Duration (Days)"),
                input = tostring(loan_days),
                type = "number",
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(days_dlg) end,
                        },
                        {
                            text = _("Save"),
                            is_primary = true,
                            callback = function()
                                local d = tonumber(days_dlg:getInputText())
                                if d and d > 0 and d <= 365 then
                                    State.setDrmDefaultLoanDays(d)
                                    UIManager:close(days_dlg)
                                    refresh()
                                else
                                    M.showToast(_("Please enter a valid number of days (1-365)"), 3)
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(days_dlg)
        end))

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

    local status_toast = nil
    if not is_background then
        status_toast = M.showToast(_("🐝 Checking Beeline inbox…"), 0)
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

    local pending_acsm = findUnfulfilledAcsmFiles(inbox_dir)

    if #all_files == 0 and #pending_acsm == 0 and fetch_err and not is_background then
        M.showToast(_("Inbox check failed: %s", tostring(fetch_err)), 4)
        if on_done then on_done(false) end
        return
    end

    if #all_files == 0 and #pending_acsm == 0 then
        if not is_background then
            M.showToast(_("No incoming files found."), 3)
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
                    out_f:write(decrypted.data)
                    out_f:close()

                    -- Delete remote copy
                    Client.deleteRemoteFile(worker_url, dev_id, file_meta.id)

                    local is_acsm_file = (filename:lower():match("%.acsm$") ~= nil)
                    table.insert(received_items, {
                        path = target_path,
                        filename = filename,
                        size = #decrypted.data,
                        is_book = not is_acsm_file,
                    })

                    -- Update file manager immediately if it's a real book
                    if not is_acsm_file then
                        refreshFileManager(inbox_dir)
                    end

                    -- If receiving multiple files in background, show progress toast like Calibre
                    if is_background and #all_files > 1 then
                        showDownloadToast(_("Received file %d of %d:\n%s", #received_items, #all_files, filename), 2, "download", _("Incoming Transfer"))
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

    -- Process ACSM fulfillments
    local CURRENT_CONSENT_VERSION = 1
    local consent_version = State.getDrmConsentVersion() or 0
    local has_consent = (consent_version >= CURRENT_CONSENT_VERSION)

    local function handleFulfillment(item, on_item_done)
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
            if not is_background then
                M.showToast(_("Fulfilling %s...", meta and meta.title or item.filename), 3)
            end

            UIManager:nextTick(function()
                local ok_f, fulfill_res, extra_tracked = DRM.fulfillAcsm(item.path, final_path)
                if ok_f and fulfill_res then
                    local exp = DRM.extractLoanExpiry(meta or item.path)
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

                    -- Update file manager immediately so fulfilled book appears right away
                    refreshFileManager(inbox_dir)

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

    local function processNextItem(idx, processed_list)
        if idx > #received_items then
            -- Done processing all items
            return finishReceiveUi(processed_list)
        end
        handleFulfillment(received_items[idx], function(res_item)
            table.insert(processed_list, res_item)
            processNextItem(idx + 1, processed_list)
        end)
    end

    return processNextItem(1, {})
end

return M
