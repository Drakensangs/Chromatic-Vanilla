-- Chromatic for WoW 1.12.1
-- Merged addon: damage-type coloring (Chroma), item rarity border coloring
-- (TrueColors), and class-name coloring on tooltips (ClassColoredItems).
--
-- Config (ChromaticConfig saved variable):
--   borders      — rarity-coloured tooltip borders
--   classcolor   — "Classes:" line class-name coloring
--   elementcolor — element type coloring in tooltip text
--
-- Slash commands:  /chromatic  or  /chrc
--   border   Toggle rarity tooltip borders
--   color    Toggle class name color coding
--   element  Toggle element type color coding
--   status   Show current settings

-- ============================================================
-- § 0  Localized globals & shared utilities
-- ============================================================

local GetItemInfo                  = GetItemInfo
local GetContainerItemLink         = GetContainerItemLink
local GetContainerItemInfo         = GetContainerItemInfo
local GetInventoryItemLink         = GetInventoryItemLink
local GetInventoryItemQuality      = GetInventoryItemQuality
local GetMerchantItemLink          = GetMerchantItemLink
local GetLootSlotLink              = GetLootSlotLink
local GetQuestItemLink             = GetQuestItemLink
local GetQuestLogItemLink          = GetQuestLogItemLink
local GetAuctionItemLink           = GetAuctionItemLink
local GetAuctionSellItemInfo       = GetAuctionSellItemInfo
local GetTradeSkillItemLink        = GetTradeSkillItemLink
local GetTradeSkillReagentItemLink = GetTradeSkillReagentItemLink
local GetCraftItemLink             = GetCraftItemLink
local GetCraftReagentItemLink      = GetCraftReagentItemLink
local GetInboxItemLink             = GetInboxItemLink
local GetSendMailItem              = GetSendMailItem
local GetTradePlayerItemLink       = GetTradePlayerItemLink
local GetTradeTargetItemLink       = GetTradeTargetItemLink

local strfind   = string.find
local strgsub   = string.gsub
local strlower  = string.lower
local getglobal = getglobal
local type      = type
local floor     = math.floor
local tonumber  = tonumber

local origCreateFrame = CreateFrame  -- captured before our CreateFrame override

-- ============================================================
-- § 1  Chroma — damage-type colorization
-- ============================================================

-- ChromaticConfig is a SavedVariable populated by the game before
-- VARIABLES_LOADED fires.  We must NOT initialise it here at top-level load
-- time because SavedVariables are not yet available.  The locals below start
-- as true (all features on) and are updated to the saved values inside the
-- VARIABLES_LOADED handler.
local cfgBorders      = true
local cfgClassColor   = true
local cfgElementColor = true

local function RefreshConfig()
    local cfg     = ChromaticConfig
    cfgBorders      = cfg.borders
    cfgClassColor   = cfg.classcolor
    cfgElementColor = cfg.elementcolor
end

-- Temporary at load time only; nil'd after PASS array construction.
local DAMAGE_COLORS = {
    ["Arcane"] = "|cFFFF66FF",
    ["Fire"]   = "|cFFFF0000",
    ["Frost"]  = "|cFF00FFFF",
    ["Holy"]   = "|cFFFFFF00",
    ["Nature"] = "|cFF00FF00",
    ["Shadow"] = "|cFF9900FF",
}

local EXCEPTIONS = {
    "Shadow F", "Holy F",   "Arcane M", "Holy S",   "Holy L",
    "Shadow Spr", "Shadow M", "Shadow B", "Holy T",  "Holy e",
    "d Fire",   "Arcane E", "Frost Sh", "Arcane C",  "ul Fire",
    "f Fire",   "Fire S",   "Shadow T",   "Shadow P",   "Shadow W",
    "Holy W",   "Holy P",   "m Fire",
}
local numExceptions = table.getn(EXCEPTIONS)

local PLACEHOLDERS = {}
for i = 1, numExceptions do
    PLACEHOLDERS[i] = "\001P" .. i .. "\001"
end

-- Single PASS array per damage type with all four passes interleaved.
-- Layout per entry (indices 1-40):
--   1- 8 : Resistance        patterns (4 pat/repl pairs, always title case)
--   9-16 : Spell Damage      patterns (always title case)
--  17-24 : Damage title case patterns (item stat lines: "+X Shadow Damage")
--  25-32 : Damage lower case patterns (spell descriptions: "X Shadow damage")
--  33-40 : Standalone        patterns
-- DTYPE_NAME[i]        : plain keyword for per-type presence check.
-- STANDALONE_PREFIX[i] : color+name used by the standalone already-colored guard.
local PASS              = {}
local DTYPE_NAME        = {}
local STANDALONE_PREFIX = {}

