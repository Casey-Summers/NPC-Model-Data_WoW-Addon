local ADDON_NAME = ...

local function NPCMV_Print(...)
    print("|cff00ff88NPC Model Viewer:|r", ...)
end

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

local function HarvestKey(npcId, displayId)
    return tostring(npcId or 0) .. ":" .. tostring(displayId or 0)
end

local function GetBatchLabel(npcId)
    local startRange = math.floor(npcId / BATCH_ID_RANGE) * BATCH_ID_RANGE
    return ("Display IDs %d - %d"):format(startRange, startRange + BATCH_ID_RANGE - 1)
end

local function GetEntryLabel(name, npcId, displayId)
    return ("%d - %s"):format(npcId, name or "Unknown")
end

local function EnsureHarvestDB()
    if not NPCModelViewerDB or type(NPCModelViewerDB) ~= "table" then
        NPCModelViewerDB = {}
    end

    NPCModelViewerDB.meta = NPCModelViewerDB.meta or {}
    local oldVersion = NPCModelViewerDB.meta.version or 1
    NPCModelViewerDB.meta.version = DB_VERSION
    NPCModelViewerDB.meta.importedCreatureDisplayDB = NPCModelViewerDB.meta.importedCreatureDisplayDB or false

    NPCModelViewerDB.knownIds = NPCModelViewerDB.knownIds or {}
    NPCModelViewerDB.discoveredIds = NPCModelViewerDB.discoveredIds or {}

    -- Migration to v5 (Rename batches to displayIdBatches, "Display IDs" labels)
    if not NPCModelViewerDB.displayIdBatches or oldVersion < 5 then
        local oldBatches = NPCModelViewerDB.batches or NPCModelViewerDB.displayIdBatches
        NPCModelViewerDB.displayIdBatches = {}
        NPCModelViewerDB.batches = nil
        NPCModelViewerDB.count = 0
        ModelViewer.lookup = {}

        local function MigrateEntry(entry)
            local name = entry.NPC_Name or entry.name or "Unknown"
            local id = tonumber(entry.NPC_ID or entry.npcId)
            local did = tonumber(entry.Display_ID or entry.displayId)
            if id and did then
                local bLabel = GetBatchLabel(id)
                local eLabel = GetEntryLabel(name, id, did)
                NPCModelViewerDB.displayIdBatches[bLabel] = NPCModelViewerDB.displayIdBatches[bLabel] or {}
                if not NPCModelViewerDB.displayIdBatches[bLabel][eLabel] then
                    NPCModelViewerDB.displayIdBatches[bLabel][eLabel] = {
                        NPC_Name = name,
                        NPC_ID = id,
                        Display_ID = did
                    }
                    NPCModelViewerDB.count = NPCModelViewerDB.count + 1
                    local key = HarvestKey(id, did)
                    ModelViewer.lookup[key] = NPCModelViewerDB.displayIdBatches[bLabel][eLabel]

                    NPCModelViewerDB.knownIds[id] = true
                    NPCModelViewerDB.knownIds[did] = true
                end
            end
        end

        if oldBatches then
            for _, batch in pairs(oldBatches) do
                for _, entry in pairs(batch) do MigrateEntry(entry) end
            end
        end
    end

    -- Runtime lookup
    if not ModelViewer.lookup then
        ModelViewer.lookup = {}
        for _, batch in pairs(NPCModelViewerDB.displayIdBatches) do
            for _, entry in pairs(batch) do
                local key = HarvestKey(entry.NPC_ID, entry.Display_ID)
                ModelViewer.lookup[key] = entry
            end
        end
    end

    return NPCModelViewerDB
end

local function EscapeCsv(text)
    text = tostring(text or "")
    if text:find("[\"\n\r,]") then
        text = text:gsub('"', '""')
        return '"' .. text .. '"'
    end
    return text
end

