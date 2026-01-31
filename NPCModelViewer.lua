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
-- Local Harvest DB (SavedVariables)
-- =========================================================
local DB_VERSION = 1

local function EnsureHarvestDB()
    if not NPCModelViewerDB or type(NPCModelViewerDB) ~= "table" then
        NPCModelViewerDB = {}
    end

    NPCModelViewerDB.meta = NPCModelViewerDB.meta or {}
    NPCModelViewerDB.meta.version = NPCModelViewerDB.meta.version or DB_VERSION
    NPCModelViewerDB.meta.importedCreatureDisplayDB = NPCModelViewerDB.meta.importedCreatureDisplayDB or false

    -- entriesByKey: ["<npcId>:<displayId>"] = { name=..., npcId=..., displayId=..., firstSeen=..., lastSeen=..., sources={...} }
    NPCModelViewerDB.entriesByKey = NPCModelViewerDB.entriesByKey or {}
    NPCModelViewerDB.count = NPCModelViewerDB.count or 0

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

local function HarvestKey(npcId, displayId)
    return tostring(npcId or 0) .. ":" .. tostring(displayId or 0)
end

local function AddHarvestEntry(npcName, npcId, displayId, sourceLabel)
    npcId = tonumber(npcId)
    displayId = tonumber(displayId)
    if not npcId or npcId <= 0 or not displayId or displayId <= 0 then
        return false
    end

    local db = EnsureHarvestDB()
    local key = HarvestKey(npcId, displayId)
    local now = time()
    local entry = db.entriesByKey[key]
    local isNew = not entry

    if entry then
        entry.lastSeen = now
        if npcName and npcName ~= "" then
            entry.name = npcName
        end
    else
        db.entriesByKey[key] = {
            name = npcName or "",
            npcId = npcId,
            displayId = displayId,
            firstSeen = now,
            lastSeen = now,
            sources = {}
        }
        db.count = (db.count or 0) + 1
    end

    if sourceLabel and sourceLabel ~= "" then
        db.entriesByKey[key].sources[sourceLabel] = true
    end

    return true, isNew
end

local function ParseNpcIdFromGuid(guid)
    if not guid or guid == "" then
        return nil
    end
    -- Creature-0-0000-0000-0000-<npcId>-0000000000
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" and unitType ~= "Pet" then
        return nil
    end
    npcId = tonumber(npcId)
    if not npcId or npcId <= 0 then
        return nil
    end
    return npcId
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
    local skipped = 0

    -- Seed only (DB2-derived addon may be incomplete; hover harvesting is the real source of truth)
    for npcName, _ in pairs(CreatureDisplayDBdb.byname) do
        local npcIds = CreatureDisplayDB:GetNpcIdsByName(npcName)
        if npcIds and #npcIds > 0 then
            for _, npcId in ipairs(npcIds) do
                local displayIds = CreatureDisplayDB:GetDisplayIdsByNpcId(npcId)
                if displayIds and #displayIds > 0 then
                    for _, displayId in ipairs(displayIds) do
                        local ok, isNew = AddHarvestEntry(npcName, npcId, displayId, "CreatureDisplayDB")
                        if ok and isNew then
                            imported = imported + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                else
                    skipped = skipped + 1
                end
            end
        else
            -- fallback: DisplayID -> data -> npcId (if library provides it)
            local displayIds = CreatureDisplayDB:GetDisplayIdsByName(npcName)
            if displayIds and #displayIds > 0 then
                for _, displayId in ipairs(displayIds) do
                    local data = CreatureDisplayDB:GetCreatureDisplayDataByDisplayId(displayId)
                    local npcId = data and (data.npcId or data.NPCID or data.id) or nil
                    local ok, isNew = (npcId and AddHarvestEntry(npcName, npcId, displayId, "CreatureDisplayDB"))
                    if ok and isNew then
                        imported = imported + 1
                    else
                        skipped = skipped + 1
                    end
                end
            else
                skipped = skipped + 1
            end
        end
    end

    db.meta.importedCreatureDisplayDB = true
    NPCMV_Print("Seeded local DB from CreatureDisplayDB:", imported, "new entries (skipped:", skipped .. ")")
end

