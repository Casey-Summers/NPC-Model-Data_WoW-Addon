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

function NPCDataViewerOptions:Toggle()
    if not self.frame then
        self:CreateUI()
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

function NPCDataViewerOptions:CreateUI()
    local settings = self:GetSettings()

    local frame = CreateFrame("Frame", "NPCDataViewerOptionsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(450, 250)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    frame:SetBackdropColor(0.02, 0.02, 0.02, 0.98)
    frame:SetBackdropBorderColor(1, 1, 1, 0.1)

    -- Header
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(34)
    header:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    header:SetBackdropColor(1, 1, 1, 0.05)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", 0, 0)
    title:SetText("NPC DATA VIEWER SETTINGS")
    title:SetTextColor(0.8, 0.8, 0.8)

    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("RIGHT", -2, 0)
    close:SetScale(0.8)

    -- Auto-rotate checkbox
    local autoRotateCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    autoRotateCheck:SetPoint("TOPLEFT", 30, -60)
    autoRotateCheck:SetSize(24, 24)
    autoRotateCheck:SetChecked(settings.autoRotate)

    local autoRotateLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    autoRotateLabel:SetPoint("LEFT", autoRotateCheck, "RIGHT", 5, 0)
    autoRotateLabel:SetText("Auto-rotate 3D models")

    autoRotateCheck:SetScript("OnClick", function(self)
        settings.autoRotate = self:GetChecked()
        -- Notify the model viewer to update
        if ModelViewer and ModelViewer.UpdateRotationState then
            ModelViewer:UpdateRotationState()
        end
    end)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", autoRotateCheck, "BOTTOMLEFT", 30, -10)
    hint:SetPoint("RIGHT", -30, 0)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.6, 0.6, 0.6)
    hint:SetText(
        "Tip: Left-click and drag to rotate models manually.\nRight-click and drag to reposition.\nMouse wheel to zoom in/out.")

    self.frame = frame
end

-- Initialize and register with WoW's interface options on load
local function InitializeOptions()
    NPCDataViewerOptions:CreateUI()
    local frame = NPCDataViewerOptions.frame

    frame.name = "NPC Data Viewer"
    frame.okay = function() frame:Hide() end
    frame.cancel = function() frame:Hide() end

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