local function AddHarvestEntry(npcName, npcId, displayId, sourceLabel)
    npcId = tonumber(npcId)
    displayId = tonumber(displayId)
    if not npcId or npcId <= 0 or not displayId or displayId <= 0 then
        return false
    end

    local db = EnsureHarvestDB()
    local key = HarvestKey(npcId, displayId)
    local entry = ModelViewer.lookup[key]
    local isNew = not entry

    if entry then
        if npcName and npcName ~= "" then
            entry.NPC_Name = npcName
        end
    else
        local bLabel = GetBatchLabel(npcId)
        local eLabel = GetEntryLabel(npcName, npcId, displayId)

        db.displayIdBatches[bLabel] = db.displayIdBatches[bLabel] or {}
        local newEntry = {
            NPC_Name = npcName or "Unknown",
            NPC_ID = npcId,
            Display_ID = displayId
        }
        db.displayIdBatches[bLabel][eLabel] = newEntry
        db.count = (db.count or 0) + 1
        ModelViewer.lookup[key] = newEntry

        db.knownIds[npcId] = true
        db.knownIds[displayId] = true

        if sourceLabel == "hover" or sourceLabel == "target" then
            db.discoveredIds[npcId] = true
            db.discoveredIds[displayId] = true
            newEntry.isDiscovered = true
            NPCMV_Print("|cffffff00New Discovery!|r", (npcName or "Unknown"), "(NPC:", npcId, "Display:", displayId, ")")
        end

        -- Invalidate navigation indices
        ModelViewer._indicesBuilt = false
    end

    return true, isNew
end

local function ParseNpcIdFromGuid(guid)
    if not guid then return nil end

    local ok, npcId = pcall(function()
        if guid == "" then return nil end

        -- Creature-0-0000-0000-0000-<NPCID>-0000000000
        -- Vehicle-0-0000-0000-0000-<NPCID>-0000000000
        local unitType, _, _, _, _, id = strsplit("-", guid)
        if unitType ~= "Creature" and unitType ~= "Vehicle" then
            return nil
        end

        local numId = tonumber(id)
        if not numId or numId <= 0 then
            return nil
        end
        return numId
    end)

    return ok and npcId or nil
end

local function ImportFromCreatureDisplayDBIfNeeded()
    local db = EnsureHarvestDB()
    if db.meta.importedCreatureDisplayDB then
        return
    end
    if not IsCreatureDisplayDBAvailable() then
        return
    end

    local imported = 0
    -- Iterate unique names in lib
    for npcName, _ in pairs(CreatureDisplayDBdb.byname) do
        local allNpcIds = CreatureDisplayDB:GetNpcIdsByName(npcName) or {}
        local allDispIds = CreatureDisplayDB:GetDisplayIdsByName(npcName) or {}

        -- Since AddHarvestEntry works with pairs, we ensure every NPC_ID
        -- mentioned for this name is registered with at least the first DisplayID,
        -- and every DisplayID is registered with the first NPC_ID.
        local firstNpcId = allNpcIds[1]
        local firstDispId = allDispIds[1]

        if firstNpcId and firstDispId then
            -- Cross-pollinate
            for _, dId in ipairs(allDispIds) do
                local ok, isNew = AddHarvestEntry(npcName, firstNpcId, dId, "CreatureDisplayDB")
                if ok and isNew then imported = imported + 1 end
            end
            for _, nId in ipairs(allNpcIds) do
                AddHarvestEntry(npcName, nId, firstDispId, "CreatureDisplayDB")
            end
        end
    end

    db.meta.importedCreatureDisplayDB = true
    NPCMV_Print("Imported", imported, "entries from CreatureDisplayDB.")
end

