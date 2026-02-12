-- =========================================================
-- NPC Data Viewer API (CMD)
-- Optimized for bucket-based lazy loading and efficient search
-- =========================================================

NPCDataViewerAPI = {
    _loadedBuckets = {},
    _reverseIndexes = {},
    _bucketSizeCache = {},
    _idToNames = {},
    _npcIdToDisplayIds = {},
}

-- Global aliases
NPCDataViewer = NPCDataViewerAPI
NPCModelViewer = NPCDataViewerAPI    -- Legacy support
NPCModelViewerAPI = NPCDataViewerAPI -- Legacy support

-- =========================================================
-- Helpers
-- =========================================================

local function _Trim(str)
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strict-ish: keeps word characters, converts punctuation to spaces.
-- Also strips paired leading/trailing quotes so queries like '"Chowdar"' match.
local function NormalizeStrict(input)
    if input == nil then return "" end
    local q = tostring(input)

    -- Normalize smart quotes to ASCII
    q = q:gsub("[“”]", '"'):gsub("[‘’]", "'")
    q = q:lower()
    q = _Trim(q)

    -- Strip paired surrounding quotes repeatedly
    while true do
        local first = q:sub(1, 1)
        local last  = q:sub(-1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            q = _Trim(q:sub(2, -2))
        else
            break
        end
    end

    -- Convert punctuation to spaces, keep alnum + underscore
    q = q:gsub("[^%w%s]", " ")
    q = q:gsub("%s+", " ")
    return q
end

-- Compact: removes ALL non-alphanumeric characters (including spaces and punctuation).
-- Helps match names that vary by punctuation (e.g., 'A-Me 02' vs 'A Me 02').
local function NormalizeCompact(input)
    if input == nil then return "" end
    local q = tostring(input)

    q = q:gsub("[“”]", '"'):gsub("[‘’]", "'")
    q = q:lower()
    q = _Trim(q)

    while true do
        local first = q:sub(1, 1)
        local last  = q:sub(-1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            q = _Trim(q:sub(2, -2))
        else
            break
        end
    end

    q = q:gsub("[^%w]", "")
    return q
end

-- Backwards compatible helper used by ID searches.
local function Normalize(input)
    if not input then return "" end
    local q = tostring(input):lower()
    if q.trim then q = q:trim() else q = _Trim(q) end
    q = q:gsub("%s+", " ")
    return q
end

local function StripPunctuation(str)
    if not str then return "" end
    return tostring(str):gsub("[%s%p]", ""):lower()
end

function NPCDataViewerAPI:Initialize()
    -- Build reverse maps for indexes
    if NPCDataViewer_Indexes then
        for category, map in pairs(NPCDataViewer_Indexes) do
            self._reverseIndexes[category] = {}
            for id, name in pairs(map) do
                if type(name) == "string" then
                    self._reverseIndexes[category][name:lower()] = id
                end
            end
        end
    end

    -- Initialize Cache in SavedVariables
    if not NPCDataViewerDB then NPCDataViewerDB = {} end
    -- Clear cache to ensure new sorting logic applies immediately
    NPCDataViewerDB.searchCache = {}

    -- If data is already loaded (single-file setup), build ID indexes once
    if NPCDataViewer_Data then
        self:BuildFullIdIndex()
    end
end

function NPCDataViewerAPI:BuildFullIdIndex()
    self._idToNames = {}
    self._npcIdToDisplayIds = {}
    for groupKey, bucket in pairs(NPCDataViewer_Data) do
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

function NPCDataViewerAPI:GetGroupKeys(qStrict)
    if #qStrict < 3 then return {} end

    local keys = {}
    -- Probing prefixes of 1, 2, and 3 characters
    for i = 1, math.min(3, #qStrict) do
        local prefix = qStrict:sub(1, i):upper()
        local baseAddon = "NPCDataViewer_Data_" .. prefix
        local segAddon = "NPCDataViewer_Data_" .. prefix .. "1"

        -- Probe for existence (either base or first segment)
        if C_AddOns.GetAddOnInfo(baseAddon) or C_AddOns.GetAddOnInfo(segAddon) then
            table.insert(keys, prefix)
        elseif NPCDataViewer_Data and (NPCDataViewer_Data[prefix] or NPCDataViewer_Data[prefix .. "1"]) then
            -- Fallback for already loaded or single-file data
            table.insert(keys, prefix)
        end
    end

    -- If no matches found yet, return base prefixes to trigger LoadBucket discovery
    if #keys == 0 then
        table.insert(keys, qStrict:sub(1, 3):upper())
        table.insert(keys, qStrict:sub(1, 2):upper())
    end

    return keys
end

function NPCDataViewerAPI:LoadBucket(prefix)
    local actualKeys = {}

    -- 1. Try Base Key
    if self:_TryLoad(prefix) then
        table.insert(actualKeys, prefix)
    end

    -- 2. Try Segmented Keys (Prefix1, Prefix2, ...)
    local i = 1
    while true do
        local segKey = prefix .. i
        if self:_TryLoad(segKey) then
            table.insert(actualKeys, segKey)
            i = i + 1
        else
            break
        end
    end

    return actualKeys
end

function NPCDataViewerAPI:LoadAllBuckets()
    if self._allBucketsLoaded then return end

    -- Probe all possible prefixes A-Z
    for i = 65, 90 do
        local prefix = string.char(i)
        self:LoadBucket(prefix)
    end
    -- Also numbers if any? Usually A-Z + specific ones
    self._allBucketsLoaded = true
    return true
end

function NPCDataViewerAPI:_TryLoad(groupKey)
    if self._loadedBuckets[groupKey] then return true end

    -- Check if it already exists in the global table (single-file setup)
    if NPCDataViewer_Data and NPCDataViewer_Data[groupKey] then
        self._loadedBuckets[groupKey] = true
        return true
    end

    -- Attempt to load via LOD addon mechanism
    local addonName = "NPCDataViewer_Data_" .. groupKey
    if C_AddOns.GetAddOnInfo(addonName) then
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

function NPCDataViewerAPI:Search(query, searchType)
    searchType = searchType or "Name"
    local qStrict = NormalizeStrict(query)
    local qCompact = NormalizeCompact(query)
    local q = qStrict

    if searchType == "Name" then
        if #q < 3 then return nil end
    else
        if #q < 1 then return nil end
    end

    -- Check Cache (Only for Name search for now to keep it simple)
    if searchType == "Name" then
        local cache = NPCDataViewerDB.searchCache
        for i, entry in ipairs(cache) do
            if entry.q == qStrict then
                table.remove(cache, i)
                table.insert(cache, 1, entry)
                return entry.results
            end
        end
    end

    local results = {}
    local searchedBuckets = {}
    local seenPairs = {}

    if searchType == "NPC ID" or searchType == "Display ID" then
        local targetId = tonumber(q)
        if not targetId then return nil end

        -- Ensure deterministic ID search across entire database
        self:LoadAllBuckets()

        if NPCDataViewer_Data then
            for groupKey, bucket in pairs(NPCDataViewer_Data) do
                for realName, data in pairs(bucket) do
                    if data.ids then
                        for npcId, displayIds in pairs(data.ids) do
                            local match = false
                            if searchType == "NPC ID" and tonumber(npcId) == targetId then
                                match = true
                            elseif searchType == "Display ID" then
                                local dList = type(displayIds) == "table" and displayIds or { displayIds }
                                for _, did in ipairs(dList) do
                                    if tonumber(did) == targetId then
                                        match = true; break
                                    end
                                end
                            end

                            if match then
                                self:AppendResults(results, realName, data, seenPairs)
                            end
                        end
                    end
                end
            end
        end

        local hdb = NPCDataViewerDB
        if hdb and hdb.displayIdBatches then
            for _, batch in pairs(hdb.displayIdBatches) do
                for _, entry in pairs(batch) do
                    local match = false
                    if searchType == "NPC ID" and entry.NPC_ID == targetId then
                        match = true
                    elseif searchType == "Display ID" and entry.Display_ID == targetId then
                        match = true
                    end
                    if match then
                        local key = entry.NPC_Name .. "_" .. tostring(entry.NPC_ID) .. "_" .. tostring(entry.Display_ID)
                        if not seenPairs[key] then
                            seenPairs[key] = true
                            table.insert(results, {
                                name = entry.NPC_Name,
                                npcId = entry.NPC_ID,
                                displayId = entry.Display_ID,
                            })
                        end
                    end
                end
            end
        end

        if #results > 0 then return results end
        return nil
    end

    -- Find Buckets for Name Search
    local prefixes = self:GetGroupKeys(qStrict)
    if #prefixes == 0 then return nil end

    local results = {}
    local exactMatch = nil
    local searchedBuckets = {}
    local seenPairs = {} -- For duplicate filtering

    for _, prefix in ipairs(prefixes) do
        local groupKeys = self:LoadBucket(prefix)
        for _, groupKey in ipairs(groupKeys) do
            if not searchedBuckets[groupKey] then
                searchedBuckets[groupKey] = true

                local bucket = NPCDataViewer_Data and NPCDataViewer_Data[groupKey]
                if bucket then
                    -- 1. Exact Match Scan
                    for realName, data in pairs(bucket) do
                        local rnStrict = NormalizeStrict(realName)
                        if rnStrict == qStrict or NormalizeCompact(realName) == qCompact then
                            self:AppendResults(results, realName, data, seenPairs)
                            exactMatch = true
                        end
                    end

                    -- 2. Prefix/Contains Scan (only if no exact match found yet)
                    if not exactMatch then
                        for realName, data in pairs(bucket) do
                            local rnStrict = NormalizeStrict(realName)
                            local rnCompact = NormalizeCompact(realName)

                            local strictHit = rnStrict:find(qStrict, 1, true) and rnStrict ~= qStrict
                            local compactHit = (qCompact ~= "") and rnCompact:find(qCompact, 1, true) and
                            rnCompact ~= qCompact

                            if strictHit or compactHit then
                                self:AppendResults(results, realName, data, seenPairs)
                                if #results > 100 then break end
                            end
                        end
                    end
                end
                if #results > 100 then break end
            end
        end
        if #results > 100 then break end
        if exactMatch then break end -- Stop if we found exact matches
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

        -- Cache results (only for Name search)
        if searchType == "Name" then
            local cache = NPCDataViewerDB.searchCache
            table.insert(cache, 1, { q = qStrict, results = results })
            while #cache > 20 do table.remove(cache) end
        end
        return results
    end

    return nil
end

function NPCDataViewerAPI:AppendResults(results, name, data, seenPairs)
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

function NPCDataViewerAPI:GetMetadataValue(data, field, npcId)
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

function NPCDataViewerAPI:GetNamesByNpcId(npcId)
    return self._idToNames[npcId]
end

function NPCDataViewerAPI:GetDisplayIdsByNpcId(npcId)
    return self._npcIdToDisplayIds[npcId]
end

function NPCDataViewerAPI:GetNpcDataByName(name)
    local res = self:Search(name)
    return res and res[1] -- Return first variant for legacy support
end
