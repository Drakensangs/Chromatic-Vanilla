-- Chromatic for WoW 1.12.1
-- Damage-type coloring, item rarity border coloring, and class-name coloring on tooltips.

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
local UnitName  = UnitName
local IsAddOnLoaded = IsAddOnLoaded

local origCreateFrame = CreateFrame  -- captured before our CreateFrame override

-- ============================================================
-- § 1  Damage-type colorization
-- ============================================================

local cfgBorders      = true
local cfgClassColor   = true
local cfgElementColor = true

-- Result cache for ProcessDamageLine — declared here so RefreshConfig can wipe it.
local lineResultCache     = {}
local lineResultCacheSize = 0
local LINE_CACHE_MAX      = 512

local function RefreshConfig()
    local cfg     = ChromaticConfig
    cfgBorders      = cfg.borders
    cfgClassColor   = cfg.classcolor
    cfgElementColor = cfg.elementcolor
    -- Wipe the line result cache: toggling element color changes what
    -- ProcessDamageLine returns for every previously cached input.
    lineResultCache     = {}
    lineResultCacheSize = 0
end

-- Guild Charter (5863): body may contain element keywords (Fire, Frost, etc.)
-- that must not be recolored.
local ITEM_ELEMENT_SKIP = { [5863] = true }

local DAMAGE_COLORS = {
    ["Arcane"] = "|cFFFF66FF",
    ["Fire"]   = "|cFFFF0000",
    ["Frost"]  = "|cFF00FFFF",
    ["Holy"]   = "|cFFFFFF00",
    ["Nature"] = "|cFF00FF00",
    ["Shadow"] = "|cFF9900FF",
}

local EXCEPTIONS = {
"Arcane Intellect", "Arcane Brilliance", "Arcane Explosion", "Arcane Missiles", "Arcane Instability", "Arcane Talents", "Arcane Resilience", "Arcane Shot", "Arcane Detonation", "Arcane Protection", "Arcane Crystal", "Arcane Elixir", "Arcane Powder", "Arcane Bomb", 
"Fire Talents", "Fire Ward", "Fire Shield", "Fire Blast", "Inner Fire", "Faerie Fire", "Fire Totem", "Fire Nova", "Fire Resistance Totem", "fire every", "Fire trap", "Rapid Fire", "Fire Oil", "Elemental Fire", "Essence of Fire", "Heart of Fire", "of Fire", "Fire Protection", 
"Frost Talents", "Frost Nova", "Frost Armor", "Frost Shock", "Frost Trap", "Frost trap", "frost trap", "Frost Resistance Totem", "of Frost", "Frost Protection", "Frost Oil", "Frost Tiger", 
"Shadow Talents", "Shadow Flame", "Shadow Bolt", "Shadow Word", "Shadow energy", "Shadow Trance", "Shadow Oil", "Shadow Silk", "Zandalarian Shadow", "of Shadow", "Shadow Protection", "Shadow Crescent", "Shadow Hood", "Shadow Goggles", "Flash Shadow", 
"Holy Talents", "Holy Shield", "Holy Shock", "Holy Light", "Holy Fire", "Holy Power", "Holy Candle", 
"Nature's Guard", "Nature's Grace", "of nature", "of Nature", "Nature Protection", 
}
local numExceptions = table.getn(EXCEPTIONS)

local PLACEHOLDERS = {}
for i = 1, numExceptions do
    PLACEHOLDERS[i] = "\001P" .. i .. "\001"
end

local PASS              = {}
local DTYPE_NAME        = {}
local DTYPE_NAME_LOWER  = {}
local STANDALONE_PREFIX = {}
local SPACE_PREFIX      = {}  -- " Fire", " Frost", etc. pre-built to avoid runtime concat