do
    local ORDER = { "Arcane", "Fire", "Frost", "Holy", "Nature", "Shadow" }
    for n, dt in ipairs(ORDER) do
        local color = DAMAGE_COLORS[dt]
        local cr  = color .. dt .. " Resistance|r"
        local csd = color .. dt .. " Spell Damage|r"
        local cd  = color .. dt .. " Damage|r"
        local cs  = color .. dt .. "|r"

        -- Item stat lines use title case: "+15 Shadow Damage", "+20 Shadow Resistance".
        -- Spell description lines use sentence case: "dealing 100 Shadow damage".
        -- For the lowercase form we colorize the element word ONLY and leave
        -- " damage" as plain text, preserving the original casing and wording.
        PASS[n] = {
            -- Resistance (1-8)  — always title case
            "([^%a])" .. dt .. " Resistance([^%a])", "%1" .. cr  .. "%2",
            "^"       .. dt .. " Resistance([^%a])",        cr  .. "%1",
            "([^%a])" .. dt .. " Resistance$",       "%1" .. cr,
            "^"       .. dt .. " Resistance$",               cr,
            -- Spell Damage (9-16) — always title case
            "([^%a])" .. dt .. " Spell Damage([^%a])", "%1" .. csd .. "%2",
            "^"       .. dt .. " Spell Damage([^%a])",        csd .. "%1",
            "([^%a])" .. dt .. " Spell Damage$",       "%1" .. csd,
            "^"       .. dt .. " Spell Damage$",               csd,
            -- Damage title case (17-24) — item stat lines: colorize full phrase
            "([^%a])" .. dt .. " Damage([^%a])", "%1" .. cd .. "%2",
            "^"       .. dt .. " Damage([^%a])",        cd .. "%1",
            "([^%a])" .. dt .. " Damage$",       "%1" .. cd,
            "^"       .. dt .. " Damage$",               cd,
            -- Damage lower case (25-32) — spell descriptions: colorize element only,
            -- leave " damage" as-is so the original text is not altered.
            "([^%a])" .. dt .. " damage([^%a])", "%1" .. cs .. " damage%2",
            "^"       .. dt .. " damage([^%a])",        cs .. " damage%1",
            "([^%a])" .. dt .. " damage$",       "%1" .. cs .. " damage",
            "^"       .. dt .. " damage$",               cs .. " damage",
            -- Standalone (33-40)
            "([^%a])" .. dt .. "([^%a])", "%1" .. cs .. "%2",
            "^"       .. dt .. "([^%a])",        cs .. "%1",
            "([^%a])" .. dt .. "$",       "%1" .. cs,
            "^"       .. dt .. "$",               cs,
        }
        DTYPE_NAME[n]        = dt
        STANDALONE_PREFIX[n] = color .. dt
    end
end
local numDamageTypes = 6

-- DAMAGE_COLORS not needed at runtime; free its memory.
DAMAGE_COLORS = nil

local protectedPhrases = {}

local function ProcessDamageLine(text)
    if not cfgElementColor then return text end

    -- Fast exit: bail if none of the six keywords appear at all.
    local anyFound = false
    for i = 1, numDamageTypes do
        if strfind(text, DTYPE_NAME[i], 1, true) then
            anyFound = true
            break
        end
    end
    if not anyFound then return text end

    local newText = text

    for i = 1, numExceptions do
        if strfind(newText, EXCEPTIONS[i], 1, true) then
            newText = strgsub(newText, EXCEPTIONS[i], PLACEHOLDERS[i])
            protectedPhrases[i] = true
        else
            protectedPhrases[i] = false
        end
    end

    for i = 1, numDamageTypes do
        if strfind(newText, DTYPE_NAME[i], 1, true) then
            local p = PASS[i]
            -- Resistance
            newText = strgsub(newText, p[1],  p[2])
            newText = strgsub(newText, p[3],  p[4])
            newText = strgsub(newText, p[5],  p[6])
            newText = strgsub(newText, p[7],  p[8])
            -- Spell Damage
            newText = strgsub(newText, p[9],  p[10])
            newText = strgsub(newText, p[11], p[12])
            newText = strgsub(newText, p[13], p[14])
            newText = strgsub(newText, p[15], p[16])
            -- Damage (title case)
            newText = strgsub(newText, p[17], p[18])
            newText = strgsub(newText, p[19], p[20])
            newText = strgsub(newText, p[21], p[22])
            newText = strgsub(newText, p[23], p[24])
            -- Damage (lower case — spell descriptions)
            newText = strgsub(newText, p[25], p[26])
            newText = strgsub(newText, p[27], p[28])
            newText = strgsub(newText, p[29], p[30])
            newText = strgsub(newText, p[31], p[32])
            -- Standalone (only if not already colored)
            if not strfind(newText, STANDALONE_PREFIX[i], 1, true) then
                newText = strgsub(newText, p[33], p[34])
                newText = strgsub(newText, p[35], p[36])
                newText = strgsub(newText, p[37], p[38])
                newText = strgsub(newText, p[39], p[40])
            end
        end
    end

    for i = 1, numExceptions do
        if protectedPhrases[i] then
            newText = strgsub(newText, PLACEHOLDERS[i], EXCEPTIONS[i])
        end
    end

    return newText
