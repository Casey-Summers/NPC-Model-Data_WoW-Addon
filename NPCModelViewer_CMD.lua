-- =========================================================
-- NPC Model Viewer API (CMD)
-- Allows other addons to query the NPC Master Data
-- =========================================================

NPCModelViewerAPI = {}

--- Returns the main data table for an NPC by name
--- @param name string The NPC name
--- @return table|nil
function NPCModelViewerAPI:GetNpcDataByName(name)
    if not NPCModelViewer_Data then return nil end
    return NPCModelViewer_Data[name]
end

--- Returns all known NPC IDs for a given name
--- @param name string The NPC name
--- @return table|nil array of npcIds
function NPCModelViewerAPI:GetNpcIdsByName(name)
    local data = self:GetNpcDataByName(name)
    if not data or not data.ids then return nil end

    local ids = {}
    for npcId, _ in pairs(data.ids) do
        if type(npcId) == "number" then
            table.insert(ids, npcId)
        end
    end
    table.sort(ids)
    return ids
end

--- Returns all known Display IDs for a given name
--- @param name string The NPC name
--- @return table|nil array of displayIds
function NPCModelViewerAPI:GetDisplayIdsByName(name)
    local data = self:GetNpcDataByName(name)
    if not data or not data.ids then return nil end

    local ids = {}
    local seen = {}
    for _, dIds in pairs(data.ids) do
        for _, did in ipairs(dIds) do
            if type(did) == "number" and not seen[did] then
                table.insert(ids, did)
                seen[did] = true
            end
        end
    end
    table.sort(ids)
    return ids
end

--- Returns all known Display IDs for a given NPC ID
--- @param npcId number The NPC ID
--- @return table|nil array of displayIds
function NPCModelViewerAPI:GetDisplayIdsByNpcId(npcId)
    if not NPCModelViewer_Data then return nil end

    -- First check if we can find it by name if we have the index
    local names = self:GetNamesByNpcId(npcId)
    if names then
        for _, name in ipairs(names) do
            local data = NPCModelViewer_Data[name]
            if data and data.ids and data.ids[npcId] then
                return data.ids[npcId]
            end
        end
    end

    -- Fallback: Build full index if not already built and search
    if not self._npcIdToDisplayIds then
        self:BuildNpcIdIndex()
    end

    return self._npcIdToDisplayIds[npcId]
end

--- Returns the name associated with an NPC ID
--- @param npcId number The NPC ID
--- @return table|nil array of names
function NPCModelViewerAPI:GetNamesByNpcId(npcId)
    if not NPCModelViewer_Data then return nil end
    if not self._idToNames then
        self:BuildIdToNamesIndex()
    end
    return self._idToNames[npcId]
end

-- Metadata helper
local function GetMetadataForNpcId(data, field, npcId)
    if not data or not data[field] then return nil end
    for val, list in pairs(data[field]) do
        for _, id in ipairs(list) do
            if id == npcId then
                return val
            end
        end
    end
    return nil
end

function NPCModelViewerAPI:GetZoneForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "zones", npcId)
end

function NPCModelViewerAPI:GetTypeForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "types", npcId)
end

function NPCModelViewerAPI:GetFamilyForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "fams", npcId)
end

function NPCModelViewerAPI:GetClassificationForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "class", npcId)
end

function NPCModelViewerAPI:GetPatchForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "patch", npcId)
end

function NPCModelViewerAPI:GetTameableForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "tame", npcId)
end

function NPCModelViewerAPI:GetEncounterForNpcId(name, npcId)
    local data = self:GetNpcDataByName(name)
    return GetMetadataForNpcId(data, "enc", npcId)
end

function NPCModelViewerAPI:GetInstanceForEncounter(name, encounterName)
    local data = self:GetNpcDataByName(name)
    if not data or not data.inst then return nil end
    -- Note: This is an inverse lookup: Find the instance that contains this encounter
    for inst, encounters in pairs(data.inst) do
        for _, enc in ipairs(encounters) do
            if enc == encounterName then
                return inst
            end
        end
    end
    return nil
end

--- Returns data for an NPC ID (compatibility with CreatureDisplayDB)
function NPCModelViewerAPI:GetCreatureDisplayDataByNpcId(npcId)
    local names = self:GetNamesByNpcId(npcId)
    if names and names[1] then
        local name = names[1]
        local data = self:GetNpcDataByName(name)
        if data then
            local res = {
                name = name,
                npcId = npcId,
                displayIds = data.ids[npcId],
                zone = self:GetZoneForNpcId(name, npcId),
                type = self:GetTypeForNpcId(name, npcId),
                family = self:GetFamilyForNpcId(name, npcId),
                classification = self:GetClassificationForNpcId(name, npcId),
                patch = self:GetPatchForNpcId(name, npcId),
                tameable = self:GetTameableForNpcId(name, npcId)
            }
            return res
        end
    end
    return nil
end

function NPCModelViewerAPI:BuildIdToNamesIndex()
    self._idToNames = {}
    for name, data in pairs(NPCModelViewer_Data) do
        if data.ids then
            for npcId, _ in pairs(data.ids) do
                if type(npcId) == "number" then
                    self._idToNames[npcId] = self._idToNames[npcId] or {}
                    table.insert(self._idToNames[npcId], name)
                end
            end
        end
    end
end

function NPCModelViewerAPI:BuildNpcIdIndex()
    self._npcIdToDisplayIds = {}
    for name, data in pairs(NPCModelViewer_Data) do
        if data.ids then
            for npcId, displayIds in pairs(data.ids) do
                if type(npcId) == "number" then
                    self._npcIdToDisplayIds[npcId] = displayIds
                end
            end
        end
    end
end

-- Global alias
NPCModelData = NPCModelViewerAPI