local function ExportHarvestCsv()
    local db = EnsureHarvestDB()
    local lines = {}
    lines[#lines + 1] = "NPC_Name,NPC_ID,Display_ID"

    local entries = {}
    for _, batch in pairs(db.displayIdBatches) do
        for _, entry in pairs(batch) do
            if entry.isDiscovered then
                entries[#entries + 1] = entry
            end
        end
    end

    table.sort(entries, function(a, b)
        local an = ToLowerSafe(a.NPC_Name)
        local bn = ToLowerSafe(b.NPC_Name)
        if an == bn then
            if a.NPC_ID == b.NPC_ID then
                return a.Display_ID < b.Display_ID
            end
            return a.NPC_ID < b.NPC_ID
        end
        return an < bn
    end)

    for _, entry in ipairs(entries) do
        lines[#lines + 1] = table.concat(
            { EscapeCsv(entry.NPC_Name), tostring(entry.NPC_ID), tostring(entry.Display_ID) }, ",")
    end

    return table.concat(lines, "\n")
end

-- =========================================================
-- Export Popup UI
-- =========================================================
local ExportUI = {}

function ExportUI:Ensure()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "NPCModelViewerExportFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 560)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
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
    frame:SetBackdropColor(0, 0, 0, 0.90)
    frame:SetBackdropBorderColor(1, 1, 1, 0.15)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("NPC Model Viewer Export")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
    hint:SetText("Copy and paste into a file / website. Format: NPC_Name,NPC_ID,Display_ID")

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -54)
    scroll:SetPoint("BOTTOMRIGHT", -34, 46)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetAutoFocus(false)
    editBox:SetWidth(700)
    editBox:SetText("")
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    scroll:SetScrollChild(editBox)

    local copy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    copy:SetSize(120, 24)
    copy:SetPoint("BOTTOMLEFT", 16, 14)
    copy:SetText("Copy")

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(120, 24)
    refresh:SetPoint("LEFT", copy, "RIGHT", 10, 0)
    refresh:SetText("Refresh")

    local stats = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    stats:SetPoint("BOTTOMRIGHT", -18, 18)
    stats:SetText("")

    copy:SetScript("OnClick", function()
        local text = editBox:GetText() or ""
        if C_Clipboard and C_Clipboard.SetClipboard then
            C_Clipboard.SetClipboard(text)
            NPCMV_Print("Export copied to clipboard.")
        else
            editBox:SetFocus()
            editBox:HighlightText()
            NPCMV_Print("Clipboard API not available; text highlighted for manual copy.")
        end
    end)

    refresh:SetScript("OnClick", function()
        self:Show()
    end)

    self.frame = frame
    self.editBox = editBox
    self.stats = stats
end

function ExportUI:Show()
    self:Ensure()
    local csv = ExportHarvestCsv()
    self.editBox:SetText(csv)
    self.editBox:SetCursorPosition(0)
    self.editBox:HighlightText()
    self.editBox:SetFocus()

    local db = EnsureHarvestDB()
    self.stats:SetText("Entries: " .. tostring(db.count or 0))

    self.frame:Show()
end

function ExportUI:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

-- =========================================================
-- Model Viewer (UI + logic) - Definition moved up
-- =========================================================

function ModelViewer:Ensure()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "NPCModelViewerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(620, 715)
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
        edgeSize = 2
    })
    frame:SetBackdropColor(0.04, 0.04, 0.04, 0.96)
    frame:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.9)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 25, -20)
    title:SetText("NPC Model Viewer")

    -- Search bar and buttons container (centered)
    local searchGroup = CreateFrame("Frame", nil, frame)
    searchGroup:SetSize(500, 30)
    searchGroup:SetPoint("TOP", frame, "TOP", 0, -60)

    local input = CreateFrame("EditBox", nil, searchGroup, "InputBoxTemplate")
    input:SetSize(300, 24)
    input:SetPoint("LEFT", 0, 0)
    input:SetAutoFocus(false)
    input:SetText("")
    input:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local go = CreateFrame("Button", nil, searchGroup, "UIPanelButtonTemplate")
    go:SetSize(80, 24)
    go:SetPoint("LEFT", input, "RIGHT", 12, 0)
    go:SetText("Search")

    local export = CreateFrame("Button", nil, searchGroup, "UIPanelButtonTemplate")
    export:SetSize(80, 24)
    export:SetPoint("LEFT", go, "RIGHT", 6, 0)
    export:SetText("Export")

    -- Global Navigation (Outside)
    local function CreateAtlasButton(parent, atlas, xOff, flipX)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(32, 32)
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

    local gPrev = CreateAtlasButton(frame, "shop-header-arrow-disabled", -8, false)
    gPrev:SetPoint("RIGHT", frame, "LEFT", -8, 0)
    gPrev:SetScript("OnClick", function() self:PrevGlobal() end)

    local gNext = CreateAtlasButton(frame, "shop-header-arrow-disabled", 8, true)
    gNext:SetPoint("LEFT", frame, "RIGHT", 8, 0)
    gNext:SetScript("OnClick", function() self:NextGlobal() end)

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
    modelContainer:SetSize(570, 480)
    modelContainer:SetPoint("TOP", searchGroup, "BOTTOM", 0, -10)
    modelContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    modelContainer:SetBackdropColor(0, 0, 0, 0.4)
    modelContainer:SetBackdropBorderColor(1, 1, 1, 0.1)

    local model = CreateFrame("PlayerModel", nil, modelContainer)
    model:SetAllPoints()

    -- Subsection (Subcontext frame)
    local infoBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    infoBox:SetPoint("TOPLEFT", modelContainer, "BOTTOMLEFT", 0, -10)
    infoBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -25, 10)
    infoBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    infoBox:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
    infoBox:SetBackdropBorderColor(1, 1, 1, 0.1)

    -- 1. Name top center
    local nameLabel = infoBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    nameLabel:SetPoint("TOP", infoBox, "TOP", 0, -15)
    nameLabel:SetText("-")
    self.nameLabel = nameLabel

    -- 4. Warning Label (Under name)
    self.warningLabel = infoBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.warningLabel:SetPoint("TOP", nameLabel, "BOTTOM", 0, -2)
    self.warningLabel:SetTextColor(1, 0.2, 0.2)
    self.warningLabel:SetText("")

    -- 2. Left Side: NPC ID
    local npcCont = CreateFrame("Frame", nil, infoBox)
    npcCont:SetSize(220, 120)
    npcCont:SetPoint("TOPLEFT", 10, -35)

    local npcLabel = npcCont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    npcLabel:SetPoint("TOP", 0, 0)
    npcLabel:SetText("NPC ID")
    npcLabel:SetTextColor(0.5, 0.5, 0.5)

    local npcValue = npcCont:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    npcValue:SetPoint("TOP", npcLabel, "BOTTOM", 0, -4)
    npcValue:SetText("-")
    self.npcIdLabel = npcValue

    local nPrev = CreateFrame("Button", nil, npcCont)
    nPrev:SetSize(24, 24)
    nPrev:SetPoint("TOPRIGHT", npcCont, "TOP", -22, -45)
    local nPrevTex = nPrev:CreateTexture(nil, "ARTWORK")
    nPrevTex:SetAllPoints()
    nPrevTex:SetAtlas("shop-header-arrow-disabled")
    nPrevTex:SetVertexColor(1, 0.8, 0)
    -- points RIGHT
    nPrev:SetNormalTexture(nPrevTex)
    local nPrevHigh = nPrev:CreateTexture(nil, "HIGHLIGHT")
    nPrevHigh:SetAllPoints()
    nPrevHigh:SetAtlas("shop-header-arrow-disabled")
    nPrevHigh:SetVertexColor(1, 0.8, 0)
    nPrevHigh:SetBlendMode("ADD")
    nPrev:SetScript("OnClick", function() self:PrevNpc() end)

    local nNext = CreateFrame("Button", nil, npcCont)
    nNext:SetSize(24, 24)
    nNext:SetPoint("TOPLEFT", npcCont, "TOP", 22, -45)
    local nNextTex = nNext:CreateTexture(nil, "ARTWORK")
    nNextTex:SetAllPoints()
    nNextTex:SetAtlas("shop-header-arrow-disabled")
    nNextTex:SetVertexColor(1, 0.8, 0)
    nNextTex:SetTexCoord(1, 0, 0, 1) -- points LEFT
    nNext:SetNormalTexture(nNextTex)
    local nNextHigh = nNext:CreateTexture(nil, "HIGHLIGHT")
    nNextHigh:SetAllPoints()
    nNextHigh:SetAtlas("shop-header-arrow-disabled")
    nNextHigh:SetVertexColor(1, 0.8, 0)
    nNextHigh:SetTexCoord(1, 0, 0, 1)
    nNextHigh:SetBlendMode("ADD")
    nNext:SetScript("OnClick", function() self:NextNpc() end)

    local npcCounter = npcCont:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    npcCounter:SetPoint("TOP", npcCont, "TOP", 0, -48)
    npcCounter:SetText("0/0")
    self.npcCounter = npcCounter

    local npcDesc = npcCont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    npcDesc:SetPoint("TOP", 0, -85)
    npcDesc:SetText("Flick through same-name IDs")
    npcDesc:SetScale(0.8)

    -- 2. Right Side: Display ID
    local dispCont = CreateFrame("Frame", nil, infoBox)
    dispCont:SetSize(220, 120)
    dispCont:SetPoint("TOPRIGHT", -10, -35)

    local dispLabel = dispCont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dispLabel:SetPoint("TOP", 0, 0)
    dispLabel:SetText("DISPLAY ID")
    dispLabel:SetTextColor(0.5, 0.5, 0.5)

    local dispValue = dispCont:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dispValue:SetPoint("TOP", dispLabel, "BOTTOM", 0, -4)
    dispValue:SetText("-")
    self.displayIdLabel = dispValue

    local dPrev = CreateFrame("Button", nil, dispCont)
    dPrev:SetSize(24, 24)
    dPrev:SetPoint("TOPRIGHT", dispCont, "TOP", -22, -45)
    local dPrevTex = dPrev:CreateTexture(nil, "ARTWORK")
    dPrevTex:SetAllPoints()
    dPrevTex:SetAtlas("shop-header-arrow-disabled")
    dPrevTex:SetVertexColor(1, 0.8, 0)
    -- points RIGHT
    dPrev:SetNormalTexture(dPrevTex)
    local dPrevHigh = dPrev:CreateTexture(nil, "HIGHLIGHT")
    dPrevHigh:SetAllPoints()
    dPrevHigh:SetAtlas("shop-header-arrow-disabled")
    dPrevHigh:SetVertexColor(1, 0.8, 0)
    dPrevHigh:SetBlendMode("ADD")
    dPrev:SetScript("OnClick", function() self:PrevDisp() end)

    local dNext = CreateFrame("Button", nil, dispCont)
    dNext:SetSize(24, 24)
    dNext:SetPoint("TOPLEFT", dispCont, "TOP", 22, -45)
    local dNextTex = dNext:CreateTexture(nil, "ARTWORK")
    dNextTex:SetAllPoints()
    dNextTex:SetAtlas("shop-header-arrow-disabled")
    dNextTex:SetVertexColor(1, 0.8, 0)
    dNextTex:SetTexCoord(1, 0, 0, 1) -- points LEFT
    dNext:SetNormalTexture(dNextTex)
    local dNextHigh = dNext:CreateTexture(nil, "HIGHLIGHT")
    dNextHigh:SetAllPoints()
    dNextHigh:SetAtlas("shop-header-arrow-disabled")
    dNextHigh:SetVertexColor(1, 0.8, 0)
    dNextHigh:SetTexCoord(1, 0, 0, 1)
    dNextHigh:SetBlendMode("ADD")
    dNext:SetScript("OnClick", function() self:NextDisp() end)

    local dispCounter = dispCont:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dispCounter:SetPoint("TOP", dispCont, "TOP", 0, -48)
    dispCounter:SetText("0/0")
    self.dispCounter = dispCounter

    local dispDesc = dispCont:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dispDesc:SetPoint("TOP", 0, -85)
    dispDesc:SetText("Flick through NPC variations")
    dispDesc:SetScale(0.8)

    self.frame = frame
    self.title = title
    self.input = input
    self.go = go
    self.export = export
    self.model = model
    self.suggest = suggest
    self.suggestButtons = suggestButtons
    self.MAX_SUGGEST = MAX_SUGGEST

    self.npcPrev = nPrev
    self.npcNext = nNext
    self.dispPrev = dPrev
    self.dispNext = dNext