end

-- ============================================================
-- § 2  ClassColoredItems — class-name colorization
-- ============================================================

-- Two flat parallel arrays: no inner-table pointer indirection per iteration.
-- Eliminates the inner-table pointer indirection per iteration.
local CLASS_NAMES = {
    "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
    "Shaman",  "Mage",    "Warlock", "Druid",
}
local CLASS_REPLS = {
    "|cFFC79C6EWarrior|r", "|cFFF58CBAPaladin|r", "|cFFABD473Hunter|r",
    "|cFFFFF569Rogue|r",   "|cFFFFFFFFPriest|r",  "|cFF0070DEShaman|r",
    "|cFF69CCF0Mage|r",    "|cFF9482C9Warlock|r", "|cFFFF7D0ADruid|r",
}
local numClasses = 9

local function ProcessClassLine(text)
    -- Called only when cfgClassColor is true and "Classes:" is present.
    local newText  = text
    local modified = false
    for i = 1, numClasses do
        if strfind(newText, CLASS_NAMES[i], 1, true) then
            newText  = strgsub(newText, CLASS_NAMES[i], CLASS_REPLS[i])
            modified = true
        end
    end
    return newText, modified
end

-- ============================================================
-- § 3  Combined tooltip line walker + dirty-flag system
-- ============================================================

local tooltipDirty = {}

-- Line-frame cache: lineCache[tooltip] = { left={}, right={}, max=N, name="..." }
-- The tooltip name is stored here so tooltip:GetName() is only ever called
-- once per tooltip frame instead of once per ProcessTooltipLines call.
local lineCache = {}

local function ProcessTooltipLines(tooltip)
    local numLines = tooltip:NumLines()
    if numLines == 0 then return end

    -- Short-circuit: nothing to do if both text features are disabled.
    if not cfgElementColor and not cfgClassColor then return end

    local cache = lineCache[tooltip]
    if not cache then
        local name = tooltip:GetName()
        if not name then return end
        cache = { left = {}, right = {}, max = 0, name = name }
        lineCache[tooltip] = cache
    end

    if numLines > cache.max then
        local lp = cache.name .. "TextLeft"
        local rp = cache.name .. "TextRight"
        for i = cache.max + 1, numLines do
            cache.left[i]  = getglobal(lp .. i)
            cache.right[i] = getglobal(rp .. i)
        end
        cache.max = numLines
    end

    local left  = cache.left
    local right = cache.right

    -- Line 1: class coloring only (never damage-color item/spell names).
    if cfgClassColor then
        local line1 = left[1]
        if line1 then
            local text = line1:GetText()
            if text and strfind(text, "Classes:", 1, true) then
                local newText, modified = ProcessClassLine(text)
                if modified then line1:SetText(newText) end
            end
        end
    end

    -- Lines 2+: two code paths so the per-line classLineDone branch is
    -- completely absent when class coloring is off.
    if cfgClassColor then
        local classLineDone = false
        for i = 2, numLines do
            local lineL = left[i]
            if lineL then
                local text = lineL:GetText()
                if text then
                    local newText = ProcessDamageLine(text)
                    if not classLineDone and strfind(newText, "Classes:", 1, true) then
                        local newText2, classModified = ProcessClassLine(newText)
                        if classModified then
                            classLineDone = true
                            lineL:SetText(newText2)
                        elseif newText ~= text then
                            lineL:SetText(newText)
                        end
                    elseif newText ~= text then
                        lineL:SetText(newText)
                    end
                end
            end
            local lineR = right[i]
            if lineR then
                local text = lineR:GetText()
                if text then
                    local newText = ProcessDamageLine(text)
                    if newText ~= text then lineR:SetText(newText) end
                end
            end
        end
    else
        -- Class coloring off: tighter loop, no class-line tracking overhead.
        for i = 2, numLines do
            local lineL = left[i]
            if lineL then
                local text = lineL:GetText()
                if text then
                    local newText = ProcessDamageLine(text)
                    if newText ~= text then lineL:SetText(newText) end
                end
            end
            local lineR = right[i]
            if lineR then
                local text = lineR:GetText()
                if text then
                    local newText = ProcessDamageLine(text)
                    if newText ~= text then lineR:SetText(newText) end
                end
            end
        end
    end
