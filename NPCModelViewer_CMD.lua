-- =========================================================
-- NPC Model Viewer API (CMD)
-- Optimized for bucket-based lazy loading and efficient search
-- =========================================================

NPCModelViewerAPI = {
    _loadedBuckets = {},
    _reverseIndexes = {},
    _bucketSizeCache = {},
    _idToNames = {},
    _npcIdToDisplayIds = {},
}

-- Global aliases
NPCModelData = NPCModelViewerAPI

-- =========================================================
-- Helpers
-- =========================================================

local function Normalize(query)
    if not query then return "" end
    -- Lowercase, trim, collapse multiple spaces
    local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    q = q:gsub("%s+", " ")
    return q
end

function NPCModelViewerAPI:Initialize()
    -- Build reverse maps for indexes
    if NPCModelViewer_Indexes then
        for category, map in pairs(NPCModelViewer_Indexes) do
            self._reverseIndexes[category] = {}
            for id, name in pairs(map) do
                if type(name) == "string" then
                    self._reverseIndexes[category][name:lower()] = id
                end
            end
        end
    end

    -- Initialize Cache in SavedVariables
    if not NPCModelViewerDB then NPCModelViewerDB = {} end
    -- Clear cache to ensure new sorting logic applies immediately
    NPCModelViewerDB.searchCache = {}

    -- If data is already loaded (single-file setup), build ID indexes once
    if NPCModelViewer_Data then
        self:BuildFullIdIndex()
    end
end

function NPCModelViewerAPI:BuildFullIdIndex()
    self._idToNames = {}
    self._npcIdToDisplayIds = {}
    for groupKey, bucket in pairs(NPCModelViewer_Data) do
        self._loadedBuckets[groupKey] = true
        for name, data in pairs(bucket) do
            if data.ids then
                for npcId, displayIds in pairs(data.ids) do
                    self._idToNames[npcId] = self._idToNames[npcId] or {}
                    table.insert(self._idToNames[npcId], name)
                    self._npcIdToDisplayIds[npcId] = displayIds
                end
            end
        end
    end
end

function NPCModelViewerAPI:GetGroupKeys(q)
    if #q < 2 then return {} end

    local k2 = q:sub(1, 2):upper()
    local k3 = q:sub(1, 3):upper()
    local keys = {}

    if NPCModelViewer_Data then
        -- If data is loaded, look for any keys starting with k3 or k2 (including numeric suffixes)
        for groupKey in pairs(NPCModelViewer_Data) do
            -- Match "SHA", "SHA1", "SHA2" etc.
            if groupKey == k3 or groupKey:match("^" .. k3 .. "%d+$") then
                table.insert(keys, groupKey)
            end
        end

        -- If no 3-letter keys found, look for 2-letter keys
        if #keys == 0 then
            for groupKey in pairs(NPCModelViewer_Data) do
                if type(groupKey) == "string" and (groupKey == k2 or groupKey:match("^" .. k2 .. "%d+$")) then
                    table.insert(keys, groupKey)
                end
            end
        end
    end

    -- If still empty (e.g. LOD not yet loaded), we can't easily know the suffixes
    -- so we return at least the base keys to trigger LoadBucket
    if #keys == 0 then
        table.insert(keys, k3)
        table.insert(keys, k2)
    end

    return keys
end

function NPCModelViewerAPI:LoadBucket(groupKey)
    if self._loadedBuckets[groupKey] then return true end

    -- Check if it already exists in the global table (single-file setup)
    if NPCModelViewer_Data and NPCModelViewer_Data[groupKey] then
        self._loadedBuckets[groupKey] = true
        return true
    end

    -- Attempt to load via LOD addon mechanism
    local addonName = "NPCModelViewer_Data_" .. groupKey
    -- Some addons might be named without the suffix if only one exists
    -- But we follow the groupKey exactly
    if C_AddOns.IsAddOnLoadable(addonName) then
        local loaded, reason = C_AddOns.LoadAddOn(addonName)
        if loaded then
            self._loadedBuckets[groupKey] = true
            return true
        end
    end

    return false
end

-- =========================================================
-- Search Implementation
-- =========================================================

