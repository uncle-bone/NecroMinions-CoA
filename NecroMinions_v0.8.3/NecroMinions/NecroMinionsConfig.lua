-- Saved-setting validation is deliberately independent of native UI objects.
NecroMinionsConfig = {}
local Config = NecroMinionsConfig

Config.Defaults = {
    scale = 1, width = 190, height = 38, spacing = 6,
    barWidthPct = 100, barHeightPct = 45,
    color = { r = 0.2, g = 0.8, b = 0.2 },
    bgColor = { r = 0, g = 0, b = 0, a = 0.75 },
    borderColor = { r = 0, g = 0, b = 0 },
    opacity = 1, separateOpacity = false, combatOpacity = 1, idleOpacity = 1,
    healthText = "percent", healthColors = false, numberDuplicates = false,
    -- Automatic nearby health turns friendly nameplates on and makes them
    -- invisible; skeletons and fiends have no other source of live health.
    growDirection = "down", showTooltips = true, autoHealth = true,
    -- Zombies, Animate: Skeletal Archer and other cooldown summons are off by default.
    trackTemporary = false,
    -- A locked HUD hides its Move tab and resize grip outside preview mode.
    locked = false,
    -- Show the Move/Locked tab and resize grip only while hovering the HUD.
    handleOnHover = true,
    -- Hide this player's minion visuals; old size/launch fields are legacy only.
    minionPlates = true, combatPlatesAtLaunch = false, minionPlateAlpha = 0.4, minionPlateWidth = 40,
    -- CR's own Raise costs (NECROMANCER_SUMMON_SPELLS in the client's
    -- FrameXML\Constants.lua). Skeletal Mage drops to 1 with Grave Mages.
    lifeForceCosts = {
        lesser = 1, greater = 2, rogue = 1, ghoul = 1, mage = 2, abomination = 3,
        fiend = 2, colossus = 3, archer = 1, gargoyle = 3, banshee = 2,
    },
}

-- The guessed defaults used before CR's real costs; only these values migrate.
local oldCostDefaults = {
    lesser = 1, greater = 1, rogue = 1, ghoul = 1, mage = 1, abomination = 2,
    fiend = 0, colossus = 0, archer = 0, gargoyle = 0, banshee = 0,
}

