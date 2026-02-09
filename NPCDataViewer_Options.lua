local ADDON_NAME, T = ...
NPCDataViewerOptions = {}

-- Default settings
local defaults = {
    autoRotate = false, -- Disabled by default
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
    local settings = self:GetSettings()

    -- Create a simple frame for WoW's interface options (not draggable, not a popup)
    local frame = CreateFrame("Frame", "NPCDataViewerOptionsFrame")
    frame.name = "NPC Data Viewer"

    -- Title
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("NPC Data Viewer Settings")

    -- Auto-rotate checkbox
    local autoRotateCheck = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    autoRotateCheck:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    autoRotateCheck.Text:SetText("Auto-rotate 3D models")
    autoRotateCheck:SetChecked(settings.autoRotate)

    autoRotateCheck:SetScript("OnClick", function(self)
        settings.autoRotate = self:GetChecked()
        -- Notify the model viewer to update
        if ModelViewer and ModelViewer.UpdateRotationState then
            ModelViewer:UpdateRotationState()
        end
    end)

    -- Hint text
    local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", autoRotateCheck, "BOTTOMLEFT", 24, -8)
    hint:SetPoint("RIGHT", -32, 0)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.6, 0.6, 0.6)
    hint:SetText(
    "Tip: Left-click and drag to rotate models manually.\nRight-click and drag to reposition.\nMouse wheel to zoom in/out.")

    self.frame = frame
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
        -- Fall back to legacy API (pre-Dragonflight)
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
