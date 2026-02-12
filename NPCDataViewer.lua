local ADDON_NAME = ...

local function NPCDV_Print(...)
    print("|cff00ff88NPC Data Viewer:|r", ...)
end

-- =========================================================
-- UI CONFIGURATION CONSTANTS (Adjust these for size)
-- =========================================================
local UI_WIDTH = 640
local UI_VIEWPORT_HEIGHT = 500 -- Taller for large NPCs
local UI_INFO_HEIGHT = 180
local UI_SEARCH_HEIGHT = 34
local UI_HEADER_HEIGHT = 34
local UI_DETAIL_TEXT_SIZE = 12
local UI_PADDING = 8 -- Spacing between elements

-- Rotation and Translation Speed Constants
local ROTATION_SPEED_X = 0.025
local ROTATION_SPEED_Y = 0.025
local TRANSLATION_SPEED = 0.015
local ZOOM_SPEED = 0.5
local MAX_ZOOM_IN = 5.0 -- Increased from 1.5 to allow closer inspection

-- =========================================================
-- Small utils
-- =========================================================

local function Trim(text)
    if not text then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ToLowerSafe(text)
    if not text then
        return ""
    end
    return string.lower(text)
end

local function ParsePositiveInt(text)
    text = Trim(text)
    if text == "" then
        return nil
    end
    local value = tonumber(text)
    if not value or value <= 0 or math.floor(value) ~= value then
        return nil
    end
    return value
end

-- =========================================================
-- Copy popup (safe replacement for missing URL_COPY_POPUP)
-- =========================================================
if not StaticPopupDialogs then StaticPopupDialogs = {} end

StaticPopupDialogs["NPCDATAVIEWER_COPY_POPUP"] = {
    text = "",
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 420,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self, data)
        local editBox = _G[self:GetName() .. "EditBox"]
        if editBox then
            editBox:SetAutoFocus(true)
            editBox:SetText((data and data.text) or "")
            editBox:HighlightText()
            editBox:SetCursorPosition(0)
        end
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
}

-- =========================================================
-- Model Viewer (UI + logic)
-- =========================================================
ModelViewer = {
    _namesIndexBuilt = false,
    _nameIndex = nil, -- array: { {name="X", lower="x"} ... }
    _pendingSuggestToken = 0,
    lookup = nil,     -- runtime lookup for DB
    searchType = "Name",
    filters = {},     -- Active detail filters

    -- Browsing state
    _curGlobalIdx = 0,
    _curNpcIds = {},
    _curNpcIdx = 0,
    _curDispIds = {},
    _curDispIdx = 0,
    _lastSearchName = ""
}

-- =========================================================
-- Local Harvest DB (SavedVariables)
-- =========================================================
local DB_VERSION = 5
local BATCH_ID_RANGE = 1000

local function EnsureHarvestDB()
    if not NPCDataViewerDB or type(NPCDataViewerDB) ~= "table" then
        NPCDataViewerDB = {}
    end

    NPCDataViewerDB.meta = NPCDataViewerDB.meta or {}
    NPCDataViewerDB.meta.version = DB_VERSION

    NPCDataViewerDB.displayIdBatches = NPCDataViewerDB.displayIdBatches or {}
    NPCDataViewerDB.count = NPCDataViewerDB.count or 0

    return NPCDataViewerDB
end

-- =========================================================
-- Model Viewer (UI + logic)
-- =========================================================