local numericSettings = {
    scale = { 0.5, 1.5 }, width = { 100, 350 }, height = { 25, 70 }, spacing = { 0, 20 },
    barWidthPct = { 10, 100 }, barHeightPct = { 10, 100 },
    opacity = { 0, 1 }, combatOpacity = { 0, 1 }, idleOpacity = { 0, 1 },
    minionPlateAlpha = { 0.1, 1 }, minionPlateWidth = { 15, 110 },
}
-- Read-only ranges shared with the HUD's corner resize grip.
Config.Limits = numericSettings
local booleanSettings = { "separateOpacity", "healthColors", "numberDuplicates", "showTooltips", "autoHealth", "trackTemporary", "locked", "handleOnHover", "minionPlates", "combatPlatesAtLaunch" }
local anchors = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local healthFormats = { auto = true, currentmax = true, percent = true, both = true, hidden = true }
local nameplateCVars = { "nameplateShowFriends", "nameplateShowFriendlyGuardians", "nameplateShowFriendlyPets" }
local appearanceSettings = {
    "scale", "width", "height", "spacing", "barWidthPct", "barHeightPct",
    "color", "bgColor", "borderColor", "opacity", "separateOpacity", "combatOpacity",
    "idleOpacity", "healthText", "healthColors", "numberDuplicates", "growDirection", "showTooltips",
    "locked", "handleOnHover",
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function numberInRange(value, fallback, low, high)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then value = fallback end
    return math.max(low, math.min(high, value))
end

local function normalizeColor(db, key)
    local defaults = Config.Defaults[key]
    local color = type(db[key]) == "table" and db[key] or {}
    for component, fallback in pairs(defaults) do
        color[component] = numberInRange(color[component], fallback, 0, 1)
    end
    db[key] = color
end

-- Only restore values for the three binary preferences this addon manages.
-- Invalid saved data must never become arbitrary SetCVar calls.
local function normalizeBackup(source)
    if type(source) ~= "table" then return nil end
    local backup = {}
    for _, key in ipairs(nameplateCVars) do
        local value = source[key]
        if value == "0" or value == 0 then backup[key] = "0"
        elseif value == "1" or value == 1 then backup[key] = "1" end
    end
    return next(backup) and backup or nil
end

local function normalizeCosts(source)
    local costs = type(source) == "table" and source or {}
    for kind, fallback in pairs(Config.Defaults.lifeForceCosts) do
        costs[kind] = math.floor(numberInRange(costs[kind], fallback, 0, 10) + 0.5)
    end
    return costs
end

function Config.Normalize(db)
    if type(db) ~= "table" then db = {} end
    for key, limits in pairs(numericSettings) do
        db[key] = numberInRange(db[key], Config.Defaults[key], limits[1], limits[2])
    end
    for _, key in ipairs(booleanSettings) do
        if type(db[key]) ~= "boolean" then db[key] = Config.Defaults[key] end
    end
    if not healthFormats[db.healthText] then db.healthText = Config.Defaults.healthText end
    if db.growDirection ~= "up" and db.growDirection ~= "down" then db.growDirection = Config.Defaults.growDirection end
    normalizeColor(db, "color")
    normalizeColor(db, "bgColor")
    normalizeColor(db, "borderColor")

    local point = db.point
    if type(point) == "table" and anchors[point.point] and anchors[point.relativePoint] then
        point.xOfs = numberInRange(point.xOfs, 0, -10000, 10000)
        point.yOfs = numberInRange(point.yOfs, 0, -10000, 10000)
    else
        db.point = nil
    end
    -- Account-wide costs are kept only to seed characters created before 0.7.1.
    db.lifeForceCosts = normalizeCosts(db.lifeForceCosts)
    -- Automatic nearby health used to default on. Switch existing installs off
    -- once; after that the saved choice is respected. (StartAutoHealth then
    -- restores this character's managed nameplate settings at login.)
    -- Percentage became the default health text. Existing installs still on
    -- the old default (Auto) switch once; a format someone picked is kept.
    if not db.percentDefault then
        if db.healthText == "auto" then db.healthText = "percent" end
        db.percentDefault = true
    end
    if not db.autoHealthOptIn then
        db.autoHealth = false
        db.autoHealthOptIn = true
    end
    -- Automatic health then returned as the default, with the minion plates
    -- hidden. Existing installs switch on once; a later choice is respected.
    if not db.autoHealthDefaultOn then
        db.autoHealth = true
        db.autoHealthDefaultOn = true
    end
    -- Pre-0.7.1 account-wide backup, kept only until a Necromancer claims it.
    db.nameplateBackup = normalizeBackup(db.nameplateBackup)
    return db
end

-- Life Force costs depend on each character's build (SavedVariablesPerCharacter).
-- So do this client's nameplate CVars (each character's config-cache.wtf), so
-- the backup of the ones automatic health changes is per character as well.
function Config.NormalizeCharacter(cdb)
    if type(cdb) ~= "table" then cdb = {} end
    cdb.lifeForceCosts = normalizeCosts(cdb.lifeForceCosts)
    cdb.nameplateBackup = normalizeBackup(cdb.nameplateBackup)
    -- Remembered maximum health per minion kind (combat-log estimate baseline).
    local maxHealth = {}
    if type(cdb.maxHealthByKind) == "table" then
        for kind, value in pairs(cdb.maxHealthByKind) do
            value = tonumber(value)
            if type(kind) == "string" and value and value == value and value > 0 and value < 1e8 then
                maxHealth[kind] = value
            end
        end
    end
    cdb.maxHealthByKind = maxHealth
    -- Minion creature names learned from summons (lowercase name -> kind).
    -- The table is shared with the client file, so it is cleaned in place.
    if type(cdb.learnedNames) ~= "table" then cdb.learnedNames = {} end
    for name, kind in pairs(cdb.learnedNames) do
        if type(name) ~= "string" or type(kind) ~= "string" or #name > 64 or not kind:match("^%l+$") then
            cdb.learnedNames[name] = nil
        end
    end
    return cdb
end

-- The old account-wide backup could only have come from the Necromancer that
-- ran automatic health, so the first Necromancer to log in takes it over.
function Config.ClaimAccountBackup(cdb, db)
    if type(cdb) ~= "table" or type(db) ~= "table" or not db.nameplateBackup then return end
    if not cdb.nameplateBackup then cdb.nameplateBackup = db.nameplateBackup end
    db.nameplateBackup = nil
end

-- Only call after ADDON_LOADED. A character without saved data keeps the table
-- created at file load, so the "initialized" flag (not the table's existence)
-- decides whether to copy the previous account-wide costs once.
function Config.InitializeCharacter(cdb, accountDb)
    cdb = Config.NormalizeCharacter(cdb)
    if not cdb.initialized then
        local source = type(accountDb) == "table" and accountDb.lifeForceCosts
        cdb.lifeForceCosts = normalizeCosts(clone(source))
        cdb.initialized = true
    end
    -- Costs still at the old guessed defaults move to CR's real costs once;
    -- a cost someone set by hand is kept.
    if not cdb.costsFromClient then
        for kind, oldDefault in pairs(oldCostDefaults) do
            if cdb.lifeForceCosts[kind] == oldDefault then
                cdb.lifeForceCosts[kind] = Config.Defaults.lifeForceCosts[kind]
            end
        end
        cdb.costsFromClient = true
    end
    return cdb
end

function Config.Character()
    NecroMinionsCharDB = Config.NormalizeCharacter(NecroMinionsCharDB)
    return NecroMinionsCharDB
end

function Config.GetCost(db, kind)
    local costs = type(db) == "table" and db.lifeForceCosts
    local value = type(costs) == "table" and tonumber(costs[kind])
    if value and value == value and value > 0 and value <= 10 then return value end
    return nil
end

function Config.ResetAppearance(db)
    db = Config.Normalize(db)
    for _, key in ipairs(appearanceSettings) do db[key] = clone(Config.Defaults[key]) end
    db.point = nil
    return db
end