end

function ModelViewer:SyncState()
    local name = self._lastSearchName or "-"
    local npcId = self._curNpcIds[self._curNpcIdx] or "-"
    local dispId = self._curDispIds[self._curDispIdx] or "-"

    self:UpdateDetails(name, npcId, dispId)

    -- Update Counters
    local npcCount = #self._curNpcIds
    local npcIdx = self._curNpcIdx
    if npcCount == 0 then npcIdx = 0 end
    self.npcCounter:SetText(("%d/%d"):format(npcIdx, npcCount))
    self.npcPrev:SetShown(npcCount > 1)
    self.npcNext:SetShown(npcCount > 1)

    local dispCount = #self._curDispIds
    local dispIdx = self._curDispIdx
    if dispCount == 0 then dispIdx = 0 end
    self.dispCounter:SetText(("%d/%d"):format(dispIdx, dispCount))
    self.dispPrev:SetShown(dispCount > 1)
    self.dispNext:SetShown(dispCount > 1)

    -- Handle Lack of IDs or Visuals
    local warning = ""
    if dispCount == 0 and (npcId ~= "-" or name ~= "-") then
        warning = "Warning: No Display IDs found"
    elseif npcId == "-" and dispId == "-" and name ~= "-" then
        warning = "Warning: Entry found but no IDs available"
    end
    self.warningLabel:SetText(warning)

    if dispId ~= "-" and dispId ~= self._lastDisplayedId then
        self.model:SetDisplayInfo(dispId)
        self._lastDisplayedId = dispId
    elseif dispId == "-" then
        self.model:ClearModel()
        self._lastDisplayedId = nil
    end