do
    local ORDER = { "Arcane", "Fire", "Frost", "Holy", "Nature", "Shadow" }
    for n, dt in ipairs(ORDER) do
        local color = DAMAGE_COLORS[dt]
        local dtl = strlower(dt)   -- lowercase form: "arcane", "fire", etc.
        local cr  = color .. dt  .. " Resistance|r"
        local csd = color .. dt  .. " Spell Damage|r"
        local cd  = color .. dt  .. " Damage|r"
        local cs  = color .. dt  .. "|r"
        local csl = color .. dtl .. "|r"   -- lowercase element, e.g. |cFF...|fire|r

        PASS[n] = {
            -- Resistance title case (1-8)
            "([^%a])" .. dt .. " Resistance([^%a])", "%1" .. cr  .. "%2",
            "^"       .. dt .. " Resistance([^%a])",        cr  .. "%1",
            "([^%a])" .. dt .. " Resistance$",       "%1" .. cr,
            "^"       .. dt .. " Resistance$",               cr,
            -- Spell Damage (9-16)
            "([^%a])" .. dt .. " Spell Damage([^%a])", "%1" .. csd .. "%2",
            "^"       .. dt .. " Spell Damage([^%a])",        csd .. "%1",
            "([^%a])" .. dt .. " Spell Damage$",       "%1" .. csd,
            "^"       .. dt .. " Spell Damage$",               csd,
            -- Damage title case (17-24)
            "([^%a])" .. dt .. " Damage([^%a])", "%1" .. cd .. "%2",
            "^"       .. dt .. " Damage([^%a])",        cd .. "%1",
            "([^%a])" .. dt .. " Damage$",       "%1" .. cd,
            "^"       .. dt .. " Damage$",               cd,
            -- Damage lower case (25-32): colorize element word only, leave " damage" as-is
            "([^%a])" .. dt .. " damage([^%a])", "%1" .. cs .. " damage%2",
            "^"       .. dt .. " damage([^%a])",        cs .. " damage%1",
            "([^%a])" .. dt .. " damage$",       "%1" .. cs .. " damage",
            "^"       .. dt .. " damage$",               cs .. " damage",
            -- Standalone title case (33-40)
            "([^%a])" .. dt .. "([^%a])", "%1" .. cs .. "%2",
            "^"       .. dt .. "([^%a])",        cs .. "%1",
            "([^%a])" .. dt .. "$",       "%1" .. cs,
            "^"       .. dt .. "$",               cs,
            -- Resistance lower case (41-48): colorize element word only, preserve lowercase, leave " resistance" as-is
            "([^%a])" .. dtl .. " resistance([^%a])", "%1" .. csl .. " resistance%2",
            "^"       .. dtl .. " resistance([^%a])",        csl .. " resistance%1",
            "([^%a])" .. dtl .. " resistance$",       "%1" .. csl .. " resistance",
            "^"       .. dtl .. " resistance$",               csl .. " resistance",
            -- Standalone lower case (49-56): colorize element word only, preserve lowercase
            "([^%a])" .. dtl .. "([^%a])", "%1" .. csl .. "%2",
            "^"       .. dtl .. "([^%a])",        csl .. "%1",
            "([^%a])" .. dtl .. "$",       "%1" .. csl,
            "^"       .. dtl .. "$",               csl,
        }
        DTYPE_NAME[n]        = dt
        DTYPE_NAME_LOWER[n]  = dtl
        STANDALONE_PREFIX[n] = color .. dt
        SPACE_PREFIX[n]      = " " .. dt
    end
end
local numDamageTypes = 6

DAMAGE_COLORS = nil

-- Pre-allocated reuse table: avoids per-call boolean allocation in ProcessDamageLine.
local protectedPhrases = {}
for i = 1, numExceptions do protectedPhrases[i] = false end