end

-- ============================================================
-- § 4  TrueColors — rarity border coloring
-- ============================================================

local QC = {
    [0]=0.62, 0.62, 0.62,  -- 0 Poor
         1.00, 1.00, 1.00,  -- 1 Common
         0.12, 1.00, 0.00,  -- 2 Uncommon
         0.00, 0.44, 0.87,  -- 3 Rare
         0.64, 0.21, 0.93,  -- 4 Epic
         1.00, 0.50, 0.00,  -- 5 Legendary
         0.90, 0.80, 0.50,  -- 6 Artifact
}

-- Single pattern captures the numeric item ID from both bare "item:N:..."
-- strings and full "|Hitem:N:...|h..." hyperlinks in one strfind call.
local ITEM_ID_CAPTURE = "item:(%d+)"
local ITEM_PREFIX     = "item:"

local qualityCache = {}

local function QualityFromLink(link)
    local _, _, idStr = strfind(link, ITEM_ID_CAPTURE)
    if not idStr then return nil end
    local idNum = tonumber(idStr)
    local cached = qualityCache[idNum]
    if cached ~= nil then return cached end
    local _, _, quality = GetItemInfo("item:" .. idNum .. ":0:0:0")
    if quality then qualityCache[idNum] = quality end
    return quality
end

local RETRY_TIMEOUT = 5
local queue  = {}
local qHead  = 1
local qTail  = 0

local retryFrame = origCreateFrame("Frame")
retryFrame:Hide()
retryFrame:SetScript("OnUpdate", function()
    local dt      = arg1
    local i       = qHead
    local anyLeft = false
    while i <= qTail do
        local slot = queue[i]
        if slot then
            slot.elapsed = slot.elapsed + dt
            local quality = QualityFromLink(slot.link)
            if quality then
                if slot.tooltip and slot.tooltip:IsVisible() then
                    ApplyBorderColor(slot.tooltip, quality)
                end
                queue[i] = nil
            elseif slot.elapsed >= RETRY_TIMEOUT then
                queue[i] = nil
            else
                anyLeft = true
            end
        end
        i = i + 1
    end
    if not anyLeft then
        qHead = 1
        qTail = 0
        retryFrame:Hide()
    else
        while qHead <= qTail and not queue[qHead] do
            qHead = qHead + 1
        end
    end
end)

local function EnqueueRetry(tooltip, link)
    qTail = qTail + 1
    local slot = queue[qTail]
    if slot then
        slot.tooltip = tooltip
        slot.link    = link
        slot.elapsed = 0
    else
        queue[qTail] = { tooltip = tooltip, link = link, elapsed = 0 }
    end
    retryFrame:Show()
end

local function CancelRetryForTooltip(tooltip)
    for i = qHead, qTail do
        local slot = queue[i]
        if slot and slot.tooltip == tooltip then
            slot.tooltip = nil
            slot.elapsed = RETRY_TIMEOUT
        end
    end
end

-- pfUI compatibility: pfUI replaces the visible tooltip border with a child
-- frame stored at tooltip.backdrop.  When that child frame exists we must call
-- SetBackdropBorderColor on it instead of (or in addition to) the parent
-- tooltip frame, because pfUI hides the original Blizzard border textures and
-- only the child frame's border is actually visible.
--
-- pfBackdrop[tooltip] caches the result of the backdrop probe so we pay the
-- type() cost only once per tooltip frame rather than on every border update.
-- nil  = not yet probed
-- false = probed, no pfUI backdrop present
-- <frame> = the backdrop child frame to also color
local pfBackdrop = {}

local function SetBorderColor(tooltip, r, g, b, a)
    tooltip:SetBackdropBorderColor(r, g, b, a)
    local bd = pfBackdrop[tooltip]
    if bd == nil then
        -- First call for this tooltip: probe once and cache the result.
        local candidate = tooltip.backdrop
        if candidate and type(candidate) == "table"
        and type(candidate.SetBackdropBorderColor) == "function" then
            pfBackdrop[tooltip] = candidate
            bd = candidate
        else
            pfBackdrop[tooltip] = false
        end
    end
    if bd then bd:SetBackdropBorderColor(r, g, b, a) end
end

local function ApplyBorderColor(tooltip, quality)
    local b = quality * 3
    SetBorderColor(tooltip, QC[b], QC[b+1], QC[b+2], 1)
end

local function ResetBorderColor(tooltip)
    SetBorderColor(tooltip, 1, 1, 1, 1)
end

local tooltipActiveLink   = {}
local tooltipPendingRetry = {}  -- set when EnqueueRetry was called, cleared on resolution

