-- Localization Manager for Beeline Plugin (with .po support)

local logger = require("logger")
local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok or type(lfs) ~= "table" then
    ok, lfs = pcall(require, "lfs")
end
if not ok then
    logger.warn("Localization: lfs module not found!")
end

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
if plugin_path ~= "" then
    local path_to_dir = plugin_path:gsub("%.", "/")
    if not package.path:find(path_to_dir) then
        package.path = package.path .. ";" .. path_to_dir .. "?.lua"
    end
end

local Localization = {
    current_language = "en",
    translations = {},
    available_languages = {},
    path = "plugins/beeline.koplugin",
}

-- Simple .po file parser
function Localization:parsePO(filepath)
    local translations = {}
    local file = io.open(filepath, "r")
    
    if not file then
        logger.warn("Localization: Cannot open .po file:", filepath)
        return nil
    end
    
    local msgid = nil
    local msgstr = nil
    local in_msgid = false
    local in_msgstr = false
    
    for line in file:lines() do
        -- Strip trailing carriage returns and whitespace (e.g. CRLF from Windows)
        line = line:gsub("[\r\t ]+$", "")

        -- Skip comments and empty lines
        if not (line:match("^#") or line:match("^%s*$")) then
            -- Start of msgid
            if line:match('^msgid%s+"') then
                -- Save previous translation
                if msgid and msgstr then
                    translations[msgid] = msgstr
                end
                
                -- Use a greedy match so escaped quotes inside a msgid do not terminate early
                msgid = line:match('^msgid%s+"(.*)"$')
                msgstr = nil
                in_msgid = true
                in_msgstr = false
            
            -- Start of msgstr
            elseif line:match('^msgstr%s+"') then
                msgstr = line:match('^msgstr%s+"(.*)"$')
                in_msgid = false
                in_msgstr = true
            
            -- Continuation line
            elseif line:match('^"') then
                local continuation = line:match('^"(.-)"')
                if in_msgid and msgid then
                    msgid = msgid .. continuation
                elseif in_msgstr and msgstr then
                    msgstr = msgstr .. continuation
                end
            end
        end
    end
    
    -- Save last translation
    if msgid and msgstr then
        translations[msgid] = msgstr
    end
    
    file:close()
    
    -- Process escape sequences
    local function unescapePOString(str)
        if not str or type(str) ~= "string" then return str end
        local prev = str
        for _ = 1, 3 do
            local next_str = prev:gsub("\\(.)", function(c)
                if c == "n" then return "\n"
                elseif c == "t" then return "\t"
                elseif c == '"' then return '"'
                elseif c == "\\" then return "\\"
                else return c
                end
            end)
            if next_str == prev then break end
            prev = next_str
        end
        return prev
    end

    for key, value in pairs(translations) do
        local normalized_key = unescapePOString(key)
        local unescaped_val = unescapePOString(value)
        translations[normalized_key] = unescaped_val
        if normalized_key ~= key then
            translations[key] = nil
        end
    end
    
    return translations
end

local function resolveScriptDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:match("^@?(.*[/\\])") or "./"
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        dir = dir:sub(1, -2)
    end
    return dir:gsub("\\", "/")
end

-- Detect system language from KOReader settings or environment
function Localization:detectSystemLanguage()
    local lang = nil

    -- 1. Try reading KOReader global settings
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local ok_s, setting = pcall(function()
            return _G.G_reader_settings:readSetting("language") or _G.G_reader_settings:readSetting("lang")
        end)
        if ok_s and setting and type(setting) == "string" and #setting > 0 then
            lang = setting
        end
    end

    -- 2. Try KOReader gettext module
    if not lang then
        local ok_gt, gt = pcall(require, "gettext")
        if ok_gt and type(gt) == "table" then
            if type(gt.lang) == "string" and #gt.lang > 0 then
                lang = gt.lang
            elseif type(gt.language) == "string" and #gt.language > 0 then
                lang = gt.language
            end
        end
    end

    -- 3. Fall back to environment variables
    if not lang then
        local env_lang = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES")
        if env_lang and #env_lang > 0 then
            lang = env_lang:match("^([^%.@]+)") -- strip encoding like .UTF-8
        end
    end

    if not lang then
        return "en"
    end

    -- Normalize language code format (e.g. "zh_cn" -> "zh_CN", "pt-br" -> "pt_br")
    lang = lang:gsub("-", "_")
    
    -- Check exact match in available languages
    if self:languageExists(lang) then
        return lang
    end

    -- Try case normalization (e.g. "zh_cn" -> "zh_CN", "pt_BR" -> "pt_br")
    for _, code in ipairs(self.available_languages) do
        if code:lower() == lang:lower() then
            return code
        end
    end

    -- Try language prefix match (e.g. "es_ES" -> "es", "de_DE" -> "de", "fr_FR" -> "fr")
    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix then
        prefix = prefix:lower()
        if self:languageExists(prefix) then
            return prefix
        end
        for _, code in ipairs(self.available_languages) do
            if code:lower() == prefix then
                return code
            end
        end
    end

    return "en"
