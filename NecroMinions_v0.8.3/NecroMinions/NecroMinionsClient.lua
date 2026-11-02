-- Client integration: unit tokens, owner auras and the native Life Force pool.
-- The spell IDs and resource formula match this client's FrameXML/Spell.dbc.
NecroMinionsClient = {}
local Client = NecroMinionsClient

local auraKinds = {
    [805016] = "lesser", [807927] = "greater", [805021] = "rogue",
    [805019] = "ghoul", [805020] = "mage", [800034] = "fiend",
    [805017] = "abomination", [805022] = "colossus",
    [805025] = "archer", [805028] = "gargoyle", [807840] = "banshee",
}
local sacrificeSpells = { [805027] = true, [807938] = true, [807939] = true, [807940] = true, [807941] = true }
-- Actual combat summon effects from this client's Spell.dbc. Utility pets can
-- share guardian flags, and even an Animate: prefix (Skeletal Smith repairs).
local summonKinds = {
    [500970] = "lesser", [504901] = "greater", [500969] = "rogue",
    [500971] = "ghoul", [500331] = "mage", [500335] = "abomination",
    [504859] = "fiend", [500989] = "colossus", [500329] = "gargoyle",
    [504861] = "banshee", [500330] = "archer", [500332] = "archer", [801941] = "fiend",
    [302586] = "zombie", [504313] = "zombie", [525379] = "zombie",
    [302913] = "zombie", [525380] = "zombie", [520365] = "thrall",
    [531130] = "boneconstruct", [704722] = "rotling", [800936] = "rotling",
    [805977] = "rotling", [520367] = "muckworm", [806087] = "muckworm",
    [805032] = "bonewraith", [805044] = "tombking",
    [504505] = "plaguefather", [805048] = "plaguefather",
    [805428] = "frostwyrm", [280740] = "frostwyrm",
}
local temporarySpells = {
    [500330] = true, [801941] = true, [302586] = true, [504313] = true,
    [525379] = true, [302913] = true, [525380] = true, [520365] = true,
    [531130] = true, [704722] = true, [800936] = true, [805977] = true,
    [520367] = true, [806087] = true, [805032] = true, [805044] = true,
    [504505] = true, [805048] = true, [805428] = true, [280740] = true,
    [805040] = true, [805049] = true, [807811] = true, [807813] = true, [561138] = true,
}
-- Skeletal Archer is not listed: Raise: Skeletal Archer (500332) is a
-- permanent, 1 Life Force minion; only the Animate summon (500330) is temporary.
local temporaryKinds = {
    zombie = true, thrall = true, boneconstruct = true,
    rotling = true, muckworm = true, bonewraith = true, tombking = true,
    plaguefather = true, frostwyrm = true, frostgiant = true, champion = true,
}
local creatureKinds = {
    ["lesser skeletal warrior"] = "lesser", ["skeletal warrior"] = "lesser",
    ["brittle skeleton"] = "lesser", ["greater skeletal warrior"] = "greater",
    ["skeletal rogue"] = "rogue", ["ghoul"] = "ghoul", ["skeletal mage"] = "mage",
    ["crypt fiend"] = "fiend", ["abomination"] = "abomination",
    ["decaying colossus"] = "colossus", ["flesh colossus"] = "colossus",
    ["flesh giant"] = "colossus", ["skeletal archer"] = "archer",
    ["gargoyle"] = "gargoyle", ["banshee"] = "banshee",
    ["lesser zombie"] = "zombie", ["zombie"] = "zombie", ["greater zombie"] = "zombie",
    ["putrid thrall"] = "thrall", ["bone construct"] = "boneconstruct",
    ["rotling"] = "rotling", ["muckworm"] = "muckworm", ["bone wraith"] = "bonewraith",
    ["tomb king"] = "tombking", ["plaguefather"] = "plaguefather", ["frost wyrm"] = "frostwyrm",
    -- Ghoul Mastery can turn a Ghoul into a Frenzied Ghoul (same minion).
    ["frenzied ghoul"] = "ghoul",
    -- Summoning Mastery (805042) teaches these Raises; CR's class data has no
    -- Life Force cost for them, so they count only once a cost is set.
    ["flesh golem"] = "fleshgolem", ["gurgling horror"] = "gurglinghorror",
    -- Army of the North / Unholy Frenzy, and the three Champion spells.
    ["rotting frost giant"] = "frostgiant",
    ["gravebound champion"] = "champion", ["spellbound champion"] = "champion",
    ["icebound champion"] = "champion",
}
-- Raise/Animate casts by ID (summonKinds also holds the Raise IDs). Mass
-- Raise (505550) raises every minion selected on the Life Force hotbar.
local summonCasts = {
    [505550] = true, [504315] = true, [525378] = true, [525381] = true,
    [805040] = true, [805049] = true, [807811] = true, [807813] = true,
    [561138] = true,
}
-- Animate: Skeletal Smith is a repair helper, not a combat minion.
local utilityCasts = { [804681] = true }
-- Creature names first seen on a summon right after a Raise/Animate cast,
-- saved per character so later sightings recognize them too.
local learnedNames = {}
local nameplateCVars = { "nameplateShowFriends", "nameplateShowFriendlyGuardians", "nameplateShowFriendlyPets" }
local hiddenPlates = {}
-- An alpha-zero plate still receives clicks. Cloaked plates also have mouse
-- input disabled where that is allowed; the original state is kept here.
local hiddenPlateMouse = {}
-- Keep restoration data without keeping a destroyed native frame alive. A
-- pooled frame may become active again as an enemy; restore only at that point.
local pendingPlateAlphas = setmetatable({}, { __mode = "k" })
local pendingPlateMouse = setmetatable({}, { __mode = "k" })
local unitTokensByGUID = {}
-- Reused by the per-frame visual check so it does not allocate every frame.
local visualScratch = {}