local function ProcessDamageLine(text)
    if not cfgElementColor then return text end

    local cached = lineResultCache[text]
    if cached ~= nil then return cached end

    -- Fast early-out: scan for any damage keyword (title-case or lower-case)
    -- before doing any real work.
    local anyFound = false
    for i = 1, numDamageTypes do
        if strfind(text, DTYPE_NAME[i], 1, true)
        or strfind(text, DTYPE_NAME_LOWER[i], 1, true) then
            anyFound = true
            break
        end
    end
    if not anyFound then
        -- Cache the no-op result so this line is skipped entirely next time.
        if lineResultCacheSize >= LINE_CACHE_MAX then
            lineResultCache     = {}
            lineResultCacheSize = 0
        end
        lineResultCache[text] = text
        lineResultCacheSize   = lineResultCacheSize + 1
        return text
    end

    local newText = text

    -- Protect exception phrases with placeholders.
    -- Track which ones were found so we only restore those.
    local anyProtected = false
    for i = 1, numExceptions do
        if strfind(newText, EXCEPTIONS[i], 1, true) then
            newText = strgsub(newText, EXCEPTIONS[i], PLACEHOLDERS[i])
            protectedPhrases[i] = true
            anyProtected = true
        else
            protectedPhrases[i] = false
        end
    end

    for i = 1, numDamageTypes do
        local hasTitle = strfind(newText, DTYPE_NAME[i], 1, true)
        if hasTitle then
            local p = PASS[i]
            newText = strgsub(newText, p[1],  p[2])
            newText = strgsub(newText, p[3],  p[4])
            newText = strgsub(newText, p[5],  p[6])
            newText = strgsub(newText, p[7],  p[8])
            newText = strgsub(newText, p[9],  p[10])
            newText = strgsub(newText, p[11], p[12])
            newText = strgsub(newText, p[13], p[14])
            newText = strgsub(newText, p[15], p[16])
            newText = strgsub(newText, p[17], p[18])
            newText = strgsub(newText, p[19], p[20])
            newText = strgsub(newText, p[21], p[22])
            newText = strgsub(newText, p[23], p[24])
            newText = strgsub(newText, p[25], p[26])
            newText = strgsub(newText, p[27], p[28])
            newText = strgsub(newText, p[29], p[30])
            newText = strgsub(newText, p[31], p[32])
            if not strfind(newText, STANDALONE_PREFIX[i], 1, true)
            or strfind(newText, SPACE_PREFIX[i], 1, true) then
                newText = strgsub(newText, p[33], p[34])
                newText = strgsub(newText, p[35], p[36])
                newText = strgsub(newText, p[37], p[38])
                newText = strgsub(newText, p[39], p[40])
            end
        end
        if strfind(newText, DTYPE_NAME_LOWER[i], 1, true) then
            local p = PASS[i]
            newText = strgsub(newText, p[41], p[42])
            newText = strgsub(newText, p[43], p[44])
            newText = strgsub(newText, p[45], p[46])
            newText = strgsub(newText, p[47], p[48])
            newText = strgsub(newText, p[49], p[50])
            newText = strgsub(newText, p[51], p[52])
            newText = strgsub(newText, p[53], p[54])
            newText = strgsub(newText, p[55], p[56])
        end
    end

    -- Restore protected phrases (only if any were found).
    if anyProtected then
        for i = 1, numExceptions do
            if protectedPhrases[i] then
                newText = strgsub(newText, PLACEHOLDERS[i], EXCEPTIONS[i])
            end
        end
    end

    -- Store result. Input text that needed no changes maps to itself.
    if lineResultCacheSize >= LINE_CACHE_MAX then
        lineResultCache     = {}
        lineResultCacheSize = 0
    end
    lineResultCache[text] = newText
    lineResultCacheSize   = lineResultCacheSize + 1

    return newText
end

-- ============================================================
-- § 2  Class-name colorization
-- ============================================================

-- Flat parallel arrays avoid inner-table pointer indirection per iteration.
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
local lineCache = {}

local function ProcessTooltipLines(tooltip, skipElement)
    if not cfgElementColor and not cfgClassColor then return end

    local numLines = tooltip:NumLines()
    if numLines == 0 then return end

    local cache = lineCache[tooltip]
    if not cache then
        local name = tooltip:GetName()
        if not name then return end
        cache = { left = {}, right = {}, max = 0, lp = name .. "TextLeft", rp = name .. "TextRight" }
        lineCache[tooltip] = cache
    end

    -- Extend the line-frame cache only when new lines have appeared.
    if numLines > cache.max then
        local lp = cache.lp
        local rp = cache.rp
        for i = cache.max + 1, numLines do
            cache.left[i]  = getglobal(lp .. i)
            cache.right[i] = getglobal(rp .. i)
        end
        cache.max = numLines
    end

    local left  = cache.left
    local right = cache.right

    -- Line 1: class coloring only (item name line never has element keywords).
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

    -- Lines 2+: element coloring and (once) class coloring.
    local classLineDone = not cfgClassColor  -- skip class scan entirely if disabled
    for i = 2, numLines do
        local lineL = left[i]
        if lineL then
            local text = lineL:GetText()
            if text then
                if strfind(text, " Mobs:", 1, true) then break end
                local newText = skipElement and text or ProcessDamageLine(text)
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
        -- Right-side lines never carry class info; element-color only.
        if not skipElement and cfgElementColor then
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
-- § 4  Rarity border coloring
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

local ITEM_ID_CAPTURE = "item:(%d+)"
local ITEM_PREFIX     = "item:"