local function ColorFromLink(tooltip, link)
    if not cfgBorders then
        tooltipPendingRetry[tooltip] = nil
        return
    end
    if not link then
        ResetBorderColor(tooltip)
        tooltipPendingRetry[tooltip] = nil
        return
    end
    local quality = QualityFromLink(link)
    if quality then
        ApplyBorderColor(tooltip, quality)
        tooltipPendingRetry[tooltip] = nil
    else
        EnqueueRetry(tooltip, link)
        tooltipPendingRetry[tooltip] = true
    end
end

-- ── aux auction listing compatibility ────────────────────────────────────────

local function rgbKey(r, g, b)
    return floor(r * 100 + 0.5) * 10000
         + floor(g * 100 + 0.5) * 100
         + floor(b * 100 + 0.5)
end

local rgbToQuality = {}
-- Build the reverse map from the engine's own quality colors via
-- GetItemQualityColor(), which returns the exact same float values that the
-- engine uses to color item name text.  Using QC here would be wrong because
-- QC holds the border colors we choose, which are only approximately equal to
-- the item name colors.  Any mismatch causes rgbToQuality lookups to miss.
if GetItemQualityColor then
    for q = 0, 6 do
        local r, g, b = GetItemQualityColor(q)
        if r then
            rgbToQuality[rgbKey(r, g, b)] = q
        end
    end
else
    -- Fallback: seed from QC (same as before) if the API is somehow absent.
    for q = 0, 6 do
        local b = q * 3
        rgbToQuality[rgbKey(QC[b], QC[b+1], QC[b+2])] = q
    end
end

-- Use lineCache frame refs; falls back to getglobal only before cache is built.
local function applyFromLineColor(frame, lineIndex)
    if not cfgBorders then return end
    if not tooltipActiveLink[frame] then
        -- Use cached frame reference when available; fall back to getglobal
        -- only if cache hasn't been built yet (e.g. Show fires before any Set*).
        local lineFrame
        local cache = lineCache[frame]
        if cache and cache.left[lineIndex] then
            lineFrame = cache.left[lineIndex]
        else
            lineFrame = getglobal(frame:GetName() .. "TextLeft" .. lineIndex)
        end
        if lineFrame then
            local r, g, b = lineFrame:GetTextColor()
            if r then
                local quality = rgbToQuality[rgbKey(r, g, b)]
                if quality ~= nil then ApplyBorderColor(frame, quality) end
            end
        end
    end
end

-- ============================================================
-- § 5  Tooltip hooking — combined
-- ============================================================

local hookedTooltips = {}

local function WrapSetInventoryItem(tooltip)
    if not tooltip or not tooltip.SetInventoryItem then return end
    local orig = tooltip.SetInventoryItem
    tooltip.SetInventoryItem = function(self, unit, slot)
        local hasItem, hasCooldown, repairCost = orig(self, unit, slot)
        tooltipActiveLink[self] = nil
        if cfgBorders then
            if hasItem then
                local link = GetInventoryItemLink(unit, slot)
                if link then
                    ColorFromLink(self, link)
                else
                    local quality = GetInventoryItemQuality(unit, slot)
                    if quality then ApplyBorderColor(self, quality) end
                end
            else
                ResetBorderColor(self)
            end
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
        return hasItem, hasCooldown, repairCost
    end
end

local function HookTooltip(tooltip)
    if not tooltip or hookedTooltips[tooltip] then return end
    if not tooltip.SetHyperlink then return end
    hookedTooltips[tooltip] = true

    local origSHL = tooltip.SetHyperlink
    tooltip.SetHyperlink = function(self, link)
        -- Use pcall so server-generated link types the client doesn't recognise
        -- (e.g. spell links from cmangos .lookup spell) don't surface as Lua
        -- errors.  If the client rejects the link we still bail cleanly.
        local ok = pcall(origSHL, self, link)
        if not ok then return end
        if link and strfind(link, ITEM_PREFIX, 1, true) then
            tooltipActiveLink[self] = link
            ColorFromLink(self, link)
        else
            tooltipActiveLink[self] = nil
            if cfgBorders then ResetBorderColor(self) end
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end

    local origShow = tooltip.Show
    if origShow then
        tooltip.Show = function(self)
            origShow(self)
            if cfgBorders and tooltipPendingRetry[self] then
                local link = tooltipActiveLink[self]
                if link then
                    local quality = QualityFromLink(link)
                    if quality then
                        ApplyBorderColor(self, quality)
                        tooltipPendingRetry[self] = nil
                    end
                end
            end
            if tooltipDirty[self] then
                tooltipDirty[self] = nil
                ProcessTooltipLines(self)
            end
        end
    end

    WrapSetInventoryItem(tooltip)

    local origHide = tooltip:GetScript("OnHide")
    tooltip:SetScript("OnHide", function()
        CancelRetryForTooltip(this)
        tooltipActiveLink[this]   = nil
        tooltipDirty[this]        = nil
        tooltipPendingRetry[this] = nil
        if cfgBorders then ResetBorderColor(this) end
        if origHide then origHide() end
    end)