-- A cached frame userdata can outlive its native nameplate. Never call frame
-- methods just because a frame remains in hiddenPlates: obtain a fresh active
-- set from the live client first, without dereferencing the cached objects.
local function activeNameplates(into)
    local active = into or {}
    if into then for plate in pairs(into) do into[plate] = nil end end
    if Client.isLoggingOut then return active end
    if C_NamePlateManager and type(C_NamePlateManager.EnumerateActiveNamePlates) == "function" then
        local ok = pcall(function()
            for plate in C_NamePlateManager.EnumerateActiveNamePlates() do
                if plate then active[plate] = true end
            end
        end)
        if ok then return active, true end
        for plate in pairs(active) do active[plate] = nil end
    end
    if C_NamePlate and type(C_NamePlate.GetNamePlates) == "function" then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for _, plate in pairs(plates) do
                if plate then active[plate] = true end
            end
            return active, true
        end
    end
    if C_NamePlate and type(C_NamePlate.GetNamePlateForUnit) == "function" then
        for i = 1, 40 do
            local unit = "nameplate"..i
            if UnitGUID(unit) then
                local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
                if ok and plate then active[plate] = true end
            end
        end
    end
    return active, false
end

local function discardInactivePlates(active)
    for plate, alpha in pairs(hiddenPlates) do
        -- No method lookup on inactive userdata is allowed. Retain only a weak
        -- restoration record in case the client pools and reuses this frame.
        if not active[plate] then
            pendingPlateAlphas[plate] = alpha
            hiddenPlates[plate] = nil
        end
    end
    -- Muted mouse input is tracked separately: taken-over plates mute it
    -- without touching alpha.
    for plate, mouse in pairs(hiddenPlateMouse) do
        if not active[plate] then
            pendingPlateMouse[plate] = mouse
            hiddenPlateMouse[plate] = nil
        end
    end
end