-- Pre-built item-info query string avoids per-call concatenation on cache miss.
local ITEM_QUERY_FMT = "item:%d:0:0:0"

local qualityCache = {}

local function QualityFromLink(link)
    local _, _, idStr = strfind(link, ITEM_ID_CAPTURE)
    if not idStr then return nil end
    local idNum = tonumber(idStr)
    local cached = qualityCache[idNum]
    if cached ~= nil then return cached end
    local _, _, quality = GetItemInfo(string.format(ITEM_QUERY_FMT, idNum))
    if quality then qualityCache[idNum] = quality end
    return quality
end

-- Forward declaration: ApplyBorderColor is referenced by the retryFrame OnUpdate
-- closure below, but its body depends on SetBorderColor which follows. Declaring
-- the local here lets the closure capture the upvalue slot; the body is assigned
-- after SetBorderColor is defined.
local ApplyBorderColor

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

local pfBackdrop = {}

local function SetBorderColor(tooltip, r, g, b, a)
    tooltip:SetBackdropBorderColor(r, g, b, a)
    local bd = pfBackdrop[tooltip]
    if bd == nil then
        -- pfUI stores its visible border as a child frame at tooltip.backdrop.
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

ApplyBorderColor = function(tooltip, quality)
    local b = quality * 3
    SetBorderColor(tooltip, QC[b], QC[b+1], QC[b+2], 1)
end

local function ResetBorderColor(tooltip)
    SetBorderColor(tooltip, 1, 1, 1, 1)
end

local tooltipActiveLink   = {}
local tooltipPendingRetry = {}

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

-- rgbToQuality: reverse map from quality name-text color → quality index.
-- Used by applyFromLineColor for tooltips that have no item link (e.g. action bar items, aux listings).

local function rgbKey(r, g, b)
    return floor(r * 1000 + 0.5) * 1000000
         + floor(g * 1000 + 0.5) * 1000
         + floor(b * 1000 + 0.5)
end

local rgbToQuality = {}
if GetItemQualityColor then
    for q = 0, 6 do
        local r, g, b = GetItemQualityColor(q)
        if r then
            rgbToQuality[rgbKey(r, g, b)] = q
        end
    end
else
    for q = 0, 6 do
        local b = q * 3
        rgbToQuality[rgbKey(QC[b], QC[b+1], QC[b+2])] = q
    end
end

local function applyFromLineColor(frame, lineIndex)
    if not cfgBorders then return end
    if not tooltipActiveLink[frame] then
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

local ELEMENT_SKIP_STRINGS = {}
local ELEMENT_SKIP_COUNT   = 0
do
    for id in pairs(ITEM_ELEMENT_SKIP) do
        ELEMENT_SKIP_COUNT = ELEMENT_SKIP_COUNT + 1
        ELEMENT_SKIP_STRINGS[ELEMENT_SKIP_COUNT] = "item:" .. id .. ":"
    end
end
ITEM_ELEMENT_SKIP = nil

local function IsElementSkipLink(link)
    if not link then return false end
    for i = 1, ELEMENT_SKIP_COUNT do
        if strfind(link, ELEMENT_SKIP_STRINGS[i], 1, true) then return true end
    end
    return false
end

local hookedTooltips = {}

local function WrapSetInventoryItem(tooltip)
    if not tooltip or not tooltip.SetInventoryItem then return end
    local orig = tooltip.SetInventoryItem
    tooltip.SetInventoryItem = function(self, unit, slot)
        local hasItem, hasCooldown, repairCost = orig(self, unit, slot)
        local link = GetInventoryItemLink(unit, slot)
        tooltipActiveLink[self] = nil
        if cfgBorders then
            if hasItem then
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
        ProcessTooltipLines(self, IsElementSkipLink(link))
        return hasItem, hasCooldown, repairCost
    end
end

