local ok_loc, Localization = pcall(require, "localization_beeline")
if ok_loc and Localization then
    Localization:ensureInit()
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

return {
    name        = "beeline",
    fullname    = "Beeline",
    description = _("Send ebook files and ACSM tokens wirelessly and securely to KOReader."),
    version     = "1.1.0",
    author      = "Beeline",
    license     = "GPLv3",
}