end

function ModelViewer:UpdateDispListForNpc(npcId)
    -- Aggregate ALL Display IDs for the current NPC NAME
    local name = self._lastSearchName
    if not name or name == "-" or name == "" then
        -- No name context: Fallback to IDs just for this NPC_ID
        self._curDispIds = {}
        if npcId and npcId ~= "-" then
            if IsCreatureDisplayDBAvailable() then
                self._curDispIds = CreatureDisplayDB:GetDisplayIdsByNpcId(npcId) or {}
            end
            local db = EnsureHarvestDB()
            local seen = {}
            for _, d in ipairs(self._curDispIds) do seen[d] = true end
            for _, b in pairs(db.displayIdBatches) do
                for _, e in pairs(b) do
                    if e.NPC_ID == npcId and not seen[e.Display_ID] then
                        table.insert(self._curDispIds, e.Display_ID)
                        seen[e.Display_ID] = true
                    end
                end
            end
        end
        table.sort(self._curDispIds)
        self._curDispIdx = #self._curDispIds > 0 and 1 or 0
        return
    end

    local ids = {}
    local seen = {}

    -- 1) Lib
    if IsCreatureDisplayDBAvailable() then
        local dids = CreatureDisplayDB:GetDisplayIdsByName(name)
        if dids then
            for _, did in ipairs(dids) do
                if not seen[did] then
                    table.insert(ids, did)
                    seen[did] = true
                end
            end
        end
    end

    -- 2) Harvested
    local db = EnsureHarvestDB()
    local lowered = ToLowerSafe(name)
    for _, batch in pairs(db.displayIdBatches) do
        for _, entry in pairs(batch) do
            if ToLowerSafe(entry.NPC_Name) == lowered then
                local did = tonumber(entry.Display_ID)
                if did and not seen[did] then
                    table.insert(ids, did)
                    seen[did] = true
                end
            end
        end
    end

    table.sort(ids)
    self._curDispIds = ids

    -- Maintain current Display ID if it's still in the list
    local oldDid = self._curDispIds[self._curDispIdx]
    if oldDid then
        for i, id in ipairs(ids) do
            if id == oldDid then
                self._curDispIdx = i
                return
            end
        end
    end
    self._curDispIdx = #ids > 0 and 1 or 0