function ModelViewer:Ensure()
    if self.frame then
        return
    end

    self.filters = self.filters or {}
    local frame = CreateFrame("Frame", "NPCDataViewerFrame", UIParent, "BackdropTemplate")
    local totalHeight = UI_HEADER_HEIGHT + UI_SEARCH_HEIGHT + UI_VIEWPORT_HEIGHT + UI_INFO_HEIGHT + (UI_PADDING * 4)
    frame:SetSize(UI_WIDTH, totalHeight)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
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
    frame:SetBackdropBorderColor(1, 1, 1, 0.05)

    -- Header / Title Bar
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(34)

    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetAtlas("UI-Achievement-Border-2")
    headerBg:SetAlpha(0.8)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
    title:SetPoint("CENTER", 0, 0)
    title:SetText("NPC DATA VIEWER")
    title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE") -- Larger and styled
    title:SetTextColor(1, 1, 1)

    -- Custom settings button (Notify icon, grayscale)
    local settingsBtn = CreateFrame("Button", nil, header)
    settingsBtn:SetSize(20, 20)
    settingsBtn:SetPoint("RIGHT", -36, 0) -- Left of close button

    local settingsTex = settingsBtn:CreateTexture(nil, "ARTWORK")
    settingsTex:SetAllPoints()
    settingsTex:SetAtlas("glues-characterSelect-icon-notify-inProgress-hover", true)

    -- Grayscale initialization
    if settingsTex.SetDesaturated then
        settingsTex:SetDesaturated(true)
    elseif settingsTex.SetDesaturation then
        settingsTex:SetDesaturation(1)
    end
    settingsTex:SetVertexColor(0.65, 0.65, 0.65)

    settingsBtn:SetNormalTexture(settingsTex)

    settingsBtn:SetScript("OnEnter", function()
        settingsTex:SetVertexColor(0.9, 0.9, 0.9) -- Brighter gray on hover
    end)
    settingsBtn:SetScript("OnLeave", function()
        settingsTex:SetVertexColor(0.65, 0.65, 0.65)
    end)

    settingsBtn:SetScript("OnClick", function()
        self:ToggleSettings()
    end)

    self.settingsBtn = settingsBtn


    -- Custom close button with Atlas texture (Pure Gray)
    local close = CreateFrame("Button", nil, header)
    close:SetSize(20, 20)
    close:SetPoint("RIGHT", -8, 0)

    local closeTex = close:CreateTexture(nil, "ARTWORK")
    closeTex:SetAllPoints()
    closeTex:SetAtlas("common-icon-redx")
    closeTex:SetDesaturation(1)            -- Force grayscale
    closeTex:SetVertexColor(0.7, 0.7, 0.7) -- Gray color
    close:SetNormalTexture(closeTex)

    close:SetScript("OnEnter", function(self)
        closeTex:SetVertexColor(1, 1, 1) -- Highlight on hover
    end)

    close:SetScript("OnLeave", function(self)
        closeTex:SetVertexColor(0.7, 0.7, 0.7)
    end)

    close:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Search bar and buttons container (centered)
    local searchGroup = CreateFrame("Frame", nil, frame)
    searchGroup:SetSize(UI_WIDTH - 20, UI_SEARCH_HEIGHT)
    searchGroup:SetPoint("TOP", header, "BOTTOM", 0, -UI_PADDING)

    local function CreateModernButton(parent, text, width)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(width or 90, 28)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText(text)
        label:SetTextColor(0.9, 0.9, 0.9)
        btn.label = label

        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.25, 0.25, 0.25, 1)
            self:SetBackdropBorderColor(0.8, 0.6, 0, 1)
            self.label:SetTextColor(1, 0.82, 0)
        end)

        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
            self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            self.label:SetTextColor(0.9, 0.9, 0.9)
        end)

        return btn
    end

    -- Search Type Dropdown
    self.searchType = "Name"
    local typeBtn = CreateModernButton(searchGroup, self.searchType, 100)
    typeBtn:SetPoint("LEFT", 0, 0)
    typeBtn:SetHeight(UI_SEARCH_HEIGHT)
    self.searchTypeDropdownBtn = typeBtn

    local typeArrow = typeBtn:CreateTexture(nil, "OVERLAY")
    typeArrow:SetSize(12, 12)
    typeArrow:SetPoint("RIGHT", -8, 0)
    typeArrow:SetAtlas("Azerite-PointingArrow")
    typeArrow:SetRotation(0) -- Point down (Default UP) - Rotated 180 from original math.pi
    typeBtn.arrow = typeArrow

    local typeMenu = CreateFrame("Frame", nil, typeBtn, "BackdropTemplate")
    typeMenu:SetSize(100, 75)
    typeMenu:SetPoint("TOP", typeBtn, "BOTTOM", 0, -2)
    typeMenu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    typeMenu:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    typeMenu:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    typeMenu:SetFrameStrata("TOOLTIP")
    typeMenu:Hide()

    local function CreateMenuButton(text, yOff)
        local btn = CreateFrame("Button", nil, typeMenu)
        btn:SetSize(90, 20)
        btn:SetPoint("TOP", 0, yOff)
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", 5, 0)
        lbl:SetText(text)
        btn:SetScript("OnClick", function()
            ModelViewer.searchType = text
            typeBtn.label:SetText(text)
            typeMenu:Hide()
        end)
        btn:SetScript("OnEnter", function() lbl:SetTextColor(1, 0.82, 0) end)
        btn:SetScript("OnLeave", function() lbl:SetTextColor(1, 1, 1) end)
        return btn
    end

    CreateMenuButton("Name", -5)
    CreateMenuButton("NPC ID", -25)
    CreateMenuButton("Display ID", -45)

    typeBtn:SetScript("OnClick", function()
        if typeMenu:IsShown() then typeMenu:Hide() else typeMenu:Show() end
    end)

    -- Custom Search Bar (EditBox)
    local inputContainer = CreateFrame("Frame", nil, searchGroup, "BackdropTemplate")
    inputContainer:SetHeight(UI_SEARCH_HEIGHT)
    inputContainer:SetPoint("LEFT", typeBtn, "RIGHT", 8, 0)
    inputContainer:SetPoint("RIGHT", -100, 0)
    inputContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    inputContainer:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    inputContainer:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local input = CreateFrame("EditBox", nil, inputContainer)
    input:SetAllPoints(inputContainer)
    input:SetTextInsets(10, 10, 0, 0)
    input:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
    input:SetTextColor(1, 1, 1)
    input:SetAutoFocus(false)
    input:SetText("")
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    inputContainer:SetScript("OnMouseDown", function() input:SetFocus() end)

    local go = CreateModernButton(searchGroup, "SEARCH", 90)
    go:SetPoint("LEFT", inputContainer, "RIGHT", 8, 0)
    go:SetHeight(UI_SEARCH_HEIGHT)

    -- Global Navigation (Now inside the model container)
    local function CreateAtlasButton(parent, atlas, xOff, flipX)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(40, 40) -- Slightly larger for visibility
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetAtlas(atlas)
        tex:SetVertexColor(1, 0.8, 0)
        if flipX then tex:SetTexCoord(1, 0, 0, 1) end
        btn:SetNormalTexture(tex)
        local high = btn:CreateTexture(nil, "HIGHLIGHT")
        high:SetAllPoints()
        high:SetAtlas(atlas)
        high:SetVertexColor(1, 0.8, 0)
        high:SetBlendMode("ADD")
        if flipX then high:SetTexCoord(1, 0, 0, 1) end
        return btn
    end

    -- Suggestions dropdown
    local suggest = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    suggest:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -5, -2)
    suggest:SetPoint("TOPRIGHT", input, "BOTTOMRIGHT", 5, -2)
    suggest:SetHeight(1)
    suggest:Hide()
    suggest:SetFrameStrata("DIALOG")
    suggest:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    suggest:SetBackdropColor(0, 0, 0, 0.95)
    suggest:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.5)

    local suggestButtons = {}
    local MAX_SUGGEST = 8
    for index = 1, MAX_SUGGEST do
        local button = CreateFrame("Button", nil, suggest)
        button:SetHeight(20)
        button:SetPoint("TOPLEFT", 6, -6 - ((index - 1) * 20))
        button:SetPoint("TOPRIGHT", -6, -6 - ((index - 1) * 20))
        button:Hide()

        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", 5, 0)
        button.text:SetJustifyH("LEFT")

        button:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.82, 0.2) end)
        button:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 1, 1) end)

        suggestButtons[index] = button
    end

    local modelContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    modelContainer:SetSize(UI_WIDTH - 2, UI_VIEWPORT_HEIGHT)
    modelContainer:SetPoint("TOP", searchGroup, "BOTTOM", 0, -UI_PADDING)
    modelContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    modelContainer:SetBackdropColor(0, 0, 0, 0.4)
    modelContainer:SetBackdropBorderColor(1, 1, 1, 0.08)

    -- Decorative background
    local bgTex = modelContainer:CreateTexture(nil, "BACKGROUND")
    bgTex:SetAtlas("transmog-locationBG")
    bgTex:SetPoint("BOTTOM")
    bgTex:SetSize(UI_WIDTH, UI_VIEWPORT_HEIGHT)
    bgTex:SetAlpha(0.9)
    self.bgDecoration = bgTex

    local model = CreateFrame("PlayerModel", nil, modelContainer)
    model:SetAllPoints()

    -- Controls Instruction (Bottom Left - Stacked)
    local function CreateHint(text, yOff)
        local hint = modelContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("BOTTOMLEFT", 12, 10 + yOff)
        hint:SetText(text)
        hint:SetTextColor(0.6, 0.6, 0.6)
        hint:SetAlpha(0.6)
        return hint
    end

    CreateHint("Scroll: Zoom", 0)
    CreateHint("R-Click: Pan", 14)
    CreateHint("L-Click: Rotate", 28)

    -- Global Nav internal to model area (On TOP)
    local gPrev = CreateAtlasButton(modelContainer, "shop-header-arrow-disabled", 0, false)
    gPrev:SetPoint("LEFT", 12, 0)
    gPrev:SetFrameLevel(model:GetFrameLevel() + 5)
    gPrev:SetScript("OnClick", function() self:PrevGlobal() end)

    local gNext = CreateAtlasButton(modelContainer, "shop-header-arrow-disabled", 0, true)
    gNext:SetPoint("RIGHT", -12, 0)
    gNext:SetFrameLevel(model:GetFrameLevel() + 5)
    gNext:SetScript("OnClick", function() self:NextGlobal() end)

    -- Model interaction state
    self.modelRotation = 0
    self.modelPitch = 0    -- Added pitch state
    self.modelPosition = { x = 0, y = 0, z = 0 }
    self.modelDistance = 0 -- Default zoom level (0 = normal view)
    self.isRotating = false
    self.rotationSpeed = 0
    self.rotateXY = false -- Default to X-axis only

    -- Left-click drag to rotate
    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            ModelViewer.isDragging = true
            ModelViewer.dragStartX, ModelViewer.dragStartY = GetCursorPosition()
            ModelViewer.dragStartRotation = ModelViewer.modelRotation
            ModelViewer.dragStartPitch = ModelViewer.modelPitch
        elseif button == "RightButton" then
            ModelViewer.isTranslating = true
            ModelViewer.dragStartX, ModelViewer.dragStartY = GetCursorPosition()
            ModelViewer.dragStartPos = { x = ModelViewer.modelPosition.x, y = ModelViewer.modelPosition.y }
        end
    end)

    model:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            ModelViewer.isDragging = false
        elseif button == "RightButton" then
            ModelViewer.isTranslating = false
        end
    end)

    model:SetScript("OnUpdate", function(self, elapsed)
        -- Auto-rotation (Using SetFacing for smoother native rotation)
        local settings = NPCDataViewerOptions and NPCDataViewerOptions:GetSettings()
        if settings and settings.autoRotate and not ModelViewer.isDragging and not ModelViewer.isTranslating then
            ModelViewer.modelRotation = (ModelViewer.modelRotation + elapsed * 0.3) % (math.pi * 2)
            self:SetFacing(ModelViewer.modelRotation)
        end

        -- Manual rotation
        if ModelViewer.isDragging then
            local cursorX, cursorY = GetCursorPosition()

            -- Horizontal rotation (Facing)
            local deltaX = (cursorX - ModelViewer.dragStartX) * ROTATION_SPEED_X
            ModelViewer.modelRotation = (ModelViewer.dragStartRotation + deltaX) % (math.pi * 2)
            self:SetFacing(ModelViewer.modelRotation)

            -- Vertical rotation (Pitch)
            if ModelViewer.rotateXY then
                local deltaY = (cursorY - ModelViewer.dragStartY) * ROTATION_SPEED_Y
                ModelViewer.modelPitch = (ModelViewer.dragStartPitch - deltaY) -- Inverted for natural feel
                -- Clamping pitch to prevent flipping or extreme angles
                if ModelViewer.modelPitch > 1.5 then ModelViewer.modelPitch = 1.5 end
                if ModelViewer.modelPitch < -1.5 then ModelViewer.modelPitch = -1.5 end
            else
                ModelViewer.modelPitch = 0
            end

            if self.SetPitch then
                self:SetPitch(ModelViewer.modelPitch)
            end
        end

        -- Manual translation
        if ModelViewer.isTranslating then
            local cursorX, cursorY = GetCursorPosition()
            local deltaX = (cursorX - ModelViewer.dragStartX) * TRANSLATION_SPEED
            local deltaY = (cursorY - ModelViewer.dragStartY) * TRANSLATION_SPEED
            ModelViewer.modelPosition.x = ModelViewer.dragStartPos.x + deltaX
            ModelViewer.modelPosition.y = ModelViewer.dragStartPos.y + deltaY
            self:SetPosition(ModelViewer.modelPosition.z, ModelViewer.modelPosition.x, ModelViewer.modelPosition.y)
        end
    end)

    -- Mouse wheel zoom (Linear path)
    model:EnableMouseWheel(true)
    model:SetScript("OnMouseWheel", function(self, delta)
        -- Linear zoom using SetPosition instead of SetPortraitZoom
        -- Positive delta = scroll up = zoom in (z increases towards camera)
        -- Large scroll-out range, but cannot be negative enough to pass through NPC center
        -- We'll use modelPosition.z for this
        if delta > 0 then
            ModelViewer.modelPosition.z = math.min(MAX_ZOOM_IN, ModelViewer.modelPosition.z + ZOOM_SPEED)
        else
            ModelViewer.modelPosition.z = math.max(-100, ModelViewer.modelPosition.z - ZOOM_SPEED)
        end
        self:SetPosition(ModelViewer.modelPosition.z, ModelViewer.modelPosition.x, ModelViewer.modelPosition.y)
    end)

    -- Model control buttons grouped and centered
    local controlBar = CreateFrame("Frame", nil, modelContainer)
    controlBar:SetSize(160, 30)
    controlBar:SetPoint("BOTTOM", 0, 12)

    local function CreateControlButton(parent, atlas, tooltip, size)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        local btnSize = size or 28
        btn:SetSize(btnSize, btnSize)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

        -- Always provide a label so callers can safely do btn.label:SetText(...)
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetText("")
        label:SetTextColor(0.9, 0.9, 0.9)
        btn.label = label

        if atlas then
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("CENTER")
            tex:SetSize(btnSize - 6, btnSize - 6)
            tex:SetAtlas(atlas)
            tex:SetVertexColor(0.7, 0.7, 0.7)
            btn.tex = tex
            btn.isAtlas = true

            -- Icon buttons generally don't need text displayed
            label:Hide()
        end

        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.2, 0.2, 0.2, 1)
            self:SetBackdropBorderColor(0.8, 0.6, 0, 1)
            if self.tex then
                self.tex:SetVertexColor(1, 0.82, 0)
            end
            if self.label and self.label:IsShown() then
                self.label:SetTextColor(1, 0.82, 0)
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1)
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            -- Only reset border if it's not a toggle button or if toggle state is off
            if self.isToggle then
                ModelViewer:UpdateToggleVisuals()
            else
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            end

            if self.tex then
                self.tex:SetVertexColor(0.7, 0.7, 0.7)
            end
            if self.label and self.label:IsShown() then
                -- Only reset label color if not an active toggle
                if not self.isToggle then
                    self.label:SetTextColor(0.9, 0.9, 0.9)
                else
                    ModelViewer:UpdateToggleVisuals()
                end
            end
            GameTooltip:Hide()
        end)

        return btn
    end

    -- Auto-Rotation Toggle (Bottom Right)
    local autoRotateBtn = CreateControlButton(modelContainer, nil, "Toggle Auto-Rotation", 32)
    autoRotateBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    autoRotateBtn:SetFrameLevel(model:GetFrameLevel() + 10)
    autoRotateBtn.isToggle = true
    autoRotateBtn.label:SetText("AUTO")
    autoRotateBtn.label:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")

    -- Rotation Axis Toggle (Near Auto Button)
    local axisToggleBtn = CreateControlButton(modelContainer, nil, "Toggle 1D/2D Rotation", 32)
    axisToggleBtn:SetPoint("RIGHT", autoRotateBtn, "LEFT", -4, 0)
    axisToggleBtn:SetFrameLevel(model:GetFrameLevel() + 10)
    axisToggleBtn.isToggle = true
    axisToggleBtn.label:SetText("1D")
    axisToggleBtn.label:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")

    function ModelViewer:UpdateToggleVisuals()
        local settings = NPCDataViewerOptions and NPCDataViewerOptions:GetSettings()

        -- Auto button should reflect settings.autoRotate ONLY
        if autoRotateBtn then
            if settings and settings.autoRotate then
                autoRotateBtn:SetBackdropBorderColor(1, 0.82, 0, 1) -- Gold
                autoRotateBtn.label:SetTextColor(1, 0.82, 0)
            else
                autoRotateBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                autoRotateBtn.label:SetTextColor(0.6, 0.6, 0.6) -- Gray
            end
        end

        -- 2D button should reflect ModelViewer.rotateXY ONLY
        if axisToggleBtn then
            if ModelViewer.rotateXY then
                axisToggleBtn:SetBackdropBorderColor(1, 0.82, 0, 1) -- Gold
                axisToggleBtn.label:SetTextColor(1, 0.82, 0)
                axisToggleBtn.label:SetText("2D")
            else
                axisToggleBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                axisToggleBtn.label:SetTextColor(0.6, 0.6, 0.6) -- Gray
                axisToggleBtn.label:SetText("1D")
            end
        end
    end

    axisToggleBtn:SetScript("OnClick", function()
        ModelViewer.rotateXY = not ModelViewer.rotateXY
        ModelViewer:UpdateToggleVisuals()
    end)

    autoRotateBtn:SetScript("OnClick", function()
        if NPCDataViewerOptions then
            local settings = NPCDataViewerOptions:GetSettings()
            settings.autoRotate = not settings.autoRotate
            ModelViewer:UpdateToggleVisuals()
        end
    end)
    frame:SetScript("OnShow", function()
        ModelViewer:UpdateToggleVisuals()
    end) -- Sync on show

    local rotateLeftBtn = CreateControlButton(controlBar, "shop-header-arrow-hover", "Rotate Left")
    rotateLeftBtn:SetPoint("LEFT", 0, 0)
    -- No flip needed - this is already the left arrow
    rotateLeftBtn:SetScript("OnClick", function()
        ModelViewer.modelRotation = (ModelViewer.modelRotation - 0.3) % (math.pi * 2)
        model:SetFacing(ModelViewer.modelRotation)
    end)

    local rotateRightBtn = CreateControlButton(controlBar, "shop-header-arrow-hover", "Rotate Right")
    rotateRightBtn:SetPoint("LEFT", rotateLeftBtn, "RIGHT", 4, 0)
    if rotateRightBtn.tex then
        rotateRightBtn.tex:SetTexCoord(1, 0, 0, 1) -- Flip horizontally for right arrow
    end
    rotateRightBtn:SetScript("OnClick", function()
        ModelViewer.modelRotation = (ModelViewer.modelRotation + 0.3) % (math.pi * 2)
        model:SetFacing(ModelViewer.modelRotation)
    end)

    local zoomInBtn = CreateControlButton(controlBar, "common-icon-zoomin-disable", "Zoom In")
    zoomInBtn:SetPoint("LEFT", rotateRightBtn, "RIGHT", 12, 0)
    zoomInBtn:SetScript("OnClick", function()
        -- Zoom in = increase distance for closer view
        ModelViewer.modelDistance = math.min(3, ModelViewer.modelDistance + 0.2)
        model:SetPortraitZoom(ModelViewer.modelDistance)
    end)

    local zoomOutBtn = CreateControlButton(controlBar, "common-icon-zoomout-disable", "Zoom Out")
    zoomOutBtn:SetPoint("LEFT", zoomInBtn, "RIGHT", 4, 0)
    zoomOutBtn:SetScript("OnClick", function()
        -- Zoom out = decrease distance for farther view
        ModelViewer.modelDistance = math.max(-1, ModelViewer.modelDistance - 0.2)
        model:SetPortraitZoom(ModelViewer.modelDistance)
    end)

    local resetBtn = CreateControlButton(controlBar, "common-icon-undo-disable", "Reset View")
    resetBtn:SetPoint("LEFT", zoomOutBtn, "RIGHT", 12, 0)
    if resetBtn.tex then
        resetBtn.tex:SetVertexColor(0.6, 0.6, 0.6) -- Gray color
    end
    resetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.2, 0.2, 0.2, 1)
        self:SetBackdropBorderColor(0.8, 0.6, 0, 1)
        if self.tex then
            self.tex:SetVertexColor(0.8, 0.8, 0.8) -- Lighter gray on hover
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reset View", 1, 1, 1)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        if self.tex then
            self.tex:SetVertexColor(0.6, 0.6, 0.6) -- Back to gray
        end
        GameTooltip:Hide()
    end)
    resetBtn:SetScript("OnClick", function()
        ModelViewer.modelRotation = 0
        ModelViewer.modelPitch = 0
        ModelViewer.modelPosition = { x = 0, y = 0, z = 0 }
        ModelViewer.modelDistance = 0 -- Reset to default zoom level
        model:SetFacing(0)
        if model.SetPitch then model:SetPitch(0) end
        model:SetPosition(0, 0, 0)
        model:SetPortraitZoom(0) -- 0 = default view
    end)

    -- No Model Warning
    local noModelWarning = modelContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    noModelWarning:SetPoint("CENTER")
    noModelWarning:SetText("NO MODEL DATA AVAILABLE")
    noModelWarning:SetTextColor(1, 0.2, 0.2, 0.8)
    noModelWarning:Hide()
    self.noModelWarning = noModelWarning

    -- Subsection (Subcontext frame)
    local infoBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    infoBox:SetPoint("TOPLEFT", modelContainer, "BOTTOMLEFT", 0, -UI_PADDING)
    infoBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    infoBox:SetHeight(UI_INFO_HEIGHT)
    infoBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    infoBox:SetBackdropColor(1, 1, 1, 0.02)

    -- 1. Name and Extra Info (Refined for spacing)
    local nameContainer = CreateFrame("Frame", nil, infoBox)
    nameContainer:SetSize(UI_WIDTH, 30)
    nameContainer:SetPoint("TOP", 0, -10)

    local nameLabel = nameContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    nameLabel:SetPoint("CENTER", 0, 0)
    nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE") -- Larger and bold
    nameLabel:SetWidth(450)
    nameLabel:SetMaxLines(1)
    nameLabel:SetWordWrap(false)
    nameLabel:SetText("-")
    self.nameLabel = nameLabel

    -- Classifications (Gold, Centered)
    local extraInfo = infoBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    extraInfo:SetPoint("TOP", nameLabel, "BOTTOM", 0, -4) -- More padding
    extraInfo:SetTextColor(1, 0.82, 0)
    self.extraInfo       = extraInfo

    -- WoWHead Link (Top Right of infoBox)
    local RIGHT_RESERVED = 35 -- keep room for the element to the right (sidebar arrow etc.)
    local TOP_INSET      = 5
    local INNER_PAD_X    = 2  -- minimal inner padding
    local ICON_GAP       = 1

    local whLinkGroup    = CreateFrame("Button", nil, infoBox, "BackdropTemplate")
    whLinkGroup:SetHeight(24)
    whLinkGroup:SetPoint("TOPRIGHT", infoBox, "TOPRIGHT", -RIGHT_RESERVED, -TOP_INSET) -- reserved gap to the right
    whLinkGroup:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    whLinkGroup:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    whLinkGroup:SetBackdropBorderColor(1, 1, 1, 0)

    local whLabel = whLinkGroup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    whLabel:SetText("WoWHead Link:")
    whLabel:SetTextColor(0.5, 0.5, 0.5)
    whLabel:ClearAllPoints()
    whLabel:SetPoint("LEFT", whLinkGroup, "LEFT", INNER_PAD_X, 0)

    local whLinkIcon = whLinkGroup:CreateTexture(nil, "ARTWORK")
    whLinkIcon:SetSize(16, 16)
    whLinkIcon:ClearAllPoints()
    whLinkIcon:SetPoint("LEFT", whLabel, "RIGHT", ICON_GAP, 0)
    whLinkIcon:SetAtlas("socialqueuing-icon-group")
    whLinkIcon:SetVertexColor(0.5, 0.5, 0.5)

    -- Shrink-to-fit width with minimal padding, while expanding LEFT (won't overlap right-side element)
    local labelW = whLabel:GetStringWidth() or 0
    local totalW = math.ceil(INNER_PAD_X + labelW + ICON_GAP + 16 + INNER_PAD_X)
    whLinkGroup:SetWidth(totalW)

    local function GetWhUrl()
        local nid = self.lastNpcId
        if nid and nid ~= "-" then
            return "https://www.wowhead.com/npc=" .. nid
        end
        return nil
    end

    whLinkGroup:SetScript("OnClick", function(_, button)
        local url = GetWhUrl()
        if not url then return end
        if button == "RightButton" then
            StaticPopup_Show("NPCDATAVIEWER_COPY_POPUP", nil, nil, { text = url })
        else
            StaticPopup_Show("NPCDATAVIEWER_COPY_POPUP", nil, nil, { text = url })
        end
    end)

    whLinkGroup:SetScript("OnEnter", function()
        whLinkGroup:SetBackdropBorderColor(1, 1, 1, 0.1)
        whLabel:SetTextColor(1, 1, 1)
        whLinkIcon:SetVertexColor(1, 1, 1)
    end)
    whLinkGroup:SetScript("OnLeave", function()
        whLinkGroup:SetBackdropBorderColor(1, 1, 1, 0)
        whLabel:SetTextColor(0.5, 0.5, 0.5)
        whLinkIcon:SetVertexColor(0.5, 0.5, 0.5)
    end)
    self.whLink = whLinkGroup

    -- Sidebar Arrow (Far Right)
    local sidebarArrow = CreateFrame("Button", nil, infoBox)
    sidebarArrow:SetSize(24, 24)
    sidebarArrow:SetPoint("RIGHT", infoBox, "RIGHT", -5, 0)
    sidebarArrow:SetPoint("TOP", infoBox, "TOP", 0, -5)

    local saTex = sidebarArrow:CreateTexture(nil, "ARTWORK")
    saTex:SetAllPoints()
    saTex:SetAtlas("Azerite-PointingArrow")

    -- Was: -math.pi/2 (points RIGHT). Add 180° (pi radians) => points LEFT.
    saTex:SetRotation((-math.pi / 2) + math.pi)

    -- Grayscale
    saTex:SetDesaturated(true)
    saTex:SetVertexColor(0.65, 0.65, 0.65) -- neutral gray tint

    sidebarArrow:SetScript("OnEnter", function()
        -- Slightly brighter gray on hover (still grayscale)
        saTex:SetVertexColor(0.9, 0.9, 0.9)
    end)

    sidebarArrow:SetScript("OnLeave", function()
        saTex:SetVertexColor(0.65, 0.65, 0.65)
    end)

    sidebarArrow:SetScript("OnClick", function()
        self:ToggleSidebar()
    end)

    -- Instructions (Top Left - Stacked)
    local function CreateDetailHint(text, yOff)
        local hint = infoBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 12, -10 - yOff)
        hint:SetText(text)
        hint:SetTextColor(0.5, 0.5, 0.5)
        hint:SetAlpha(0.6)
        return hint
    end

    CreateDetailHint("L-Click: Filter", 0)
    CreateDetailHint("R-Click: Copy", 14)

    -- 2. Left Column (Source Info)
    local leftCol = CreateFrame("Frame", nil, infoBox)
    leftCol:SetSize(200, 120)
    leftCol:SetPoint("TOPLEFT", 10, -75) -- Moved UP

    local function CreateSpecLabel(parent, labelText, yOff, category)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(parent:GetWidth(), 42) -- Increased height for padding
        btn:SetPoint("TOP", 0, yOff)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Gold border on hover
        btn:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        btn:SetBackdropBorderColor(1, 0.82, 0, 0) -- Hidden by default

        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetSize(parent:GetWidth(), 12)
        lbl:SetPoint("TOP", 0, 0)
        lbl:SetText(labelText:upper())
        lbl:SetTextColor(1, 0.82, 0) -- Always Gold
        btn.lbl = lbl

        local val = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("TOP", lbl, "BOTTOM", 0, 0)
        val:SetPoint("LEFT", 5, 0)
        val:SetPoint("RIGHT", -5, 0)
        val:SetHeight(26)
        val:SetText("-")
        val:SetFont("Fonts\\FRIZQT__.TTF", UI_DETAIL_TEXT_SIZE, "")
        val:SetWordWrap(false)
        val:SetMaxLines(1)
        val:SetJustifyH("CENTER")
        val:SetJustifyV("TOP")
        -- "Never past left side" logic via anchoring + clip
        -- If text is too long, centering it would hide the start.
        -- We'll adjust based on text length in UpdateDetails if needed,
        -- but default CENTER usually handles short text well.
        -- To ensure start is readable, we can use LEFT justification if width exceeds container.

        btn:SetScript("OnClick", function(_, button)
            if button == "LeftButton" then
                if category then self:ShowMiniSearch(category, btn) end
            elseif button == "RightButton" then
                local txt = val:GetText()
                if txt and txt ~= "-" then
                    StaticPopup_Show("NPCDATAVIEWER_COPY_POPUP", nil, nil, { text = txt })
                end
            end
        end)

        btn:SetScript("OnEnter", function()
            btn:SetBackdropBorderColor(1, 0.82, 0, 0.6)
        end)
        btn:SetScript("OnLeave", function()
            btn:SetBackdropBorderColor(1, 0.82, 0, 0)
        end)

        return val
    end

    self.locLabel = CreateSpecLabel(leftCol, "Instance", 0, "instance")
    self.zoneLabel = CreateSpecLabel(leftCol, "Zone", -46, "zone")

    -- 3. Right Column (Details)
    local rightCol = CreateFrame("Frame", nil, infoBox)
    rightCol:SetSize(200, 100)
    rightCol:SetPoint("TOPRIGHT", -10, -75) -- Moved UP

    self.typeLabel = CreateSpecLabel(rightCol, "Type / Family", 0, "type")
    self.patchLabel = CreateSpecLabel(rightCol, "Patch", -46, "patch")

    local CATEGORY_MAP = {
        type           = "types",
        zone           = "zones",
        instance       = "inst",
        patch          = "patch",
        family         = "fams",
        significance   = "class", -- Significance maps to classification
        classification = "class"
    }
    self.CATEGORY_MAP = CATEGORY_MAP

    -- Sidebar for filtered results
    local sidebarHeight = UI_HEADER_HEIGHT + UI_SEARCH_HEIGHT + UI_VIEWPORT_HEIGHT + UI_INFO_HEIGHT + (UI_PADDING * 3)
    local sidebar = CreateFrame("Frame", "NPCDV_Sidebar", frame, "BackdropTemplate")
    sidebar:SetSize(220, sidebarHeight)
    sidebar:SetPoint("TOPLEFT", frame, "TOPRIGHT", 5, 0)
    sidebar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    sidebar:SetBackdropColor(0.02, 0.02, 0.02, 0.98)
    sidebar:SetBackdropBorderColor(1, 1, 1, 0.1)
    sidebar:Hide()
    self.sidebar = sidebar

    local lateralTitle = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lateralTitle:SetPoint("TOP", 0, -8) -- Moved slightly up
    lateralTitle:SetText("FILTERED NPCS")
    lateralTitle:SetTextColor(0.8, 0.6, 0)

    -- Filter grid section (Replaces filterStatus)
    local filterGrid = CreateFrame("Frame", nil, sidebar)
    filterGrid:SetSize(210, 110)
    filterGrid:SetPoint("TOP", 0, -28) -- Moved closer to title
    self.filterGrid = filterGrid

    local categories = { "type", "family", "zone", "instance", "patch", "significance" }
    local filterButtons = {}

    for i, cat in ipairs(categories) do
        local fbtn = CreateFrame("Button", nil, filterGrid, "BackdropTemplate")
        fbtn:SetSize(100, 36) -- Increased height (was 32)
        local row = math.floor((i - 1) / 2)
        local col = (i - 1) % 2
        fbtn:SetPoint("TOPLEFT", col * 105, -row * 40) -- Adjusted spacing (was 36)
        fbtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        fbtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        fbtn:SetBackdropBorderColor(1, 0.82, 0, 0) -- Hidden by default

        local title = fbtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("TOP", 0, -6) -- More top spacing (was -4)
        title:SetText(cat:upper())
        title:SetTextColor(0.5, 0.5, 0.5)

        local val = fbtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("BOTTOM", 0, 6) -- More bottom spacing (was 4)
        val:SetText("Any")
        val:SetWidth(90)
        val:SetMaxLines(1)
        val:SetWordWrap(false)
        fbtn.val = val

        fbtn:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                self:SetFilter(cat, nil, "Any")
            else
                self:ShowMiniSearch(cat, fbtn)
            end
        end)
        fbtn:SetScript("OnEnter", function()
            fbtn:SetBackdropBorderColor(1, 0.82, 0, 0.5)
            fbtn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        end)
        fbtn:SetScript("OnLeave", function()
            fbtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            fbtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        end)

        filterButtons[cat] = fbtn
    end
    self.sidebarFilterButtons = filterButtons

    -- (filterStatus removed and replaced by filterGrid)

    local clearFilters = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
    clearFilters:SetSize(210, 18)                              -- Expand to full grid width (was 180)
    clearFilters:SetPoint("TOP", filterGrid, "BOTTOM", 0, -15) -- More spacing
    clearFilters:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    clearFilters:SetBackdropColor(0.2, 0, 0, 0.4)
    clearFilters:SetBackdropBorderColor(0.5, 0.2, 0.2, 0.5)

    local clearTxt = clearFilters:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clearTxt:SetPoint("CENTER")
    clearTxt:SetText("CLEAR ALL FILTERS")
    clearTxt:SetTextColor(0.8, 0.4, 0.4)

    clearFilters:SetScript("OnClick", function()
        ModelViewer.filters = {}
        ModelViewer:UpdateSidebar(true)
    end)
    clearFilters:SetScript("OnEnter", function()
        clearFilters:SetBackdropColor(0.4, 0, 0, 0.8)
        clearTxt:SetTextColor(1, 1, 1)
    end)
    clearFilters:SetScript("OnLeave", function()
        clearFilters:SetBackdropColor(0.2, 0, 0, 0.4)
        clearTxt:SetTextColor(0.8, 0.4, 0.4)
    end)

    local separator = sidebar:CreateTexture(nil, "ARTWORK")
    separator:SetSize(200, 1)
    separator:SetPoint("TOP", clearFilters, "BOTTOM", 0, -10)
    separator:SetColorTexture(1, 1, 1, 0.1)

    local scrollFrame = CreateFrame("ScrollFrame", "NPCDV_SidebarScroll", sidebar, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -185) -- Moved down for clear button + separator
    scrollFrame:SetPoint("BOTTOMRIGHT", -25, 5)

    -- Modern Scrollbar skin (Strip ALL default art)
    local sbName = scrollFrame:GetName() .. "ScrollBar"
    if _G[sbName] then
        local sb = _G[sbName]
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 15, -16)
        sb:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 15, 16)
        sb:SetWidth(6)

        -- Hide default art specifically
        local function HideTex(tex)
            if tex then
                tex:SetAlpha(0); tex:Hide()
            end
        end
        HideTex(sb.ScrollUpButton)
        HideTex(sb.ScrollDownButton)
        HideTex(_G[sbName .. "ScrollUpButton"])
        HideTex(_G[sbName .. "ScrollDownButton"])
        HideTex(_G[sbName .. "Top"])
        HideTex(_G[sbName .. "Bottom"])
        HideTex(_G[sbName .. "Middle"])
        HideTex(_G[sbName .. "BG"])
        HideTex(_G[sbName .. "Track"])

        local thumb = sb:GetThumbTexture()
        if thumb then
            thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
            thumb:SetSize(6, 40)
            thumb:SetVertexColor(0.4, 0.4, 0.4, 0.8)
        end

        if not sb.modernBG then
            local bg = sb:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, 0.3)
            sb.modernBG = bg
        end
    end

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(190, 1)
    scrollFrame:SetScrollChild(scrollChild)
    self.sidebarContent = scrollChild

    self.sidebarButtons = {}

    -- Timer for debounce
    self._searchTimer = nil

    -- 4. ID Navigation Area (Center)
    local navGroup = CreateFrame("Frame", nil, infoBox)
    navGroup:SetSize(240, 100)
    navGroup:SetPoint("TOP", infoBox, "TOP", 0, -75) -- Moved UP to match columns

    local function CreateNavControl(parent, labelText, yOff, onPrev, onNext)
        local cont = CreateFrame("Frame", nil, parent)
        cont:SetSize(240, 60)
        cont:SetPoint("TOP", 0, yOff)

        local lbl = cont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetPoint("TOP", 0, 0)
        lbl:SetText(labelText)
        lbl:SetTextColor(1, 0.82, 0) -- Gold Labels

        local valBtn = CreateFrame("Button", nil, cont, "BackdropTemplate")
        valBtn:SetSize(120, 20)
        valBtn:SetPoint("TOP", lbl, "BOTTOM", 0, -2)
        valBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        valBtn:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        valBtn:SetBackdropBorderColor(1, 0.82, 0, 0) -- Hidden by default

        local val = valBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("CENTER")
        val:SetText("-")

        valBtn:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                local txt = val:GetText()
                if txt and txt ~= "-" then
                    StaticPopup_Show("NPCDATAVIEWER_COPY_POPUP", nil, nil, { text = txt })
                end
            end
        end)
        valBtn:SetScript("OnEnter", function() valBtn:SetBackdropBorderColor(1, 0.82, 0, 0.6) end)
        valBtn:SetScript("OnLeave", function() valBtn:SetBackdropBorderColor(1, 0.82, 0, 0) end)

        local prev = CreateAtlasButton(cont, "shop-header-arrow-disabled", 0, false)
        prev:SetSize(22, 22)
        prev:SetPoint("RIGHT", valBtn, "LEFT", 4, 0) -- Closer
        prev:SetScript("OnClick", onPrev)

        local next = CreateAtlasButton(cont, "shop-header-arrow-disabled", 0, true)
        next:SetSize(22, 22)
        next:SetPoint("LEFT", valBtn, "RIGHT", -4, 0) -- Closer
        next:SetScript("OnClick", onNext)

        local count = cont:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        count:SetPoint("TOP", valBtn, "BOTTOM", 0, -2)
        count:SetTextColor(0.8, 0.6, 0)

        return val, count, prev, next
    end

    self.npcIdLabel, self.npcCounter, self.npcPrev, self.npcNext = CreateNavControl(navGroup, "NPC ID", 0,
        function() self:PrevNpc() end, function() self:NextNpc() end)

    self.displayIdLabel, self.dispCounter, self.dispPrev, self.dispNext = CreateNavControl(navGroup, "DISPLAY ID", -60,
        function() self:PrevDisp() end, function() self:NextDisp() end)

    self.warningLabel = infoBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.warningLabel:SetPoint("BOTTOM", infoBox, "BOTTOM", 0, 4)
    self.warningLabel:SetTextColor(1, 0.2, 0.2)
    self.warningLabel:SetText("")

    -- Store references back to self
    self.frame = frame
    self.input = input
    self.go = go
    self.model = model
    self.suggest = suggest
    self.suggestButtons = suggestButtons
    self.MAX_SUGGEST = MAX_SUGGEST

    -- Apply initial states from settings
    self:UpdateToggleVisuals()
    self:UpdateDecorationState()