local function ExportHarvestCsv()
    local db = EnsureHarvestDB()
    local lines = {}
    lines[#lines + 1] = "NPC_Name,NPC_ID,Display_ID"

    local entries = {}
    for _, entry in pairs(db.entriesByKey) do
        entries[#entries + 1] = entry
    end

    table.sort(entries, function(a, b)
        local an = ToLowerSafe(a.name)
        local bn = ToLowerSafe(b.name)
        if an == bn then
            if a.npcId == b.npcId then
                return a.displayId < b.displayId
            end
            return a.npcId < b.npcId
        end
        return an < bn
    end)

    for _, entry in ipairs(entries) do
        lines[#lines + 1] = table.concat({ EscapeCsv(entry.name), tostring(entry.npcId), tostring(entry.displayId) }, ",")
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
-- Model Viewer (UI + logic)
-- =========================================================
local ModelViewer = {
    _namesIndexBuilt = false,
    _nameIndex = nil, -- array: { {name="X", lower="x"} ... }
    _pendingSuggestToken = 0
}

function ModelViewer:Ensure()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "NPCModelViewerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(620, 680)
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
    frame:SetBackdropColor(0, 0, 0, 0.80)
    frame:SetBackdropBorderColor(1, 1, 1, 0.15)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("NPC Model Viewer")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -6)
    subtitle:SetText("Type an NPC name / NPC_ID / DisplayID")

    local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    input:SetSize(360, 24)
    input:SetPoint("TOP", subtitle, "BOTTOM", -50, -14)
    input:SetAutoFocus(false)
    input:SetText("")
    input:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local go = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    go:SetSize(90, 24)
    go:SetPoint("LEFT", input, "RIGHT", 10, 0)
    go:SetText("Enter")

    local export = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    export:SetSize(90, 24)
    export:SetPoint("LEFT", go, "RIGHT", 10, 0)
    export:SetText("Export")

    -- Suggestions dropdown
    local suggest = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    suggest:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -2)
    suggest:SetPoint("TOPRIGHT", input, "BOTTOMRIGHT", 0, -2)
    suggest:SetHeight(1)
    suggest:Hide()
    suggest:SetFrameStrata("DIALOG")
    suggest:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1
    })
    suggest:SetBackdropColor(0, 0, 0, 0.92)
    suggest:SetBackdropBorderColor(1, 1, 1, 0.12)

    local suggestButtons = {}
    local MAX_SUGGEST = 8
    for index = 1, MAX_SUGGEST do
        local button = CreateFrame("Button", nil, suggest)
        button:SetHeight(18)
        button:SetPoint("TOPLEFT", 6, -6 - ((index - 1) * 18))
        button:SetPoint("TOPRIGHT", -6, -6 - ((index - 1) * 18))
        button:Hide()

        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", 0, 0)
        button.text:SetJustifyH("LEFT")

        button:SetScript("OnEnter", function(self)
            self.text:SetTextColor(1, 0.82, 0.25)
        end)
        button:SetScript("OnLeave", function(self)
            self.text:SetTextColor(1, 1, 1)
        end)

        suggestButtons[index] = button
    end

    local model = CreateFrame("PlayerModel", nil, frame)
    model:SetSize(580, 560)
    model:SetPoint("TOP", input, "BOTTOM", 0, -26)

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOM", 0, 10)
    status:SetText("")

    self.frame = frame
    self.title = title
    self.subtitle = subtitle
    self.input = input
    self.go = go
    self.export = export
    self.model = model
    self.status = status
    self.suggest = suggest
    self.suggestButtons = suggestButtons
    self.MAX_SUGGEST = MAX_SUGGEST
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
    self.status:SetText("")
end

function ModelViewer:SetStatus(text)
    self.status:SetText(text or "")
end

function ModelViewer:SetSubtitle(text)
    self.subtitle:SetText(text or "")
end

-- =========================================================
-- Suggestions / autocomplete
-- =========================================================
function ModelViewer:BuildNameIndexIfNeeded()
    if self._namesIndexBuilt then
        return
    end
    self._namesIndexBuilt = true

    self._nameIndex = {}
    local seen = {}

    -- 1) CreatureDisplayDB (if present)
    if IsCreatureDisplayDBAvailable() then
        for npcName, _ in pairs(CreatureDisplayDBdb.byname) do
            local lower = ToLowerSafe(npcName)
            if lower ~= "" and not seen[lower] then
                seen[lower] = true
                table.insert(self._nameIndex, {
                    name = npcName,
                    lower = lower
                })
            end
        end
    end

    -- 2) Our harvested DB (always)
    local db = EnsureHarvestDB()
    for _, entry in pairs(db.entriesByKey) do
        local npcName = entry and entry.name or nil
        local lower = ToLowerSafe(npcName)
        if lower ~= "" and not seen[lower] then
            seen[lower] = true
            table.insert(self._nameIndex, {
                name = npcName,
                lower = lower
            })
        end
    end

    if #self._nameIndex == 0 then
        NPCMV_Print("No name index available yet. Hover NPCs to harvest names, or install CreatureDisplayDB.")
        return
    end

    table.sort(self._nameIndex, function(a, b)
        return a.lower < b.lower
    end)
