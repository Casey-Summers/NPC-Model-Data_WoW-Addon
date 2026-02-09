local ADDON_NAME = ...

local function NPCDV_Print(...)
    print("|cff00ff88NPC Data Viewer:|r", ...)
end

-- =========================================================
-- UI CONFIGURATION CONSTANTS (Adjust these for size)
-- =========================================================
local UI_WIDTH = 640
local UI_VIEWPORT_HEIGHT = 500 -- Taller for large NPCs
local UI_INFO_HEIGHT = 160
local UI_SEARCH_HEIGHT = 34
local UI_HEADER_HEIGHT = 34
local UI_PADDING = 8 -- Spacing between elements

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

local function IsCreatureDisplayDBAvailable()
    return CreatureDisplayDB and CreatureDisplayDBdb and CreatureDisplayDBdb.byname and CreatureDisplayDBdb.data
end

-- =========================================================
-- Model Viewer (UI + logic)
-- =========================================================
local ModelViewer = {
    _namesIndexBuilt = false,
    _nameIndex = nil, -- array: { {name="X", lower="x"} ... }
    _pendingSuggestToken = 0,
    lookup = nil,     -- runtime lookup for DB

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
    header:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    header:SetBackdropColor(1, 1, 1, 0.05)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
    title:SetPoint("CENTER", 0, 0)
    title:SetText("NPC DATA VIEWER")
    title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE") -- Larger and styled
    title:SetTextColor(1, 1, 1)

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

    -- Custom Search Bar (EditBox)
    local inputContainer = CreateFrame("Frame", nil, searchGroup, "BackdropTemplate")
    inputContainer:SetHeight(UI_SEARCH_HEIGHT)
    inputContainer:SetPoint("LEFT", 0, 0)
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

    -- Modern styled search button
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

    local model = CreateFrame("PlayerModel", nil, modelContainer)
    model:SetAllPoints()

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
    self.modelPosition = { x = 0, y = 0, z = 0 }
    self.modelDistance = 0 -- Default zoom level (0 = normal view)
    self.isRotating = false
    self.rotationSpeed = 0

    -- Left-click drag to rotate
    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            ModelViewer.isDragging = true
            ModelViewer.dragStartX = GetCursorPosition()
            ModelViewer.dragStartRotation = ModelViewer.modelRotation
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
            local cursorX = GetCursorPosition()
            local delta = (cursorX - ModelViewer.dragStartX) * 0.01
            ModelViewer.modelRotation = (ModelViewer.dragStartRotation + delta) % (math.pi * 2)
            self:SetFacing(ModelViewer.modelRotation)
        end

        -- Manual translation
        if ModelViewer.isTranslating then
            local cursorX, cursorY = GetCursorPosition()
            local deltaX = (cursorX - ModelViewer.dragStartX) * 0.001
            local deltaY = (cursorY - ModelViewer.dragStartY) * 0.001
            ModelViewer.modelPosition.x = ModelViewer.dragStartPos.x + deltaX
            ModelViewer.modelPosition.y = ModelViewer.dragStartPos.y + deltaY
            self:SetPosition(ModelViewer.modelPosition.z, ModelViewer.modelPosition.x, ModelViewer.modelPosition.y)
        end
    end)

    -- Mouse wheel zoom
    model:EnableMouseWheel(true)
    model:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            -- Scroll up = zoom in (increase distance for closer view)
            ModelViewer.modelDistance = math.min(3, ModelViewer.modelDistance + 0.1)
        else
            -- Scroll down = zoom out (decrease distance for farther view)
            ModelViewer.modelDistance = math.max(-1, ModelViewer.modelDistance - 0.1)
        end
        self:SetPortraitZoom(ModelViewer.modelDistance)
    end)

    -- Model control buttons grouped and centered
    local controlBar = CreateFrame("Frame", nil, modelContainer)
    controlBar:SetSize(160, 30)
    controlBar:SetPoint("BOTTOM", 0, 12)

    local function CreateControlButton(parent, atlas, tooltip, size)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(size or 28, size or 28)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1
        })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

        if atlas then
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("CENTER")
            tex:SetSize((size or 28) - 6, (size or 28) - 6)
            tex:SetAtlas(atlas)
            tex:SetVertexColor(0.7, 0.7, 0.7)
            btn.tex = tex
            btn.isAtlas = true
        end

        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.2, 0.2, 0.2, 1)
            self:SetBackdropBorderColor(0.8, 0.6, 0, 1)
            if self.tex then
                self.tex:SetVertexColor(1, 0.82, 0)
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1)
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            if self.tex then
                self.tex:SetVertexColor(0.7, 0.7, 0.7)
            end
            GameTooltip:Hide()
        end)

        return btn
    end

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
        ModelViewer.modelPosition = { x = 0, y = 0, z = 0 }
        ModelViewer.modelDistance = 0 -- Reset to default zoom level
        model:SetFacing(0)
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

    -- 1. Name and Extra Info
    local nameLabel = infoBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    nameLabel:SetPoint("TOP", infoBox, "TOP", 0, -12)
    nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE") -- Larger Name
    nameLabel:SetWidth(450)                                 -- Max width crop
    nameLabel:SetMaxLines(1)
    nameLabel:SetWordWrap(false)
    nameLabel:SetText("-")
    self.nameLabel = nameLabel

    local extraInfo = infoBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    extraInfo:SetPoint("TOP", nameLabel, "BOTTOM", 0, -2)
    extraInfo:SetTextColor(0.5, 0.8, 1)
    self.extraInfo = extraInfo

    -- 2. Left Column (Biometrics)
    local leftCol = CreateFrame("Frame", nil, infoBox)
    leftCol:SetSize(200, 100)
    leftCol:SetPoint("TOPLEFT", 10, -55)

    local function CreateSpecLabel(parent, labelText, yOff)
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetPoint("TOP", 0, yOff)
        lbl:SetText(labelText:upper())
        lbl:SetTextColor(0.4, 0.4, 0.4)
        local val = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("TOP", lbl, "BOTTOM", 0, -2)
        val:SetText("-")
        return val
    end

    self.typeLabel = CreateSpecLabel(leftCol, "Type / Family", 0)
    self.zoneLabel = CreateSpecLabel(leftCol, "Zone", -40)

    -- 3. Right Column (World/Source)
    local rightCol = CreateFrame("Frame", nil, infoBox)
    rightCol:SetSize(200, 100)
    rightCol:SetPoint("TOPRIGHT", -10, -55)

    self.locLabel = CreateSpecLabel(rightCol, "Location", 0)
    self.patchLabel = CreateSpecLabel(rightCol, "Added in Patch", -40)

    -- Timer for debounce
    self._searchTimer = nil

    -- 4. ID Navigation Area (Center)
    local navGroup = CreateFrame("Frame", nil, infoBox)
    navGroup:SetSize(240, 100)
    navGroup:SetPoint("TOP", infoBox, "TOP", 0, -55)

    local function CreateNavControl(parent, labelText, yOff, onPrev, onNext)
        local cont = CreateFrame("Frame", nil, parent)
        cont:SetSize(240, 60)
        cont:SetPoint("TOP", 0, yOff)

        local lbl = cont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetPoint("TOP", 0, 0)
        lbl:SetText(labelText)
        lbl:SetTextColor(0.5, 0.5, 0.5)

        local val = cont:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOP", lbl, "BOTTOM", 0, -2)
        val:SetText("-")

        local prev = CreateAtlasButton(cont, "shop-header-arrow-disabled", 0, false)
        prev:SetSize(20, 20)
        prev:SetPoint("RIGHT", val, "LEFT", -40, 0)
        prev:SetScript("OnClick", onPrev)

        local next = CreateAtlasButton(cont, "shop-header-arrow-disabled", 0, true)
        next:SetSize(20, 20)
        next:SetPoint("LEFT", val, "RIGHT", 40, 0)
        next:SetScript("OnClick", onNext)

        local count = cont:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        count:SetPoint("TOP", val, "BOTTOM", 0, -2)
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

    -- Update Counters
    local count = self._curResults and #self._curResults or 0
    local idx = self._curResultIdx or 0
    self.npcCounter:SetText(("%d / %d"):format(idx, count))
    self.npcPrev:GetNormalTexture():SetDesaturated(count <= 1)
    self.npcNext:GetNormalTexture():SetDesaturated(count <= 1)

    -- Display counter is now redundant since results are already per DisplayID variant
    self.dispCounter:SetText("-")
    self.dispPrev:GetNormalTexture():SetDesaturated(true)
    self.dispNext:GetNormalTexture():SetDesaturated(true)

    -- Handle Lack of IDs or Visuals
    local warning = ""
    local showNoModel = false

    if dispId == "NoData" then
        showNoModel = true
    elseif count == 0 and name ~= "-" then
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

    -- Check if we are currently viewing an NPC not in the index
    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    local currentId = nameVariant and nameVariant.npcId

    if currentId then
        -- Find where we are relative to the index
        for i, id in ipairs(self._idIndex) do
            if id >= currentId then
                self._curGlobalIdx = i
                break
            end
        end
    end

    self._curGlobalIdx = (self._curGlobalIdx % #self._idIndex) + 1
    local npcId = self._idIndex[self._curGlobalIdx]
    self.input:SetText(tostring(npcId))
    self:ApplyNumeric(npcId)
end

function ModelViewer:PrevGlobal()
    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex or #self._idIndex == 0 then return end

    local nameVariant = self._curResults and self._curResults[self._curResultIdx]
    local currentId = nameVariant and nameVariant.npcId

    if currentId then
        for i = #self._idIndex, 1, -1 do
            if self._idIndex[i] <= currentId then
                self._curGlobalIdx = i
                break
            end
        end
    end

    self._curGlobalIdx = self._curGlobalIdx - 1
    if self._curGlobalIdx < 1 then self._curGlobalIdx = #self._idIndex end
    local npcId = self._idIndex[self._curGlobalIdx]
    self.input:SetText(tostring(npcId))
    self:ApplyNumeric(npcId)
end

function ModelViewer:NextNpc()
    if not self._curResults or #self._curResults <= 1 then return end
    self._curResultIdx = (self._curResultIdx % #self._curResults) + 1
    self:SyncState()
end

function ModelViewer:PrevNpc()
    if not self._curResults or #self._curResults <= 1 then return end
    self._curResultIdx = self._curResultIdx - 1
    if self._curResultIdx < 1 then self._curResultIdx = #self._curResults end
    self:SyncState()
end

function ModelViewer:NextDisp()
    if #self._curDispIds <= 1 then return end
    self._curDispIdx = (self._curDispIdx % #self._curDispIds) + 1
    self:SyncState()
end

function ModelViewer:PrevDisp()
    if #self._curDispIds <= 1 then return end
    self._curDispIdx = self._curDispIdx - 1
    if self._curDispIdx < 1 then self._curDispIdx = #self._curDispIds end
    self:SyncState()
end

function ModelViewer:Show()
    self:Ensure()
    self.frame:Show()
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

    local function SetIdText(label, id)
        if id == "NoData" then
            label:SetText("N/A")
            label:SetTextColor(1, 0.2, 0.2)
        else
            label:SetText(tostring(id or "-"))
            label:SetTextColor(1, 0.8, 0)
        end
    end

    SetIdText(self.npcIdLabel, npcId)
    SetIdText(self.displayIdLabel, displayId)

    self.zoneLabel:SetText(zone or "Unknown")
    local typeFamily = (ntype or "Unknown")
    if family and family ~= "Unknown" then
        typeFamily = typeFamily .. " / " .. family
    end
    self.typeLabel:SetText(typeFamily or "Unknown")

    local location = "Open World"
    if encounter then
        location = "Encounter: " .. encounter
        if instance then
            location = instance .. " (" .. encounter .. ")"
        end
    end
    self.locLabel:SetText(location)

    self.patchLabel:SetText(patch or "Unknown")

    local extra = ""
    if classification and classification ~= "Normal" then
        extra = classification
    end
    if tameable == "true" then
        if extra ~= "" then extra = extra .. " | " end
        extra = extra .. "Tameable"
    end
    self.extraInfo:SetText(extra)
end

-- =========================================================
-- Global Indices (Names for suggestions, IDs for navigation)
-- =========================================================
function ModelViewer:BuildGlobalIndicesIfNeeded()
    if self._indicesBuilt then
        return
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
        if type(npcId) == "number" and npcId > 0 then
            if not seenId[npcId] then
                seenId[npcId] = true
                table.insert(self._idIndex, npcId)
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
    local results = NPCDataViewerAPI:Search(typed)
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

    local results = NPCDataViewerAPI:Search(raw)
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
    local foundName = nil

    -- 1) Master Data (NPCDataViewerAPI)
    if NPCDataViewerAPI then
        local names = NPCDataViewerAPI:GetNamesByNpcId(numberValue)
        if names and names[1] then
            foundName = names[1]
        end
    end

    -- 3) Local (SavedVariables)
    if not foundName then
        local db = EnsureHarvestDB()
        if db.displayIdBatches then
            for _, batch in pairs(db.displayIdBatches) do
                for _, entry in pairs(batch) do
                    if entry.NPC_ID == numberValue or entry.Display_ID == numberValue then
                        foundName = entry.NPC_Name
                        break
                    end
                end
                if foundName then break end
            end
        end
    end

    if foundName and foundName ~= "" and foundName ~= "-" then
        local results = NPCDataViewerAPI:Search(foundName)
        if results then
            self._curResults = results
            -- Try to find the variant that matches the numberValue (either NPCID or DisplayID)
            self._curResultIdx = 1
            for i, res in ipairs(results) do
                if res.npcId == numberValue or res.displayId == numberValue then
                    self._curResultIdx = i
                    break
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

function ModelViewer:ApplyName(npcName)
    local results = NPCDataViewerAPI:Search(npcName)
    if results then
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
-- Slash command: /npcviewer  OR  /npcviewer export
-- =========================================================
SLASH_NPCVIEWER1 = "/npcviewer"
SlashCmdList.NPCVIEWER = function(message)
    ModelViewer:Ensure()
    ModelViewer:BindEvents()

    message = Trim(message)
    if message == "export" then
        return
    end

    if ModelViewer.frame:IsShown() then
        ModelViewer:Hide()
        return
    end

    ModelViewer:Show()
    ModelViewer.input:SetFocus()
    ModelViewer:BuildNameIndexIfNeeded()
end

-- Harvesting logic removed.

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
