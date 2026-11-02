local addonName, addon = ...
local Client = NecroMinionsClient
local Config = NecroMinionsConfig

NecroMinionsDB = Config.Normalize(NecroMinionsDB)
NecroMinionsCharDB = Config.NormalizeCharacter(NecroMinionsCharDB)

local frame = CreateFrame("Frame", "NecroMinionsFrame", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("UNIT_HEALTH")
frame:RegisterEvent("UNIT_MAXHEALTH")
frame:RegisterEvent("UNIT_HEALTH_FREQUENT")
frame:RegisterEvent("UNIT_PET")
frame:RegisterEvent("PET_DISMISS")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("UNIT_TARGET")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("PLAYER_LOGOUT")
-- These nameplate events exist in the client's backported UI. Keep loading
-- possible on an unextended 3.3.5 client as well.
pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_ADDED")
pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_REMOVED")
for _, event in ipairs({ "SPELLS_CHANGED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
    pcall(frame.RegisterEvent, frame, event)
end

local minions = {}
local minionOrder = {}
-- Ownership outlives a display-cache rebuild. Nameplate health/GUID can remain
-- readable even when that token's tooltip does not expose its owner's name.
local knownOwnedMinions = {}
local deadMinions = {}
local retiredMinions = {}
local newestSummonGUID
local seenSummons = {}
local acceptedCapacity
local pendingReplacement
local pendingCapacityChange
local recentRemovals = {}
local knownAuraKinds = {}
local rosterSignature, rosterChangedAt, rosterGraceUntil = nil, 0, 0
local lastRoster
local frames = {}
local playerGUID = ""
local playerName = ""
local isChangeMode = false
local isDragging = false
-- NecroMinions only runs on a Necromancer (class token NECROMANCER). Until the
-- client reports the class it stays active, as before.
local isActive, classKnown = true, false
local isResizing = false
-- Preview rows live apart from the tracked army, so tracking continues while
-- the HUD is being moved and nothing needs rediscovering afterwards.
local previewMinions, previewOrder = {}, {}
-- Recognized minion names owned by other players: tooltip ownership is not
-- re-probed for each GUID until its recheck time.
local foreignGUIDs, foreignCount = {}, 0
-- March of the Dead zombies: never tracked, and blocked from rediscovery.
local ignoredGUIDs, ignoredCount = {}, 0
local marchCastAt = 0
-- Recent summon events for /nm summons, to identify unknown summon spells.
local summonLog = {}
local displayOrder = {}

local needsRefresh = true
local layoutDirty = true
local petGUID
local UpdateMinionFrames
local RefreshUnits
local ReconcileRoster
local ResetAppearance
local ToggleChangeMode
local ShowHudMenu

local DEFAULT_WIDTH = 190
local DEFAULT_HEIGHT = 38
local DEFAULT_SPACING = 6
local DEFAULT_BAR_WIDTH_PCT = 100
local DEFAULT_BAR_HEIGHT_PCT = 45
local MAX_MINIONS = 20
-- A temporary summon with no live unit, combat-log activity or death event for
-- this long is treated as expired. Inferred retirement is undone by a live unit.
local TEMPORARY_TIMEOUT = 60
local FOREIGN_RECHECK = 5

local scanTooltip = CreateFrame("GameTooltip", "NecroMinionsScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local mainContainer = CreateFrame("Frame", "NecroMinionsContainer", UIParent)
mainContainer:SetSize(DEFAULT_WIDTH, 20)
mainContainer:SetPoint("TOPLEFT", UIParent, "LEFT", 8, 90)
mainContainer:SetMovable(true)
mainContainer:EnableMouse(false)
mainContainer:SetClampedToScreen(true)

-- Protected targeting controls have their own parent and absolute screen anchors.
-- This leaves the display free to refresh during combat. The secure driver hides
-- clicks in combat, when their target macros cannot safely follow changing rows.
local clickContainer = CreateFrame("Frame", "NecroMinionsClickContainer", UIParent)
RegisterStateDriver(clickContainer, "visibility", "[combat] hide; show")

-- Keep movement separate from the protected targeting buttons on each row.
local dragHandle = CreateFrame("Frame", "NecroMinionsDragHandle", mainContainer)
dragHandle:SetSize(64, 16)
dragHandle:SetPoint("TOPLEFT", mainContainer, "TOPLEFT", 0, -2)
dragHandle:SetFrameLevel(mainContainer:GetFrameLevel() + 20)
dragHandle:EnableMouse(false)
local dragMouseEnabled = false
dragHandle:RegisterForDrag("LeftButton")
dragHandle:Hide()

local dragHeader = dragHandle:CreateTexture(nil, "BACKGROUND")
dragHeader:SetAllPoints(dragHandle)
dragHeader:SetTexture(0, 0, 0, 0.55)

local dragText = dragHandle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dragText:SetPoint("CENTER", dragHandle, "CENTER", 0, 0)
dragText:SetText("Move")

local overflowText = mainContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
overflowText:SetJustifyH("LEFT")
overflowText:Hide()

-- Preview rows while moving the HUD, otherwise the tracked army.
local function DisplaySource()
    if isChangeMode then return previewMinions, previewOrder end
    return minions, minionOrder
end

local function GetColor()
    if NecroMinionsDB and NecroMinionsDB.color then
        return NecroMinionsDB.color.r or 0.2, NecroMinionsDB.color.g or 0.8, NecroMinionsDB.color.b or 0.2
    end
    return 0.2, 0.8, 0.2
end

local function GetBgColor()
    if NecroMinionsDB and NecroMinionsDB.bgColor then
        return NecroMinionsDB.bgColor.r or 0, NecroMinionsDB.bgColor.g or 0, NecroMinionsDB.bgColor.b or 0, NecroMinionsDB.bgColor.a or 0.75
    end
    return 0, 0, 0, 0.75
end

local function GetBorderColor()
    if NecroMinionsDB and NecroMinionsDB.borderColor then
        return NecroMinionsDB.borderColor.r or 0, NecroMinionsDB.borderColor.g or 0, NecroMinionsDB.borderColor.b or 0
    end
    return 0, 0, 0
end

local function GetWidth()
    return (NecroMinionsDB and NecroMinionsDB.width) or DEFAULT_WIDTH
end

local function GetHeight()
    return (NecroMinionsDB and NecroMinionsDB.height) or DEFAULT_HEIGHT
end

local function GetSpacing()
    return (NecroMinionsDB and NecroMinionsDB.spacing) or DEFAULT_SPACING
end

local function GetBarWidthPct()
    return (NecroMinionsDB and NecroMinionsDB.barWidthPct) or DEFAULT_BAR_WIDTH_PCT
end

local function GetBarHeightPct()
    return (NecroMinionsDB and NecroMinionsDB.barHeightPct) or DEFAULT_BAR_HEIGHT_PCT
end

local function ClearAllMinions()
    minions = {}
    minionOrder = {}
    petGUID = nil
    newestSummonGUID = nil
    pendingReplacement = nil
    pendingCapacityChange = nil
    needsRefresh = true
    if UpdateMinionFrames then
        UpdateMinionFrames()
    end
end

local function GetMinionIcon(data)
    -- The game's own icon: the Raise/Animate spell for this kind, then the
    -- spell that actually summoned it. Name guesses are only a fallback.
    local icon = Client.KindIcon(data.kind or Client.Kind(data.name)) or Client.SpellIcon(data.summonSpellID)
    if icon then return icon end
    local name = data.name
    if not name then return "Interface\\Icons\\Spell_Shadow_RaiseDead" end
    local lowerName = string.lower(name)
    
    if lowerName:find("skelet") or lowerName:find("skeletal") then
        return "Interface\\Icons\\Spell_Shadow_RaiseDead"
    elseif lowerName:find("abomination") then
        return "Interface\\Icons\\Spell_Shadow_CreepingPlague"
    elseif lowerName:find("crypt") or lowerName:find("fiend") then
        return "Interface\\Icons\\Ability_Hunter_Pet_Spider"
    elseif lowerName:find("ghoul") then
        return "Interface\\Icons\\Spell_Shadow_AnimateDead"
    end
    
    return "Interface\\Icons\\Spell_Shadow_RaiseDead"
end

local function StopHudDrag(render)
    if Client.isLoggingOut or not isDragging then return end
    isDragging = false
    mainContainer:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = mainContainer:GetPoint()
    NecroMinionsDB.point = { point = point, relativePoint = relativePoint, xOfs = xOfs, yOfs = yOfs }
    layoutDirty, needsRefresh = true, true
    if render and UpdateMinionFrames then UpdateMinionFrames(true) end
end

local function SetHudLocked(locked)
    if Client.isLoggingOut or InCombatLockdown() then return end
    NecroMinionsDB.locked = locked and true or false
    StopHudDrag(false)
    -- Locking from preview also finishes the preview.
    if locked and isChangeMode then ToggleChangeMode() end
    layoutDirty, needsRefresh = true, true
    if UpdateMinionFrames then UpdateMinionFrames(true) end
    local panel = NecroMinionsOptions and NecroMinionsOptions.panel
    if panel and panel.RefreshValues then panel.RefreshValues() end
end

dragHandle:SetScript("OnDragStart", function()
    if Client.isLoggingOut or InCombatLockdown() or isDragging or not dragHandle:IsShown() then return end
    if NecroMinionsDB.locked and not isChangeMode then return end
    if GameTooltip and GameTooltip:GetOwner() == dragHandle then GameTooltip:Hide() end
    isDragging = true
    -- Absolute targeting overlays must not remain at their old positions while
    -- the display moves. They are rebound after the mouse is released.
    for _, row in ipairs(frames) do row.clickButton:Hide() end
    mainContainer:StartMoving()
    needsRefresh = true
end)
dragHandle:SetScript("OnDragStop", function() StopHudDrag(true) end)
dragHandle:SetScript("OnHide", function() StopHudDrag(false) end)
dragHandle:SetScript("OnMouseUp", function(_, button)
    if Client.isLoggingOut then return end
    if button == "RightButton" and not InCombatLockdown() and ShowHudMenu then
        if GameTooltip and GameTooltip:GetOwner() == dragHandle then GameTooltip:Hide() end
        ShowHudMenu()
    end
end)
dragHandle:SetScript("OnEnter", function(self)
    if Client.isLoggingOut or InCombatLockdown() or not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if NecroMinionsDB.locked and not isChangeMode then
        GameTooltip:SetText("NecroMinions (locked)", 1, 0.82, 0)
    else
        GameTooltip:SetText("Move NecroMinions", 1, 0.82, 0)
        GameTooltip:AddLine("Hold left mouse and drag to move the HUD.", 1, 1, 1)
    end
    GameTooltip:AddLine("Right-click for options, including lock/unlock.", 1, 1, 1)
    GameTooltip:Show()
end)
dragHandle:SetScript("OnLeave", function(self)
    if Client.isLoggingOut or not GameTooltip then return end
    if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
end)

-- Corner grip, like a Details! window: horizontal motion sets row width and
-- vertical motion, shared across the shown rows, sets row height. The rows
-- are separate frames, so sizing is applied by hand rather than StartSizing.
local resizeGrip = CreateFrame("Button", "NecroMinionsResizeGrip", mainContainer)
resizeGrip:SetSize(16, 16)
resizeGrip:SetFrameStrata("HIGH")
resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeGrip:RegisterForClicks("LeftButtonUp")
resizeGrip:Hide()
resizeGrip.rows = 1
local resizeStart

local function SetGripFlipped(flipped)
    -- The grabber art points down-right; flip it for a top-right corner.
    local top, bottom = 0, 1
    if flipped then top, bottom = 1, 0 end
    for _, texture in ipairs({ resizeGrip:GetNormalTexture(), resizeGrip:GetPushedTexture(), resizeGrip:GetHighlightTexture() }) do
        if texture then texture:SetTexCoord(0, 1, top, bottom) end
    end
end

local function ResizeOnUpdate()
    local start = resizeStart
    if Client.isLoggingOut or not start then return end
    local x, y = GetCursorPosition()
    local dx, dy = (x - start.x) / start.scale, (y - start.y) / start.scale
    local limits = Config.Limits
    local width = math.floor(math.max(limits.width[1], math.min(limits.width[2], start.width + dx)) + 0.5)
    local rowDelta = (NecroMinionsDB.growDirection == "up" and dy or -dy) / start.rows
    local height = math.floor(math.max(limits.height[1], math.min(limits.height[2], start.height + rowDelta)) + 0.5)
    if width ~= NecroMinionsDB.width or height ~= NecroMinionsDB.height then
        NecroMinionsDB.width, NecroMinionsDB.height = width, height
        layoutDirty = true
        UpdateMinionFrames(true)
    end
end

local function StopHudResize(render)
    if Client.isLoggingOut or not isResizing then return end
    isResizing, resizeStart = false, nil
    resizeGrip:SetScript("OnUpdate", nil)
    -- Targeting overlays were withheld during the resize; rebind them now.
    layoutDirty, needsRefresh = true, true
    if render and UpdateMinionFrames then UpdateMinionFrames(true) end
    local panel = NecroMinionsOptions and NecroMinionsOptions.panel
    if panel and panel:IsShown() and panel.RefreshValues then panel.RefreshValues() end
end

resizeGrip:SetScript("OnMouseDown", function(self, button)
    if Client.isLoggingOut or button ~= "LeftButton" or InCombatLockdown() or isResizing or isDragging then return end
    if GameTooltip and GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    local x, y = GetCursorPosition()
    resizeStart = {
        x = x, y = y, width = GetWidth(), height = GetHeight(),
        rows = math.max(1, self.rows or 1), scale = mainContainer:GetEffectiveScale(),
    }
    isResizing = true
    for _, row in ipairs(frames) do row.clickButton:Hide() end
    self:SetScript("OnUpdate", ResizeOnUpdate)
end)
resizeGrip:SetScript("OnMouseUp", function() StopHudResize(true) end)
resizeGrip:SetScript("OnHide", function() StopHudResize(false) end)
resizeGrip:SetScript("OnEnter", function(self)
    if Client.isLoggingOut or InCombatLockdown() or isResizing or not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Resize NecroMinions", 1, 0.82, 0)
    GameTooltip:AddLine("Drag sideways for row width, up/down for row height.", 1, 1, 1)
    GameTooltip:Show()
end)
resizeGrip:SetScript("OnLeave", function(self)
    if Client.isLoggingOut or not GameTooltip then return end
    if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
end)

local RemoveMinion

local tooltipOwner
local lastContainerAlpha
local containerWidth

local function HudAlpha()
    if isChangeMode then return 1 end
    local alpha = NecroMinionsDB.opacity
    if NecroMinionsDB.separateOpacity then
        alpha = alpha * (InCombatLockdown() and NecroMinionsDB.combatOpacity or NecroMinionsDB.idleOpacity)
    end
    return alpha
end

local function HideMinionTooltip(owner)
    if tooltipOwner ~= owner then return end
    tooltipOwner = nil
    if Client.isLoggingOut or not GameTooltip then return end
    if GameTooltip.GetOwner and GameTooltip:GetOwner() ~= owner then return end
    GameTooltip:Hide()
end

local function ShowMinionTooltip(owner)
    if Client.isLoggingOut or not GameTooltip or not NecroMinionsDB.showTooltips or HudAlpha() <= 0 then return end
    local row = owner.row or owner
    local data = row.minionGuid and (DisplaySource())[row.minionGuid]
    if not data then return end
    tooltipOwner = owner
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:SetText(data.name or "Guardian", 1, 0.82, 0)
    if NecroMinionsDB.numberDuplicates and data.ordinal then GameTooltip:AddLine("Summon #"..data.ordinal, 1, 1, 1) end
    if data.hp and data.maxHp and data.maxHp > 0 then
        local hp = math.min(data.maxHp, math.max(0, data.hp))
        local prefix = data.estimated and "~" or ""
        GameTooltip:AddLine(string.format("%s%d / %d (%d%%)", prefix, math.floor(hp), math.floor(data.maxHp), math.floor(100 * hp / data.maxHp)), 1, 1, 1)
        if data.estimated then GameTooltip:AddLine("~ Estimated health", 0.7, 0.7, 0.7) end
    else
        GameTooltip:AddLine("Health not available", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function SetTargetAction(button, unit, verify)
    local action = unit and "macro" or nil
    local macro = unit and ("/target "..unit) or nil
    if button:GetAttribute("unit") ~= nil then button:SetAttribute("unit", nil) end
    if button.actionType ~= action or (verify and button:GetAttribute("type") ~= action) then
        button:SetAttribute("type", action)
        button.actionType = action
    end
    if button.actionMacro ~= macro or (verify and button:GetAttribute("macrotext") ~= macro) then
        button:SetAttribute("macrotext", macro)
        button.actionMacro = macro
    end
end

local function HealthText(data, width)
    local mode = NecroMinionsDB.healthText
    if mode == "hidden" then return "" end
    if not data.hp or not data.maxHp or data.maxHp <= 0 then return width >= 65 and "HP unknown" or "?" end
    local hp = math.min(data.maxHp, math.max(0, data.hp))
    local pct = math.floor(100 * hp / data.maxHp)
    local prefix = data.estimated and "~" or ""
    if mode == "auto" then mode = width >= 120 and "both" or (width >= 90 and "currentmax" or "percent") end
    if mode == "percent" then return string.format("%s%d%%", prefix, pct) end
    if mode == "currentmax" then return string.format("%s%d / %d", prefix, math.floor(hp), math.floor(data.maxHp)) end
    return string.format("%s%d / %d (%d%%)", prefix, math.floor(hp), math.floor(data.maxHp), pct)
end

local function CreateMinionFrame(index)
    local f = CreateFrame("Frame", "NecroMinionFrame"..index, mainContainer)
    local w, h = GetWidth(), GetHeight()
    local spacing = GetSpacing()
    f:SetSize(w, h)
    f:SetPoint("TOPLEFT", mainContainer, "TOPLEFT", 0, -25 - ((index - 1) * (h + spacing)))
    f:EnableMouse(true)
    f:SetScript("OnEnter", ShowMinionTooltip)
    f:SetScript("OnLeave", HideMinionTooltip)

    local clickButton = CreateFrame("Button", "NecroMinionTargetButton"..index, clickContainer, "SecureActionButtonTemplate")
    clickButton:RegisterForClicks("LeftButtonUp")
    clickButton.row = f
    clickButton:SetScript("OnEnter", ShowMinionTooltip)
    clickButton:SetScript("OnLeave", HideMinionTooltip)
    clickButton:SetScript("PreClick", function(self)
        if Client.isLoggingOut or InCombatLockdown() then return end
        local unit = not isChangeMode and not isDragging and not isResizing and HudAlpha() > 0 and minions[self.targetGUID]
            and Client.ResolveUnitToken(self.targetGUID, self.preferredUnit) or nil
        -- A nameplate token may be recycled between the periodic refresh and
        -- this click. Never leave an old token/name macro armed on a mismatch.
        SetTargetAction(self, unit, true)
        self.boundUnit = unit
    end)
    clickButton:SetFrameStrata(f:GetFrameStrata())
    clickButton:SetFrameLevel(f:GetFrameLevel() + 10)
    clickButton:Hide()
    f.clickButton = clickButton

    if not f.highlightTex then
        local highlightTex = f:CreateTexture(nil, "HIGHLIGHT")
        highlightTex:SetAllPoints(true)
        highlightTex:SetTexture(1, 1, 1, 0.15)
        f.highlightTex = highlightTex
    end

    if not f.frameBorder then
        local frameBorder = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
        frameBorder:SetPoint("TOPLEFT", -2, 2)
        frameBorder:SetPoint("BOTTOMRIGHT", 2, -2)
        frameBorder:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
        })
        f.frameBorder = frameBorder
    end

    if not f.bg then
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        f.bg = bg
    end

    if not f.icon then
        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.icon = icon
    end

    if not f.iconBorder then
        local iconBorder = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
        iconBorder:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
        })
        f.iconBorder = iconBorder
    end

    if not f.hpBar then
        local hpBar = CreateFrame("StatusBar", nil, f)
        hpBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        
        local hpBg = hpBar:CreateTexture(nil, "BACKGROUND")
        hpBg:SetAllPoints(true)
        hpBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
        hpBg:SetVertexColor(0.1, 0.1, 0.1, 0.8)

        local border = CreateFrame("Frame", nil, hpBar, BackdropTemplateMixin and "BackdropTemplate" or nil)
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
        })
        hpBar.border = border

        f.hpBar = hpBar
    end

    if not f.nameText then
        local nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetDrawLayer("OVERLAY", 7)
        nameText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        nameText:SetTextColor(1, 1, 0, 1)
        nameText:SetJustifyH("LEFT")
        if nameText.SetWordWrap then nameText:SetWordWrap(false) end
        nameText:SetShadowColor(0, 0, 0, 1)
        nameText:SetShadowOffset(1, -1)
        f.nameText = nameText
    end

    if not f.hpText then
        -- Put the label above the StatusBar's child border frame as well as
        -- its fill; a FontString on the row itself is covered by the bar.
        local hpText = f.hpBar.border:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hpText:SetDrawLayer("OVERLAY", 7)
        hpText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        hpText:SetTextColor(1, 1, 1, 1)
        hpText:SetJustifyH("CENTER")
        if hpText.SetWordWrap then hpText:SetWordWrap(false) end
        hpText:SetShadowColor(0, 0, 0, 1)
        hpText:SetShadowOffset(1, -1)
        f.hpText = hpText
    end

    f:Hide()
    f.renderedVisible = false
    f.mouseEnabled = true
    return f