end

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
        self:SetSubtitle("Type an NPC name / NPC_ID / DisplayID")
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
    self:SetSubtitle("Loading: " .. tostring(numberValue))
    self:SetStatus("")

    local didTried = false

    if IsCreatureDisplayDBAvailable() then
        local asNpc = CreatureDisplayDB:GetCreatureDisplayDataByNpcId(numberValue)
        if asNpc then
            local displayIds = CreatureDisplayDB:GetDisplayIdsByNpcId(numberValue)
            if displayIds and #displayIds > 0 then
                self:SetStatus("Numeric lookup: NPC_ID -> DisplayIDs")
                self:TryIdSequence("Numeric->NPC_ID->DisplayIDs(SetDisplayInfo)", displayIds, function(model, id)
                    model:SetDisplayInfo(id)
                end, function(ok, chosenId)
                    if ok then
                        self:SetSubtitle("NPC_ID " .. numberValue .. " (DisplayID " .. chosenId .. ")")
                    else
                        self:SetStatus("Numeric lookup: NPC_ID -> SetCreature fallback")
                        self.model:ClearModel()
                        self.model:SetCreature(numberValue)
                        NPCMV_Print("SUCCESS via:", "Numeric->NPC_ID(SetCreature)", "ID:", numberValue)
                        self:SetSubtitle("NPC_ID " .. numberValue)
                    end
                end)
                return
            end

            self:SetStatus("Numeric lookup: NPC_ID -> SetCreature")
            self.model:ClearModel()
            self.model:SetCreature(numberValue)
            NPCMV_Print("SUCCESS via:", "Numeric->NPC_ID(SetCreature)", "ID:", numberValue)
            self:SetSubtitle("NPC_ID " .. numberValue)
            return
        end

        local asDid = CreatureDisplayDB:GetCreatureDisplayDataByDisplayId(numberValue)
        if asDid then
            self:SetStatus("Numeric lookup: DisplayID -> SetDisplayInfo")
            self.model:ClearModel()
            self.model:SetDisplayInfo(numberValue)
            NPCMV_Print("SUCCESS via:", "Numeric->DisplayID(SetDisplayInfo)", "ID:", numberValue)
            self:SetSubtitle("DisplayID " .. numberValue)
            didTried = true
            return
        end
    end

    self:SetStatus("Numeric fallback: SetDisplayInfo")
    self.model:ClearModel()
    self.model:SetDisplayInfo(numberValue)
    NPCMV_Print("SUCCESS via:", "Numeric->DisplayInfoDirect(SetDisplayInfo)", "ID:", numberValue)
    self:SetSubtitle("DisplayInfo ID " .. numberValue .. (didTried and " (DB unmatched)" or ""))
end

