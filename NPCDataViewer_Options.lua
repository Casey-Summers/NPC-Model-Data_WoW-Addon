local ADDON_NAME, T = ...
NPCDataViewerOptions = {}

-- Default settings
local defaults = {
    autoRotate = false,     -- Disabled by default
    showDecorations = true, -- Decorative backgrounds
}

function NPCDataViewerOptions:GetSettings()
    if not NPCDataViewerDB then NPCDataViewerDB = {} end
    if not NPCDataViewerDB.settings then
        NPCDataViewerDB.settings = {}
        for k, v in pairs(defaults) do
            NPCDataViewerDB.settings[k] = v
        end
    end
    return NPCDataViewerDB.settings
end

function NPCDataViewerOptions:CreateUI()
    local frame = CreateFrame("Frame", "NPCDataViewerOptionsFrame")
    frame.name = "NPC Data Viewer"

    -- Title
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("NPC Data Viewer")

    local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    text:SetWidth(400)
    text:SetJustifyH("LEFT")
    text:SetText(
        "Access settings directly within the addon via the Gear icon in the header.\n\nUse /ndv or /npcviewer to open the interface.")

    return frame
end

-- Initialize and register with WoW's interface options on load
local function InitializeOptions()
    local frame = NPCDataViewerOptions:CreateUI()

    -- Try modern API first (Dragonflight+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category, layout = Settings.RegisterCanvasLayoutCategory(frame, frame.name)
        category.ID = frame.name
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(frame)
    end
end

-- Register on ADDON_LOADED
local optionsLoader = CreateFrame("Frame")
optionsLoader:RegisterEvent("ADDON_LOADED")
optionsLoader:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "NPCDataViewer" then
        InitializeOptions()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