end

local function HookAddonTooltipMethods(tooltip)
    if not tooltip then return end
    HookTooltip(tooltip)

    if tooltip.SetBagItem then
        local orig = tooltip.SetBagItem
        tooltip.SetBagItem = function(self, bag, slot)
            orig(self, bag, slot)
            tooltipActiveLink[self] = nil
            if cfgBorders then
                local link = GetContainerItemLink(bag, slot)
                if link then
                    ColorFromLink(self, link)
                else
                    local _, _, _, quality = GetContainerItemInfo(bag, slot)
                    if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
                end
            end
            tooltipDirty[self] = nil
        ProcessTooltipLines(self)
        end
    end

    if tooltip.SetLootItem then
        local orig = tooltip.SetLootItem
        tooltip.SetLootItem = function(self, index)
            orig(self, index)
            tooltipActiveLink[self] = nil
            ColorFromLink(self, GetLootSlotLink(index))
            tooltipDirty[self] = nil
        ProcessTooltipLines(self)
        end
    end
end

-- ============================================================
-- § 6  GameTooltip — full Blizzard Set* hooks + single Show
-- ============================================================

local GT = GameTooltip
HookTooltip(GT)

do
    local prevShow = GT.Show
    GT.Show = function(self)
        -- Process lines BEFORE showing, exactly as the original Chroma addon did.
        -- This covers tooltips built via AddLine/AddDoubleLine (e.g. aux auction
        -- listings) where no Set* hook fires and tooltipDirty is never set.
        -- The dirty flag is cleared first so the inner Show wrapper's FlushDirty
        -- check does not redundantly re-process lines that we just handled.
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
        applyFromLineColor(self, 1)
        prevShow(self)
    end
end