function ModelViewer:ApplyName(npcName)
    self:SetSubtitle("Loading: " .. npcName)
    self:SetStatus("")

    -- If CreatureDisplayDB isn't present, fall back to our harvested DB.
    if not IsCreatureDisplayDBAvailable() then
        local want = ToLowerSafe(npcName)
        local db = EnsureHarvestDB()
        local displayIds = {}
        local seen = {}

        for _, entry in pairs(db.entriesByKey) do
            if entry and ToLowerSafe(entry.name) == want then
                local did = tonumber(entry.displayId)
                if did and did > 0 and not seen[did] then
                    seen[did] = true
                    displayIds[#displayIds + 1] = did
                end
            end
        end

        if #displayIds == 0 then
            self:SetStatus("Name not found locally yet. Hover NPCs to harvest it, or install CreatureDisplayDB.")
            NPCMV_Print("Local DB: name not found:", npcName)
            return
        end

        table.sort(displayIds)
        self:SetStatus("Local DB: DisplayIDs -> SetDisplayInfo (fallback chain)")
        self:TryIdSequence("LocalDB->DisplayIDs(SetDisplayInfo)", displayIds, function(model, id)
            model:SetDisplayInfo(id)
        end, function(ok, chosenId)
            if ok then
                self:SetSubtitle(npcName .. " (DisplayID " .. chosenId .. ")")
            else
                self:SetStatus("Local DB had IDs, but no model loaded.")
                NPCMV_Print("Local DB: IDs exist but no model loaded for name:", npcName)
            end
        end)
        return
    end

    -- 1) Zone-fixed NPC_ID
    local fixedNpcId = CreatureDisplayDB:GetFixedNpcIdForCurrentZone(npcName)
    if fixedNpcId then
        self:SetStatus("Name lookup: ZoneFixed NPC_ID -> SetCreature")
        self.model:ClearModel()
        self.model:SetCreature(fixedNpcId)
        NPCMV_Print("SUCCESS via:", "Name->ZoneFixedNPC_ID(SetCreature)", "Name:", npcName, "NPC_ID:", fixedNpcId)
        self:SetSubtitle(npcName .. " (NPC_ID " .. fixedNpcId .. ")")
        return
    end

    -- 2) Prefer DisplayIDs list
    local displayIds = CreatureDisplayDB:GetDisplayIdsByName(npcName)
    if displayIds and #displayIds > 0 then
        self:SetStatus("Name lookup: DisplayIDs -> SetDisplayInfo (fallback chain)")
        self:TryIdSequence("Name->DisplayIDs(SetDisplayInfo)", displayIds, function(model, id)
            model:SetDisplayInfo(id)
        end, function(ok, chosenId)
            if ok then
                self:SetSubtitle(npcName .. " (DisplayID " .. chosenId .. ")")
            else
                local npcIds = CreatureDisplayDB:GetNpcIdsByName(npcName)
                if npcIds and #npcIds > 0 then
                    self:SetStatus("Name lookup: DisplayIDs failed -> NPC_IDs -> SetCreature (fallback chain)")
                    self:TryIdSequence("Name->NPC_IDs(SetCreature)", npcIds, function(model, id)
                        model:SetCreature(id)
                    end, function(ok2, chosenNpc)
                        if ok2 then
                            self:SetSubtitle(npcName .. " (NPC_ID " .. chosenNpc .. ")")
                        else
                            self:SetStatus("No model found for this name (DB entry exists).")
                            NPCMV_Print("FAILED: name found in DB, but no model loaded from IDs:", npcName)
                        end
                    end)
                else
                    self:SetStatus("Name not found (or has no IDs) in DB.")
                    NPCMV_Print("FAILED: no IDs for name:", npcName)
                end
            end
        end)
        return
    end

    local npcIds = CreatureDisplayDB:GetNpcIdsByName(npcName)
    if npcIds and #npcIds > 0 then
        self:SetStatus("Name lookup: NPC_IDs -> SetCreature (fallback chain)")
        self:TryIdSequence("Name->NPC_IDs(SetCreature)", npcIds, function(model, id)
            model:SetCreature(id)
        end, function(ok, chosenNpc)
            if ok then
                self:SetSubtitle(npcName .. " (NPC_ID " .. chosenNpc .. ")")
            else
                self:SetStatus("No model found for this name (DB entry exists).")
                NPCMV_Print("FAILED: name found in DB, but no model loaded from NPC_IDs:", npcName)
            end
        end)
        return
    end

    self:SetStatus("Name not found in DB.")
    NPCMV_Print("FAILED: name not found in DB:", npcName)
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

local function HookHoverHarvestIfNeeded()
    if hoverHarvestHooked then
        return
    end
    hoverHarvestHooked = true

    if not GameTooltip or not GameTooltip.HookScript then
        return
    end

    GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
        local _, unit = tooltip:GetUnit()
        unit = unit or "mouseover"
        if not UnitExists(unit) then
            return
        end

        local name = UnitName(unit)
        local guid = UnitGUID(unit)
        local npcId = ParseNpcIdFromGuid(guid)
        if not npcId then
            return
        end

        local displayId = UnitCreatureDisplayID and UnitCreatureDisplayID(unit) or nil
        if not displayId or displayId <= 0 then
            return
        end

        local ok, isNew = AddHarvestEntry(name, npcId, displayId, "hover")
        if ok and isNew then
            NPCMV_Print("Harvested:", name, "NPC_ID", npcId, "Display_ID", displayId)
            ModelViewer._namesIndexBuilt = false
        end
    end)
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
        ImportFromCreatureDisplayDBIfNeeded()
    elseif event == "PLAYER_LOGIN" then
        HookHoverHarvestIfNeeded()
    end
end)