end

-- Initialize localization system
function Localization:init(path)
    logger.info("Localization: Initializing Beeline localization...")
    
    if path then
        self.path = path:gsub("\\", "/")
    else
        self.path = resolveScriptDir()
    end
    self.initialized = true
    
    self:discoverLanguages()
    
    -- Detect KOReader system language
    self.current_language = self:detectSystemLanguage()
    
    -- Load translation file
    self:loadTranslations()
    
    logger.info("Localization: Initialized with system language:", self.current_language)
end

function Localization:ensureInit(path)
    if not self.initialized then
        self:init(path)
    elseif path then
        local norm_path = path:gsub("\\", "/")
        if norm_path ~= self.path and next(self.translations) == nil then
            self:init(path)
        end
    end
end

-- Discover available .po files
function Localization:discoverLanguages()
    local lang_dir = self.path .. "/languages"
    self.available_languages = {}
    
    if not lfs then
        logger.warn("Localization: lfs not available, using fallback language discovery")
        self.available_languages = { "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja", "ko", "nl", "pl", "pt_br", "ru", "sk", "sr", "tr", "uk", "zh_CN" }
        return
    end

    local attr = lfs.attributes(lang_dir)
    if not attr or attr.mode ~= "directory" then
        logger.warn("Localization: Languages directory not found at:", lang_dir)
        -- Fallback to default list
        self.available_languages = { "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja", "ko", "nl", "pl", "pt_br", "ru", "sk", "sr", "tr", "uk", "zh_CN" }
        return
    end
    
    for file in lfs.dir(lang_dir) do
        if file:match("%.po$") then
            local lang_code = file:match("^(.+)%.po$")
            if lang_code then
                table.insert(self.available_languages, lang_code)
            end
        end
    end
    
    table.sort(self.available_languages)
    logger.info("Localization: Discovered", #self.available_languages, "languages")
end

-- Load translations from .po file
function Localization:loadTranslations()
    local po_file = self.path .. "/languages/" .. self.current_language .. ".po"
    logger.info("Localization: Loading translations from:", po_file)
    
    local translations = self:parsePO(po_file)
    
    if translations then
        self.translations = translations
        logger.info("Localization: Loaded", self:tableSize(translations), "translations")
    else
        logger.warn("Localization: Failed to load .po file:", po_file)
        if self.current_language ~= "en" then
            logger.info("Localization: Falling back to English master")
            self.current_language = "en"
            po_file = self.path .. "/languages/en.po"
            translations = self:parsePO(po_file)
            self.translations = translations or {}
        else
            self.translations = {}
        end
    end
end

-- Helper: count table size
function Localization:tableSize(t)
    local count = 0
    if t then
        for _ in pairs(t) do count = count + 1 end
    end
    return count
end

function Localization:languageExists(lang_code)
    for _, code in ipairs(self.available_languages) do
        if code == lang_code then return true end
    end
    return false
end

-- Fallback English map for strings in case .po file is missing or incomplete
local FALLBACKS = {
    -- Plugin Info & Menu
    plugin_description = "Send ebook files and ACSM tokens wirelessly and securely to KOReader.",
    menu_beeline = "Beeline",
    beeline_title = "Beeline",
    action_check_inbox = "Beeline: Check for Files",
    action_open_menu = "Beeline: Open Menu",
    action_qr_code = "Beeline: Scan to Pair (QR Code)",

    -- UI Header & Buttons
    btn_close = "Close",
    btn_back = "Back",
    btn_cancel = "Cancel",
    btn_ok = "OK",
    btn_save = "Save",
    btn_settings = "Settings",
    btn_new_code = "↻  New Code",
    btn_check_files = "Check for Incoming Files",
    btn_generate_new_code = "Generate New Code",
    btn_disconnect_all = "Disconnect All",
    btn_disconnect_all_browsers = "Disconnect All Browsers",
    btn_open_now = "Open Now",
    btn_open_folder = "Open Folder",
    btn_keep_in_inbox = "Keep in Inbox",
    btn_decline = "Decline",
    btn_accept = "Accept",
    btn_test_save = "Test & Save",
    btn_sign_in = "Sign In",
    btn_next = "Next",
    btn_deauthorize = "Deauthorize",

    -- Sections
    section_device_pairing = "Device Pairing",
    section_relay_storage = "Relay & Storage",
    section_library_loans = "Library Loans",
    section_connection = "Connection",

    -- Folder Picker
    picker_select_folder_title = "Select Download Folder",
    picker_select_inbox_title = "Select Inbox Folder",
    picker_new_folder = "New Folder",
    picker_create_subfolder = "Create subfolder in '%s':",
    picker_create = "Create",
    picker_created = "Created '%s'",
    picker_failed = "Failed to create folder.",
    picker_books_found = "%d books found in this folder",
    picker_parent_folder = ".. (Parent Folder)",
    picker_no_subfolders = "No subfolders in this directory.\nTap 'Select Folder' below to use it, or '+ New' to create a subfolder.",
    picker_folder = "Folder",
    picker_page_info = "Page %d of %d",
    picker_btn_new = "+ New",
    picker_btn_select = "Select Folder",
}

local KEY_ALIASES = {
    ["Beeline"] = "beeline_title",
    ["Close"] = "btn_close",
    ["Back"] = "btn_back",
    ["Cancel"] = "btn_cancel",
    ["OK"] = "btn_ok",
    ["Save"] = "btn_save",
    ["Settings"] = "btn_settings",
    ["Send ebook files and ACSM tokens wirelessly and securely to KOReader."] = "plugin_description",
    ["Beeline: Check for Files"] = "action_check_inbox",
    ["Beeline: Open Menu"] = "action_open_menu",
    ["Beeline: Scan to Pair (QR Code)"] = "action_qr_code",
    ["Select Download Folder"] = "picker_select_folder_title",
    ["Select Inbox Folder"] = "picker_select_inbox_title",
    ["New Folder"] = "picker_new_folder",
    ["Create subfolder in '%s':"] = "picker_create_subfolder",
    ["Create"] = "picker_create",
    ["Created '%s'"] = "picker_created",
    ["Failed to create folder."] = "picker_failed",
    ["%d books found in this folder"] = "picker_books_found",
    [".. (Parent Folder)"] = "picker_parent_folder",
    ["Folder"] = "picker_folder",
    ["Page %d of %d"] = "picker_page_info",
    ["+ New"] = "picker_btn_new",
    ["Select Folder"] = "picker_btn_select",
    ["Device Pairing"] = "section_device_pairing",
    ["Relay & Storage"] = "section_relay_storage",
    ["Library Loans"] = "section_library_loans",
    ["Connection"] = "section_connection",
    ["Check for Incoming Files"] = "btn_check_files",
    ["Generate New Code"] = "btn_generate_new_code",
    ["Disconnect All"] = "btn_disconnect_all",
    ["Open Now"] = "btn_open_now",
    ["Open Folder"] = "btn_open_folder",
    ["Keep in Inbox"] = "btn_keep_in_inbox",
    ["Decline"] = "btn_decline",
    ["Accept"] = "btn_accept",
    ["Test & Save"] = "btn_test_save",
    ["Sign In"] = "btn_sign_in",
    ["Next"] = "btn_next",
    ["Deauthorize"] = "btn_deauthorize",
}

-- Translate string key with formatting support
function Localization:t(key, ...)
    if key == "Beeline" or key == "menu_beeline" or key == "beeline_title" then
        return "Beeline"
    end
    self:ensureInit()
    local translation = self.translations[key]
    if (not translation or translation == "") and KEY_ALIASES[key] then
        translation = self.translations[KEY_ALIASES[key]]
    end
    
    if not translation or translation == "" then
        translation = FALLBACKS[key] or (KEY_ALIASES[key] and FALLBACKS[KEY_ALIASES[key]]) or key
    end
    
    local arg_count = select('#', ...)
    if arg_count > 0 then
        local args = {}
        for i = 1, arg_count do
            local arg = select(i, ...)
            args[i] = (arg == nil) and "???" or arg
        end
        
        -- Check if it contains positional arguments like %1$s or %2$d
        if translation:find("%%%d+%$") then
            local success, result = pcall(function()
                return string.gsub(translation, "%%(%d+)%$([-+ #0]?%d*%.?%d*[cdeEfgGiouuxXsqp%%])", function(index, spec)
                    local idx = tonumber(index)
                    local val = args[idx]
                    if val == nil then val = "???" end
                    if spec == "%" then return "%" end
                    return string.format("%" .. spec, val)
                end)
            end)
            if success then
                return result
            else
                logger.warn("Localization: Positional format error for key:", key)
                return translation
            end
        else
            local success, result = pcall(string.format, translation, (unpack or table.unpack)(args))
            if success then
                return result
            else
                logger.warn("Localization: Format error for key:", key)
                return translation
            end
        end
    end
    
    return translation
end

-- Global helper alias `_` (matching gettext pattern)
function Localization:getHelper()
    return function(key, ...)
        return self:t(key, ...)
    end
end

return Localization