local function HookTooltip(tooltip)
    if not tooltip or hookedTooltips[tooltip] then return end
    if not tooltip.SetHyperlink then return end
    hookedTooltips[tooltip] = true

    local origSHL = tooltip.SetHyperlink
    tooltip.SetHyperlink = function(self, link)
        -- pcall guards against unrecognised link types (e.g. cmangos spell links).
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
        ProcessTooltipLines(self, IsElementSkipLink(link))
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
                if not UnitName("mouseover") then
                    ProcessTooltipLines(self, IsElementSkipLink(tooltipActiveLink[self]))
                end
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
            local link = GetContainerItemLink(bag, slot)
            if cfgBorders then
                if link then
                    ColorFromLink(self, link)
                else
                    local _, _, _, quality = GetContainerItemInfo(bag, slot)
                    if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
                end
            end
            tooltipDirty[self] = nil
            ProcessTooltipLines(self, IsElementSkipLink(link))
        end
    end

    if tooltip.SetLootItem then
        local orig = tooltip.SetLootItem
        tooltip.SetLootItem = function(self, index)
            orig(self, index)
            tooltipActiveLink[self] = nil
            local link = GetLootSlotLink(index)
            ColorFromLink(self, link)
            tooltipDirty[self] = nil
            ProcessTooltipLines(self, IsElementSkipLink(link))
        end
    end
end

-- ============================================================
-- § 6  GameTooltip — full Blizzard Set* hooks + single Show
-- ============================================================

local GT = GameTooltip
HookTooltip(GT)

-- Track tooltips currently showing a unit via SetUnit (party/raid frames etc.).
-- These must not have element coloring applied since pfUI/ShaguTweaks append the
-- ToT name as an extra line, which could match element keywords.
local tooltipIsUnit = {}

do
    local origSetUnit = GT.SetUnit
    if origSetUnit then
        GT.SetUnit = function(self, unit)
            tooltipIsUnit[self] = true
            origSetUnit(self, unit)
        end
    end
end

do
    local prevShow = GT.Show
    GT.Show = function(self)
        if not UnitName("mouseover") then
            tooltipDirty[self] = nil
            local skipElem = tooltipIsUnit[self] or IsElementSkipLink(tooltipActiveLink[self])
            tooltipIsUnit[self] = nil
            ProcessTooltipLines(self, skipElem)
            applyFromLineColor(self, 1)
        end
        prevShow(self)
    end
end