do
    local orig = GT.SetBagItem
    GT.SetBagItem = function(self, bag, slot)
        orig(self, bag, slot)
        tooltipActiveLink[self] = nil
        if cfgBorders then
            local link = GetContainerItemLink(bag, slot)
            if link then
                ColorFromLink(self, link)
            else
                local _, _, _, quality = GetContainerItemInfo(bag, slot)
                if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
            end
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetMerchantItem
    GT.SetMerchantItem = function(self, index)
        orig(self, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetMerchantItemLink(index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetLootItem
    GT.SetLootItem = function(self, index)
        orig(self, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetLootSlotLink(index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetQuestItem
    GT.SetQuestItem = function(self, qtype, index)
        orig(self, qtype, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetQuestItemLink(qtype, index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetQuestLogItem
    GT.SetQuestLogItem = function(self, qtype, index)
        orig(self, qtype, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetQuestLogItemLink(qtype, index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetAuctionItem
    GT.SetAuctionItem = function(self, atype, index)
        orig(self, atype, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetAuctionItemLink(atype, index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetAuctionSellItem
    GT.SetAuctionSellItem = function(self)
        orig(self)
        tooltipActiveLink[self] = nil
        if cfgBorders then
            local _, _, _, quality = GetAuctionSellItemInfo()
            if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetTradeSkillItem
    GT.SetTradeSkillItem = function(self, index, reagentIndex)
        orig(self, index, reagentIndex)
        tooltipActiveLink[self] = nil
        local link = reagentIndex
            and GetTradeSkillReagentItemLink(index, reagentIndex)
             or GetTradeSkillItemLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetCraftItem
    GT.SetCraftItem = function(self, index, reagentIndex)
        orig(self, index, reagentIndex)
        tooltipActiveLink[self] = nil
        local link = reagentIndex
            and GetCraftReagentItemLink(index, reagentIndex)
             or GetCraftItemLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetInboxItem
    GT.SetInboxItem = function(self, mailIndex, attachIndex)
        orig(self, mailIndex, attachIndex)
        tooltipActiveLink[self] = nil
        if GetInboxItemLink then
            ColorFromLink(self, GetInboxItemLink(mailIndex, attachIndex))
        else
            ResetBorderColor(self)
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

do
    local orig = GT.SetSendMailItem
    if orig then
        GT.SetSendMailItem = function(self)
            orig(self)
            tooltipActiveLink[self] = nil
            if cfgBorders then
                local _, _, _, quality = GetSendMailItem()
                if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
            end
            tooltipDirty[self] = nil
        ProcessTooltipLines(self)
        end
    end
end

do
    local origPlayer = GT.SetTradePlayerItem
    local origTarget = GT.SetTradeTargetItem
    GT.SetTradePlayerItem = function(self, index)
        origPlayer(self, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetTradePlayerItemLink(index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
    GT.SetTradeTargetItem = function(self, index)
        origTarget(self, index)
        tooltipActiveLink[self] = nil
        ColorFromLink(self, GetTradeTargetItemLink(index))
        tooltipDirty[self] = nil
        ProcessTooltipLines(self)
    end
end

-- Spell / action / buff hooks (line processing only, no border color).
-- These call ProcessTooltipLines DIRECTLY after orig(), not via the dirty flag.
--
-- Why: In 1.12.1, the C implementation of SetSpell, SetAction, SetPlayerBuff
-- etc. calls GameTooltip:Show() internally at the C level, which bypasses our
-- Lua Show wrapper entirely.  The dirty-flag system relies on our Lua Show
-- wrapper to flush the flag, so it never fires for these methods.  The UI also
-- does not call Show() explicitly from Lua after these Set* calls (unlike item
-- tooltips where OnEnter explicitly calls Show), so the flag would sit
-- unconsumed forever.
--
-- The original Chroma addon solved this by calling ColorizeDamageTypes()
-- synchronously after every hooked method, with no deferred flush.  We do the
-- same here: after orig() returns the lines are populated and readable, so we
-- process them immediately.  The dirty flag is explicitly cleared so a
-- redundant Show (if one does fire) does not re-process.
do
    local function HookLineOnly(tooltip, methodName)
        local orig = tooltip[methodName]
        if not orig then return end
        tooltip[methodName] = function(self, a, b, c, d)
            orig(self, a, b, c, d)
            tooltipDirty[self] = nil
            ProcessTooltipLines(self)
        end
    end

    HookLineOnly(GT, "SetSpell")

    -- SetAction needs border coloring too: action bar item tooltips have no item
    -- link available, so we infer quality from the name text color on line 1
    -- (the same fallback applyFromLineColor uses).  We must clear tooltipActiveLink
    -- first so applyFromLineColor's guard doesn't skip the lookup.
    do
        local origSetAction = GT.SetAction
        if origSetAction then
            GT.SetAction = function(self, slot)
                origSetAction(self, slot)
                tooltipDirty[self] = nil
                tooltipActiveLink[self] = nil
                ProcessTooltipLines(self)
                applyFromLineColor(self, 1)
            end
        end
    end
    HookLineOnly(GT, "SetTrainerService")
    HookLineOnly(GT, "SetTalent")
    HookLineOnly(GT, "SetCraftSpell")
    HookLineOnly(GT, "SetPlayerBuff")
    HookLineOnly(GT, "SetUnitBuff")
    HookLineOnly(GT, "SetUnitDebuff")
    HookLineOnly(GT, "SetShapeshift")
    HookLineOnly(GT, "SetPetAction")

    HookLineOnly(ItemRefTooltip, "SetHyperlink")
end

do
    local origAnchor = GameTooltip_SetDefaultAnchor
    if origAnchor then
        GameTooltip_SetDefaultAnchor = function(tooltip, parent)
            if cfgBorders then ResetBorderColor(tooltip) end
            origAnchor(tooltip, parent)
        end
    end
end

-- ============================================================
-- § 7  Dynamic tooltip detection
-- ============================================================

local KNOWN_ADDON_TOOLTIPS = {
    "AtlasLootTooltip", "AtlasLootTooltip1", "AtlasLootTooltip2",
    "TmogTooltip", "TmogDressupTooltip",
    "ShoppingTooltip1", "ShoppingTooltip2",
    "ItemRefTooltip",
    "GameTooltip",
}

local function ScanForTooltips()
    for _, name in ipairs(KNOWN_ADDON_TOOLTIPS) do
        local obj = getglobal(name)
        if obj
        and type(obj) == "table"
        and type(obj.SetHyperlink)           == "function"
        and type(obj.SetBackdropBorderColor) == "function" then
            HookTooltip(obj)
        end
    end
end

CreateFrame = function(frameType, name, parent, template)
    local frame = origCreateFrame(frameType, name, parent, template)
    if frameType == "GameTooltip" then HookTooltip(frame) end
    return frame
end

local function HookAtlasLoot()
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip"))
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip1"))
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip2"))
end

local function HookTmog()
    HookAddonTooltipMethods(getglobal("TmogTooltip"))
    HookAddonTooltipMethods(getglobal("TmogDressupTooltip"))
end

HookAtlasLoot()
HookTmog()

-- ============================================================
-- § 8  VARIABLES_LOADED + aux ShoppingTooltip hooks
-- ============================================================

do
    local varFrame = origCreateFrame("Frame")
    varFrame:RegisterEvent("VARIABLES_LOADED")
    varFrame:SetScript("OnEvent", function()
        if event ~= "VARIABLES_LOADED" then return end

        -- SavedVariables are now available.  Ensure ChromaticConfig exists and
        -- fill in any keys that are missing (e.g. first login, or new keys added
        -- in an update).  Existing saved values are preserved as-is.
        if not ChromaticConfig then
            ChromaticConfig = {}
        end
        local cfg = ChromaticConfig
        if cfg.borders      == nil then cfg.borders      = true end
        if cfg.classcolor   == nil then cfg.classcolor   = true end
        if cfg.elementcolor == nil then cfg.elementcolor = true end
        RefreshConfig()

        ScanForTooltips()
        WrapSetInventoryItem(getglobal("ShoppingTooltip1"))
        WrapSetInventoryItem(getglobal("ShoppingTooltip2"))

        do
            local function WrapShoppingShow(tt)
                if tt and tt.Show then
                    local origST = tt.Show
                    tt.Show = function(self)
                        -- Process lines before showing (no dirty-flag guard) so
                        -- text coloring fires even when no Set* hook set the flag
                        -- (e.g. SetMerchantItem on the compare tooltip).  Clear
                        -- the flag first so the inner HookTooltip Show wrapper
                        -- does not redundantly re-process the same lines.
                        tooltipDirty[self] = nil
                        ProcessTooltipLines(self)
                        applyFromLineColor(self, 2)
                        origST(self)
                    end
                end
            end
            WrapShoppingShow(getglobal("ShoppingTooltip1"))
            WrapShoppingShow(getglobal("ShoppingTooltip2"))
        end

        varFrame:UnregisterEvent("VARIABLES_LOADED")
    end)
end

-- ============================================================
-- § 9  ADDON_LOADED event
-- ============================================================

do
    local addonFrame = origCreateFrame("Frame")
    addonFrame:RegisterEvent("ADDON_LOADED")
    addonFrame:SetScript("OnEvent", function()
        if event ~= "ADDON_LOADED" then return end
        local name = arg1
        if strfind(name, "AtlasLoot", 1, true) then HookAtlasLoot() end
        if name == "Tmog" then HookTmog() end
    end)
end

-- ============================================================
-- § 10  Slash commands
-- ============================================================

local MSG_ENABLED  = "|cFF00FF00enabled|r"
local MSG_DISABLED = "|cFFFF0000disabled|r"

local function SlashHandler(msg)
    local cmd = strlower(msg or "")
    local cfg = ChromaticConfig

    if cmd == "class" then
        cfg.classcolor = not cfg.classcolor
        RefreshConfig()
        DEFAULT_CHAT_FRAME:AddMessage("Chromatic: Class color coding " .. (cfg.classcolor and MSG_ENABLED or MSG_DISABLED))
    elseif cmd == "border" then
        cfg.borders = not cfg.borders
        RefreshConfig()
        DEFAULT_CHAT_FRAME:AddMessage("Chromatic: Tooltip borders " .. (cfg.borders and MSG_ENABLED or MSG_DISABLED))
    elseif cmd == "element" then
        cfg.elementcolor = not cfg.elementcolor
        RefreshConfig()
        DEFAULT_CHAT_FRAME:AddMessage("Chromatic: Element color coding " .. (cfg.elementcolor and MSG_ENABLED or MSG_DISABLED))
    elseif cmd == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("Chromatic status:")
        DEFAULT_CHAT_FRAME:AddMessage("Class: " .. (cfg.classcolor   and MSG_ENABLED or MSG_DISABLED))
        DEFAULT_CHAT_FRAME:AddMessage("Border: " .. (cfg.borders      and MSG_ENABLED or MSG_DISABLED))
        DEFAULT_CHAT_FRAME:AddMessage("Element: " .. (cfg.elementcolor and MSG_ENABLED or MSG_DISABLED))
    else
        DEFAULT_CHAT_FRAME:AddMessage("Chromatic commands:")
        DEFAULT_CHAT_FRAME:AddMessage("/chromatic class - Toggle class name color coding")
        DEFAULT_CHAT_FRAME:AddMessage("/chromatic border - Toggle tooltip rarity borders")
        DEFAULT_CHAT_FRAME:AddMessage("/chromatic element - Toggle element type color coding")
        DEFAULT_CHAT_FRAME:AddMessage("/chromatic status - Show current settings")
    end
end

SLASH_CHROMATIC1 = "/chromatic"
SLASH_CHROMATIC2 = "/chrc"
SlashCmdList["CHROMATIC"] = SlashHandler