end

function ModelViewer:NextGlobal()
    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex or #self._idIndex == 0 then return end
    self._curGlobalIdx = (self._curGlobalIdx % #self._idIndex) + 1
    local npcId = self._idIndex[self._curGlobalIdx]
    self.input:SetText(tostring(npcId))
    self:ApplyNumeric(npcId)
end

function ModelViewer:PrevGlobal()
    self:BuildGlobalIdIndexIfNeeded()
    if not self._idIndex or #self._idIndex == 0 then return end
    self._curGlobalIdx = self._curGlobalIdx - 1
    if self._curGlobalIdx < 1 then self._curGlobalIdx = #self._idIndex end
    local npcId = self._idIndex[self._curGlobalIdx]
    self.input:SetText(tostring(npcId))
    self:ApplyNumeric(npcId)
end

function ModelViewer:NextNpc()
    if #self._curNpcIds <= 1 then return end
    self._curNpcIdx = (self._curNpcIdx % #self._curNpcIds) + 1
    self:UpdateDispListForNpc(self._curNpcIds[self._curNpcIdx])
    self:SyncState()
end

function ModelViewer:PrevNpc()
    if #self._curNpcIds <= 1 then return end
    self._curNpcIdx = self._curNpcIdx - 1
    if self._curNpcIdx < 1 then self._curNpcIdx = #self._curNpcIds end
    self:UpdateDispListForNpc(self._curNpcIds[self._curNpcIdx])
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

function ModelViewer:UpdateDetails(name, npcId, displayId)
    if not self.frame then return end
    self.nameLabel:SetText(name or "-")
    self.npcIdLabel:SetText(tostring(npcId or "-"))
    self.displayIdLabel:SetText(tostring(displayId or "-"))
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
        if npcId and npcId > 0 then
            if not seenId[npcId] then
                seenId[npcId] = true
                table.insert(self._idIndex, npcId)
            end
        end
    end

    -- 1) Lib
    if IsCreatureDisplayDBAvailable() then
        for name, _ in pairs(CreatureDisplayDBdb.byname) do
            local ids = CreatureDisplayDB:GetNpcIdsByName(name)
            if ids then
                for _, id in ipairs(ids) do Collect(name, id) end
            else
                Collect(name, nil)
            end
        end
    end

    -- 2) Local
    local db = EnsureHarvestDB()
    for _, batch in pairs(db.displayIdBatches) do
        for _, entry in pairs(batch) do
            Collect(entry.NPC_Name, entry.NPC_ID)
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