end

function ModelViewer:UpdateGlobalIndexFromCurrent()
    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    if not nameVariant or not nameVariant.npcId then return end

    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex then return end

    -- Find the index of the current NPC ID in the global index
    for i, id in ipairs(self._idIndex) do
        if id == nameVariant.npcId then
            self._curGlobalIdx = i
            break
        end
    end
end

function ModelViewer:UpdateRotationState()
    -- Called when auto-rotation setting changes
    -- No action needed as the OnUpdate script checks settings dynamically
end

function ModelViewer:UpdateDecorationState()
    local settings = NPCDataViewerOptions and NPCDataViewerOptions:GetSettings()
    if self.bgDecoration then
        if settings and settings.showDecorations then
            self.bgDecoration:Show()
        else
            self.bgDecoration:Hide()
        end
    end
end

function ModelViewer:ToggleSidebar(force)
    if not self.sidebar then return end
    if force ~= nil then
        if force then self.sidebar:Show() else self.sidebar:Hide() end
    else
        if self.sidebar:IsShown() then self.sidebar:Hide() else self.sidebar:Show() end
    end
end

function ModelViewer:ToggleSettings()
    if not self.settingsFrame then
        local sf = CreateFrame("Frame", "NPCDV_SettingsFrame", self.frame, "BackdropTemplate")
        sf:SetSize(300, 200)
        sf:SetPoint("CENTER")
        sf:SetFrameLevel(self.frame:GetFrameLevel() + 50)
        sf:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        sf:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
        sf:SetBackdropBorderColor(1, 0.82, 0, 1)
        sf:Hide()

        local title = sf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -10)
        title:SetText("ADDON SETTINGS")

        local close = CreateFrame("Button", nil, sf, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT")

        local settings = NPCDataViewerOptions:GetSettings()

        local function CreateSettingCheck(text, yOff, key, onChange)
            local cb = CreateFrame("CheckButton", nil, sf, "InterfaceOptionsCheckButtonTemplate")
            cb:SetPoint("TOPLEFT", 20, yOff)
            cb.Text:SetText(text)
            cb:SetChecked(settings[key])
            cb:SetScript("OnClick", function(s)
                settings[key] = s:GetChecked()
                if onChange then onChange() end
            end)
            return cb
        end

        CreateSettingCheck("Auto-rotate 3D models", -50, "autoRotate", function()
            self:UpdateToggleVisuals()
        end)

        CreateSettingCheck("Show decorative backgrounds", -90, "showDecorations", function()
            self:UpdateDecorationState()
        end)

        self.settingsFrame = sf
    end

    if self.settingsFrame:IsShown() then
        self.settingsFrame:Hide()
    else
        self.settingsFrame:Show()
    end
end

function ModelViewer:SyncState()
    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    local name = nameVariant and nameVariant.name or "-"
    local npcId = nameVariant and nameVariant.npcId or "-"
    local dispId = nameVariant and nameVariant.displayId or "-"

    local zone, ntype, family, classification, patch, tameable, encounter, instance
    if nameVariant and NPCDataViewer_Indexes then
        local idx = NPCDataViewer_Indexes
        zone = idx.zone[nameVariant.zone]
        ntype = idx.type[nameVariant.type]
        family = idx.family[nameVariant.family]
        classification = idx.classification[nameVariant.class]
        patch = idx.patch[nameVariant.patch]
        tameable = nameVariant.tameable
        encounter = idx.encounters[nameVariant.encounter]
        instance = idx.instance[nameVariant.instance]
    end

    self:UpdateDetails(name, npcId, dispId, zone, ntype, family, classification, patch, tameable, encounter, instance)

    -- Group variants by NPC ID for hierarchical navigation
    local uniqueNpcs = {}
    if self._curResults then
        local seenNpc = {}
        for _, res in ipairs(self._curResults) do
            if not seenNpc[res.npcId] then
                table.insert(uniqueNpcs, res.npcId)
                seenNpc[res.npcId] = true
            end
        end
        table.sort(uniqueNpcs, function(a, b)
            return (tonumber(a) or 0) < (tonumber(b) or 0)
        end)
    end
    self._curUniqueNpcIds = uniqueNpcs

    -- Update Counters
    local npcCount = #uniqueNpcs
    local currentNpcIdx = 0
    if npcId ~= "-" then
        for i, id in ipairs(uniqueNpcs) do
            if id == npcId then
                currentNpcIdx = i
                break
            end
        end
    end

    self.npcCounter:SetText(("%d / %d"):format(currentNpcIdx, npcCount))
    self.npcPrev:GetNormalTexture():SetDesaturated(npcCount <= 1)
    self.npcNext:GetNormalTexture():SetDesaturated(npcCount <= 1)

    -- Unique Display ID logic for ALL variants of this name
    local uniqueDispIds = {}
    local currentDispIdx = 0
    if name ~= "-" then
        local seenDisp = {}
        if self._curResults then
            for _, var in ipairs(self._curResults) do
                if not seenDisp[var.displayId] then
                    table.insert(uniqueDispIds, var.displayId)
                    seenDisp[var.displayId] = true
                end
            end
        end
        table.sort(uniqueDispIds, function(a, b)
            if a == "NoData" then return false end
            if b == "NoData" then return true end
            return (tonumber(a) or 0) < (tonumber(b) or 0)
        end)
        for i, did in ipairs(uniqueDispIds) do
            if did == dispId then
                currentDispIdx = i
                break
            end
        end
    end
    self._curUniqueDispIds = uniqueDispIds

    local totalDisp = #uniqueDispIds
    self.dispCounter:SetText(("%d / %d"):format(currentDispIdx, totalDisp))
    self.dispPrev:GetNormalTexture():SetDesaturated(totalDisp <= 1)
    self.dispNext:GetNormalTexture():SetDesaturated(totalDisp <= 1)

    -- Handle Lack of IDs or Visuals
    local warning = ""
    local showNoModel = false

    if dispId == "NoData" then
        showNoModel = true
    elseif npcCount == 0 and name ~= "-" then
        warning = "Warning: No data found"
        showNoModel = true
    end

    self.warningLabel:SetText(warning)
    self.noModelWarning:SetShown(showNoModel)

    if not showNoModel and type(dispId) == "number" and dispId ~= self._lastDisplayedId then
        self.model:SetDisplayInfo(dispId)
        self.model:SetAnimation(0) -- Freeze
        self._lastDisplayedId = dispId
    elseif showNoModel or dispId == "-" or dispId == "NoData" then
        self.model:ClearModel()
        self._lastDisplayedId = nil
    end

    -- Update global selection index based on current NPC ID
    self:UpdateGlobalIndexFromCurrent()
end

function ModelViewer:UpdateDispListForNpc(npcId)
    local ids = {}
    local seen = {}

    local function AddId(did)
        if did == "NoData" then
            if not seen["NoData"] then
                table.insert(ids, "NoData")
                seen["NoData"] = true
            end
        else
            local num = tonumber(did)
            if num and not seen[num] then
                table.insert(ids, num)
                seen[num] = true
            end
        end
    end

    -- 1) Master Data (Strict Correlation)
    if NPCDataViewerAPI then
        local apiDids = NPCDataViewerAPI:GetDisplayIdsByNpcId(npcId)
        if apiDids then
            for _, did in ipairs(apiDids) do AddId(did) end
        end
    end

    -- 2) Harvested (SavedVariables) - only if it matches this npcId
    local db = EnsureHarvestDB()
    if db.displayIdBatches then
        for _, batch in pairs(db.displayIdBatches) do
            for _, entry in pairs(batch) do
                if entry.NPC_ID == npcId then
                    AddId(entry.Display_ID)
                end
            end
        end
    end

    table.sort(ids, function(a, b)
        if a == "NoData" then return false end
        if b == "NoData" then return true end
        return a < b
    end)

    self._curDispIds = ids
    self._curDispIdx = #ids > 0 and 1 or 0