end

for i = 1, MAX_MINIONS do
    frames[i] = CreateMinionFrame(i)
end

UpdateMinionFrames = function(forceLayout)
    if Client.isLoggingOut then return end
    local force = forceLayout or layoutDirty
    layoutDirty = false
    needsRefresh = false
    local r, g, b = GetColor()
    local br, bg_c, bb, ba = GetBgColor()
    local bcr, bcg, bcb = GetBorderColor()
    local w, h, spacing = GetWidth(), GetHeight(), GetSpacing()
    local barW_pct, barH_pct = GetBarWidthPct() / 100, GetBarHeightPct() / 100
    local alpha = HudAlpha()
    if force or lastContainerAlpha ~= alpha then
        mainContainer:SetAlpha(alpha)
        lastContainerAlpha = alpha
    end
    local source, order = DisplaySource()
    -- Permanent minions keep the first rows; short-lived summons follow them
    -- and are the ones moved into the overflow count when rows run out.
    for i = #displayOrder, 1, -1 do displayOrder[i] = nil end
    for _, guid in ipairs(order) do
        if source[guid] and not source[guid].temporary then displayOrder[#displayOrder + 1] = guid end
    end
    for _, guid in ipairs(order) do
        if source[guid] and source[guid].temporary then displayOrder[#displayOrder + 1] = guid end
    end
    -- The tab stays visible when locked so its right-click menu can unlock it;
    -- only dragging and the resize grip need an unlocked HUD (or preview).
    local showHandle = alpha > 0 and not InCombatLockdown() and #displayOrder > 0
    local canDrag = showHandle and (isChangeMode or not NecroMinionsDB.locked)
    local handleText = canDrag and "Move" or "Locked"
    if dragText:GetText() ~= handleText then dragText:SetText(handleText) end
    if dragMouseEnabled ~= showHandle then
        dragHandle:EnableMouse(showHandle)
        dragMouseEnabled = showHandle
    end
    if showHandle then
        if not dragHandle:IsShown() then dragHandle:Show() end
    elseif dragHandle:IsShown() then
        if GameTooltip and GameTooltip:GetOwner() == dragHandle then GameTooltip:Hide() end
        dragHandle:Hide()
    end
    if force or containerWidth ~= w then mainContainer:SetSize(w, 20); containerWidth = w end
    if tooltipOwner and (not NecroMinionsDB.showTooltips or alpha <= 0) then HideMinionTooltip(tooltipOwner) end
    local styleSignature = table.concat({ br, bg_c, bb, ba, bcr, bcg, bcb }, "|")
    local displayIndex = 1
    for _, guid in ipairs(displayOrder) do
        local data = source[guid]
        if data and displayIndex <= MAX_MINIONS then
            local mf = frames[displayIndex]
            if mf.minionGuid ~= guid then
                HideMinionTooltip(mf)
                HideMinionTooltip(mf.clickButton)
            end
            mf.minionName, mf.minionGuid = data.name, guid
            local name = data.name or "Guardian"
            local displayName = NecroMinionsDB.numberDuplicates and data.ordinal and ("#"..data.ordinal.." "..name) or name
            if mf.cachedName ~= displayName then mf.nameText:SetText(displayName); mf.cachedName = displayName end

            local iconSize = h - 4
            local offsetLeft = iconSize + 6
            local usableWidth = w - offsetLeft - 4
            local barW = math.min(usableWidth, math.max(32, usableWidth * barW_pct))
            local barH = math.max(9, math.min(h - 18, h * barH_pct))
            local layoutSignature = table.concat({ w, h, spacing, barW_pct, barH_pct, NecroMinionsDB.growDirection, displayIndex }, "|")
            local layoutChanged = force or mf.layoutSignature ~= layoutSignature
            if layoutChanged then
                mf:SetSize(w, h)
                mf:ClearAllPoints()
                if NecroMinionsDB.growDirection == "up" then
                    mf:SetPoint("BOTTOMLEFT", mainContainer, "TOPLEFT", 0, 25 + ((displayIndex - 1) * (h + spacing)))
                else
                    mf:SetPoint("TOPLEFT", mainContainer, "TOPLEFT", 0, -25 - ((displayIndex - 1) * (h + spacing)))
                end
                mf.icon:SetSize(iconSize, iconSize)
                mf.icon:ClearAllPoints()
                mf.icon:SetPoint("LEFT", mf, "LEFT", 2, 0)
                mf.icon:Show()
                mf.iconBorder:SetSize(iconSize + 2, iconSize + 2)
                mf.iconBorder:ClearAllPoints()
                mf.iconBorder:SetPoint("CENTER", mf.icon, "CENTER", 0, 0)
                mf.iconBorder:Show()
                mf.hpBar:ClearAllPoints()
                mf.hpBar:SetSize(barW, barH)
                mf.hpBar:SetPoint("BOTTOMLEFT", mf, "BOTTOMLEFT", offsetLeft, 2)
                mf.nameText:ClearAllPoints()
                mf.nameText:SetPoint("TOPLEFT", mf, "TOPLEFT", offsetLeft, -3)
                mf.nameText:SetWidth(usableWidth)
                mf.nameText:SetHeight(11)
                mf.hpText:ClearAllPoints()
                mf.hpText:SetPoint("CENTER", mf.hpBar, "CENTER", 0, 0)
                mf.hpText:SetWidth(math.max(1, barW - 4))
                mf.hpText:SetHeight(barH)
                mf.layoutSignature = layoutSignature
            end
            if force or mf.styleSignature ~= styleSignature then
                mf.bg:SetTexture(br, bg_c, bb, ba)
                mf.frameBorder:SetBackdropBorderColor(bcr, bcg, bcb, 1)
                mf.hpBar.border:SetBackdropBorderColor(bcr, bcg, bcb, 1)
                mf.iconBorder:SetBackdropBorderColor(bcr, bcg, bcb, 1)
                mf.styleSignature = styleSignature
            end
            local icon = GetMinionIcon(data)
            if mf.cachedIcon ~= icon then mf.icon:SetTexture(icon); mf.cachedIcon = icon end

            local hasHealth = data.hp and data.maxHp and data.maxHp > 0
            local maximum = hasHealth and data.maxHp or 1
            local current = hasHealth and math.min(maximum, math.max(0, data.hp)) or 0
            if mf.cachedMaximum ~= maximum then mf.hpBar:SetMinMaxValues(0, maximum); mf.cachedMaximum = maximum end
            if mf.cachedCurrent ~= current then mf.hpBar:SetValue(current); mf.cachedCurrent = current end
            local text = HealthText(data, barW)
            local healthChanged = mf.cachedText ~= text
            if healthChanged then mf.hpText:SetText(text); mf.cachedText = text end
            -- The tooltip always shows exact HP, even when the row displays a
            -- rounded percentage or has its health text hidden.
            local tooltipSignature = table.concat({ name, current, maximum, tostring(hasHealth and true or false), tostring(data.estimated and true or false), tostring(data.ordinal), tostring(NecroMinionsDB.numberDuplicates) }, "|")
            local tooltipChanged = mf.tooltipSignature ~= tooltipSignature
            mf.tooltipSignature = tooltipSignature
            local hr, hg, hb = r, g, b
            if NecroMinionsDB.healthColors and hasHealth then
                local fraction = current / maximum
                if fraction >= 0.5 then hr, hg, hb = 2 * (1 - fraction), 1, 0
                else hr, hg, hb = 1, 2 * fraction, 0 end
            end
            if mf.cachedR ~= hr or mf.cachedG ~= hg or mf.cachedB ~= hb then
                mf.hpBar:SetStatusBarColor(hr, hg, hb)
                mf.cachedR, mf.cachedG, mf.cachedB = hr, hg, hb
            end
            local mouse = alpha > 0 and NecroMinionsDB.showTooltips
            if mf.mouseEnabled ~= mouse then mf:EnableMouse(mouse); mf.mouseEnabled = mouse end
            if not mf:IsShown() then mf:Show() end
            mf.renderedVisible = true

            local button = mf.clickButton
            if not InCombatLockdown() then
                local unit = alpha > 0 and not isChangeMode and not isDragging and not isResizing and Client.ResolveUnitToken(guid, data.unit) or nil
                button.targetGUID, button.preferredUnit, button.boundUnit = guid, data.unit, unit
                SetTargetAction(button, unit, false)
                local x, y = mf:GetCenter()
                if unit and x and y then
                    local scale = mf:GetEffectiveScale() / button:GetEffectiveScale()
                    local bx, by, bw, bh = x * scale, y * scale, w * scale, h * scale
                    local geometry = table.concat({ bx, by, bw, bh }, "|")
                    if force or layoutChanged or button.geometrySignature ~= geometry then
                        button:ClearAllPoints()
                        button:SetPoint("CENTER", UIParent, "BOTTOMLEFT", bx, by)
                        button:SetSize(bw, bh)
                        button.geometrySignature = geometry
                    end
                    if not button:IsShown() then button:Show() end
                else
                    if button:IsShown() then button:Hide() end
                    HideMinionTooltip(button)
                    if unit and (not x or not y) then needsRefresh = true end
                end
            end
            if tooltipChanged and tooltipOwner and (tooltipOwner == mf or tooltipOwner == button) then ShowMinionTooltip(tooltipOwner) end
            displayIndex = displayIndex + 1
        end
    end
    for i = displayIndex, MAX_MINIONS do
        local mf, button = frames[i], frames[i].clickButton
        HideMinionTooltip(mf)
        HideMinionTooltip(button)
        mf.minionName, mf.minionGuid = nil, nil
        if mf:IsShown() then mf:Hide() end
        mf.renderedVisible = false
        if not InCombatLockdown() then
            button.targetGUID, button.preferredUnit, button.boundUnit = nil, nil, nil
            SetTargetAction(button, nil, false)
            if button:IsShown() then button:Hide() end
        end
    end

    local shown = displayIndex - 1
    local hidden = #displayOrder - shown
    local up = NecroMinionsDB.growDirection == "up"
    local rowsExtent = 25 + shown * (h + spacing) - (shown > 0 and spacing or 0)
    if hidden > 0 then
        local text = string.format("+%d more", hidden)
        if overflowText:GetText() ~= text then overflowText:SetText(text) end
        overflowText:ClearAllPoints()
        if up then
            overflowText:SetPoint("BOTTOMLEFT", mainContainer, "TOPLEFT", 2, rowsExtent + 2)
        else
            overflowText:SetPoint("TOPLEFT", mainContainer, "TOPLEFT", 2, -rowsExtent - 2)
        end
        if not overflowText:IsShown() then overflowText:Show() end
        rowsExtent = rowsExtent + 16
    elseif overflowText:IsShown() then
        overflowText:Hide()
    end
    -- The container itself is only the 20px header; extend the clamp area over
    -- the rows so a drag cannot leave them off-screen.
    local clampSignature = (up and "up" or "down")..rowsExtent
    if force or mainContainer.clampSignature ~= clampSignature then
        if up then
            mainContainer:SetClampRectInsets(0, 0, rowsExtent, 0)
        else
            mainContainer:SetClampRectInsets(0, 0, 0, -math.max(0, rowsExtent - 20))
        end
        mainContainer.clampSignature = clampSignature
    end

    -- The grip sits on the far corner of the last shown row: bottom-right when
    -- rows grow down, top-right when they grow up. Same availability as Move.
    if canDrag and shown > 0 then
        resizeGrip.rows = shown
        local gripSignature = clampSignature..":"..shown
        if force or resizeGrip.gripSignature ~= gripSignature then
            resizeGrip:ClearAllPoints()
            if up then
                resizeGrip:SetPoint("TOPRIGHT", frames[shown], "TOPRIGHT", 0, 0)
            else
                resizeGrip:SetPoint("BOTTOMRIGHT", frames[shown], "BOTTOMRIGHT", 0, 0)
            end
            SetGripFlipped(up)
            resizeGrip.gripSignature = gripSignature
        end
        if not resizeGrip:IsShown() then resizeGrip:Show() end
    elseif resizeGrip:IsShown() then
        if GameTooltip and GameTooltip:GetOwner() == resizeGrip then GameTooltip:Hide() end
        resizeGrip:Hide()
    end
end

RemoveMinion = function(guid, confirmedDead, reason)
    guid = Client.GUID(guid)
    if guid and confirmedDead then
        local data = minions[guid] or knownOwnedMinions[guid]
        if retiredMinions[guid] == "confirmed" then
            -- A hard sacrifice tombstone already carries the necessary guard.
            deadMinions[guid] = nil
        elseif data and data.temporary then
            -- Temporary summons are not resurrected; a minimal guard is enough
            -- and keeps long sessions of Zombie spam from growing this table.
            deadMinions[guid] = true
        elseif data then
            -- Compact historical metadata into an array; discard stale aliases
            -- and redundant ownership/summon-map entries, keeping resurrection
            -- metadata and the minimal duplicate/death guard for this session.
            deadMinions[guid] = { data.name, data.kind, data.temporary or false, data.summonSpellID or false, data.ordinal or false }
        elseif not deadMinions[guid] then
            deadMinions[guid] = true
        end
        knownOwnedMinions[guid] = nil
        seenSummons[guid] = nil
    end
    if guid and minions[guid] then
        recentRemovals[#recentRemovals + 1] = string.format("%.1f %s: %s", GetTime(), minions[guid].name or guid, reason or (confirmedDead and "confirmed death" or "pet token changed"))
        if #recentRemovals > 12 then table.remove(recentRemovals, 1) end
        minions[guid] = nil
        for i, g in ipairs(minionOrder) do
            if g == guid then
                table.remove(minionOrder, i)
                break
            end
        end
        needsRefresh = true
        layoutDirty = true
    end
end

-- Logs never carry maximum health, so combat-log estimates need a baseline.
-- The last real unit read for each kind is remembered per character (talents
-- and gear change it), and a row with no read yet starts at that value: full
-- health is the honest guess for a fresh summon, and it is shown with "~".
local function RememberedMaxHealth(kind)
    local store = kind and type(NecroMinionsCharDB) == "table" and NecroMinionsCharDB.maxHealthByKind
    local value = store and tonumber(store[kind])
    return value and value > 0 and value or nil
end

local function SeedEstimatedHealth(data)
    if data.hp and data.maxHp then return end
    local remembered = RememberedMaxHealth(data.kind)
    if remembered then
        data.hp, data.maxHp, data.estimated = remembered, remembered, true
        needsRefresh = true
    end
end

local function RememberMaxHealth(kind, maxHp)
    if not kind or not maxHp or maxHp <= 0 or type(NecroMinionsCharDB) ~= "table" then return end
    NecroMinionsCharDB.maxHealthByKind = NecroMinionsCharDB.maxHealthByKind or {}
    if NecroMinionsCharDB.maxHealthByKind[kind] == maxHp then return end
    NecroMinionsCharDB.maxHealthByKind[kind] = maxHp
    -- Rows of this kind that were waiting for a baseline can estimate now.
    for _, data in pairs(minions) do
        if data.kind == kind then SeedEstimatedHealth(data) end
    end
end

-- fromActivity: the minion itself attacked, cast or took damage in the combat
-- log. Guardians without a readable unit (every skeleton and fiend when
-- friendly nameplates are off) can only prove they are alive this way.
local function AddMinion(guid, name, hp, maxHp, unit, isPet, kind, fromActivity)
    guid = Client.GUID(guid)
    if not guid or guid == "" or ignoredGUIDs[guid] then return end
    if UnitIsDeadOrGhost("player") then return end
    -- Never adopt the client's "Unknown" placeholder as a row name.
    if Client.IsUnknownName(name) then name = nil end
    local known = knownOwnedMinions[guid]
    local deadRecord = deadMinions[guid]
    local previous = minions[guid]
    kind = kind or Client.Kind(name) or (previous and previous.kind) or (known and known.kind)
    -- Ownership alone also describes vanity books, repair helpers and other
    -- utility pets. New rows need a recognized Necromancer creature/spell;
    -- previously accepted GUIDs retain that identity when names are unavailable.
    if not kind and not previous and not known and type(deadRecord) ~= "table" then return end
    local revived = false
    if retiredMinions[guid] then
        -- Aggregate roster guesses are recoverable, by a live unit or by the
        -- minion fighting. A successful sacrifice is stronger evidence and can
        -- still have briefly readable stale tokens.
        if retiredMinions[guid] == "confirmed" then return end
        if not fromActivity and (not unit or not hp or hp <= 0) then return end
        retiredMinions[guid] = nil
        revived = true
    end
    if deadMinions[guid] then
        -- Aura cleanup can follow UNIT_DIED with the same ownership flags.
        -- Only a live unit query (e.g. a resurrected pet) can undo that death.
        if not unit or not hp or hp <= 0 then return end
        deadMinions[guid] = nil
        seenSummons[guid] = true
    end
    
    if not known and type(deadRecord) == "table" then
        known = { name = deadRecord[1], kind = deadRecord[2], temporary = deadRecord[3], summonSpellID = deadRecord[4] or nil, ordinal = deadRecord[5] or nil }
    end
    local oldName, oldHp, oldMaxHp, oldUnit, oldEstimated, oldKind
    if previous then oldName, oldHp, oldMaxHp, oldUnit, oldEstimated, oldKind = previous.name, previous.hp, previous.maxHp, previous.unit, previous.estimated, previous.kind end
    if not minions[guid] then
        local newKind = kind or Client.Kind(name) or (known and known.kind)
        local temporary, uncertainOrigin
        if known and known.temporary ~= nil then
            temporary, uncertainOrigin = known.temporary, known.uncertainOrigin
        else
            temporary = Client.IsTemporaryKind(newKind)
            -- Without its summon spell, a fiend may be the temporary Animate:
            -- version. Keep it out of Life Force counts rather than risk
            -- retiring real minions; its summon event corrects this.
            if not temporary and Client.IsAmbiguousKind(newKind) and not (known and known.summonSpellID) then
                temporary, uncertainOrigin = true, true
            end
        end
        -- With temporary tracking off, only an uncertain fiend (which may be
        -- the permanent Raise) still gets a row.
        if temporary and not uncertainOrigin and not NecroMinionsDB.trackTemporary then return end
        -- Only permanent rows can change the owner roster that is settling.
        if unit and not temporary then rosterGraceUntil = math.max(rosterGraceUntil, GetTime() + 0.75) end
        table.insert(minionOrder, guid)
        minions[guid] = {
            name = (name ~= "" and name) or (known and known.name) or "Guardian",
            hp = hp,
            maxHp = maxHp,
            unit = unit,
            isPet = isPet,
            kind = newKind,
            temporary = temporary,
            uncertainOrigin = uncertainOrigin,
            summonSpellID = known and known.summonSpellID,
            ordinal = known and known.ordinal,
            spawnTime = GetTime()
        }
        layoutDirty = true
    else
        minions[guid].name = (name ~= "" and name) or minions[guid].name or (known and known.name) or "Guardian"
        if unit then minions[guid].unit = unit end
        if hp then minions[guid].hp = hp end
        if maxHp and maxHp > 0 then minions[guid].maxHp = maxHp end
        if isPet then minions[guid].isPet = true end
        minions[guid].kind = kind or Client.Kind(name) or minions[guid].kind or (known and known.kind)
    end
    if unit and hp and hp > 0 and maxHp and maxHp > 0 then
        minions[guid].estimated = false
        minions[guid].lastLiveAt = GetTime()        RememberMaxHealth(minions[guid].kind, maxHp)
    else
        SeedEstimatedHealth(minions[guid])
    end
    local data = minions[guid]
    -- Any sighting or combat-log activity is evidence the summon still exists.
    data.lastEvidenceAt = GetTime()
    if fromActivity then data.lastActivityAt = data.lastEvidenceAt end
    -- A minion that kept fighting after an owner-aura guess removed it has
    -- disproved that guess; the aura hint is not applied to it again.
    if revived then data.auraHintDisproved = true end
    -- Numbers count the minions of a type that exist now: a new summon takes
    -- the lowest number no current row of its type uses, so four Ghouls are
    -- #1-#4 however many were raised before. A remembered number is kept
    -- unless another current row already holds it.
    local numberGroup = data.kind or data.name
    local ordinalTaken = false
    if data.ordinal and data.numberGroup == numberGroup then
        for otherGUID, other in pairs(minions) do
            if otherGUID ~= guid and other.numberGroup == numberGroup and other.ordinal == data.ordinal then
                ordinalTaken = true
                break
            end
        end
    end
    if not data.ordinal or data.numberGroup ~= numberGroup or ordinalTaken then
        local used = {}
        for otherGUID, other in pairs(minions) do
            if otherGUID ~= guid and other.numberGroup == numberGroup and other.ordinal then used[other.ordinal] = true end
        end
        local ordinal = 1
        while used[ordinal] do ordinal = ordinal + 1 end
        data.ordinal = ordinal
    end
    data.numberGroup = numberGroup
    do
        local known = knownOwnedMinions[guid] or {}
        known.name = minions[guid].name
        known.kind = minions[guid].kind
        known.unit = unit or known.unit
        known.temporary = data.temporary
        known.uncertainOrigin = data.uncertainOrigin
        known.summonSpellID = data.summonSpellID
        known.ordinal = data.ordinal
        knownOwnedMinions[guid] = known
    end
    if not previous or oldName ~= data.name or oldHp ~= data.hp or oldMaxHp ~= data.maxHp or oldUnit ~= data.unit or oldEstimated ~= data.estimated or oldKind ~= data.kind then needsRefresh = true end
    return true
end

local function IsMyGuardian(unit)
    if not UnitGUID(unit) then return false end
    if UnitIsUnit(unit, "pet") then return true end
    if playerName == "" or UnitIsPlayer(unit) then return false end
    
    -- A hidden tooltip loses its owner, after which SetUnit fills nothing.
    -- Reassign the owner before every scan.
    scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTooltip:ClearLines()
    scanTooltip:SetUnit(unit)
    
    for i = 2, scanTooltip:NumLines() do
        local line = _G["NecroMinionsScanTooltipTextLeft"..i]
        local lineText = line and line:GetText()
        if lineText then
            -- Plain matching avoids Lua-pattern characters in character names.
            -- Require name boundaries so Ann does not match Joann's guardian.
            local first, last = lineText:find(playerName, 1, true)
            if first then
                local before = first == 1 or lineText:sub(first - 1, first - 1):match("[%s<]")
                local after = lineText:sub(last + 1, last + 1)
                if before and (after == "'" or after == " " or after == ">") then return true end
            end
        end
    end
    return false
end

local function SyncUnit(unit)
    if UnitIsDeadOrGhost("player") then return false end

    -- Ascension nameplate tokens can expose GUID/health while UnitExists is
    -- false, so UnitGUID is the availability check here.
    local guid = Client.GUID(UnitGUID(unit))
    if not guid or ignoredGUIDs[guid] then return false end
    local name = UnitName(unit)
    -- Avoid probing ownership tooltips for unrelated utility companions. A
    -- known GUID remains recoverable even when its current name is missing.
    if not (minions[guid] or knownOwnedMinions[guid] or type(deadMinions[guid]) == "table"
        or retiredMinions[guid] == "inferred" or Client.Kind(name)) then return false end
    -- A placeholder name means the client has no loaded object behind this
    -- token. Its health reading must not keep a despawned minion's row alive.
    if Client.IsUnknownName(name) then return false end
    if not (minions[guid] or knownOwnedMinions[guid] or deadMinions[guid] or retiredMinions[guid] == "inferred") then
        -- Other Necromancers' minions share these names. Cache a negative
        -- ownership result briefly instead of probing a tooltip on every
        -- UNIT_HEALTH event and refresh.
        local now = GetTime()
        local recheckAt = foreignGUIDs[guid]
        if recheckAt and now < recheckAt then return false end
        if not IsMyGuardian(unit) then
            if not recheckAt then
                foreignCount = foreignCount + 1
                if foreignCount > 300 then foreignGUIDs, foreignCount = {}, 1 end
            end
            foreignGUIDs[guid] = now + FOREIGN_RECHECK
            return false
        end
        foreignGUIDs[guid] = nil
    end
    if UnitIsDeadOrGhost(unit) then
        RemoveMinion(guid, true)
        return true
    end
    local hp = UnitHealth(unit)
    local maxHp = UnitHealthMax(unit)
    if hp and hp > 0 and maxHp and maxHp > 0 then
        local updated = AddMinion(guid, name, hp, maxHp, unit, UnitIsUnit(unit, "pet"))
        if UnitIsUnit(unit, "pet") then petGUID = guid end
        return updated and true or false
    else
        -- Some custom clients briefly report zero during unit creation.
        AddMinion(guid, name, nil, nil, unit, UnitIsUnit(unit, "pet"))
    end
    return false
end

local scanUnits = { "pet", "target", "mouseover", "focus", "targettarget", "focustarget", "pettarget" }
for i = 1, 4 do
    scanUnits[#scanUnits + 1] = "party"..i.."target"
    scanUnits[#scanUnits + 1] = "partypet"..i
end
for i = 1, 40 do
    scanUnits[#scanUnits + 1] = "raid"..i.."target"
    scanUnits[#scanUnits + 1] = "raidpet"..i
end

-- Lets automatic health hide the nameplates of tracked minions.
Client.IsOwnMinionGUID = function(guid)
    return guid ~= nil and (minions[guid] ~= nil or knownOwnedMinions[guid] ~= nil)
end

-- Automatic health pulses friendly nameplates on (hidden) only while there is
-- health to read: in combat, briefly after a summon, and while the player
-- drains a minion. The rest of the time the character's own nameplate
-- settings are in effect; rows keep their last reading, adjusted by the log.
local SUMMON_PULSE, DRAIN_PULSE, COMBAT_LINGER = 3, 4, 2
local pulseUntil = 0
-- Plates switched on right after a login, reload or loading screen were
-- drawn old-style, so nameplate settings are left alone for a few seconds.
local LOGIN_SETTLE = 4
local settleUntil = 0
Client.PlatesWanted = function()
    return isActive and GetTime() >= settleUntil
        and (UnitAffectingCombat("player") or GetTime() < pulseUntil)
end

-- 0.7.8 switched friendly plates off and on after loading. Settings it
-- switched off and never back on (a reload in that half second) are kept
-- per character and switched back on here.
local friendlyPlateCVars = { "nameplateShowFriends", "nameplateShowFriendlyGuardians", "nameplateShowFriendlyPets" }
local function RestoreRefreshedPlates()
    local cdb = NecroMinionsCharDB
    local off = type(cdb) == "table" and type(cdb.plateRefreshOff) == "table" and cdb.plateRefreshOff
    if not off then return end
    for _, key in ipairs(friendlyPlateCVars) do
        if off[key] then pcall(SetCVar, key, "1") end
    end
    cdb.plateRefreshOff = nil
end

local function UpdatePlatePulse()
    if Client.isLoggingOut or not isActive or NecroMinionsDB.autoHealth == false then return end
    local wanted = Client.PlatesWanted() and true or false
    if wanted ~= (Client.pulseActive and true or false) then
        if wanted then Client.StartAutoHealth() else Client.StopAutoHealth() end
    end
end

local function PulsePlates(seconds)
    pulseUntil = math.max(pulseUntil, GetTime() + seconds)
    UpdatePlatePulse()
end

-- The player's last Raise/Animate/Mass Raise cast. Its summons can follow a
-- moment later, under a summon effect or creature name not listed anywhere.
local SUMMON_CAST_WINDOW = 2
local recentSummonCast
local function OnSummonCast(spellID, spellName)
    local now = GetTime()
    -- UNIT_SPELLCAST_SUCCEEDED and the combat log both report the same cast.
    if recentSummonCast and recentSummonCast.name == spellName and now - recentSummonCast.at < 0.3 then return end
    recentSummonCast = { id = spellID, name = spellName, at = now }
    PulsePlates(SUMMON_PULSE)
end

RefreshUnits = function()
    if Client.isLoggingOut or not isActive then return end
    if UnitIsDeadOrGhost("player") then
        if #minionOrder > 0 then ClearAllMinions() end
        return
    end
    playerGUID = Client.GUID(UnitGUID("player")) or playerGUID
    playerName = UnitName("player") or playerName

    local currentPetGUID = Client.GUID(UnitGUID("pet"))
    if petGUID and petGUID ~= currentPetGUID then RemoveMinion(petGUID) end
    petGUID = currentPetGUID

    local units = {}
    for _, data in pairs(minions) do
        if data.unit then units[#units + 1] = { data.unit, data } end
    end
    for _, entry in ipairs(units) do
        local unit, data = entry[1], entry[2]
        if minions[Client.GUID(UnitGUID(unit))] == data then
            SyncUnit(unit)
        else
            -- A target/mouseover token can now refer to an entirely different NPC.
            data.unit = nil
        end
    end
    for _, unit in ipairs(scanUnits) do
        if UnitGUID(unit) then SyncUnit(unit) end
    end
    Client.ScanNameplates(SyncUnit)
    ReconcileRoster()
end

local function RebuildMinions()
    if Client.isLoggingOut then return end
    local aliases, captured = {}, {}
    local function remember(guid, preferredUnit)
        local known = knownOwnedMinions[guid]
        if captured[guid] or not known then return end
        local unit = Client.ResolveUnitToken(guid, preferredUnit or known.unit)
        if unit then
            captured[guid] = true
            aliases[#aliases + 1] = { guid = guid, unit = unit }
        end
    end
    -- Keep existing row order and useful nonstandard unit aliases. Never carry
    -- health estimates or a disappeared unit back into the rebuilt display.
    for _, guid in ipairs(minionOrder) do remember(guid, minions[guid].unit) end
    for guid, data in pairs(knownOwnedMinions) do
        -- Do not run a full resolver search for every historical summon. Live
        -- nameplates are scanned once below; only cached aliases need saving.
        if data.unit and Client.GUID(UnitGUID(data.unit)) == guid then remember(guid, data.unit) end
    end

    ClearAllMinions()
    knownAuraKinds = {}
    rosterSignature, rosterChangedAt, rosterGraceUntil = nil, 0, GetTime() + 0.75
    lastRoster = nil
    -- Retired/dead GUID guards and seen-summon history deliberately survive.
    -- A real living unit can recover an inference, while stale combat events
    -- still cannot restore a sacrificed guardian or rearm an old replacement.
    Client.StartAutoHealth()
    for _, entry in ipairs(aliases) do
        if Client.GUID(UnitGUID(entry.unit)) == entry.guid then SyncUnit(entry.unit) end
    end
    RefreshUnits()
    UpdateMinionFrames()
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[NecroMinions]|r Tracking rebuilt: %d minion(s) detected.", #minionOrder))
end

-- Live evidence: a current unit read, or the minion's own combat-log activity
-- in the last two seconds (shorter than a replacement check's 3s deadline, so
-- a minion that really despawned at a new summon can still be retired).
local ACTIVITY_WINDOW = 2
local function HasLiveUnit(guid)
    local data = minions[guid]
    if not data then return false end
    if data.lastActivityAt and GetTime() - data.lastActivityAt <= ACTIVITY_WINDOW then return true end
    return data.unit and data.lastLiveAt and GetTime() - data.lastLiveAt <= 0.6
        and Client.GUID(UnitGUID(data.unit)) == guid and not UnitIsDeadOrGhost(data.unit)
end

local function RetireMinion(guid, confirmed, reason)
    guid = Client.GUID(guid)
    if not guid or (not confirmed and HasLiveUnit(guid)) then return false end
    retiredMinions[guid] = confirmed and "confirmed" or "inferred"
    RemoveMinion(guid, confirmed, reason)
    return true
end

local function SacrificeMinions()
    -- Include previously hidden candidates so stale tokens cannot restore them
    -- after a later successful sacrifice.
    for guid in pairs(knownOwnedMinions) do
        retiredMinions[guid] = "confirmed"
        deadMinions[guid] = nil
        seenSummons[guid] = nil
        knownOwnedMinions[guid] = nil
    end
    for guid in pairs(retiredMinions) do retiredMinions[guid] = "confirmed" end
    for i = #minionOrder, 1, -1 do RetireMinion(minionOrder[i], true, "Sacrifice / Dismiss Undead") end
    petGUID = nil
    newestSummonGUID = nil
    pendingReplacement = nil
    pendingCapacityChange = nil
    rosterGraceUntil = GetTime() + 0.75
end

-- A fallback for this character's observed pool: skeletons cost one, Abomination
-- two. Owner auras are presence hints; no exact aura count or fixed maximum
-- is assumed, and a current live unit always takes precedence.
local GRAVE_MAGES = 807937
local graveMagesKnown, graveMagesCheckedAt = false, -10
local function GetMinionCost(kind)
    local cost = Config.GetCost(NecroMinionsCharDB, kind)
    -- Grave Mages makes Skeletal Mage cost 1; only the CR default is adjusted,
    -- never a cost set by hand. Rechecked every few seconds for respecs.
    if kind == "mage" and cost == 2 then
        local now = GetTime()
        if now - graveMagesCheckedAt > 5 then
            graveMagesKnown, graveMagesCheckedAt = Client.IsSpellKnownByID(GRAVE_MAGES), now
        end
        if graveMagesKnown then cost = 1 end
    end
    return cost
end

local function ArmReplacementCheck(trigger, newGUID, capacity)
    local candidates = {}
    for _, guid in ipairs(minionOrder) do
        local data = minions[guid]
        local cost = not data.temporary and GetMinionCost(data.kind)
        if cost and guid ~= newGUID then candidates[#candidates + 1] = { guid = guid, cost = cost } end
    end
    pendingReplacement = {
        trigger = trigger, newGUID = newGUID, capacity = capacity,
        candidates = candidates, deadline = GetTime() + 3,
    }
end

local function ObserveCapacity(roster, now)
    local capacity = roster.capacity
    -- A brief low native read is not evidence that an established army must
    -- shrink. A larger observed limit is safe to accept immediately.
    if capacity and (not acceptedCapacity or capacity > acceptedCapacity) then acceptedCapacity = capacity end
    local change = pendingCapacityChange
    if not change then return end
    if now > change.deadline then pendingCapacityChange = nil; return end
    if not capacity then return end
    if change.value ~= capacity then
        change.value, change.since = capacity, now
        return
    end
    if now - change.since < 1.5 then return end
    pendingCapacityChange = nil
    if acceptedCapacity and capacity < acceptedCapacity then
        acceptedCapacity = capacity
        ArmReplacementCheck("confirmed capacity change", newestSummonGUID, capacity)
    end
end

-- Temporary summons are excluded from aura and capacity cleanup, so a despawn
-- with no observed death event needs its own fallback.
local function ExpireTemporaryMinions(now)
    for i = #minionOrder, 1, -1 do
        local guid = minionOrder[i]
        local data = minions[guid]
        if data and data.temporary then
            local lifetime = Client.MaxLifetime(data.kind)
            local reason
            if lifetime and now - (data.spawnTime or now) > lifetime + 2 then
                reason = string.format("temporary summon: past its %ds duration", lifetime)
            elseif now - (data.lastEvidenceAt or data.spawnTime or now) > TEMPORARY_TIMEOUT then
                reason = string.format("temporary summon: no activity for %ds", TEMPORARY_TIMEOUT)
            end
            -- The inferred tombstone still lets a live unit restore the row.
            if reason and RetireMinion(guid, false, reason) then knownOwnedMinions[guid] = nil end
        end
    end
end

ReconcileRoster = function()
    if Client.isLoggingOut or not isActive then return end
    local now = GetTime()
    ExpireTemporaryMinions(now)
    local roster = Client.ReadRoster()
    lastRoster = roster
    ObserveCapacity(roster, now)
    local observedCost = 0
    for _, data in pairs(minions) do
        if not data.temporary then observedCost = observedCost + (GetMinionCost(data.kind) or 0) end
    end
    local observedUsed = roster.capacity and roster.free and (roster.capacity - roster.free)
    local keys = {}
    for kind in pairs(roster.counts) do knownAuraKinds[kind] = true end
    for _, data in pairs(minions) do
        if data.kind and roster.counts[data.kind] then data.ownerAuraSeen = true end
        if roster.freeObserved and observedUsed and observedUsed > 0 and observedCost <= observedUsed then
            data.poolObservedInUse = true
        end
    end
    for kind in pairs(knownAuraKinds) do keys[#keys + 1] = kind end
    table.sort(keys)
    local signature = tostring(roster.capacity)..":"..tostring(roster.free)
    for _, kind in ipairs(keys) do signature = signature..":"..kind.."="..(roster.counts[kind] or 0) end
    if signature ~= rosterSignature then
        rosterSignature, rosterChangedAt = signature, now
        return
    end
    -- Aura lists and summon events do not arrive as an atomic update. Require
    -- the roster to settle before removing rows; mere loss of a token is not death.
    if now - rosterChangedAt < 0.6 or now < rosterGraceUntil then return end

    local occupied = 0
    for _, data in pairs(minions) do
        if not data.temporary then occupied = occupied + (GetMinionCost(data.kind) or 0) end
    end
    local used = roster.capacity and roster.free and (roster.capacity - roster.free)
    local auraCandidates = {}
    for _, guid in ipairs(minionOrder) do
        local data = minions[guid]
        -- One owner-buff icon can represent several minions. Never treat its
        -- stack/instance count as an exact number of live guardian GUIDs.
        -- Absence is only a hint after this guardian has seen that owner aura,
        -- and cannot overrule a matching live target/nameplate or a pool that
        -- still supports every tracked minion.
        if roster.readable and data.ownerAuraSeen and data.kind and not data.temporary and not data.auraHintDisproved
            and (guid ~= newestSummonGUID or not roster.capacity or data.poolObservedInUse)
            and not roster.counts[data.kind] and (not used or occupied > used) then
            auraCandidates[#auraCandidates + 1] = { guid = guid, cost = GetMinionCost(data.kind) or 0 }
        end
    end
    for _, entry in ipairs(auraCandidates) do
        if (not used or occupied > used) and RetireMinion(entry.guid, false, "owner aura disappeared; no live unit") then
            occupied = occupied - entry.cost
        end
    end

    -- Capacity is a replacement hint for a particular new paid summon (or a
    -- confirmed spell/talent change), not a recurring cull during movement.
    -- Snapshot candidates and close the decision so a recovered GUID cannot
    -- be removed again merely because its nameplate temporarily disappears.
    local check = pendingReplacement
    if not check then return end
    if now > check.deadline then pendingReplacement = nil; return end
    local capacity = check.capacity or acceptedCapacity
    if not capacity then return end
    capacity = math.max(capacity, acceptedCapacity or capacity)
    check.capacity = capacity
    occupied = 0
    for _, guid in ipairs(minionOrder) do
        local data = minions[guid]
        local cost = not data.temporary and GetMinionCost(data.kind)
        if cost then occupied = occupied + cost end
    end
    if occupied <= capacity then pendingReplacement = nil; return end
    -- The native free count is a direct reading of Life Force in use. When it
    -- already covers every tracked row, the overflow comes from a cost or
    -- capacity guess, not from a despawn, so nothing is retired.
    if roster.freeObserved and used and occupied <= used then pendingReplacement = nil; return end
    local waitingForLiveCandidates = false
    for _, entry in ipairs(check.candidates) do
        if occupied <= capacity then break end
        if minions[entry.guid] then
            if HasLiveUnit(entry.guid) then
                waitingForLiveCandidates = true
            elseif RetireMinion(entry.guid, false, string.format("%s: tracked=%d capacity=%d new=%s", check.trigger, occupied, capacity, check.newGUID or "none")) then
                occupied = occupied - entry.cost
            end
        end
    end
    if occupied <= capacity or not waitingForLiveCandidates then pendingReplacement = nil end
end

local damageEvents = {
    SWING_DAMAGE = 1, RANGE_DAMAGE = 4, SPELL_DAMAGE = 4,
    SPELL_PERIODIC_DAMAGE = 4, DAMAGE_SHIELD = 4, DAMAGE_SPLIT = 4,
    SPELL_BUILDING_DAMAGE = 4, ENVIRONMENTAL_DAMAGE = 2,
}
local deathEvents = { UNIT_DIED = true, UNIT_DESTROYED = true, UNIT_DISSIPATES = true, PARTY_KILL = true, SPELL_INSTAKILL = true }
-- Events only a present, living creature produces. Aura removals are left out:
-- they can trail a despawn.
local missEvents = { SWING_MISSED = true, RANGE_MISSED = true, SPELL_MISSED = true, SPELL_PERIODIC_MISSED = true }
local sourceActivityEvents = { SPELL_CAST_START = true, SPELL_CAST_SUCCESS = true, SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true, SPELL_ENERGIZE = true }
for subevent in pairs(damageEvents) do sourceActivityEvents[subevent] = true end
for subevent in pairs(missEvents) do sourceActivityEvents[subevent] = true end
sourceActivityEvents.ENVIRONMENTAL_DAMAGE = nil
local drainEvents = {
    SPELL_CAST_SUCCESS = true, SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
    SPELL_LEECH = true, SPELL_PERIODIC_LEECH = true, SPELL_DRAIN = true, SPELL_PERIODIC_DRAIN = true,
    SPELL_AURA_APPLIED = true, SPELL_AURA_REFRESH = true,
}

local function IsOwnedMinion(flags)
    return type(flags) == "number"
        and bit.band(flags, COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001) ~= 0
        and bit.band(flags, (COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000) + (COMBATLOG_OBJECT_TYPE_PET or 0x00001000)) ~= 0
end

local function IgnoreMinion(guid, reason)
    if not guid then return end
    if not ignoredGUIDs[guid] then
        ignoredCount = ignoredCount + 1
        -- Exploding zombies may produce no death event to free their entry.
        if ignoredCount > 500 then ignoredGUIDs, ignoredCount = {}, 1 end
        ignoredGUIDs[guid] = true
    end
    knownOwnedMinions[guid] = nil
    seenSummons[guid] = nil
    if minions[guid] then RemoveMinion(guid, false, reason) end
end

local function LogSummon(spellID, spellName, destName, outcome)
    summonLog[#summonLog + 1] = string.format("%.1f %s <- spell %s (%s): %s",
        GetTime(), tostring(destName or "?"), tostring(spellID or "?"), tostring(spellName or "?"), outcome)
    if #summonLog > 12 then table.remove(summonLog, 1) end
end

-- Zombie summons that arrive shortly after March of the Dead, through a spell
-- other than a known Zombie summon, belong to it. Log order is not
-- guaranteed, so a cast also reclaims rows created just before it.
local MARCH_WINDOW = 1.5
local function OnMarchCast()
    local now = GetTime()
    if now - marchCastAt < 0.2 then return end
    marchCastAt = now
    for i = #minionOrder, 1, -1 do
        local guid = minionOrder[i]
        local data = minions[guid]
        if data and data.kind == "zombie" and not Client.IsKnownSummonSpell(data.summonSpellID)
            and data.spawnTime and now - data.spawnTime <= 0.5 then
            IgnoreMinion(guid, "March of the Dead zombie (not tracked)")
        end
    end
end

local function IsMarchZombie(spellID, spellName, kind)
    if Client.IsMarchOfTheDead(spellID, spellName) then return true end
    return kind == "zombie" and not Client.IsKnownSummonSpell(spellID) and GetTime() - marchCastAt <= MARCH_WINDOW
end

local function ProcessCombatLog(timestamp, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
    if not subevent or UnitIsDeadOrGhost("player") then return end
    sourceGUID, destGUID = Client.GUID(sourceGUID), Client.GUID(destGUID)
    playerGUID = Client.GUID(UnitGUID("player")) or playerGUID
    local spellID, spellName = ...
    if subevent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID and Client.IsSacrifice(spellID, spellName) then
        SacrificeMinions()
        return
    end
    if subevent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID and Client.IsMarchOfTheDead(spellID, spellName) then
        OnMarchCast()
        return
    end

    -- Lifecycle handling must run before discovery, even for friendly fire or a
    -- minion killing another minion. Source discovery must not swallow damage.
    if deathEvents[subevent] then
        if ignoredGUIDs[destGUID] then
            ignoredGUIDs[destGUID] = nil
            ignoredCount = math.max(0, ignoredCount - 1)
            return
        end
        if minions[destGUID] or knownOwnedMinions[destGUID]
            or (IsOwnedMinion(destFlags) and Client.Kind(destName)) then RemoveMinion(destGUID, true) end
        return
    end
    if subevent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID and Client.IsSummonCast(spellID, spellName) then
        OnSummonCast(spellID, spellName)
    end
    local castKind, castIsAnimate
    if subevent == "SPELL_SUMMON" then
        -- A summon right after a Raise/Animate/Mass Raise cast is a minion even
        -- when neither its summon effect nor its creature name is listed.
        if Client.IsSummonCast(spellID, spellName) then
            castKind, castIsAnimate = Client.CastKind(spellID, spellName) or "other", Client.IsAnimateCast(spellID, spellName)
        elseif recentSummonCast and GetTime() - recentSummonCast.at <= SUMMON_CAST_WINDOW then
            castKind = Client.CastKind(recentSummonCast.id, recentSummonCast.name) or "other"
            castIsAnimate = Client.IsAnimateCast(recentSummonCast.id, recentSummonCast.name)
        end
    end
    if subevent == "SPELL_SUMMON" and sourceGUID and sourceGUID ~= ""
        and destGUID and ((playerGUID ~= "" and sourceGUID == playerGUID) or minions[sourceGUID])
        and (Client.SummonKind(spellID, destName) or castKind) then
        if ignoredGUIDs[destGUID] then return end
        local summonedKind = Client.SummonKind(spellID, destName) or castKind
        -- Remember a new creature name so nameplates and mouseover know it.
        if not Client.Kind(destName) then Client.LearnName(destName, summonedKind) end
        -- An Animate cast gives timed minions even for an unlisted creature.
        local isTemporary = Client.IsTemporarySummon(spellID, spellName) or Client.IsTemporaryKind(summonedKind)
            or (castIsAnimate and not Client.IsKnownSummonSpell(spellID)) or false
        if IsMarchZombie(spellID, spellName, summonedKind) then
            LogSummon(spellID, spellName, destName, "ignored (March of the Dead)")
            IgnoreMinion(destGUID, "March of the Dead zombie (not tracked)")
            return
        end
        if not NecroMinionsDB.trackTemporary and isTemporary then
            LogSummon(spellID, spellName, destName, "ignored (temporary tracking off)")
            IgnoreMinion(destGUID, "temporary summon (tracking off)")
            return
        end
        -- The combat log can repeat a summon after its GUID was retired. Only
        -- the first real summon can create a replacement decision or clear a
        -- retirement; later copies must not revive a sacrificed guardian.
        if seenSummons[destGUID] or deadMinions[destGUID] or retiredMinions[destGUID] == "confirmed" then return end
        LogSummon(spellID, spellName, destName, "tracked")
        -- Show (hidden) plates long enough to read the new minion's health.
        PulsePlates(SUMMON_PULSE)
        seenSummons[destGUID] = true
        retiredMinions[destGUID] = nil
        deadMinions[destGUID] = nil
        AddMinion(destGUID, destName, nil, nil, nil, nil, summonedKind)
        local data = minions[destGUID]
        if data then
            data.summonSpellID = spellID
            -- The summon spell settles permanence, including for a fiend
            -- first seen on a nameplate before this event arrived.
            data.temporary = isTemporary or Client.IsTemporaryKind(data.kind)
            data.uncertainOrigin = nil
            local known = knownOwnedMinions[destGUID]
            if known then
                known.summonSpellID = spellID
                known.temporary = data.temporary
                known.uncertainOrigin = nil
            end
            -- Temporary summons do not touch the owner roster. Letting them
            -- extend settling time could postpone a pending replacement past
            -- its deadline, and they must not displace the newest paid summon.
            if not data.temporary then
                newestSummonGUID = destGUID
                rosterGraceUntil = GetTime() + 0.75
                if GetMinionCost(data.kind) then
                    ArmReplacementCheck("new summon replacement", destGUID, acceptedCapacity)
                end
            end
            needsRefresh, layoutDirty = true, true
        end
    end
    if IsOwnedMinion(sourceFlags) then
        AddMinion(sourceGUID, sourceName, nil, nil, nil, nil, nil, sourceActivityEvents[subevent])
    end
    if IsOwnedMinion(destFlags) then
        AddMinion(destGUID, destName, nil, nil, nil, nil, nil, damageEvents[subevent] or missEvents[subevent])
    end

    local data = minions[destGUID]
    if not data then return end
    -- The player's own spell hitting a minion (a cast on it, a drain or a
    -- leech, direct or over time) changes its health outside the usual
    -- combat flow, so the plates pulse on to read it.
    if sourceGUID == playerGUID and sourceGUID ~= destGUID and drainEvents[subevent] then
        PulsePlates(DRAIN_PULSE)
    end
    local amountIndex = damageEvents[subevent]
    local isHeal = subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" or subevent == "SPELL_BUILDING_HEAL"
    if not amountIndex and not isHeal then return end

    if data.unit and Client.GUID(UnitGUID(data.unit)) == destGUID then
        if SyncUnit(data.unit) then return end
    end
    -- Logs cannot reveal a guardian's maximum health. Keep it unknown until a
    -- unit query succeeds; use estimates only after obtaining a real baseline.
    if not data.hp or not data.maxHp then return end
    local amount = select(amountIndex or 4, ...)
    if type(amount) ~= "number" or amount <= 0 then return end
    -- Overkill and overheal follow the amount; neither changed real health.
    local excess = select((amountIndex or 4) + 1, ...)
    amount = math.max(0, amount - (type(excess) == "number" and math.max(0, excess) or 0))
    if isHeal then
        data.hp = math.min(data.maxHp, data.hp + amount)
    else
        data.hp = math.max(0, data.hp - amount)
    end
    data.estimated = true
    needsRefresh = true
end

local function DecodeCombatLog(...)
    -- Wrath uses 8 header fields; custom clients can backport the 9- or
    -- 11-field variants. Detect types rather than assume a retail layout.
    if type(select(3, ...)) == "boolean" then
        local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags = ...
        if type(select(7, ...)) == "number" then
            local destGUID, destName, destFlags = select(8, ...)
            ProcessCombatLog(timestamp, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, select(12, ...))
        else
            local destGUID, destName, destFlags = select(7, ...)
            ProcessCombatLog(timestamp, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, select(10, ...))
        end
    else
        ProcessCombatLog(...)
    end
end

local previewSamples = {
    { "Skeletal Warrior", 1800, 2400 }, { "Abomination", 3500, 4500 },
    { "Crypt Fiend", 1200, 1500 }, { "Ghoul", 900, 1000 },
}

ToggleChangeMode = function()
    -- Preview only swaps what this addon's unprotected rows display, so it
    -- can always be left; entering it (to move the HUD) waits for combat to end.
    if not isActive then return end
    if not isChangeMode and InCombatLockdown() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Editor mode is available after combat.")
        return
    end
    StopHudDrag(false)
    isChangeMode = not isChangeMode
    previewMinions, previewOrder = {}, {}
    if isChangeMode then
        for i, sample in ipairs(previewSamples) do
            local guid = "preview"..i
            previewOrder[i] = guid
            previewMinions[guid] = { name = sample[1], kind = Client.Kind(sample[1]), hp = sample[2], maxHp = sample[3], ordinal = 1 }
        end
    end
    layoutDirty = true
    -- Tracking kept running during preview; a refresh just picks up tokens.
    if not isChangeMode then RefreshUnits() end
    UpdateMinionFrames(true)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions Editor mode]|r "..(isChangeMode and "On." or "Off."))
end

-- The Move/Locked tab and resize grip fade in while the cursor is over the
-- tab or any row (with a small margin and a short linger so gaps between rows
-- do not flicker). Alpha is used rather than Hide, so a drag never stops.
local HOVER_LINGER = 0.4
local hoverUntil, handleAlpha = 0, nil
local function UpdateHandleHover()
    if not dragHandle:IsShown() and not resizeGrip:IsShown() then return end
    local visible = not NecroMinionsDB.handleOnHover or isChangeMode or isDragging or isResizing
        or (DropDownList1 and DropDownList1:IsShown())
    if not visible then
        local now = GetTime()
        local over = dragHandle:IsMouseOver(6, -6, -6, 6)
        if not over then
            for _, row in ipairs(frames) do
                if row:IsShown() and row:IsMouseOver(4, -4, -4, 4) then over = true; break end
            end
        end
        if over then hoverUntil = now + HOVER_LINGER end
        visible = now < hoverUntil
    end
    local alpha = visible and 1 or 0
    if handleAlpha ~= alpha then
        dragHandle:SetAlpha(alpha)
        resizeGrip:SetAlpha(alpha)
        handleAlpha = alpha
    end
end

local timer = 0
mainContainer:SetScript("OnUpdate", function(self, elapsed)
    if Client.isLoggingOut then return end
    Client.UpdatePlateVisuals()
    UpdateHandleHover()
    timer = timer + elapsed
    if timer >= 0.25 then
        timer = 0
        UpdatePlatePulse()
        RefreshUnits()
    end
    -- Coalesce bursts of combat-log messages into one render per game frame.
    if needsRefresh then UpdateMinionFrames() end
end)

local function ApplyAppearance()
    NecroMinionsDB = Config.Normalize(NecroMinionsDB)
    mainContainer:ClearAllPoints()
    if NecroMinionsDB.point then
        local point = NecroMinionsDB.point
        mainContainer:SetPoint(point.point, UIParent, point.relativePoint, point.xOfs, point.yOfs)
    else
        mainContainer:SetPoint("TOPLEFT", UIParent, "LEFT", 8, 90)
    end
    mainContainer:SetScale(NecroMinionsDB.scale)
    layoutDirty = true
    UpdateMinionFrames(true)
end

ResetAppearance = function()
    if Client.isLoggingOut then return end
    NecroMinionsDB = Config.ResetAppearance(NecroMinionsDB)
    ApplyAppearance()
end

-- Turning temporary tracking off also drops current temporary rows (except an
-- uncertain fiend) and keeps those GUIDs from being rediscovered.
local function SetTemporaryTracking(enabled)
    NecroMinionsDB.trackTemporary = enabled and true or false
    if not enabled then
        for i = #minionOrder, 1, -1 do
            local guid = minionOrder[i]
            local data = minions[guid]
            if data and data.temporary and not data.uncertainOrigin then
                IgnoreMinion(guid, "temporary summon (tracking off)")
            end
        end
    end
    layoutDirty, needsRefresh = true, true
    UpdateMinionFrames(true)
end

local configPanel = NecroMinionsOptions.Create({
    onAppearanceChanged = function(forceLayout)
        if Client.isLoggingOut then return end
        NecroMinionsDB = Config.Normalize(NecroMinionsDB)
        mainContainer:SetScale(NecroMinionsDB.scale)
        if forceLayout then layoutDirty = true end
        UpdateMinionFrames(forceLayout)
    end,
    onMove = ToggleChangeMode,
    onSummonDiagnostics = function()
        if Client.isLoggingOut then return end
        if #summonLog == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r No summon events recorded yet.")
        end
        for _, message in ipairs(summonLog) do
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r "..message)
        end
    end,
    onStatusDiagnostics = function()
        if Client.isLoggingOut then return end
        if not isActive then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Inactive: this character is not a Necromancer.")
            return
        end
        local roster = lastRoster or Client.ReadRoster()
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[NecroMinions]|r Minions: %d. Life Force: %s/%s free. Nameplate tokens: %d.",
            #minionOrder, tostring(roster.free or "?"), tostring(roster.capacity or "?"), Client.lastPlateCount or 0))
    end,
    onResetAppearance = ResetAppearance,
    onCostsChanged = function()
        if Client.isLoggingOut then return end
        Config.Character()
        pendingReplacement, pendingCapacityChange, rosterSignature = nil, nil, nil
        needsRefresh = true
        UpdateMinionFrames()
    end,
    onTrackingChanged = function(value)
        if Client.isLoggingOut then return end
        SetTemporaryTracking(value)
    end,
    onAutoHealthChanged = function(value)
        if Client.isLoggingOut then return end
        NecroMinionsDB.autoHealth = value
        if not isActive then return end
        if value then Client.StartAutoHealth() else Client.StopAutoHealth() end
        RefreshUnits()
        UpdateMinionFrames()
    end,
})

local function OpenOptions()
    configPanel.RefreshValues()
    InterfaceOptionsFrame_OpenToCategory(configPanel)
    -- 3.3.5 can land on the wrong category the first time the frame opens.
    InterfaceOptionsFrame_OpenToCategory(configPanel)
end

local function ToggleSetting(key)
    NecroMinionsDB[key] = not NecroMinionsDB[key]
    configPanel.RefreshValues()
    layoutDirty = true
    UpdateMinionFrames(true)
end

-- Right-click menu on the Move/Locked tab. Built on each open so check marks
-- reflect the current settings.
local hudMenuFrame = CreateFrame("Frame", "NecroMinionsHudMenu", UIParent, "UIDropDownMenuTemplate")
ShowHudMenu = function()
    if Client.isLoggingOut or InCombatLockdown() then return end
    local db = NecroMinionsDB
    local menu = {
        { text = "NecroMinions", isTitle = true, notCheckable = true },
        { text = "Lock HUD", isNotRadio = true, checked = db.locked,
            func = function() SetHudLocked(not NecroMinionsDB.locked) end },
        { text = "Preview mode", isNotRadio = true, checked = isChangeMode,
            func = function() ToggleChangeMode() end },
        { text = "Track temporary summons", isNotRadio = true, checked = db.trackTemporary,
            func = function() SetTemporaryTracking(not NecroMinionsDB.trackTemporary); configPanel.RefreshValues() end },
        { text = "Number identical summons", isNotRadio = true, checked = db.numberDuplicates,
            func = function() ToggleSetting("numberDuplicates") end },
        { text = "Health as percentage", isNotRadio = true, checked = db.healthText == "percent",
            func = function()
                -- Off returns to the width-based Auto format.
                NecroMinionsDB.healthText = NecroMinionsDB.healthText == "percent" and "auto" or "percent"
                configPanel.RefreshValues()
                UpdateMinionFrames(true)
            end },
        { text = "Hide my minion nameplates", isNotRadio = true, checked = db.minionPlates,
            func = function() ToggleSetting("minionPlates") end },
        { text = "Colour bars by health", isNotRadio = true, checked = db.healthColors,
            func = function() ToggleSetting("healthColors") end },
        { text = "Show tooltips", isNotRadio = true, checked = db.showTooltips,
            func = function() ToggleSetting("showTooltips") end },
        { text = "Show this tab only on mouseover", isNotRadio = true, checked = db.handleOnHover,
            func = function() ToggleSetting("handleOnHover") end },
        { text = "Rows grow upward", isNotRadio = true, checked = db.growDirection == "up",
            func = function()
                NecroMinionsDB.growDirection = NecroMinionsDB.growDirection == "up" and "down" or "up"
                configPanel.RefreshValues()
                layoutDirty = true
                UpdateMinionFrames(true)
            end },
        { text = "Rescan minions", notCheckable = true,
            func = function() Client.StartAutoHealth(); RefreshUnits(); UpdateMinionFrames() end },
        { text = "Rebuild tracking", notCheckable = true, func = function() RebuildMinions() end },
        { text = "All options...", notCheckable = true, func = OpenOptions },
        { text = "Close", notCheckable = true, func = function() CloseDropDownMenus() end },
    }
    EasyMenu(menu, hudMenuFrame, "cursor", 0, 0, "MENU")
end

-- Switches the addon off on every class but Necromancer: no tracking, no HUD
-- and no nameplate CVar changes. The nameplate preferences it manages are
-- account-wide, so an alt also restores any backup left by the Necromancer.
local function DetectClass()
    local _, class = UnitClass("player")
    if not class then return end
    local active = class == "NECROMANCER"
    if classKnown and active == isActive then return end
    classKnown, isActive = true, active
    Client.inactive = not active
    if active then
        mainContainer:Show()
        -- Before StartAutoHealth, which restores or extends this backup.
        Config.ClaimAccountBackup(NecroMinionsCharDB, NecroMinionsDB)
        Client.StartAutoHealth()
        RefreshUnits()
    else
        StopHudDrag(false)
        StopHudResize(false)
        if isChangeMode then
            isChangeMode = false
            previewMinions, previewOrder = {}, {}
        end
        CloseDropDownMenus()
        ClearAllMinions()
        Client.StopAutoHealth()
        mainContainer:Hide()
    end
    layoutDirty = true
    UpdateMinionFrames(true)
end

frame:SetScript("OnEvent", function(self, event, ...)
    if Client.isLoggingOut then return end
    if not classKnown and event ~= "ADDON_LOADED" then DetectClass() end
    -- Saved settings still load on other classes; everything else is ignored.
    if classKnown and not isActive and event ~= "ADDON_LOADED" then return end
    if event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        layoutDirty = true
        UpdateMinionFrames(true)

    elseif event == "ADDON_LOADED" then
        local addonLoaded = ...
        if addonLoaded == addonName then
            NecroMinionsDB = Config.Normalize(NecroMinionsDB)
            NecroMinionsCharDB = Config.InitializeCharacter(NecroMinionsCharDB, NecroMinionsDB)
            Client.SetLearnedNames(NecroMinionsCharDB.learnedNames)
            configPanel.RefreshValues()
            ApplyAppearance()
            ClearAllMinions()
            DetectClass()
            if isActive then Client.StartAutoHealth() end
            UpdateMinionFrames()
        end

    elseif event == "PLAYER_DEAD" then
        ClearAllMinions()

    elseif event == "PLAYER_REGEN_DISABLED" then
        StopHudDrag(false)
        StopHudResize(false)
        UpdatePlatePulse()
        UpdateMinionFrames()

    elseif event == "PLAYER_LOGOUT" then
        -- This client's native nameplate objects are already being destroyed.
        -- No frame methods or CVar updates are safe from this shutdown event.
        pendingReplacement = nil
        pendingCapacityChange = nil
        Client.StopAutoHealth(true)
        return

    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" or event == "PLAYER_REGEN_ENABLED" then
        playerGUID = Client.GUID(UnitGUID("player")) or ""
        playerName = UnitName("player") or ""
        if event == "PLAYER_ENTERING_WORLD" then
            settleUntil = GetTime() + LOGIN_SETTLE
            RestoreRefreshedPlates()
        else
            -- A short pulse after combat takes a final reading before the
            -- character's own nameplate settings return.
            pulseUntil = math.max(pulseUntil, GetTime() + COMBAT_LINGER)
        end
        Client.StartAutoHealth()
        -- Existing guardians can survive a reload or a loading screen.
        RefreshUnits()
        needsRefresh = true

    elseif event == "PET_DISMISS" then
        -- PET_DISMISS can arrive after UnitGUID("pet") has already gone nil.
        RemoveMinion(petGUID)
        petGUID = nil

    elseif event == "UNIT_PET" then
        local unit = ...
        if unit == "player" then RefreshUnits() end

    elseif (event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED") then
        pendingCapacityChange = { deadline = GetTime() + 5 }
        ReconcileRoster()

    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then ReconcileRoster() end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, spellName, _, _, spellID = ...
        if type(select(3, ...)) == "number" and not spellID then spellID = select(3, ...) end
        if unit == "player" and Client.IsSacrifice(spellID, spellName) then SacrificeMinions() end
        if unit == "player" and Client.IsMarchOfTheDead(spellID, spellName) then OnMarchCast() end
        if unit == "player" and Client.IsSummonCast(spellID, spellName) then OnSummonCast(spellID, spellName) end

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        if unit then SyncUnit(unit) end

    elseif (event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT" or event == "UNIT_MAXHEALTH") then
        local unit = ...
        if unit then SyncUnit(unit) end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if select("#", ...) > 0 then
            DecodeCombatLog(...)
        elseif type(CombatLogGetCurrentEventInfo) == "function" then
            DecodeCombatLog(CombatLogGetCurrentEventInfo())
        end

    elseif (event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_FOCUS_CHANGED" or event == "UNIT_TARGET") then
        SyncUnit("target")
        SyncUnit("mouseover")
        SyncUnit("focus")
    end
    if needsRefresh and event ~= "COMBAT_LOG_EVENT_UNFILTERED" then UpdateMinionFrames() end
end)

SLASH_NECROMINIONS1 = "/nm"
SlashCmdList["NECROMINIONS"] = function(msg)
    if Client.isLoggingOut then return end
    local command = (msg or ""):lower():match("^%s*(.-)%s*$")
    if not isActive and command ~= "options" and command ~= "config" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Inactive: this character is not a Necromancer.")
        return
    end
    if command == "options" or command == "config" then
        OpenOptions()
    elseif command == "resetui" then
        ResetAppearance()
        configPanel.RefreshValues()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Appearance reset; your army and tracking settings are preserved.")
    elseif command == "change" then
        ToggleChangeMode()
    elseif command == "refresh" then
        Client.StartAutoHealth()
        RefreshUnits()
        UpdateMinionFrames()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Refreshed accessible minions.")
    elseif command == "clear" then
        RebuildMinions()
    elseif command == "autohealth off" then
        NecroMinionsDB.autoHealth = false
        Client.StopAutoHealth()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Automatic nameplate health off; previous nameplate settings restored.")
    elseif command == "autohealth on" then
        NecroMinionsDB.autoHealth = true
        Client.StartAutoHealth()
        RefreshUnits()
        UpdateMinionFrames()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Automatic nameplate health on.")
    elseif command == "status" then
        local roster = lastRoster or Client.ReadRoster()
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[NecroMinions]|r Minions: %d. Life Force: %s/%s free. Nameplate tokens: %d. Nameplate manager: %s.", #minionOrder, tostring(roster.free or "?"), tostring(roster.capacity or "?"), Client.lastPlateCount or 0, C_NamePlateManager and "yes" or "no"))
        if #recentRemovals > 0 then DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Last removal: "..recentRemovals[#recentRemovals]) end
    elseif command == "plates" then
        local lines = Client.DescribePlates()
        if #lines == 0 then DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r No nameplates are showing right now.") end
        for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r "..line) end
    elseif command == "trace" then
        for _, message in ipairs(recentRemovals) do DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r "..message) end
    elseif command == "lock" or command == "unlock" then
        if InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Lock and unlock are available after combat.")
        else
            SetHudLocked(command == "lock")
        end
    elseif command == "temporary on" or command == "temporary off" then
        SetTemporaryTracking(command == "temporary on")
        configPanel.RefreshValues()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r Temporary summon tracking "..(NecroMinionsDB.trackTemporary and "on." or "off."))
    elseif command == "summons" then
        if #summonLog == 0 then DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r No summon events recorded yet.") end
        for _, message in ipairs(summonLog) do DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r "..message) end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[NecroMinions]|r /nm options - Settings. /nm change - Move. /nm lock or unlock. /nm resetui - Reset appearance. /nm refresh - Rescan. /nm clear - Rebuild. /nm status or trace - Diagnostics.")
    end
end