-- Mouse changes are skipped in combat and on protected plates, where they
-- would be blocked rather than raise a catchable error.
local function canChangePlateMouse(plate)
    if InCombatLockdown() then return false end
    local ok, protected = pcall(plate.IsProtected, plate)
    return not (ok and protected)
end

local function restorePlateMouse(plate, enabled)
    if enabled == nil then return true end
    if not canChangePlateMouse(plate) then return false end
    return pcall(plate.EnableMouse, plate, enabled)
end

local function restorePendingPlate(plate)
    local alpha = pendingPlateAlphas[plate]
    if alpha ~= nil then
        local ok = pcall(plate.SetAlpha, plate, alpha)
        if ok then pendingPlateAlphas[plate] = nil end
    end
    if pendingPlateMouse[plate] ~= nil and restorePlateMouse(plate, pendingPlateMouse[plate]) then
        pendingPlateMouse[plate] = nil
    end
end

function Client.GUID(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    -- Some backports wrap a Wrath GUID inside a retail-style log GUID.
    return (guid:match("(0[xX]%x+)$") or guid):lower()
end

-- UnitName returns the client's placeholder for a unit whose object is not
-- loaded (not yet, or a stale token after despawn). It is neither a real name
-- nor evidence that the unit is alive.
function Client.IsUnknownName(name)
    return type(name) ~= "string" or name == "" or name == "Unknown"
        or name == UNKNOWNOBJECT or name == UNKNOWN
end

function Client.Kind(name)
    if type(name) ~= "string" then return nil end
    local key = name:lower():match("^%s*(.-)%s*$")
    return creatureKinds[key] or learnedNames[key]
end

function Client.SetLearnedNames(names)
    learnedNames = type(names) == "table" and names or {}
end

function Client.LearnName(name, kind)
    if type(name) ~= "string" or type(kind) ~= "string" or Client.IsUnknownName(name) then return end
    local key = name:lower():match("^%s*(.-)%s*$")
    if key ~= "" and not creatureKinds[key] then learnedNames[key] = kind end
end

local function castCreature(spellName)
    return type(spellName) == "string" and spellName:lower():match("^%a+:%s*(.-)%s*$")
end

-- A Raise, Animate or Mass Raise cast by the player: any of these may summon
-- minions, including ones whose creature name this file does not list.
function Client.IsSummonCast(spellID, spellName)
    spellID = tonumber(spellID)
    if utilityCasts[spellID] then return false end
    if summonCasts[spellID] or summonKinds[spellID] then return true end
    if type(spellName) ~= "string" then return false end
    local lower = spellName:lower()
    if lower:find("skeletal smith", 1, true) then return false end
    return lower == "mass raise" or lower:find("^raise:") ~= nil or lower:find("^animate:") ~= nil
end

-- The kind a summon cast creates when the summon event itself does not say.
-- Mass Raise covers several kinds, so it gives none.
function Client.CastKind(spellID, spellName)
    return summonKinds[tonumber(spellID)] or Client.Kind(castCreature(spellName))
end

function Client.IsAnimateCast(spellID, spellName)
    if temporarySpells[tonumber(spellID)] then return true end
    return type(spellName) == "string" and spellName:lower():find("^animate") ~= nil
end

function Client.IsSacrifice(spellID, spellName)
    if sacrificeSpells[tonumber(spellID)] then return true end
    -- Dismiss Undead (added by CR) also removes every minion at once.
    if spellName == "Sacrifice Undead" or spellName == "Dismiss Undead" then return true end
    if GetSpellInfo then
        local localizedName = GetSpellInfo(805027)
        return localizedName and spellName == localizedName or false
    end
    return false
end

function Client.SummonKind(spellID, name)
    return summonKinds[tonumber(spellID)] or Client.Kind(name)
end

-- The player-facing spell for each kind (CoA class data), whose icon is the
-- game's own icon for that minion. Zombies use the cast spell rather than
-- the summon effect ID listed in summonKinds.
local kindIconSpells = {
    lesser = 500970, greater = 504901, rogue = 500969, ghoul = 500971,
    mage = 500331, abomination = 500335, fiend = 504859, colossus = 500989,
    gargoyle = 500329, banshee = 504861, archer = 500332, zombie = 504315,
    boneconstruct = 531130, bonewraith = 805032, tombking = 805044,
    plaguefather = 805048, frostwyrm = 805428, thrall = 520365,
    rotling = 704722, muckworm = 520367,
}
local spellIcons = {}

function Client.SpellIcon(spellID)
    spellID = tonumber(spellID)
    if not spellID or type(GetSpellInfo) ~= "function" then return nil end
    if spellIcons[spellID] == nil then
        local ok, _, _, icon = pcall(GetSpellInfo, spellID)
        spellIcons[spellID] = ok and type(icon) == "string" and icon ~= "" and icon or false
    end
    return spellIcons[spellID] or nil
end

function Client.KindIcon(kind)
    return kind and Client.SpellIcon(kindIconSpells[kind]) or nil
end

function Client.IsKnownSummonSpell(spellID)
    return summonKinds[tonumber(spellID)] ~= nil
end

-- March of the Dead (707007) raises Zombies that walk to an enemy and explode.
-- They are never useful HUD rows. Its triggered summon spell is not in the
-- class data, so the cast itself (and a matching summon name) identifies them.
local marchSpells = { [707007] = true }
function Client.IsMarchOfTheDead(spellID, spellName)
    if marchSpells[tonumber(spellID)] then return true end
    if spellName == "March of the Dead" then return true end
    if GetSpellInfo and type(spellName) == "string" then
        local localizedName = GetSpellInfo(707007)
        return localizedName ~= nil and spellName == localizedName
    end
    return false
end

-- Longest known duration (Spell.dbc tooltips) for a temporary kind. Every
-- Zombie source lasts at most 15 sec, so their rows need not wait for the
-- generic inactivity fallback.
local kindLifetimes = { zombie = 15 }
function Client.MaxLifetime(kind)
    return kindLifetimes[kind]
end

function Client.IsTemporarySummon(spellID, spellName)
    -- Animate: Crypt Fiend shares its creature name with the permanent Raise.
    -- It has no permanent owner-roster aura and must not count against that roster.
    if temporarySpells[tonumber(spellID)] then return true end
    -- Every Animate: spell is a timed summon, including creatures not listed.
    return type(spellName) == "string" and spellName:lower():find("^animate:") ~= nil
end

function Client.IsTemporaryKind(kind)
    return temporaryKinds[kind] == true
end

-- Raise and Animate: Crypt Fiend (and Skeletal Archer) create identically
-- named creatures. Without the summon event (e.g. after /reload) their
-- permanence is unknown.
function Client.IsAmbiguousKind(kind)
    return kind == "fiend" or kind == "archer"
end

function Client.IsSpellKnownByID(spellID)
    if type(IsSpellIDKnown) == "function" then
        local ok, known = pcall(IsSpellIDKnown, spellID)
        if ok and known then return true end
    end
    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, spellID)
        if ok and known then return true end
    end
    return false