end

function ModelViewer:NextGlobal()
    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex or #self._idIndex == 0 then return end

    local currentId = tonumber(self.lastNpcId)
    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    if nameVariant then currentId = tonumber(nameVariant.npcId) end

    local nextId = self._idIndex[1]
    if currentId then
        for i, id in ipairs(self._idIndex) do
            if id > currentId then
                nextId = id
                self._curGlobalIdx = i
                break
            end
        end
    end

    self.searchType = "NPC ID" -- Switch to ID mode for global browsing
    if self.searchTypeDropdownBtn then self.searchTypeDropdownBtn.label:SetText("NPC ID") end
    self.input:SetText(tostring(nextId))
    self:ApplyNumeric(nextId)
end

function ModelViewer:PrevGlobal()
    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex or #self._idIndex == 0 then return end

    local currentId = tonumber(self.lastNpcId)
    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    if nameVariant then currentId = tonumber(nameVariant.npcId) end

    local prevId = self._idIndex[#self._idIndex]
    if currentId then
        for i = #self._idIndex, 1, -1 do
            if self._idIndex[i] < currentId then
                prevId = self._idIndex[i]
                self._curGlobalIdx = i
                break
            end
        end
    end

    self.searchType = "NPC ID" -- Switch to ID mode for global browsing
    if self.searchTypeDropdownBtn then self.searchTypeDropdownBtn.label:SetText("NPC ID") end
    self.input:SetText(tostring(prevId))
    self:ApplyNumeric(prevId)
end

function ModelViewer:NextNpc()
    local ids = self._curUniqueNpcIds or {}
    local total = #ids
    if total <= 1 then return end

    local currentVar = self._curResults and self._curResults[self._curResultIdx]
    if not currentVar then return end

    local currentId = currentVar.npcId
    local currentIdx = 1
    for i, id in ipairs(ids) do
        if id == currentId then
            currentIdx = i; break
        end
    end

    local nextIdx = (currentIdx % total) + 1
    local nextId = ids[nextIdx]

    -- Find the first result matching this NPC ID
    for i, res in ipairs(self._curResults) do
        if res.npcId == nextId then
            self._curResultIdx = i
            break
        end
    end
    self:SyncState()
end

function ModelViewer:PrevNpc()
    local ids = self._curUniqueNpcIds or {}
    local total = #ids
    if total <= 1 then return end

    local currentVar = self._curResults and self._curResults[self._curResultIdx]
    if not currentVar then return end

    local currentId = currentVar.npcId
    local currentIdx = 1
    for i, id in ipairs(ids) do
        if id == currentId then
            currentIdx = i; break
        end
    end

    local prevIdx = ((currentIdx - 2 + total) % total) + 1
    local prevId = ids[prevIdx]

    -- Find the first result matching this NPC ID
    for i, res in ipairs(self._curResults) do
        if res.npcId == prevId then
            self._curResultIdx = i
            break
        end
    end
    self:SyncState()
end

function ModelViewer:NextDisp()
    local ids = self._curUniqueDispIds or {}
    local total = #ids
    if total <= 1 then return end

    local currentVar = self._curResults and self._curResults[self._curResultIdx]
    if not currentVar then return end

    local currentDid = currentVar.displayId
    local currentIdx = 1
    for i, id in ipairs(ids) do
        if id == currentDid then
            currentIdx = i; break
        end
    end

    local nextIdx = (currentIdx % total) + 1
    local nextDid = ids[nextIdx]

    -- Find the first result matching this display ID
    for i, res in ipairs(self._curResults) do
        if res.displayId == nextDid then
            self._curResultIdx = i
            break
        end
    end
    self:SyncState()
end

function ModelViewer:PrevDisp()
    local ids = self._curUniqueDispIds or {}
    local total = #ids
    if total <= 1 then return end

    local currentVar = self._curResults and self._curResults[self._curResultIdx]
    if not currentVar then return end

    local currentDid = currentVar.displayId
    local currentIdx = 1
    for i, id in ipairs(ids) do
        if id == currentDid then
            currentIdx = i; break
        end
    end

    local prevIdx = ((currentIdx - 2 + total) % total) + 1
    local prevId = ids[prevIdx]

    -- Find the first result matching this display ID
    for i, res in ipairs(self._curResults) do
        if res.displayId == prevId then
            self._curResultIdx = i
            break
        end
    end
    self:SyncState()
end

function ModelViewer:Show()
    self:Ensure()
    self.frame:Show()
    self:UpdateSidebar(true) -- Show sidebar by default to allow filtering
end

function ModelViewer:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function ModelViewer:ResetVisuals()
    self.model:ClearModel()
    self:UpdateDetails("-", "-", "-")
end

function ModelViewer:UpdateDetails(name, npcId, displayId, zone, ntype, family, classification, patch, tameable,
                                   encounter, instance)
    if not self.frame then return end
    self.nameLabel:SetText(name or "-")

    local function SafeSetDetail(fs, txt)
        fs:SetText(txt or "-")
        fs:SetJustifyH("CENTER")
        local width = fs:GetStringWidth()
        local parentWidth = fs:GetParent():GetWidth() - 10
        if width > parentWidth then
            fs:SetJustifyH("LEFT")
        end
    end

    -- (ID Text labels removed from rightCol, handled by nav group)

    self.lastNpcId = npcId ~= "-" and npcId or nil
    self.lastDisplayId = displayId ~= "-" and displayId or nil

    SafeSetDetail(self.zoneLabel, zone or "Unknown")
    local typeFamily = (ntype or "Unknown")
    if family and family ~= "Unknown" then
        typeFamily = typeFamily .. " / " .. family
    end
    SafeSetDetail(self.typeLabel, typeFamily or "Unknown")

    local location = "Open World"
    if encounter then
        location = "Encounter: " .. encounter
        if instance then
            location = instance .. " (" .. encounter .. ")"
        end
    end
    SafeSetDetail(self.locLabel, location)

    SafeSetDetail(self.patchLabel, patch or "Unknown")

    local function SetIdText(label, id)
        if label then
            if id == "NoData" then
                label:SetText("N/A")
                label:SetTextColor(1, 0.2, 0.2)
            else
                label:SetText(id or "-")
                label:SetTextColor(1, 0.82, 0) -- Gold values as well per user request
            end
        end
    end

    SetIdText(self.npcIdLabel, npcId)
    SetIdText(self.displayIdLabel, displayId)

    local extra = ""
    if classification and classification ~= "Normal" then
        extra = classification
    end
    if tameable == "true" or tameable == true then
        if extra ~= "" then extra = extra .. " | " end
        extra = extra .. "Tameable"
    end
    self.extraInfo:SetText(extra)

    -- Update Wowhead link visibility
    if self.whLink then
        if npcId and npcId ~= "-" then
            self.whLink:Show()
        else
            self.whLink:Hide()
        end
    end
end

-- =========================================================
-- Global Indices (Names for suggestions, IDs for navigation)
-- =========================================================
function ModelViewer:BuildGlobalIndicesIfNeeded()
    if self._indicesBuilt then
        return
    end

    -- Ensure all master segments are loaded for full index coverage
    if NPCDataViewerAPI then
        NPCDataViewerAPI:LoadAllBuckets()
    end

    self._indicesBuilt = true
    self._namesIndexBuilt = true -- Sync old flag

    self._nameIndex = {}
    self._idIndex = {}
    local seenName = {}
    local seenId = {}

    local function Collect(name, npcId)
        if name then
            local lower = ToLowerSafe(name)
            if lower ~= "" and not seenName[lower] then
                seenName[lower] = true
                table.insert(self._nameIndex, { name = name, lower = lower })
            end
        end
        local nid = tonumber(npcId)
        if nid and nid > 0 then
            if not seenId[nid] then
                seenId[nid] = true
                table.insert(self._idIndex, nid)
            end
        end
    end

    -- 2) Local
    local db = EnsureHarvestDB()
    if db.displayIdBatches then
        for _, batch in pairs(db.displayIdBatches) do
            for _, entry in pairs(batch) do
                Collect(entry.NPC_Name, entry.NPC_ID)
            end
        end
    end

    -- 3) Master Data
    if NPCDataViewer_Data then
        for _, bucket in pairs(NPCDataViewer_Data) do
            for name, data in pairs(bucket) do
                if data.ids then
                    for npcId, _ in pairs(data.ids) do
                        Collect(name, npcId)
                    end
                else
                    Collect(name, nil)
                end
            end
        end
    end

    table.sort(self._nameIndex, function(a, b) return a.lower < b.lower end)
    table.sort(self._idIndex)