do
    local orig = GT.SetBagItem
    GT.SetBagItem = function(self, bag, slot)
        orig(self, bag, slot)
        local link = GetContainerItemLink(bag, slot)
        tooltipActiveLink[self] = link
        if cfgBorders then
            if link then
                ColorFromLink(self, link)
            else
                local _, _, _, quality = GetContainerItemInfo(bag, slot)
                if quality then ApplyBorderColor(self, quality) else ResetBorderColor(self) end
            end
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetMerchantItem
    GT.SetMerchantItem = function(self, index)
        orig(self, index)
        tooltipActiveLink[self] = nil
        local link = GetMerchantItemLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetLootItem
    GT.SetLootItem = function(self, index)
        orig(self, index)
        tooltipActiveLink[self] = nil
        local link = GetLootSlotLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetQuestItem
    GT.SetQuestItem = function(self, qtype, index)
        orig(self, qtype, index)
        tooltipActiveLink[self] = nil
        local link = GetQuestItemLink(qtype, index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetQuestLogItem
    GT.SetQuestLogItem = function(self, qtype, index)
        orig(self, qtype, index)
        tooltipActiveLink[self] = nil
        local link = GetQuestLogItemLink(qtype, index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetAuctionItem
    GT.SetAuctionItem = function(self, atype, index)
        orig(self, atype, index)
        tooltipActiveLink[self] = nil
        local link = GetAuctionItemLink(atype, index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
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
        ProcessTooltipLines(self, IsElementSkipLink(link))
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
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

do
    local orig = GT.SetInboxItem
    GT.SetInboxItem = function(self, mailIndex, attachIndex)
        orig(self, mailIndex, attachIndex)
        tooltipActiveLink[self] = nil
        local link = GetInboxItemLink and GetInboxItemLink(mailIndex, attachIndex)
        if link then
            ColorFromLink(self, link)
        else
            ResetBorderColor(self)
        end
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
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
        local link = GetTradePlayerItemLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
    GT.SetTradeTargetItem = function(self, index)
        origTarget(self, index)
        tooltipActiveLink[self] = nil
        local link = GetTradeTargetItemLink(index)
        ColorFromLink(self, link)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(link))
    end
end

-- Spell/action/buff hooks: ProcessTooltipLines is called directly (not via the
-- dirty flag) because these Set* methods call Show internally at the C level,
-- bypassing our Lua Show wrapper.
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

    -- SetAction: no item link available, infer quality from name text color.
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

-- CreateFrame override: hook any GameTooltip-type frame created at runtime
-- (e.g. by addon frameworks that create their own tooltip frames).
CreateFrame = function(frameType, name, parent, template)
    local frame = origCreateFrame(frameType, name, parent, template)
    if frameType == "GameTooltip" then HookTooltip(frame) end
    return frame
end

-- ============================================================
-- § C  Addon compatibility
-- ============================================================

-- ── AtlasLoot ────────────────────────────────────────────────────────────────

local function HookAtlasLoot()
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip"))
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip1"))
    HookAddonTooltipMethods(getglobal("AtlasLootTooltip2"))
end

-- ── Tmog ─────────────────────────────────────────────────────────────────────

local function HookTmog()
    HookAddonTooltipMethods(getglobal("TmogTooltip"))
    HookAddonTooltipMethods(getglobal("TmogDressupTooltip"))
end

-- ── aux / ShoppingTooltip ────────────────────────────────────────────────────
-- WrapShoppingShow is applied unconditionally in VARIABLES_LOADED to both
-- ShoppingTooltip frames.  This ensures ProcessTooltipLines fires even when no
-- Set* hook set the dirty flag (e.g. aux auction listings call Show directly).

local function WrapShoppingShow(tt)
    if not tt or not tt.Show then return end
    local origST = tt.Show
    tt.Show = function(self)
        tooltipDirty[self] = nil
        ProcessTooltipLines(self, IsElementSkipLink(tooltipActiveLink[self]))
        applyFromLineColor(self, 2)
        origST(self)
    end
end

-- ── AdvancedTradeSkillWindow2 ─────────────────────────────────────────────────

local function HookATSW()
    -- ATSWRecipeTooltip is a custom dynamic tooltip; HookAddonTooltipMethods
    -- covers SetHyperlink, SetBagItem, SetLootItem, and Show.
    HookAddonTooltipMethods(getglobal("ATSWRecipeTooltip"))

    -- ATSWRecipeItemTooltip is a standard GameTooltip used to show craft/tradeskill
    -- item details. SetTradeSkillItem and SetCraftSpell populate it; hook both so
    -- ProcessTooltipLines fires immediately after the tooltip content is set.
    local tt = getglobal("ATSWRecipeItemTooltip")
    HookAddonTooltipMethods(tt)
    if tt then
        if tt.SetTradeSkillItem then
            local orig = tt.SetTradeSkillItem
            tt.SetTradeSkillItem = function(self, index, reagent)
                orig(self, index, reagent)
                tooltipDirty[self] = nil
                ProcessTooltipLines(self)
            end
        end
        if tt.SetCraftSpell then
            local orig = tt.SetCraftSpell
            tt.SetCraftSpell = function(self, index)
                orig(self, index)
                tooltipDirty[self] = nil
                ProcessTooltipLines(self)
            end
        end
    end
end

-- ============================================================
-- § 8  VARIABLES_LOADED
-- ============================================================

do
    local varFrame = origCreateFrame("Frame")
    varFrame:RegisterEvent("VARIABLES_LOADED")
    varFrame:SetScript("OnEvent", function()
        if event ~= "VARIABLES_LOADED" then return end

        if not ChromaticConfig then ChromaticConfig = {} end
        local cfg = ChromaticConfig
        if cfg.borders      == nil then cfg.borders      = true end
        if cfg.classcolor   == nil then cfg.classcolor   = true end
        if cfg.elementcolor == nil then cfg.elementcolor = true end
        RefreshConfig()

        local st1 = getglobal("ShoppingTooltip1")
        local st2 = getglobal("ShoppingTooltip2")
        HookTooltip(st1)
        HookTooltip(st2)
        WrapSetInventoryItem(st1)
        WrapSetInventoryItem(st2)
        WrapShoppingShow(st1)
        WrapShoppingShow(st2)

        if IsAddOnLoaded("AtlasLoot")               then HookAtlasLoot() end
        if IsAddOnLoaded("Tmog")                     then HookTmog()      end
        if IsAddOnLoaded("AdvancedTradeSkillWindow2") then HookATSW()      end

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
        if strfind(name, "AtlasLoot", 1, true)          then HookAtlasLoot() end
        if name == "Tmog"                               then HookTmog()      end
        if name == "AdvancedTradeSkillWindow2"           then HookATSW()      end
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