end

-- Each of these passives adds 1 Life Force (as CR's Life Force bar counts it).
local capacityPassives = { 92123, 504431, 807494, 680283 }
function Client.CapacityBonus()
    local bonus = 0
    for _, spellID in ipairs(capacityPassives) do
        if Client.IsSpellKnownByID(spellID) then bonus = bonus + 1 end
    end
    return bonus
end

function Client.ReadRoster()
    if Client.isLoggingOut then return { counts = {}, readable = false } end
    if not UnitGUID("player") then return { counts = {}, readable = false } end
    local bySpell, free, hasFree = {}, nil, false
    local readable = false
    local function scan(filter, reader)
        if type(reader) ~= "function" then return end
        readable = true
        for index = 1, 255 do
            local name, _, _, count, _, _, _, caster, _, _, spellID = reader("player", index, filter)
            if not name then break end
            spellID = tonumber(spellID)
            if spellID == 525004 then
                -- Unlike a minion aura, zero free Life Force really means zero.
                free, hasFree = tonumber(count) or 0, true
            elseif auraKinds[spellID] then
                -- Different minions can have separate instances of one aura;
                -- a nonstacking aura's zero stack count still means one minion.
                bySpell[spellID] = (bySpell[spellID] or 0) + math.max(1, tonumber(count) or 0)
            end
        end
    end
    if type(UnitAura) == "function" then
        scan("HELPFUL", UnitAura)
        scan("HARMFUL", UnitAura)
    else
        scan(nil, UnitBuff)
        scan(nil, UnitDebuff)
    end

    -- Mirror the built-in resource UI's query if normal enumeration missed it.
    if not hasFree and AuraUtil and AuraUtil.Predicate and AuraUtil.Predicate.MatchesSpellID then
        for _, readerName in ipairs({ "GetBuff", "GetDebuff" }) do
            local reader = AuraUtil[readerName]
            if type(reader) == "function" then
                local ok, name, _, _, count = pcall(reader, "player", 525004, true, AuraUtil.Predicate.MatchesSpellID)
                if ok and name then free, hasFree = tonumber(count) or 0, true; break end
            end
        end
    end
    local capacity
    if type(GetSpellMaxStack) == "function" then
        for _, spellID in ipairs({ 525004, 805011 }) do
            local ok, value = pcall(GetSpellMaxStack, spellID)
            value = ok and tonumber(value)
            if value and value > 0 then capacity = math.max(capacity or 0, value) end
        end
        -- CR's Life Force bar adds one per known capacity passive on top of
        -- the spell's max stacks. Without them the cap read low, so raising a
        -- minion looked like going over it and live minions were retired.
        if capacity then capacity = capacity + Client.CapacityBonus() end
    end
    if not capacity and CoAResourceOrb then
        capacity = tonumber(CoAResourceOrb.maxValue)
        if capacity and capacity > 0 then free = tonumber(CoAResourceOrb.value); hasFree = free ~= nil end
    end
    if capacity and capacity > 0 and readable then
        -- The native UI interprets an absent 525004 aura as a full pool in use.
        free = math.min(capacity, math.max(0, free or 0))
    else
        capacity = nil
    end

    local counts = {}
    for spellID, count in pairs(bySpell) do
        local kind = auraKinds[spellID]
        -- Alternate IDs can describe the same species; take the strongest
        -- count, while retaining separate instances within each spell ID.
        counts[kind] = math.max(counts[kind] or 0, count)
    end
    return { counts = counts, capacity = capacity, free = free, freeObserved = hasFree, readable = readable }
end

-- This client keeps nameplate CVars per character, so their backup lives in
-- the per-character saved variables.
local function CharacterData()
    return type(NecroMinionsCharDB) == "table" and NecroMinionsCharDB or nil
end

function Client.StartAutoHealth()
    if Client.InstallPlateVisibilityHooks then Client.InstallPlateVisibilityHooks() end
    -- Client.inactive: not a Necromancer, so never take over nameplate CVars.
    if Client.isLoggingOut or Client.inactive or not NecroMinionsDB then return end
    -- Plates are only switched on for a pulse (a fresh summon, combat or a
    -- drain on a minion); Client.PlatesWanted is set by the main file.
    if NecroMinionsDB.autoHealth == false or (Client.PlatesWanted and not Client.PlatesWanted()) then
        -- Also covers a logout during a pulse: restoration was deferred until
        -- native UI objects and CVar APIs were available in a fresh session.
        Client.StopAutoHealth()
        return
    end
    Client.pulseActive = true
    local manager = C_NamePlateManager and type(C_NamePlateManager.EnumerateActiveNamePlates) == "function"
    local api = C_NamePlate and (type(C_NamePlate.GetNamePlates) == "function" or type(C_NamePlate.GetNamePlateForUnit) == "function")
    if not manager and not api then return end
    if type(GetCVar) ~= "function" or type(SetCVar) ~= "function" then return end
    local cdb = CharacterData()
    if not cdb then return end
    local backup = cdb.nameplateBackup or {}
    for _, key in ipairs(nameplateCVars) do
        local ok, value = pcall(GetCVar, key)
        if ok and value ~= nil then
            if backup[key] == nil then backup[key] = tostring(value) end
            if tostring(value) ~= "1" then pcall(SetCVar, key, "1") end
        end
    end
    cdb.nameplateBackup = backup
end

function Client.StopAutoHealth(isLoggingOut)
    if isLoggingOut then
        -- PLAYER_LOGOUT runs while this client is destroying native UI state.
        -- pcall cannot catch an access violation in SetAlpha or a CVar binding.
        -- Preserve the saved backup for manual disable or a later login.
        Client.isLoggingOut = true
        hiddenPlates = {}
        hiddenPlateMouse = {}
        pendingPlateAlphas = setmetatable({}, { __mode = "k" })
        pendingPlateMouse = setmetatable({}, { __mode = "k" })
        unitTokensByGUID = {}
        Client.lastPlateCount = 0
        return
    end
    if Client.isLoggingOut then return end
    Client.pulseActive = false
    local active = activeNameplates()
    discardInactivePlates(active)
    for plate in pairs(active) do restorePendingPlate(plate) end
    for plate, alpha in pairs(hiddenPlates) do
        -- Only the freshly enumerated active objects survive the discard.
        pcall(plate.SetAlpha, plate, alpha)
        if not restorePlateMouse(plate, hiddenPlateMouse[plate]) then
            pendingPlateMouse[plate] = hiddenPlateMouse[plate]
        end
        hiddenPlates[plate] = nil
        hiddenPlateMouse[plate] = nil
    end
    local cdb = CharacterData()
    local backup = cdb and cdb.nameplateBackup
    if backup and type(SetCVar) == "function" then
        for key, value in pairs(backup) do
            -- Do not undo a preference the user changed independently.
            local ok, current = pcall(GetCVar, key)
            if ok and tostring(current) == "1" then pcall(SetCVar, key, value) end
        end
    end
    if cdb then cdb.nameplateBackup = nil end
    if Client.UpdatePlateVisuals then Client.UpdatePlateVisuals() end
end

local function plateUnit(plate)
    local unit = plate.namePlateUnitToken or plate.unitToken or plate.unit or plate._unit
    if not unit and plate.GetAttribute then unit = plate:GetAttribute("unit") end
    return unit
end

function Client.ResolveUnitToken(guid, preferredUnit)
    if Client.isLoggingOut then return nil end
    guid = Client.GUID(guid)
    if not guid then return nil end
    local function matches(unit)
        -- A token becomes a single /target argument, never a name or extra
        -- macro command. Validate identity again even for a cached token.
        return type(unit) == "string" and unit:match("^[%w_%-]+$")
            and Client.GUID(UnitGUID(unit)) == guid and not UnitIsDeadOrGhost(unit)
            and not Client.IsUnknownName(UnitName(unit))
    end
    if matches(unitTokensByGUID[guid]) then return unitTokensByGUID[guid] end
    -- Stable nameplate tokens come before volatile target/mouseover aliases.
    for plate in pairs(activeNameplates()) do
        local unit = plateUnit(plate)
        if matches(unit) then unitTokensByGUID[guid] = unit; return unit end
    end
    for i = 1, 40 do
        local unit = "nameplate"..i
        if matches(unit) then unitTokensByGUID[guid] = unit; return unit end
    end
    if matches(preferredUnit) then return preferredUnit end
    for _, unit in ipairs({ "pet", "focus", "target", "mouseover", "targettarget", "focustarget", "pettarget" }) do
        if matches(unit) then return unit end
    end
    -- An unavailable guardian cannot safely be addressed by its shared name.
    return nil
end

-- Ascension's ApplyFPSIncrease reparents UnitFrame to WorldFrame and writes
-- its alpha from movement/target callbacks. Enforce visibility immediately
-- after those writes, rather than competing with the driver once per frame.
local visualRecords = setmetatable({}, { __mode = "k" })

local function plateRole(unit)
    if Client.isLoggingOut or Client.inactive then return "plain" end
    if not unit then return "plain" end
    local guid = Client.GUID(UnitGUID(unit))
    if not guid then return "plain" end
    local db = NecroMinionsDB
    if db and db.minionPlates ~= false and Client.IsOwnMinionGUID
        and Client.IsOwnMinionGUID(guid) then return "minion" end
    local cdb = CharacterData()
    local backup = cdb and cdb.nameplateBackup
    if Client.pulseActive and db and db.autoHealth ~= false and backup
        and backup.nameplateShowFriends == "0" and not UnitIsUnit(unit, "player")
        and UnitIsFriend("player", unit) then return "hidden" end
    return "plain"
end

local function enforceHost(host, record)
    if Client.isLoggingOut or record.busy then return end
    -- Read the driver's current unit, never a GUID captured when hooks were
    -- installed. The driver pools frames across friendly and enemy units.
    local hide = plateRole(host.unit) ~= "plain"
    if hide then
        if not record.suppressed then
            record.requestedAlpha = host:GetAlpha()
            record.suppressed = true
        end
        if host:GetAlpha() ~= 0 then
            record.busy = true
            host:SetAlpha(0)
            record.busy = false
        end
    elseif record.suppressed then
        record.suppressed = false
        record.busy = true
        host:SetAlpha(record.requestedAlpha or 1)
        record.busy = false
    end
end

local function watchHost(host)
    if not host or type(hooksecurefunc) ~= "function" then return end
    local record = visualRecords[host]
    if not record then
        record = {}
        visualRecords[host] = record
        hooksecurefunc(host, "SetAlpha", function(self, alpha)
            if Client.isLoggingOut or record.busy then return end
            -- Preserve the driver's latest requested opacity for restoration.
            record.requestedAlpha = alpha
            enforceHost(self, record)
        end)
        hooksecurefunc(host, "Show", function(self)
            enforceHost(self, record)
        end)
        if type(host.SetUnit) == "function" then
            hooksecurefunc(host, "SetUnit", function(self)
                enforceHost(self, record)
            end)
        end
    end
    enforceHost(host, record)
end

local hookedManager, hookedDriver
function Client.InstallPlateVisibilityHooks()
    if Client.isLoggingOut or type(hooksecurefunc) ~= "function" then return end
    local manager = C_NamePlateManager
    if manager and type(manager.ApplyFPSIncrease) == "function" and hookedManager ~= manager then
        hookedManager = manager
        hooksecurefunc(manager, "ApplyFPSIncrease", function(host)
            if not Client.isLoggingOut then watchHost(host) end
        end)
    end
    local driver = NamePlateDriverFrame
    if driver and type(driver.NamePlateUnitAdded) == "function" and hookedDriver ~= driver then
        hookedDriver = driver
        hooksecurefunc(driver, "NamePlateUnitAdded", function(self, unit, plate)
            if not Client.isLoggingOut and plate then watchHost(plate.UnitFrame) end
        end)
    end
end

local function updatePlateVisual(plate, unit)
    watchHost(plate.UnitFrame)
    -- Do not hide or disable the native base frame: it owns the health token.
    if plateRole(unit) ~= "plain" then
        if canChangePlateMouse(plate) then
            local ok, mouse = pcall(plate.IsMouseEnabled, plate)
            if ok and mouse ~= nil then
                if hiddenPlateMouse[plate] == nil then hiddenPlateMouse[plate] = mouse and true or false end
                if mouse then pcall(plate.EnableMouse, plate, false) end
            end
        end
    elseif hiddenPlateMouse[plate] ~= nil then
        if restorePlateMouse(plate, hiddenPlateMouse[plate]) then hiddenPlateMouse[plate] = nil end
    end
end

function Client.UpdatePlateVisuals()
    if Client.isLoggingOut then return end
    Client.InstallPlateVisibilityHooks()
    local active = activeNameplates(visualScratch)
    discardInactivePlates(active)
    for plate in pairs(active) do
        restorePendingPlate(plate)
        updatePlateVisual(plate, plateUnit(plate))
    end
end

-- /nm plates: active health tokens and immediate driver visibility hooks.
function Client.DescribePlates()
    local lines = {}
    for plate in pairs(activeNameplates()) do
        local unit = plateUnit(plate)
        local host = plate.UnitFrame
        local hostState = "no frame"
        if host then
            local okShown, shown = pcall(host.IsShown, host)
            local okAlpha, alpha = pcall(host.GetAlpha, host)
            hostState = string.format("frame %s alpha %s", okShown and (shown and "shown" or "hidden") or "?",
                okAlpha and string.format("%.2f", alpha or 0) or "?")
        end
        local mine = Client.IsOwnMinionGUID and unit and UnitGUID(unit) and Client.IsOwnMinionGUID(Client.GUID(UnitGUID(unit)))
        lines[#lines + 1] = string.format("%s: %s - %s, %s, %s, my minion: %s", tostring(unit),
            tostring(unit and UnitName(unit)), plateRole(unit), host and visualRecords[host] and visualRecords[host].suppressed and "hook-hidden" or "game-drawn",
            hostState, mine and "yes" or "no")
        -- Each part's type, visibility and alpha, to see what still draws.
        local parts = {}
        local function describe(part)
            local okType, kind = pcall(part.GetObjectType, part)
            local okShown, shown = pcall(part.IsShown, part)
            local okAlpha, alpha = pcall(part.GetAlpha, part)
            local tag = part == plate.UnitFrame and "*" or ""
            parts[#parts + 1] = string.format("%s%s %s %s", tag, okType and kind or "?",
                okShown and (shown and "on" or "off") or "?", okAlpha and string.format("%.1f", alpha or 0) or "?")
        end
        local okChildren, children = pcall(function() return { plate:GetChildren() } end)
        if okChildren then for _, child in ipairs(children) do describe(child) end end
        local okRegions, regions = pcall(function() return { plate:GetRegions() } end)
        if okRegions then for _, region in ipairs(regions) do describe(region) end end
        lines[#lines + 1] = "   parts: "..(#parts > 0 and table.concat(parts, ", ") or "none")
    end
    return lines
end

function Client.ScanNameplates(sync)
    if Client.isLoggingOut then return end
    local active, hasEnumerator = activeNameplates()
    discardInactivePlates(active)
    local seen, count = {}, 0
    unitTokensByGUID = {}
    local function add(unit)
        if type(unit) == "string" and not seen[unit] then
            seen[unit] = true
            local guid = Client.GUID(UnitGUID(unit))
            if guid then
                unitTokensByGUID[guid] = unit
                sync(unit)
                count = count + 1
            end
        end
    end
    for plate in pairs(active) do
        local unit = plateUnit(plate)
        add(unit)
        -- Hide the extra world plates only when friends were originally off.
        updatePlateVisual(plate, unit)
    end
    -- A successful current-client iterator already supplies every active token.
    -- Probe numbered aliases only on older clients without that enumeration.
    if not hasEnumerator then for i = 1, 40 do add("nameplate"..i) end end
    Client.lastPlateCount = count
end