end

function ModelViewer:BuildNameIndexIfNeeded()
    self:BuildGlobalIndicesIfNeeded()
end

function ModelViewer:BuildGlobalIdIndexIfNeeded()
    self:BuildGlobalIndicesIfNeeded()
end

-- =========================================================
-- Suggestions / autocomplete
-- =========================================================
function ModelViewer:HideSuggestions()
    self.suggest:Hide()
    for index = 1, self.MAX_SUGGEST do
        self.suggestButtons[index]:Hide()
    end
end

function ModelViewer:ShowSuggestions(matches)
    if not matches or #matches == 0 then
        self:HideSuggestions()
        return
    end

    local visibleCount = math.min(#matches, self.MAX_SUGGEST)
    local height = 6 + (visibleCount * 18) + 6
    self.suggest:SetHeight(height)
    self.suggest:Show()

    for index = 1, self.MAX_SUGGEST do
        local button = self.suggestButtons[index]
        local match = matches[index]
        if match then
            button.text:SetText(match)
            button:Show()
            button:SetScript("OnClick", function()
                self.input:SetText(match)
                self.input:SetCursorPosition(#match)
                self:HideSuggestions()
                self:ApplyInput()
            end)
        else
            button:Hide()
        end
    end
end

function ModelViewer:ComputeSuggestions(typed)
    local results = NPCDataViewerAPI:Search(typed, "Name")
    if not results then return {} end

    local matches = {}
    local seen = {}
    for _, res in ipairs(results) do
        if not seen[res.name] then
            table.insert(matches, res.name)
            seen[res.name] = true
            if #matches >= self.MAX_SUGGEST then break end
        end
    end
    return matches
end

function ModelViewer:ScheduleSuggestions()
    if self._searchTimer then self._searchTimer:Cancel() end

    local typed = Trim(self.input:GetText())
    if #typed < 2 then
        self:HideSuggestions()
        return
    end

    self._searchTimer = C_Timer.NewTimer(0.25, function()
        if not self.frame or not self.frame:IsShown() then return end

        local currentTyped = Trim(self.input:GetText())
        if #currentTyped < 2 then
            self:HideSuggestions()
            return
        end

        local matches = self:ComputeSuggestions(currentTyped)
        if #matches > 0 then
            self:ShowSuggestions(matches)
        else
            self:HideSuggestions()
        end
    end)
end

-- =========================================================
-- Model loading helpers (tries multiple ids with timeouts)
-- =========================================================
function ModelViewer:TryIdSequence(labelPrefix, idList, applyFn, onDone)
    if not idList or #idList == 0 then
        onDone(false)
        return
    end

    local attemptIndex = 1
    local model = self.model
    local resolved = false

    local function Finish(ok, chosenId)
        if resolved then
            return
        end
        resolved = true
        if ok then
            NPCDV_Print("SUCCESS via:", labelPrefix, "ID:", chosenId)
        end
        onDone(ok, chosenId)
    end

    local function AttemptNext()
        if resolved then
            return
        end
        if attemptIndex > #idList then
            Finish(false)
            return
        end

        local id = idList[attemptIndex]
        attemptIndex = attemptIndex + 1

        model:ClearModel()

        local ok = pcall(applyFn, model, id)
        if not ok then
            AttemptNext()
            return
        end

        local timeoutToken = {}
        model._ss_timeoutToken = timeoutToken

        model:SetScript("OnModelLoaded", function(selfModel)
            if selfModel._ss_timeoutToken ~= timeoutToken then
                return
            end
            local fileId = selfModel.GetModelFileID and selfModel:GetModelFileID() or nil
            if fileId and fileId > 0 then
                selfModel:SetScript("OnModelLoaded", nil)
                Finish(true, id)
            end
        end)

        C_Timer.After(0.35, function()
            if resolved then
                return
            end
            if model._ss_timeoutToken ~= timeoutToken then
                return
            end
            model:SetScript("OnModelLoaded", nil)
            AttemptNext()
        end)
    end

    AttemptNext()
end

-- =========================================================
-- Lookup + Apply
-- =========================================================
function ModelViewer:ApplyInput()
    self:Ensure()
    self:HideSuggestions()
    if self._searchTimer then self._searchTimer:Cancel() end

    local raw = Trim(self.input:GetText())
    if raw == "" then return end

    local results = NPCDataViewerAPI:Search(raw, "Name")
    if results then
        self._curResults = results
        self._curResultIdx = 1
        self:SyncState()
    else
        -- Fallback for numeric IDs if no name match
        local numeric = ParsePositiveInt(raw)
        if numeric then
            self:ApplyNumeric(numeric)
        else
            -- Clear state if no results
            self._curResults = {}
            self._curResultIdx = 0
            self:SyncState()
        end
    end
end

function ModelViewer:ApplyNumeric(numberValue)
    if not NPCDataViewerAPI then return end

    -- Use the strictly selected search type from the dropdown
    local results = NPCDataViewerAPI:Search(tostring(numberValue), self.searchType)

    if results and #results > 0 then
        self._curResults = results
        -- If searching by a specific ID, try to find the exact variant that matches that ID
        self._curResultIdx = 1
        for i, res in ipairs(results) do
            if self.searchType == "NPC ID" and res.npcId == numberValue then
                self._curResultIdx = i; break
            elseif self.searchType == "Display ID" and res.displayId == numberValue then
                self._curResultIdx = i; break
            end
        end
        self:SyncState()
        return
    end

    -- Fallback/Orphaned ID logic if No Master Data found
    local foundName = nil
    local db = EnsureHarvestDB()
    if db.displayIdBatches then
        for _, batch in pairs(db.displayIdBatches) do
            for _, entry in pairs(batch) do
                if (self.searchType == "NPC ID" and entry.NPC_ID == numberValue) or
                    (self.searchType == "Display ID" and entry.Display_ID == numberValue) then
                    foundName = entry.NPC_Name
                    break
                end
            end
            if foundName then break end
        end
    end

    if foundName and foundName ~= "" and foundName ~= "-" then
        local res = NPCDataViewerAPI:Search(foundName)
        if res then
            self._curResults = res
            self._curResultIdx = 1
            for i, r in ipairs(res) do
                if (self.searchType == "NPC ID" and r.npcId == numberValue) or
                    (self.searchType == "Display ID" and r.displayId == numberValue) then
                    self._curResultIdx = i; break
                end
            end
            self:SyncState()
            return
        end
    end

    -- Fallback for orphaned IDs
    self._lastSearchName = "-"
    self._curNpcIds = {}
    self._curNpcIdx = 0
    self._curDispIds = {}
    self._curDispIdx = 0

    if not isNpcId then
        local db = EnsureHarvestDB()
        if db.displayIdBatches then
            for _, b in pairs(db.displayIdBatches) do
                for _, e in pairs(b) do
                    if e.NPC_ID == numberValue then
                        isNpcId = true
                        break
                    end
                end
                if isNpcId then break end
            end
        end
    end

    if isNpcId then
        self._curNpcIds = { numberValue }
        self._curNpcIdx = 1
        self:UpdateDispListForNpc(numberValue)
    else
        self._curDispIds = { numberValue }
        self._curDispIdx = 1
    end

    self:SyncState()
end

function ModelViewer:ApplyActiveVariantFilters(results)
    local filters = self.filters
    if type(filters) ~= "table" or not next(filters) then
        return results
    end

    local out = {}
    for _, row in ipairs(results or {}) do
        local ok = true
        for cat, filterId in pairs(filters) do
            if cat == "significance" then
                if filterId == "TAMEABLE" then
                    if row.tameable ~= "true" then
                        ok = false; break
                    end
                else
                    if row.class ~= filterId then
                        ok = false; break
                    end
                end
            elseif cat == "type" then
                if row.type ~= filterId then
                    ok = false; break
                end
            elseif cat == "family" then
                if row.family ~= filterId then
                    ok = false; break
                end
            elseif cat == "zone" then
                if row.zone ~= filterId then
                    ok = false; break
                end
            elseif cat == "patch" then
                if row.patch ~= filterId then
                    ok = false; break
                end
            elseif cat == "instance" then
                if row.instance ~= filterId then
                    ok = false; break
                end
            elseif cat == "encounter" then
                if row.encounter ~= filterId then
                    ok = false; break
                end
            end
        end
        if ok then
            out[#out + 1] = row
        end
    end

    return out
end

function ModelViewer:ApplyName(npcName)
    local results = NPCDataViewerAPI:Search(npcName)
    if not results or #results == 0 then
        -- Try a broader search or harvested search if literal fails
        results = NPCDataViewerAPI:Search(npcName, "Name")
    end

    if results and #results > 0 then
        results = self:ApplyActiveVariantFilters(results)
        self._curResults = results
        self._curResultIdx = 1
    else
        self._curResults = {}
        self._curResultIdx = 0
    end
    self:SyncState()
end

function ModelViewer:LoadSpecific(npcId, displayId, name)
    if not self.frame or not self.frame:IsShown() then return end

    self.input:SetText(name or "")
    self:ApplyName(name or "")

    -- Refine selection to the exact hovered/targeted IDs
    if npcId then
        for i, id in ipairs(self._curNpcIds) do
            if id == npcId then
                self._curNpcIdx = i
                break
            end
        end
        self:UpdateDispListForNpc(npcId)
    end

    if displayId then
        for i, id in ipairs(self._curDispIds) do
            if id == displayId then
                self._curDispIdx = i
                break
            end
        end
    end

    self:SyncState()
end

function ModelViewer:ShowMiniSearch(category, anchor)
    if self.miniSearch and self.miniSearch:IsShown() and self.miniSearch.category == category then
        self.miniSearch:Hide()
        return
    end

    if not self.miniSearch then
        local ms = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
        ms:SetSize(200, 220)
        ms:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        ms:SetBackdropColor(0.05, 0.05, 0.05, 0.98)
        ms:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        ms:SetFrameStrata("TOOLTIP")

        local input = CreateFrame("EditBox", nil, ms, "BackdropTemplate")
        input:SetSize(170, 22)
        input:SetPoint("TOP", 0, -8)
        input:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        input:SetBackdropColor(0.1, 0.1, 0.1, 1)
        input:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        input:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        input:SetTextInsets(5, 5, 0, 0)

        local scrollFrame = CreateFrame("ScrollFrame", nil, ms, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 5, -38)
        scrollFrame:SetPoint("BOTTOMRIGHT", -25, 8)

        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetSize(160, 1)
        scrollFrame:SetScrollChild(scrollChild)

        ms.input = input
        ms.scrollChild = scrollChild
        ms.buttons = {}

        input:SetScript("OnTextChanged", function(s, userInput)
            if userInput then ModelViewer:UpdateMiniSearch(ms.category, s:GetText()) end
        end)
        input:SetScript("OnEscapePressed", function() ms:Hide() end)

        self.miniSearch = ms
    end

    self.miniSearch.category = category
    self.miniSearch:ClearAllPoints()

    -- Positioning: Above for Details, Below for Sidebar
    if anchor:GetParent() == self.filterGrid then
        self.miniSearch:SetPoint("TOP", anchor, "BOTTOM", 0, -5)
    else
        self.miniSearch:SetPoint("BOTTOM", anchor, "TOP", 0, 5)
    end
    self.miniSearch.input:SetText("")
    self.miniSearch.input:SetFocus()
    self.miniSearch:Show()
    self:UpdateMiniSearch(category, "")
end

function ModelViewer:UpdateMiniSearch(category, text)
    local ms = self.miniSearch
    if not ms or not ms.scrollChild then return end

    if type(ms.buttons) ~= "table" then ms.buttons = {} end

    local q = ToLowerSafe(text)
    local matches = {}

    -- Cascading logic: find IDs that are actually present given other active filters
    local eligibleIds = self:GetEligibleIds(category)

    local indexKey = category == "instance" and "instance" or
        (category == "zone" and "zone" or (category == "significance" and "classification" or category))
    local idx = NPCDataViewer_Indexes and NPCDataViewer_Indexes[indexKey]

    if type(idx) == "table" then
        for id, label in pairs(idx) do
            if ToLowerSafe(label):find(q, 1, true) then
                if not eligibleIds or eligibleIds[id] then
                    matches[#matches + 1] = { id = id, label = label }
                end
            end
        end
    end

    -- Special case for Significance: only suggest Tameable when it is actually eligible
    if category == "significance" and ToLowerSafe("Tameable"):find(q, 1, true) then
        if not eligibleIds or eligibleIds["TAMEABLE"] then
            matches[#matches + 1] = { id = "TAMEABLE", label = "Tameable Only" }
        end
    end
    table.sort(matches, function(a, b) return a.label < b.label end)

    local sc = ms.scrollChild
    for _, btn in ipairs(ms.buttons) do btn:Hide() end

    for i, match in ipairs(matches) do
        local btn = ms.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, sc)
            btn:SetSize(150, 18)
            btn:SetNormalFontObject("GameFontHighlightSmall")
            local fs = btn:GetFontString()
            if fs then
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", 5, 0)
                fs:SetJustifyH("LEFT")
            end
            btn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
            local hl = btn:GetHighlightTexture()
            if hl then hl:SetVertexColor(1, 1, 1, 0.1) end
            ms.buttons[i] = btn
        end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
        btn:SetText(match.label)
        btn:SetScript("OnClick", function()
            self:SetFilter(category, match.id, match.label)
            ms:Hide()
        end)
        btn:Show()
    end
    sc:SetHeight(#matches * 18)
end

-- =========================================================
-- Progressive filtering (robust + fast)
--
-- Goal:
--  - Filters intersect at the NPC ID level
--  - A name is eligible if ANY of its NPC IDs survive all active filters
--  - Eligible filter options only include values that exist on surviving NPCs
-- =========================================================

function ModelViewer:_GetDataReverseMap(data)
    if not data or type(data) ~= "table" then return nil end
    if data.__ndv_rev then return data.__ndv_rev end

    local rev = {
        zone = {},
        type = {},
        family = {},
        patch = {},
        significance = {}, -- classification
        encounter = {},
        instance = {},
        tameable = {},
    }

    local function addSet(map, npcId, id)
        if npcId == nil or id == nil then return end
        local n = tonumber(npcId) or npcId
        local set = map[n]
        if not set then
            set = {}
            map[n] = set
        end
        set[id] = true
    end

    if data.zones then
        for zid, nids in pairs(data.zones) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.zone, nid, zid) end
            else
                addSet(rev.zone, nids, zid)
            end
        end
    end

    if data.types then
        for tid, nids in pairs(data.types) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.type, nid, tid) end
            else
                addSet(rev.type, nids, tid)
            end
        end
    end

    if data.fams then
        for fid, nids in pairs(data.fams) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.family, nid, fid) end
            else
                addSet(rev.family, nids, fid)
            end
        end
    end

    if data.patch then
        for pid, nids in pairs(data.patch) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.patch, nid, pid) end
            else
                addSet(rev.patch, nids, pid)
            end
        end
    end

    if data.class then
        for cid, nids in pairs(data.class) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.significance, nid, cid) end
            else
                addSet(rev.significance, nids, cid)
            end
        end
    end

    if data.tame then
        local t = data.tame
        local trueList = t["true"]
        if type(trueList) == "table" then
            for _, nid in ipairs(trueList) do
                local n = tonumber(nid) or nid
                rev.tameable[n] = true
            end
        elseif trueList ~= nil then
            local n = tonumber(trueList) or trueList
            rev.tameable[n] = true
        end
    end

    -- encounterId -> npcIds
    if data.enc then
        for eid, nids in pairs(data.enc) do
            if type(nids) == "table" then
                for _, nid in ipairs(nids) do addSet(rev.encounter, nid, eid) end
            else
                addSet(rev.encounter, nids, eid)
            end
        end
    end

    -- instanceId -> encounterId(s) (derive npcId -> instanceId(s) via enc)
    if data.inst and data.enc then
        for instId, eids in pairs(data.inst) do
            local elist = (type(eids) == "table") and eids or { eids }
            for _, eid in ipairs(elist) do
                local nids = data.enc[eid]
                if nids then
                    if type(nids) == "table" then
                        for _, nid in ipairs(nids) do addSet(rev.instance, nid, instId) end
                    else
                        addSet(rev.instance, nids, instId)
                    end
                end
            end
        end
    end

    data.__ndv_rev = rev
    return rev
