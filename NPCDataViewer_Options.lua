local ADDON_NAME, T = ...
NPCDataViewerOptions = {}

-- Default settings
local defaults = {
    autoRotate = false,
    showDecorations = true,
    removeUnused = false,                -- Toggle for "Remove Unused NPCs"
    excludeUnusedFromSuggestions = true, -- Hide "Unused" NPCs from search suggestions by default
}

function NPCDataViewerOptions:GetSettings()
    if not NPCDataViewerDB then NPCDataViewerDB = {} end
    if not NPCDataViewerDB.settings then
        NPCDataViewerDB.settings = {}
        for k, v in pairs(defaults) do
            NPCDataViewerDB.settings[k] = v
        end
    end
    -- Migrate old settings if any
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

-- Custom settings UI logic is handled in NPCDataViewer.lua's ToggleSettings
-- But we keep this file as the central source of truth for settings state.

function NPCDataViewerOptions:CreateUI()
    local frame = CreateFrame("Frame", "NPCDataViewerOptionsFrame")
    frame.name = "NPC Data Viewer"

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("NPC Data Viewer")

    local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    text:SetWidth(400)
    text:SetJustifyH("LEFT")
    text:SetText(
        "Settings are now consolidated directly within the addon interface.\n\nClick the Gear icon in the NPC Data Viewer header to adjust options.\n\nCommands: /ndv, /npcviewer")

    return frame
end

local function InitializeOptions()
    local frame = NPCDataViewerOptions:CreateUI()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(frame, frame.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(frame)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addon)
    if addon == "NPCDataViewer" then
        InitializeOptions()
    end
end)