function ModelViewer:ComputeSuggestions(typedLower)
    if not self._nameIndex then
        return nil
    end

    local matches = {}
    local maxScan = 2500

    local scanned = 0
    for _, entry in ipairs(self._nameIndex) do
        scanned = scanned + 1
        if scanned > maxScan and #matches > 0 then
            break
        end

        if entry.lower:find(typedLower, 1, true) then
            matches[#matches + 1] = entry.name
            if #matches >= self.MAX_SUGGEST then
                break
            end
        end
    end

    return matches
end

function ModelViewer:ScheduleSuggestions()
    self._pendingSuggestToken = self._pendingSuggestToken + 1
    local token = self._pendingSuggestToken

    C_Timer.After(0.05, function()
        if token ~= self._pendingSuggestToken then
            return
        end
        if not self.frame or not self.frame:IsShown() then
            return
        end

        local typed = Trim(self.input:GetText())
        if #typed < 3 then
            self:HideSuggestions()
            return
        end

        self:BuildNameIndexIfNeeded()
        if not self._nameIndex or #self._nameIndex == 0 then
            self:HideSuggestions()
            return
        end

        local matches = self:ComputeSuggestions(ToLowerSafe(typed))
        self:ShowSuggestions(matches)
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
            NPCMV_Print("SUCCESS via:", labelPrefix, "ID:", chosenId)
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
    self:ResetVisuals()

    local raw = Trim(self.input:GetText())
    if raw == "" then
        return
    end

    local numeric = ParsePositiveInt(raw)
    if numeric then
        self:ApplyNumeric(numeric)
        return
    end

    self:ApplyName(raw)
end

function ModelViewer:ApplyNumeric(numberValue)
    local foundName = nil

    -- Tie back to name if possible
    if IsCreatureDisplayDBAvailable() then
        local data = CreatureDisplayDB:GetCreatureDisplayDataByNpcId(numberValue)
        if data and data.name then foundName = data.name end
        if not foundName then
            local data2 = CreatureDisplayDB:GetCreatureDisplayDataByDisplayId(numberValue)
            if data2 and data2.name then foundName = data2.name end
        end
    end

    if not foundName then
        local db = EnsureHarvestDB()
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

    if foundName and foundName ~= "" and foundName ~= "-" then
        self:ApplyName(foundName)
        -- After tying to name, ensure we select the correct NPC ID in browsing state
        for i, id in ipairs(self._curNpcIds) do
            if id == numberValue then
                self._curNpcIdx = i
                self:UpdateDispListForNpc(id)
                break
            end
        end
        -- Or if it was a Display ID
        for i, id in ipairs(self._curDispIds) do
            if id == numberValue then
                self._curDispIdx = i
                break
            end
        end
        self:SyncState()
        return
    end

    -- Fallback for orphaned IDs
    self._lastSearchName = "-"
    self._curNpcIds = {}
    self._curNpcIdx = 0
    self._curDispIds = {}
    self._curDispIdx = 0

    local isNpcId = false
    if IsCreatureDisplayDBAvailable() then
        local d = CreatureDisplayDB:GetCreatureDisplayDataByNpcId(numberValue)
        if d then isNpcId = true end
    end
    if not isNpcId then
        local db = EnsureHarvestDB()
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
    self._lastSearchName = npcName
    self._curNpcIds = {}
    self._curNpcIdx = 0
    self._curDispIds = {}
    self._curDispIdx = 0

    -- Update Global Index if found
    self:BuildNameIndexIfNeeded()
    local lowered = ToLowerSafe(npcName)
    if self._nameIndex then
        for i, entry in ipairs(self._nameIndex) do
            if entry.lower == lowered then
                self._curGlobalIdx = i
                break
            end
        end
    end

    local npcIds = {}
    local seen = {}

    -- 1) Lib
    if IsCreatureDisplayDBAvailable() then
        local ids = CreatureDisplayDB:GetNpcIdsByName(npcName)
        if ids then
            for _, id in ipairs(ids) do
                if not seen[id] then
                    table.insert(npcIds, id)
                    seen[id] = true
                end
            end
        end
    end

    -- 2) Local
    local db = EnsureHarvestDB()
    for _, batch in pairs(db.displayIdBatches) do
        for _, entry in pairs(batch) do
            if ToLowerSafe(entry.NPC_Name) == lowered then
                if not seen[entry.NPC_ID] then
                    table.insert(npcIds, entry.NPC_ID)
                    seen[entry.NPC_ID] = true
                end
            end
        end
    end

    table.sort(npcIds)
    self._curNpcIds = npcIds
    if #npcIds > 0 then
        self._curNpcIdx = 1
        self:UpdateDispListForNpc(npcIds[1])
    else
        -- Fallback: Check if name exists directly in lib via displayIds
        if IsCreatureDisplayDBAvailable() then
            local dids = CreatureDisplayDB:GetDisplayIdsByName(npcName)
            if dids and #dids > 0 then
                self._curDispIds = dids
                self._curDispIdx = 1
            end
        end
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

    self.export:SetScript("OnClick", function()
        ExportUI:Show()
    end)

    self.input:SetScript("OnEnterPressed", function()
        self:ApplyInput()
    end)

    self.input:SetScript("OnTextChanged", function(_, userInput)
        if not userInput then
            return
        end
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
        ExportUI:Show()
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

-- =========================================================
-- Harvest from hovered NPCs
-- =========================================================
local hoverHarvestHooked = false

function HookHarvestUnit(unit, source)
    if not unit then return end

    local okE, exists = pcall(UnitExists, unit)
    if not okE or not exists then return end

    local okP, isPlayer = pcall(UnitIsPlayer, unit)
    if okP and isPlayer then return end

    local okN, name = pcall(UnitName, unit)
    local okG, guid = pcall(UnitGUID, unit)
    local okD, displayId = pcall(function()
        return UnitCreatureDisplayID and UnitCreatureDisplayID(unit) or nil
    end)

    if not okN or not okG or not okD or not guid or not displayId or displayId <= 0 then
        return
    end

    local npcId = ParseNpcIdFromGuid(guid)
    if not npcId then return end

    AddHarvestEntry(name, npcId, displayId, source)

    if ModelViewer.frame and ModelViewer.frame:IsShown() then
        ModelViewer:LoadSpecific(npcId, displayId, name)
    end
end

local function HookHoverHarvestIfNeeded()
    if hoverHarvestHooked then return end
    hoverHarvestHooked = true

    -- 1. Modern Tooltip API
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
            if tooltip == GameTooltip then
                HookHarvestUnit("mouseover", "hover")
            end
        end)
        -- 2. Legacy Tooltip API
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(function()
            GameTooltip:HookScript("OnTooltipSetUnit", function()
                HookHarvestUnit("mouseover", "hover")
            end)
        end)
    end
end

-- =========================================================
-- Addon init
-- =========================================================
local InitFrame = CreateFrame("Frame")
InitFrame:RegisterEvent("ADDON_LOADED")
InitFrame:RegisterEvent("PLAYER_LOGIN")
InitFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
InitFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
InitFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")

InitFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureHarvestDB()
        ImportFromCreatureDisplayDBIfNeeded()
    elseif event == "PLAYER_LOGIN" then
        HookHoverHarvestIfNeeded()
    elseif event == "PLAYER_TARGET_CHANGED" then
        HookHarvestUnit("target", "target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        HookHarvestUnit("mouseover", "hover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        HookHarvestUnit(arg1, "nameplate")
    end
end)