end

function ModelViewer:_NpcIdPassesFilters(data, npcId, ignoreCategory)
    local filters = self.filters
    if not filters or not next(filters) then return true end

    local rev = self:_GetDataReverseMap(data)
    if not rev then return false end

    local n = tonumber(npcId) or npcId

    for cat, filterId in pairs(filters) do
        if cat ~= ignoreCategory then
            if cat == "significance" and filterId == "TAMEABLE" then
                if not rev.tameable[n] then return false end
            else
                local map = rev[cat] or (cat == "classification" and rev.significance)
                if not map then return false end
                local set = map[n]
                if not set or not set[filterId] then return false end
            end
        end
    end

    return true
end

function ModelViewer:_FilterVariantsByActiveFilters(variants)
    if not variants or #variants == 0 then return variants end
    local filters = self.filters
    if not filters or not next(filters) then return variants end

    local out = {}
    for _, row in ipairs(variants) do
        local ok = true
        for cat, filterId in pairs(filters) do
            if cat == "significance" and filterId == "TAMEABLE" then
                if row.tameable ~= "true" then
                    ok = false; break
                end
            elseif cat == "significance" or cat == "classification" then
                if row.class ~= filterId then
                    ok = false; break
                end
            else
                if row[cat] ~= filterId then
                    ok = false; break
                end
            end
        end
        if ok then out[#out + 1] = row end
    end
    return out
end

function ModelViewer:SetFilter(category, id, label)
    if type(self.filters) ~= "table" then
        self.filters = {}
    end

    if id == nil then
        self.filters[category] = nil
    else
        self.filters[category] = id
    end

    NPCDV_Print("Filter added: " .. category .. " = " .. (label or tostring(id)))
    self:UpdateSidebar(true)
end

function ModelViewer:CheckFilters(data, ignoreCategory)
    if not data then return false end
    if not self.filters or not next(self.filters) then return true end

    -- Prefer ids as canonical npc set
    if data.ids then
        for npcId in pairs(data.ids) do
            if self:_NpcIdPassesFilters(data, npcId, ignoreCategory) then
                return true
            end
        end
        return false
    end

    -- Fallback: derive from any mapped category list
    if self.CATEGORY_MAP then
        for _, field in pairs(self.CATEGORY_MAP) do
            local fd = data[field]
            if fd then
                for _, nids in pairs(fd) do
                    if type(nids) == "table" then
                        for _, nid in ipairs(nids) do
                            if self:_NpcIdPassesFilters(data, nid, ignoreCategory) then
                                return true
                            end
                        end
                    else
                        if self:_NpcIdPassesFilters(data, nids, ignoreCategory) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

function ModelViewer:GetEligibleIds(category)
    local eligible = {}

    -- Ensure all segments are loaded to provide accurate filter options
    if NPCDataViewerAPI then
        NPCDataViewerAPI:LoadAllBuckets()
    end

    if not NPCDataViewer_Data then return nil end

    for _, bucket in pairs(NPCDataViewer_Data) do
        for _, data in pairs(bucket) do
            if data and data.ids then
                for npcId in pairs(data.ids) do
                    if self:_NpcIdPassesFilters(data, npcId, category) then
                        local rev = self:_GetDataReverseMap(data)
                        if rev then
                            local n = tonumber(npcId) or npcId

                            if category == "significance" or category == "classification" then
                                local set = rev.significance[n]
                                if set then
                                    for id in pairs(set) do eligible[id] = true end
                                end
                                if rev.tameable[n] then
                                    eligible["TAMEABLE"] = true
                                end
                            else
                                local map = rev[category]
                                local set = map and map[n]
                                if set then
                                    for id in pairs(set) do eligible[id] = true end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return eligible
end

function ModelViewer:UpdateSidebar(resetLimit)
    if not self.sidebar then return end
    if resetLimit then self.sidebarResultsLimit = 100 end
    self.sidebarResultsLimit = self.sidebarResultsLimit or 100

    local results = {}
    local activeStr = ""
    local hasFilters = false

    self.sidebar:Show()

    local idx = NPCDataViewer_Indexes
    for cat, fbtn in pairs(self.sidebarFilterButtons) do
        local filterId = self.filters[cat]
        if filterId then
            local label = "Unknown"
            if filterId == "TAMEABLE" then
                label = "Tameable"
            else
                local indexKey = cat == "instance" and "instance" or
                    (cat == "zone" and "zone" or (cat == "significance" and "classification" or cat))
                if idx and idx[indexKey] then
                    label = idx[indexKey][filterId] or tostring(filterId)
                end
            end
            fbtn.val:SetText(label)
            fbtn.val:SetTextColor(1, 0.82, 0)
        else
            fbtn.val:SetText("Any")
            fbtn.val:SetTextColor(0.4, 0.4, 0.4)
        end
    end

    local seen = {}
    if NPCDataViewer_Data then
        for _, bucket in pairs(NPCDataViewer_Data) do
            for name, data in pairs(bucket) do
                if self:CheckFilters(data) then
                    if not seen[name] then
                        seen[name] = true
                        table.insert(results, name)
                    end
                end
            end
        end
    end

    table.sort(results)

    local sc = self.sidebarContent
    -- Use pairs to ensure all buttons are hidden regardless of holes
    for _, btn in pairs(self.sidebarButtons) do btn:Hide() end
    if self.sidebarPaginationFrame then self.sidebarPaginationFrame:Hide() end

    if #results == 0 then
        if not self.sidebarNoResults then
            self.sidebarNoResults = sc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            self.sidebarNoResults:SetPoint("TOP", 0, -20)
            self.sidebarNoResults:SetText("No NPCs match these filters.")
        end
        self.sidebarNoResults:Show()
    else
        if self.sidebarNoResults then self.sidebarNoResults:Hide() end
    end

    local displayCount = math.min(#results, self.sidebarResultsLimit)
    for i = 1, displayCount do
        local name = results[i]
        local btn = self.sidebarButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, sc, "BackdropTemplate")
            btn:SetSize(180, 20)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
            })
            btn:SetBackdropColor(1, 1, 1, 0) -- Transparent default

            local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("LEFT", 5, 0)
            lbl:SetPoint("RIGHT", -5, 0)
            lbl:SetWordWrap(false)
            lbl:SetJustifyH("LEFT")
            btn.label = lbl
            btn:SetScript("OnEnter", function(s)
                s.label:SetTextColor(1, 0.82, 0)
                s:SetBackdropColor(1, 1, 1, 0.05)
            end)
            btn:SetScript("OnLeave", function(s)
                s.label:SetTextColor(1, 1, 1)
                s:SetBackdropColor(1, 1, 1, 0)
            end)
            self.sidebarButtons[i] = btn
        end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", 0, -(i - 1) * 22)
        btn.label:SetText(name)
        btn:SetScript("OnClick", function()
            self:ApplyName(name)
        end)
        btn:Show()
    end

    local finalY = displayCount * 22
    if #results > displayCount then
        if not self.sidebarPaginationFrame then
            local pf = CreateFrame("Frame", nil, sc)
            pf:SetSize(180, 50)

            local more = CreateFrame("Button", nil, pf, "BackdropTemplate")
            more:SetSize(85, 20)
            more:SetPoint("TOPLEFT", 0, -5)
            more:SetNormalFontObject("GameFontNormalSmall")
            more:SetText("Load More")
            more:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            more:SetBackdropColor(1, 1, 1, 0.05)
            more:SetBackdropBorderColor(1, 1, 1, 0.2)
            more:SetScript("OnClick", function()
                self.sidebarResultsLimit = self.sidebarResultsLimit + 100
                self:UpdateSidebar()
            end)

            local all = CreateFrame("Button", nil, pf, "BackdropTemplate")
            all:SetSize(85, 20)
            all:SetPoint("TOPRIGHT", 0, -5)
            all:SetNormalFontObject("GameFontNormalSmall")
            all:SetText("Load All")
            all:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            all:SetBackdropColor(1, 1, 1, 0.05)
            all:SetBackdropBorderColor(1, 1, 1, 0.2)
            all:SetScript("OnClick", function()
                self.sidebarResultsLimit = 10000
                self:UpdateSidebar()
            end)

            self.sidebarPaginationFrame = pf
        end
        self.sidebarPaginationFrame:SetPoint("TOPLEFT", 0, -finalY)
        self.sidebarPaginationFrame:Show()
        finalY = finalY + 50
    end

    sc:SetHeight(math.max(1, finalY))
