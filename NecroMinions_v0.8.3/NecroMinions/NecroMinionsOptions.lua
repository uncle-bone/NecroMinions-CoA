-- Native 3.3.5 interface-options panel. Settings are applied immediately.
NecroMinionsOptions = {}
local Options = NecroMinionsOptions
local Config = NecroMinionsConfig

local function shuttingDown()
    return NecroMinionsClient and NecroMinionsClient.isLoggingOut
end

local function percent(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end
local function integer(value) return tostring(math.floor(value + 0.5)) end

function Options.Create(callbacks)
    if Options.panel then return Options.panel end
    callbacks = callbacks or {}
    local panel = CreateFrame("Frame", "NecroMinionsOptionsPanel", UIParent)
    panel.name = "NecroMinions"
    panel.controls = { lifeForceCosts = {} }
    Options.panel = panel
    local controls, refreshers = panel.controls, {}
    local refreshing = false
    local function db()
        NecroMinionsDB = Config.Normalize(NecroMinionsDB)
        return NecroMinionsDB
    end
    local function notify(layout)
        if callbacks.onAppearanceChanged then callbacks.onAppearanceChanged(layout and true or false) end
    end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("NecroMinions")
    local scroll = CreateFrame("ScrollFrame", "NecroMinionsOptionsScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -42)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 12)
    local content = CreateFrame("Frame", "NecroMinionsOptionsContent", scroll)
    content:SetSize(560, 1300)
    scroll:SetScrollChild(content)
    panel.scrollFrame, panel.content = scroll, content

    local y, column, rowHeight = -12, 0, 0
    local function flush()
        if column ~= 0 then y = y - rowHeight; column, rowHeight = 0, 0 end
    end
    local function place(control, height)
        control:SetPoint("TOPLEFT", content, "TOPLEFT", column == 0 and 16 or 286, y)
        rowHeight = math.max(rowHeight, height)
        if column == 0 then column = 1 else y, column, rowHeight = y - rowHeight, 0, 0 end
    end
    local function heading(text)
        flush()
        local label = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", content, "TOPLEFT", 12, y)
        label:SetText(text)
        y = y - 32
    end
    local function description(text)
        flush()
        local label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
        label:SetWidth(510)
        label:SetJustifyH("LEFT")
        label:SetText(text)
        y = y - 36
    end
    local function button(key, label, onClick)
        local control = CreateFrame("Button", "NecroMinionsOption_"..key, content, "UIPanelButtonTemplate")
        control:SetSize(230, 24)
        control:SetText(label)
        control:SetScript("OnClick", function(self)
            if shuttingDown() or refreshing then return end
            onClick(self)
        end)
        controls[key] = control
        place(control, 38)
        return control
    end
    local function checkbox(key, label, callback)
        local control = CreateFrame("CheckButton", "NecroMinionsOption_"..key, content, "UICheckButtonTemplate")
        control:SetSize(26, 26)
        local text = control:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", control, "RIGHT", 2, 0)
        text:SetText(label)
        control.label = text
        control:SetScript("OnClick", function(self)
            if shuttingDown() or refreshing then return end
            local value = self:GetChecked() and true or false
            db()[key] = value
            if callback then callback(value) else notify(false) end
        end)
        controls[key] = control
        refreshers[#refreshers + 1] = function() control:SetChecked(db()[key]) end
        place(control, 36)
        return control
    end
    local function slider(key, label, low, high, step, format, layout, kind)
        local names = {
            scale = "NecroMinionsScaleSlider", width = "NecroMinionsWidthSlider",
            height = "NecroMinionsHeightSlider", spacing = "NecroMinionsSpacingSlider",
            barWidthPct = "NecroMinionsBarWidthSlider", barHeightPct = "NecroMinionsBarHeightSlider",
        }
        local name = names[key] or "NecroMinionsOption_"..key
        local control = CreateFrame("Slider", name, content, "OptionsSliderTemplate")
        control:SetSize(218, 18)
        control:SetMinMaxValues(low, high)
        control:SetValueStep(step)
        if control.SetObeyStepOnDrag then control:SetObeyStepOnDrag(true) end
        _G[name.."Text"]:SetText(label)
        _G[name.."Low"]:SetText(format(low))
        _G[name.."High"]:SetText(format(high))
        local valueText = control:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        valueText:SetPoint("TOP", control, "BOTTOM", 0, -4)
        valueText:SetText("")
        control.valueText = valueText
        control:SetScript("OnValueChanged", function(self, value)
            if shuttingDown() or refreshing then return end
            local settings = db()
            if kind then
                value = math.floor(value + 0.5)
                Config.Character().lifeForceCosts[kind] = value
            else
                settings[key] = value
            end
            valueText:SetText(format(value))
            if kind then
                if callbacks.onCostsChanged then callbacks.onCostsChanged() end
            else
                notify(layout)
            end
        end)
        controls[key] = control
        if kind then controls.lifeForceCosts[kind] = control end
        refreshers[#refreshers + 1] = function()
            local value
            if kind then value = Config.Character().lifeForceCosts[kind] else value = db()[key] end
            control:SetValue(value)
            valueText:SetText(format(value))
        end
        place(control, 64)
        return control
    end
    local function cycle(key, label, choices, layout)
        local control
        control = button(key, label, function()
            local settings, index = db(), 1
            for i, choice in ipairs(choices) do if choice[1] == settings[key] then index = i; break end end
            settings[key] = choices[(index % #choices) + 1][1]
            control:SetText(label..": "..choices[(index % #choices) + 1][2])
            notify(layout)
        end)
        refreshers[#refreshers + 1] = function()
            local value = db()[key]
            for _, choice in ipairs(choices) do
                if choice[1] == value then control:SetText(label..": "..choice[2]); return end
            end
        end
        return control
    end
    local function colorButton(key, label, withOpacity)
        local names = { color = "NecroMinionsColorSwatch", bgColor = "NecroMinionsBgColorSwatch", borderColor = "NecroMinionsBorderColorSwatch" }
        local control = CreateFrame("Button", names[key], content)
        control:SetSize(22, 22)
        local texture = control:CreateTexture(nil, "OVERLAY")
        texture:SetAllPoints(true)
        texture:SetTexture(1, 1, 1)
        local text = control:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", control, "RIGHT", 8, 0)
        text:SetText(label)
        control.texture = texture
        control:SetScript("OnClick", function()
            if shuttingDown() or refreshing or not ColorPickerFrame then return end
            local original = db()[key]
            local r, g, b, a = original.r, original.g, original.b, original.a
            local function updateSwatch()
                local value = db()[key]
                texture:SetVertexColor(value.r, value.g, value.b)
            end
            local function apply()
                if shuttingDown() then return end
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                local alpha = a
                if withOpacity and OpacitySliderFrame and OpacitySliderFrame:IsShown() then
                    alpha = 1 - OpacitySliderFrame:GetValue()
                end
                local value = { r = nr, g = ng, b = nb }
                if withOpacity then value.a = alpha end
                db()[key] = value
                updateSwatch()
                notify(false)
            end
            -- Detach prior callbacks before changing the shared picker so one
            -- addon's old callback cannot edit an unrelated swatch on setup.
            ColorPickerFrame.func = nil
            ColorPickerFrame.opacityFunc = nil
            ColorPickerFrame.cancelFunc = nil
            ColorPickerFrame:Hide()
            ColorPickerFrame.hasOpacity = withOpacity and true or false
            ColorPickerFrame.opacity = withOpacity and (1 - a) or nil
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame.func = apply
            ColorPickerFrame.opacityFunc = withOpacity and apply or nil
            ColorPickerFrame.cancelFunc = function()
                if shuttingDown() then return end
                local value = { r = r, g = g, b = b }
                if withOpacity then value.a = a end
                db()[key] = value
                updateSwatch()
                notify(false)
            end
            ColorPickerFrame:Show()
        end)
        controls[key] = control
        refreshers[#refreshers + 1] = function()
            local value = db()[key]
            texture:SetVertexColor(value.r, value.g, value.b)
        end
        place(control, 38)
        return control
    end

    heading("Position and size")
    button("move", "Move / preview HUD", function() if callbacks.onMove then callbacks.onMove() end end)
    button("resetAppearance", "Reset appearance", function()
        if callbacks.onResetAppearance then callbacks.onResetAppearance() end
        panel.RefreshValues()
    end)
    description("Drag the small Move tab on the HUD outside combat. Right-click it for a menu with lock/unlock, preview and other options.")
    checkbox("locked", "Lock HUD position (tab shows Locked; no drag or resize)")
    checkbox("handleOnHover", "Show Move/Locked tab only on mouseover")
    slider("scale", "HUD scale", 0.5, 1.5, 0.05, percent, true)
    slider("width", "Row width", 100, 350, 5, integer, true)
    slider("height", "Row height", 25, 70, 1, integer, true)
    slider("spacing", "Row spacing", 0, 20, 1, integer, true)
    slider("barWidthPct", "Health bar width", 10, 100, 5, function(v) return integer(v).."%" end, true)
    slider("barHeightPct", "Health bar height", 10, 100, 5, function(v) return integer(v).."%" end, true)
    cycle("growDirection", "Rows grow", { { "down", "Down" }, { "up", "Up" } }, true)
    checkbox("numberDuplicates", "Number identical summons")

    heading("Opacity and colours")
    colorButton("color", "Health bar colour", false)
    colorButton("bgColor", "Background colour / opacity", true)
    colorButton("borderColor", "Border colour", false)
    checkbox("healthColors", "Colour bars by remaining health")
    slider("opacity", "Whole HUD opacity", 0, 1, 0.05, percent, false)
    checkbox("separateOpacity", "Separate combat / idle opacity")
    slider("combatOpacity", "In-combat opacity", 0, 1, 0.05, percent, false)
    slider("idleOpacity", "Out-of-combat opacity", 0, 1, 0.05, percent, false)
    description("When separate opacity is enabled, combat / idle opacity multiplies whole HUD opacity. For example, 80% with 50% gives 40%.")

    heading("Labels and health")
    cycle("healthText", "Health text", {
        { "auto", "Auto" }, { "currentmax", "Current / max" }, { "percent", "Percentage" },
        { "both", "HP + percentage" }, { "hidden", "Hidden" },
    }, false)
    checkbox("showTooltips", "Full-name / health tooltip")
    checkbox("autoHealth", "Automatic nearby health (hidden nameplates on summon, combat and drains)", function(value)
        if callbacks.onAutoHealthChanged then callbacks.onAutoHealthChanged(value) end
    end)

    heading("Minion nameplates")
    checkbox("minionPlates", "Hide my minions' nameplates (keep health tracking)")
    description("Suppresses the driver's visible minion frames, including camera and target alpha updates. Health tokens stay active during automatic health pulses.")

    heading("Tracking")
    checkbox("trackTemporary", "Track temporary summons", function(value)
        if callbacks.onTrackingChanged then callbacks.onTrackingChanged(value) end
    end)
    description("Zombies, March of the Dead, Animate: Skeletal Archer and other cooldown summons. Off by default; they are short-lived and rarely need a row.")

    heading("Life Force costs for this character")
    description("Match costs to this character's spell tooltips. Set a cost to 0 when unknown; that type will not be used for capacity estimates.")
    local costs = {
        { "lesser", "Lesser skeletal warrior" }, { "greater", "Greater skeletal warrior" },
        { "rogue", "Skeletal rogue" }, { "ghoul", "Ghoul" }, { "mage", "Skeletal mage" },
        { "abomination", "Abomination" }, { "fiend", "Crypt fiend" }, { "colossus", "Colossus" },
        { "archer", "Skeletal archer" }, { "gargoyle", "Gargoyle" }, { "banshee", "Banshee" },
    }
    for _, item in ipairs(costs) do
        local kind, label = item[1], item[2]
        slider("cost_"..kind, label, 0, 10, 1, function(v) return v == 0 and "Unknown" or integer(v) end, false, kind)
    end
    flush()
    content:SetHeight(math.max(600, -y + 20))

    function panel.RefreshValues()
        if shuttingDown() then return end
        refreshing = true
        for _, refresh in ipairs(refreshers) do refresh() end
        refreshing = false
    end
    panel.refresh = panel.RefreshValues
    panel:SetScript("OnShow", function() panel.RefreshValues() end)
    InterfaceOptions_AddCategory(panel)
    panel.RefreshValues()
    return panel
end