function NPCModelViewerAPI:Search(query)
    local q = Normalize(query)
    if #q < 2 then return nil end

    -- Check Cache
    local cache = NPCModelViewerDB.searchCache
    for i, entry in ipairs(cache) do
        if entry.q == q then
            table.remove(cache, i)
            table.insert(cache, 1, entry)
            return entry.results
        end
    end

    -- Find Buckets
    local groupKeys = self:GetGroupKeys(q)
    if #groupKeys == 0 then return nil end

    local results = {}
    local exactMatch = nil
    local searchedBuckets = {}
    local seenPairs = {} -- For duplicate filtering

    for _, groupKey in ipairs(groupKeys) do
        if not searchedBuckets[groupKey] then
            self:LoadBucket(groupKey)
            searchedBuckets[groupKey] = true

            local bucket = NPCModelViewer_Data and NPCModelViewer_Data[groupKey]
            if bucket then
                -- 1. Exact Match Scan
                for realName, data in pairs(bucket) do
                    if Normalize(realName) == q then
                        self:AppendResults(results, realName, data, seenPairs)
                        exactMatch = true
                    end
                end

                -- 2. Prefix/Contains Scan (only if no exact match found yet or we want more)
                if not exactMatch or #results < 10 then
                    for realName, data in pairs(bucket) do
                        local normName = Normalize(realName)
                        if normName:find(q, 1, true) and normName ~= q then
                            self:AppendResults(results, realName, data, seenPairs)
                            if #results > 100 then break end
                        end
                    end
                end
            end
            if #results > 100 then break end
        end
    end

    if #results > 0 then
        -- GLOBAL SORT: Ensure variants are always presented in ascending order
        table.sort(results, function(a, b)
            -- Primary sort: Name (alphabetical)
            if a.name ~= b.name then
                return a.name < b.name
            end
            -- Secondary sort: NPC ID (numeric ascending)
            local na, nb = tonumber(a.npcId), tonumber(b.npcId)
            if na and nb and na ~= nb then
                return na < nb
            end
            if tostring(a.npcId) ~= tostring(b.npcId) then
                return tostring(a.npcId) < tostring(b.npcId)
            end
            -- Tertiary sort: Display ID (numeric ascending)
            local da, db = tonumber(a.displayId), tonumber(b.displayId)
            if da and db and da ~= db then
                return da < db
            end
            return tostring(a.displayId) < tostring(b.displayId)
        end)

        -- Cache results
        table.insert(cache, 1, { q = q, results = results })
        while #cache > 20 do table.remove(cache) end
        return results
    end

    return nil
end

function NPCModelViewerAPI:AppendResults(results, name, data, seenPairs)
    local sortedNpcIds = {}
    for npcId in pairs(data.ids) do
        table.insert(sortedNpcIds, npcId)
    end
    table.sort(sortedNpcIds, function(a, b)
        if a == "NoData" then return false end
        if b == "NoData" then return true end
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)

    for _, npcId in ipairs(sortedNpcIds) do
        local displayIds = data.ids[npcId]
        local idList = {}
        if type(displayIds) == "table" then
            for _, did in ipairs(displayIds) do table.insert(idList, did) end
        else
            table.insert(idList, displayIds)
        end
        table.sort(idList, function(a, b)
            if a == "NoData" then return false end
            if b == "NoData" then return true end
            local na, nb = tonumber(a), tonumber(b)
            if na and nb then return na < nb end
            return tostring(a) < tostring(b)
        end)

        local encounterId = self:GetMetadataValue(data, "enc", npcId)
        local instanceId = encounterId and self:GetMetadataValue(data, "inst", encounterId)

        for _, dispId in ipairs(idList) do
            -- Explicit Filtering: Ensure no duplicate NPCID+DisplayID pairs for the same name
            local key = name .. "_" .. tostring(npcId) .. "_" .. tostring(dispId)
            if not seenPairs[key] then
                seenPairs[key] = true
                table.insert(results, {
                    name = name,
                    npcId = npcId,
                    displayId = dispId,
                    zone = self:GetMetadataValue(data, "zones", npcId),
                    type = self:GetMetadataValue(data, "types", npcId),
                    family = self:GetMetadataValue(data, "fams", npcId),
                    class = self:GetMetadataValue(data, "class", npcId),
                    patch = self:GetMetadataValue(data, "patch", npcId),
                    instance = instanceId,
                    encounter = encounterId,
                    tameable = self:GetMetadataValue(data, "tame", npcId),
                })
            end
        end
    end
end

function NPCModelViewerAPI:GetMetadataValue(data, field, npcId)
    if not data or not data[field] then return nil end
    for labelId, npcList in pairs(data[field]) do
        if type(npcList) == "table" then
            for _, id in ipairs(npcList) do
                if id == npcId then return labelId end
            end
        elseif npcList == npcId then
            return labelId
        end
    end
    return nil
end

-- =========================================================
-- Legacy & ID Lookups
-- =========================================================

function NPCModelViewerAPI:GetNamesByNpcId(npcId)
    return self._idToNames[npcId]
end

function NPCModelViewerAPI:GetDisplayIdsByNpcId(npcId)
    return self._npcIdToDisplayIds[npcId]
end

function NPCModelViewerAPI:GetNpcDataByName(name)
    local res = self:Search(name)
    return res and res[1] -- Return first variant for legacy support
end