end

-- =========================================================
-- Wire UI events
-- =========================================================
function ModelViewer:BindEvents()
    if self._eventsBound then
        return
    end
    self._eventsBound = true

    self.go:SetScript("OnClick", function()
        self:ApplyInput()
    end)

    self.input:SetScript("OnEnterPressed", function()
        self:ApplyInput()
    end)

    self.input:SetScript("OnTextChanged", function(_, userInput)
        if not userInput then return end
        self:ScheduleSuggestions()
    end)

    self.input:SetScript("OnEditFocusLost", function()
        C_Timer.After(0.10, function()
            if self.frame and self.frame:IsShown() then
                self:HideSuggestions()
            end
        end)
    end)
end

-- =========================================================
-- Slash commands: /npcviewer, /ndv, /npcdataviewer
-- =========================================================
SLASH_NPCVIEWER1 = "/npcviewer"
SLASH_NPCVIEWER2 = "/ndv"
SLASH_NPCVIEWER3 = "/npcdataviewer"

SlashCmdList.NPCVIEWER = function(message)
    ModelViewer:Ensure()
    ModelViewer:BindEvents()

    if ModelViewer.frame:IsShown() then
        ModelViewer:Hide()
        return
    end

    ModelViewer:Show()
    ModelViewer.input:SetFocus()
    ModelViewer:BuildNameIndexIfNeeded()
end

-- =========================================================
-- Addon init
-- =========================================================
local InitFrame = CreateFrame("Frame")
InitFrame:RegisterEvent("ADDON_LOADED")
InitFrame:RegisterEvent("PLAYER_LOGIN")

InitFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureHarvestDB()
        NPCDataViewerAPI:Initialize()
    end
end)
