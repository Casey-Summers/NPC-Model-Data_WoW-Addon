local ADDON_NAME, T = ...
NPCDataViewerOptions = {}

-- Default settings
local defaults = {
    autoRotate = false,
    showDecorations = true,
    removeUnused = false,
    excludeUnusedFromSuggestions = true,
    hideHints = false,
    hideNav = false,
}

function NPCDataViewerOptions:GetSettings()
    if not NPCDataViewerDB then NPCDataViewerDB = {} end
    if not NPCDataViewerDB.settings then
        NPCDataViewerDB.settings = {}
        for k, v in pairs(defaults) do
            NPCDataViewerDB.settings[k] = v
        end
    end
    for k, v in pairs(defaults) do
        if NPCDataViewerDB.settings[k] == nil then
            NPCDataViewerDB.settings[k] = v
        end
    end
    return NPCDataViewerDB.settings
end

function NPCDataViewerOptions:SetSetting(key, value)
    local s = self:GetSettings()
    s[key] = value
end

function NPCDataViewerOptions:ToggleSetting(key)
    local s = self:GetSettings()
    s[key] = not s[key]
    return s[key]
end
