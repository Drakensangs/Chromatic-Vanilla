-- Chromatic for WoW 1.12.1 (requires ClassicAPI)
-- Colors item tooltip borders by rarity, class names on the Classes line,
-- and damage/resistance types in tooltips and trainer/craft descriptions.

local addonName, ns = ...

if not (CLASSIC_API_VERSION
        and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemInfoInstant
        and GameTooltip.GetItem and GameTooltip.HasItem and GameTooltip.HasUnit
        and GameTooltip.HookScript
        and GameTooltip.GetOwner and GameTooltip.GetAnchorType
        and LE_SCRIPT_BINDING_TYPE_INTRINSIC_POSTCALL
        and Item and Item.CreateFromItemID and ItemMixin and ItemMixin.ContinueWithCancelOnItemLoad
        and hooksecurefunc and wipe and strtrim and strmatch
        and Enum and Enum.ItemQuality
        and C_ClassColor and C_ClassColor.GetClassColor and FillLocalizedClassList
        and C_ColorUtil and C_ColorUtil.WrapTextInColor) then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF66FFChromatic|r: ClassicAPI is required but was not found. Chromatic is disabled.")
    do return end
end

local strfind   = string.find
local strgsub   = string.gsub
local strlower  = string.lower
local strsub    = string.sub
local strlen    = string.len
local tconcat   = table.concat
local strmatch  = strmatch
local getglobal = getglobal
local type      = type
local WrapTextInColor = C_ColorUtil.WrapTextInColor

-- Chromatic's own frames are made with this, so they skip the CreateFrame hook.
local origCreateFrame = CreateFrame

-- Tooltip hooks go on the postcall part of a script: it runs after every
-- handler, and another addon's SetScript cannot remove it.
local POSTCALL = LE_SCRIPT_BINDING_TYPE_INTRINSIC_POSTCALL

-- Tooltip methods read from the widget method table, because some addons put
-- a plain field with the same name on their tooltip (ATSW's tooltip.NumLines).
local TooltipNumLines, TooltipGetOwner, TooltipGetAnchorType, TooltipGetNumPoints, TooltipGetPoint
do
    local mt = getmetatable(GameTooltip)
    local methods = mt and mt.__index
    local function Method(name)
        if type(methods) == "table" and type(methods[name]) == "function" then
            return methods[name]
        end
        return GameTooltip[name]
    end
    TooltipNumLines      = Method("NumLines")
    TooltipGetOwner      = Method("GetOwner")
    TooltipGetAnchorType = Method("GetAnchorType")
    TooltipGetNumPoints  = Method("GetNumPoints")
    TooltipGetPoint      = Method("GetPoint")
end

-- False for hidden scanning tooltips that addons fill only to read the text
-- back (no owner, owned by WorldFrame, or ANCHOR_NONE and never positioned).
-- Those are never changed, so their text matching keeps working.
local function IsShownToPlayer(tooltip)
    local owner = TooltipGetOwner(tooltip)
    if not owner or owner == WorldFrame then return false end
    if TooltipGetAnchorType(tooltip) == "ANCHOR_NONE" then
        if TooltipGetNumPoints then
            if TooltipGetNumPoints(tooltip) == 0 then return false end
        elseif TooltipGetPoint and not TooltipGetPoint(tooltip, 1) then
            return false
        end
    end
    return true
end

-- Escape sequences are never colored over: color spans (|c...|r), links
-- (|H...|h...|h), textures (|T...|t), atlases (|A...|a) and other |x codes.
-- The ranges go into PROT_S/PROT_E; returns how many there are.
local PROT_S, PROT_E = {}, {}

local function ScanEscapes(text)
    if not strfind(text, "|", 1, true) then return 0 end
    local n, pos, len = 0, 1, strlen(text)
    while true do
        local s = strfind(text, "|", pos, true)
        if not s then break end
        local c = strsub(text, s + 1, s + 1)
        local e
        if c == "c" then
            local r = strfind(text, "|r", s + 2, true)
            e = r and r + 1 or len
        elseif c == "H" then
            local h1 = strfind(text, "|h", s + 2, true)
            local h2 = h1 and strfind(text, "|h", h1 + 2, true)
            e = h2 and h2 + 1 or len
        elseif c == "T" or c == "A" then
            local t = strfind(text, c == "T" and "|t" or "|a", s + 2, true)
            e = t and t + 1 or len
        else
            e = s + 1
        end
        n = n + 1
        PROT_S[n], PROT_E[n] = s, e
        pos = e + 1
        if pos > len then break end
    end
    return n
end

local function IsProtected(numProt, s, e)
    for k = 1, numProt do
        if s <= PROT_E[k] and e >= PROT_S[k] then return true end
    end
    return false
end

-- Settings

local DEFAULTS = {
    borders      = true,
    classcolor   = true,
    elementcolor = true,
    advanced     = false,
}

local cfgBorders, cfgClassColor, cfgElementColor = true, true, true

-- Element coloring results, cached by line text. A full cache replaces its
-- oldest entry rather than starting over.
local lineResultCache = {}
local cacheKeys       = {}
local cacheCursor     = 0
local LINE_CACHE_MAX  = 512

local function WipeLineCache()
    wipe(lineResultCache)
    wipe(cacheKeys)
    cacheCursor = 0
end

local function CacheStore(text, result)
    if lineResultCache[text] == nil then
        cacheCursor = cacheCursor + 1
        if cacheCursor > LINE_CACHE_MAX then cacheCursor = 1 end
        local old = cacheKeys[cacheCursor]
        if old ~= nil then lineResultCache[old] = nil end
        cacheKeys[cacheCursor] = text
    end
    lineResultCache[text] = result
end

local function RefreshConfig()
    local cfg = ChromaticConfig
    cfgBorders      = cfg.borders
    cfgClassColor   = cfg.classcolor
    cfgElementColor = cfg.elementcolor
    WipeLineCache()
end

-- Element coloring

local ITEM_ELEMENT_SKIP = ns.ITEM_ELEMENT_SKIP or {}
local EXCEPTIONS        = ns.EXCEPTIONS or {}

local ELEMENTS = { "Arcane", "Fire", "Frost", "Holy", "Nature", "Shadow" }
local ELEMENT_DEFAULT = {
    Arcane = { r = 1.0, g = 0.4, b = 1.0 },  -- FF66FF
    Fire   = { r = 1.0, g = 0.0, b = 0.0 },  -- FF0000
    Frost  = { r = 0.0, g = 1.0, b = 1.0 },  -- 00FFFF
    Holy   = { r = 1.0, g = 1.0, b = 0.0 },  -- FFFF00
    Nature = { r = 0.0, g = 1.0, b = 0.0 },  -- 00FF00
    Shadow = { r = 0.6, g = 0.0, b = 1.0 },  -- 9900FF
}

-- Colored text for each element word ("Fire" and "fire"). Elements switched
-- off on the Advanced panel have no entry.
local WRAP = {}

-- A title-case element followed by one of these is colored together with it
-- ("Fire Resistance"). Each entry also holds that colored phrase per element.
local SUFFIXES = { { text = " Resistance" }, { text = " Spell Damage" }, { text = " Damage" } }
for k = 1, table.getn(SUFFIXES) do SUFFIXES[k].len = strlen(SUFFIXES[k].text) end

-- Element words searched for in each line, rebuilt with the settings.
local SEARCH, numSearch = {}, 0

-- Exception phrases grouped by the element words they contain, so a line is
-- only checked against phrases that can occur in it. Phrases without an
-- element word are always checked. Indices keep the order of Exceptions.lua,
-- which decides which of two overlapping phrases wins.
local EXC_BUCKET, EXC_ALWAYS = {}, {}
for n = 1, table.getn(ELEMENTS) do
    EXC_BUCKET[ELEMENTS[n]] = {}
    EXC_BUCKET[strlower(ELEMENTS[n])] = {}
end
for i = 1, table.getn(EXCEPTIONS) do
    local phrase = EXCEPTIONS[i]
    if type(phrase) == "string" and phrase ~= "" then
        local any = false
        for word, bucket in pairs(EXC_BUCKET) do
            if strfind(phrase, word, 1, true) then
                table.insert(bucket, i)
                any = true
            end
        end
        if not any then table.insert(EXC_ALWAYS, i) end
    end
end

local candStamp, candList, stamp = {}, {}, 0
local outBuf = {}

local function QueueBucket(bucket, nc)
    local j, i = 1, bucket[1]
    while i do
        if candStamp[i] ~= stamp then
            candStamp[i] = stamp
            nc = nc + 1
            candList[nc] = i
        end
        j = j + 1
        i = bucket[j]
    end
    return nc
end

-- Marks the parts of a line that must not be colored: escape sequences, then
-- exception phrases in list order (one overlapping an earlier range is
-- skipped). Returns the range count, or nil when no element word is present.
local function FindProtected(text)
    stamp = stamp + 1
    local nc, found = 0, false
    for j = 1, numSearch do
        local word = SEARCH[j]
        if strfind(text, word, 1, true) then
            found = true
            nc = QueueBucket(EXC_BUCKET[word], nc)
        end
    end
    if not found then return nil end
    nc = QueueBucket(EXC_ALWAYS, nc)

    -- Back into list order (a line queues only a few phrases).
    for j = 2, nc do
        local v, k = candList[j], j - 1
        while k >= 1 and candList[k] > v do
            candList[k + 1] = candList[k]
            k = k - 1
        end
        candList[k + 1] = v
    end

    local np = ScanEscapes(text)
    for j = 1, nc do
        local phrase = EXCEPTIONS[candList[j]]
        local plen = strlen(phrase)
        local s = strfind(text, phrase, 1, true)
        while s do
            local e = s + plen - 1
            if not IsProtected(np, s, e) then
                np = np + 1
                PROT_S[np], PROT_E[np] = s, e
            end
            s = strfind(text, phrase, e + 1, true)
        end
    end
    return np
end

-- Colors the damage and resistance types in one line of text. Inserted color
-- codes are never searched again, so colors are never nested.
local function ProcessDamageLine(text)
    if not cfgElementColor then return text end
    local cached = lineResultCache[text]
    if cached ~= nil then return cached end

    -- Flavor text ("Keep away from fire.") is never colored.
    local np = strsub(text, 1, 1) ~= "\"" and FindProtected(text)
    if not np then
        CacheStore(text, text)
        return text
    end

    -- A word is a whole run of letters, so "Firestone" is not "Fire".
    local nout, copied, pos = 0, 1, 1
    while true do
        local s, e = strfind(text, "%a+", pos)
        if not s then break end
        local stop = e
        local word = strsub(text, s, e)
        local wrapped = WRAP[word]
        if wrapped and not IsProtected(np, s, e) then
            -- Lowercase words have no suffix entries, which ends the loop.
            local k, sfx = 1, SUFFIXES[1]
            while sfx and sfx[word] do
                local L = sfx.len
                if strsub(text, e + 1, e + L) == sfx.text then
                    if not strfind(text, "^%a", e + L + 1) and not IsProtected(np, e + 1, e + L) then
                        wrapped = sfx[word]
                        stop = e + L
                    end
                    break
                end
                k = k + 1
                sfx = SUFFIXES[k]
            end
            nout = nout + 1; outBuf[nout] = strsub(text, copied, s - 1)
            nout = nout + 1; outBuf[nout] = wrapped
            copied = stop + 1
        end
        pos = stop + 1
    end

    local newText = text
    if nout > 0 then
        nout = nout + 1; outBuf[nout] = strsub(text, copied)
        newText = tconcat(outBuf, "", 1, nout)
    end
    CacheStore(text, newText)
    return newText
end

-- Class-name coloring

-- Text of a localized format string up to its first escape ("Classes: %s"
-- gives "Classes:").
local function FormatPrefix(fmt, fallback)
    if type(fmt) ~= "string" then return fallback end
    local prefix = strmatch(fmt, "^([^|%%]+)")
    if prefix then prefix = strtrim(prefix) end
    if prefix and prefix ~= "" then return prefix end
    return fallback
end

local CLASSES_PREFIX = FormatPrefix(ITEM_CLASSES_ALLOWED, "Classes:")

-- Localized class names. Colors are read from C_ClassColor on each use, so
-- class-color addons are followed.
local CLASS_TOKENS   = {}
local CLASS_NAMES    = {}
local CLASS_PATTERNS = {}
local CLASS_REPL     = {}   -- colored replacement, rebuilt when the color changes
local CLASS_R, CLASS_G, CLASS_B = {}, {}, {}
local CLASS_ON       = {}   -- Advanced panel: class is colored
local CLASS_OVERRIDE = {}   -- Advanced panel: own color, or false
local numClasses     = 0
for token, localized in pairs(FillLocalizedClassList({})) do
    if type(localized) == "string" and localized ~= "" then
        numClasses = numClasses + 1
        CLASS_TOKENS[numClasses]   = token
        CLASS_NAMES[numClasses]    = localized
        CLASS_PATTERNS[numClasses] = strgsub(localized, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        CLASS_ON[numClasses]       = true
        CLASS_OVERRIDE[numClasses] = false
    end
end

local function ClassReplacement(i, color)
    local r, g, b = color.r, color.g, color.b
    if CLASS_REPL[i] == nil or CLASS_R[i] ~= r or CLASS_G[i] ~= g or CLASS_B[i] ~= b then
        CLASS_R[i], CLASS_G[i], CLASS_B[i] = r, g, b
        CLASS_REPL[i] = strgsub(WrapTextInColor(CLASS_NAMES[i], color), "%%", "%%%%")
    end
    return CLASS_REPL[i]
end

-- Colors class names in text that has no escape sequences.
local function ColorClassNames(text)
    local modified = false
    for i = 1, numClasses do
        if CLASS_ON[i] and strfind(text, CLASS_NAMES[i], 1, true) then
            local color = CLASS_OVERRIDE[i] or C_ClassColor.GetClassColor(CLASS_TOKENS[i])
            if color then
                text = strgsub(text, CLASS_PATTERNS[i], ClassReplacement(i, color))
                modified = true
            end
        end
    end
    return text, modified
end

-- Names already inside a color span or link are left alone, so a line is
-- never wrapped twice.
local function ProcessClassLine(text)
    local np = ScanEscapes(text)
    if np == 0 then return ColorClassNames(text) end
    local parts, nparts, pos, modified = outBuf, 0, 1, false
    for k = 1, np do
        local segment, segModified = ColorClassNames(strsub(text, pos, PROT_S[k] - 1))
        modified = modified or segModified
        nparts = nparts + 1; parts[nparts] = segment
        nparts = nparts + 1; parts[nparts] = strsub(text, PROT_S[k], PROT_E[k])
        pos = PROT_E[k] + 1
    end
    local segment, segModified = ColorClassNames(strsub(text, pos))
    modified = modified or segModified
    nparts = nparts + 1; parts[nparts] = segment
    if not modified then return text, false end
    return tconcat(parts, "", 1, nparts), true
end

-- Tooltip lines

local lineCache = {}

-- Text Chromatic last wrote to each font string, and the text it replaced.
-- A line still showing Chromatic's text is skipped; the original comes back
-- when a setting is switched off.
local lastSetText = {}
local origText    = {}

-- Lines that needed no change, skipped on the next pass over the same text.
local seenText = {}

local function SetLineText(fs, text, original)
    fs:SetText(text)
    lastSetText[fs] = text
    origText[fs]    = original
end

-- First line of a block added by another addon that must stay as it is
-- (MobInfo2). Lines from there on are skipped until the tooltip is cleared.
local foreignLinesFrom = {}

-- "Equipment Sets: <names>" holds user-chosen names, so it is never colored.
local EQUIPMENT_SETS_PREFIX     = FormatPrefix(EQUIPMENT_SETS, "Equipment Sets:")
local EQUIPMENT_SETS_PREFIX_LEN = strlen(EQUIPMENT_SETS_PREFIX)

local function ColorTooltipLines(tooltip, skipElement)
    if not cfgElementColor and not cfgClassColor then return end

    local numLines = TooltipNumLines(tooltip)
    if type(numLines) ~= "number" or numLines == 0 then return end

    local cache = lineCache[tooltip]
    if not cache then
        local name = tooltip:GetName()
        if not name then return end
        cache = { left = {}, right = {}, max = 0, lp = name .. "TextLeft", rp = name .. "TextRight" }
        lineCache[tooltip] = cache
    end

    -- Look up line font strings only once; stop at one that does not exist yet.
    if numLines > cache.max then
        local left, right, lp, rp = cache.left, cache.right, cache.lp, cache.rp
        local i = cache.max + 1
        while i <= numLines do
            local fs = getglobal(lp .. i)
            if not fs then break end
            left[i]  = fs
            right[i] = getglobal(rp .. i)
            i = i + 1
        end
        cache.max = i - 1
    end

    local left  = cache.left
    local right = cache.right
    -- Lines of a skipped item prove nothing about other items.
    local useSeen = not skipElement

    local lastLine = numLines
    if cache.max < lastLine then lastLine = cache.max end
    local fence = foreignLinesFrom[tooltip]
    if fence and fence <= lastLine then lastLine = fence - 1 end

    -- The first line (the item name) only gets class coloring.
    if cfgClassColor and lastLine >= 1 then
        local line1 = left[1]
        local text = line1:GetText()
        if text and text ~= lastSetText[line1] and strfind(text, CLASSES_PREFIX, 1, true) then
            local newText, modified = ProcessClassLine(text)
            if modified then SetLineText(line1, newText, text) end
        end
    end

    local classLineDone = not cfgClassColor
    for i = 2, lastLine do
        local lineL = left[i]
        local isSetLine = false
        local text = lineL:GetText()
        if text and text ~= lastSetText[lineL] and not (useSeen and text == seenText[lineL]) then
            isSetLine = strsub(text, 1, EQUIPMENT_SETS_PREFIX_LEN) == EQUIPMENT_SETS_PREFIX
            if not isSetLine then
                local newText = skipElement and text or ProcessDamageLine(text)
                if not classLineDone and strfind(newText, CLASSES_PREFIX, 1, true) then
                    local newText2, classModified = ProcessClassLine(newText)
                    if classModified then
                        classLineDone = true
                        SetLineText(lineL, newText2, text)
                    elseif newText ~= text then
                        SetLineText(lineL, newText, text)
                    end
                elseif newText ~= text then
                    SetLineText(lineL, newText, text)
                elseif useSeen then
                    seenText[lineL] = text
                end
            end
        end
        -- Right-hand text only gets element coloring.
        if not skipElement and not isSetLine and cfgElementColor then
            local lineR = right[i]
            if lineR then
                local textR = lineR:GetText()
                if textR and textR ~= lastSetText[lineR] and textR ~= seenText[lineR] then
                    local newText = ProcessDamageLine(textR)
                    if newText ~= textR then
                        SetLineText(lineR, newText, textR)
                    else
                        seenText[lineR] = textR
                    end
                end
            end
        end
    end
end

-- Rarity borders

-- Rarity colors from ClassicAPI's ITEM_*_COLOR, or GetItemQualityColor.
-- Stored flat as r, g, b at index quality * 3.
local ItemQuality = Enum.ItemQuality
local QUALITY_COLOR_GLOBALS = {
    [ItemQuality.Poor]      = "ITEM_POOR_COLOR",
    [ItemQuality.Common]    = "ITEM_STANDARD_COLOR",
    [ItemQuality.Uncommon]  = "ITEM_GOOD_COLOR",
    [ItemQuality.Rare]      = "ITEM_SUPERIOR_COLOR",
    [ItemQuality.Epic]      = "ITEM_EPIC_COLOR",
    [ItemQuality.Legendary] = "ITEM_LEGENDARY_COLOR",
    [ItemQuality.Artifact]  = "ITEM_ARTIFACT_COLOR",
}
local MIN_QUALITY = ItemQuality.Poor
local MAX_QUALITY = ItemQuality.Artifact

local QC         = {}   -- ITEM_*_COLOR values
local qualityRGB = {}   -- GetItemQualityColor values (can differ slightly)
for q = MIN_QUALITY, MAX_QUALITY do
    local i = q * 3
    local c = getglobal(QUALITY_COLOR_GLOBALS[q])
    local r, g, b
    if GetItemQualityColor then r, g, b = GetItemQualityColor(q) end
    if type(c) == "table" and c.r then
        QC[i], QC[i+1], QC[i+2] = c.r, c.g, c.b
    else
        QC[i], QC[i+1], QC[i+2] = r, g, b
    end
    qualityRGB[i]   = r or QC[i]
    qualityRGB[i+1] = g or QC[i+1]
    qualityRGB[i+2] = b or QC[i+2]
end

-- Border color per quality and whether it is colored at all; the Advanced
-- panel can change both. QC stays as it is for matching name-line colors.
local BORDER_RGB = {}
local BORDER_ON  = {}
for q = MIN_QUALITY, MAX_QUALITY do
    local i = q * 3
    BORDER_RGB[i], BORDER_RGB[i+1], BORDER_RGB[i+2] = QC[i], QC[i+1], QC[i+2]
    BORDER_ON[q] = true
end

-- pfUI keeps its visible border in a child frame at tooltip.backdrop. Looked
-- up each time, as a skin can add it after the tooltip was first used.
local function GetPfBackdrop(tooltip)
    local candidate = tooltip.backdrop
    if type(candidate) == "table"
    and type(candidate.SetBackdropBorderColor) == "function"
    and type(candidate.GetBackdropBorderColor) == "function" then
        return candidate
    end
    return nil
end

-- Border color from before Chromatic's first recolor, so a skin's own color
-- comes back afterwards: { r, g, b, a, pfR, pfG, pfB, pfA, pfFrame }.
local savedBorder     = {}
local borderRecolored = {}

local function SaveBorderColor(tooltip)
    local saved = savedBorder[tooltip]
    if not saved then
        saved = {}
        savedBorder[tooltip] = saved
    end
    local r, g, b, a = tooltip:GetBackdropBorderColor()
    saved[1], saved[2], saved[3], saved[4] = r or 1, g or 1, b or 1, a or 1
    local bd = GetPfBackdrop(tooltip)
    saved[9] = bd
    if bd then
        r, g, b, a = bd:GetBackdropBorderColor()
        saved[5], saved[6], saved[7], saved[8] = r or 1, g or 1, b or 1, a or 1
    end
end

local function SetBorderColor(tooltip, r, g, b, a)
    if not borderRecolored[tooltip] then
        SaveBorderColor(tooltip)
        borderRecolored[tooltip] = true
    end
    tooltip:SetBackdropBorderColor(r, g, b, a)
    local bd = GetPfBackdrop(tooltip)
    if bd then bd:SetBackdropBorderColor(r, g, b, a) end
end

-- Puts back the saved border color, if Chromatic changed it.
local function ResetBorderColor(tooltip)
    if not borderRecolored[tooltip] then return end
    borderRecolored[tooltip] = nil
    local saved = savedBorder[tooltip]
    tooltip:SetBackdropBorderColor(saved[1], saved[2], saved[3], saved[4])
    local bd = saved[9]
    if bd and bd == GetPfBackdrop(tooltip) then
        bd:SetBackdropBorderColor(saved[5], saved[6], saved[7], saved[8])
    end
end

-- True when the quality is known (colored, or switched off and left at its
-- normal color). False means the item is not loaded yet.
local function ApplyBorderColor(tooltip, quality)
    if not quality or quality < 0 then return false end
    local b = quality * 3
    if QC[b] == nil then return false end
    if not BORDER_ON[quality] then
        ResetBorderColor(tooltip)
        return true
    end
    SetBorderColor(tooltip, BORDER_RGB[b], BORDER_RGB[b+1], BORDER_RGB[b+2], 1)
    return true
end

-- Quality from the name line's color, for tooltips filled with plain text
-- (aux). Small tolerance: font strings return colors with 8-bit precision.
local QUALITY_COLOR_TOLERANCE = 0.02

local function near(a, b) return a - b <= QUALITY_COLOR_TOLERANCE and b - a <= QUALITY_COLOR_TOLERANCE end

local function QualityFromColor(r, g, b)
    for q = MIN_QUALITY, MAX_QUALITY do
        local i = q * 3
        if (qualityRGB[i] and near(r, qualityRGB[i]) and near(g, qualityRGB[i+1]) and near(b, qualityRGB[i+2]))
        or (QC[i] and near(r, QC[i]) and near(g, QC[i+1]) and near(b, QC[i+2])) then
            return q
        end
    end
end

local function ApplyFromLineColor(tooltip, lineIndex)
    local name = tooltip:GetName()
    if not name then return end
    local line = getglobal(name .. "TextLeft" .. lineIndex)
    if not line or not line:GetText() then return end
    local r, g, b = line:GetTextColor()
    if r then ApplyBorderColor(tooltip, QualityFromColor(r, g, b)) end
end

-- Tooltips waiting for an item to load: the cancel function and the item ID.
local pendingCancel = {}
local pendingItem   = {}

local function CancelPending(tooltip)
    local cancel = pendingCancel[tooltip]
    if cancel then
        pendingCancel[tooltip] = nil
        pendingItem[tooltip]   = nil
        cancel()
    end
end

-- Item ID from the last item link the tooltip was given. Covers uncached
-- items, for which GetItem returns nothing.
local lastLinkID = {}

local function CurrentItemID(tooltip)
    if tooltip:HasItem() then
        local _, _, id = tooltip:GetItem()
        if id then return id end
    end
    return lastLinkID[tooltip]
end

local function ColorFromItemID(tooltip, itemID)
    if not cfgBorders or not itemID then
        CancelPending(tooltip)
        return
    end
    if pendingCancel[tooltip] and pendingItem[tooltip] == itemID then return end
    CancelPending(tooltip)
    if ApplyBorderColor(tooltip, C_Item.GetItemQualityByID(itemID)) then return end

    -- Not loaded yet: color once it is, if the tooltip still shows the item.
    local fired, cancel = false, nil
    cancel = Item:CreateFromItemID(itemID):ContinueWithCancelOnItemLoad(function(_, success)
        fired = true
        if pendingCancel[tooltip] == cancel then
            pendingCancel[tooltip] = nil
            pendingItem[tooltip]   = nil
        end
        if success and cfgBorders and tooltip:IsVisible() and CurrentItemID(tooltip) == itemID then
            ApplyBorderColor(tooltip, C_Item.GetItemQualityByID(itemID))
        end
    end)
    -- The callback can run right away; only keep the cancel while it waits.
    if not fired then
        pendingCancel[tooltip] = cancel
        pendingItem[tooltip]   = itemID
    end
end

-- Tooltips are colored in the same call that filled them: many are refilled
-- every frame, and a later pass would always arrive too late.
-- The exception is a tooltip another addon fills and reads back while it is
-- shown (ATSW reads item stats from ATSWRecipeItemTooltip). Colored text
-- would break its reading, so it is colored on the next frame update instead.
local READ_BACK_TOOLTIPS = {
    ATSWRecipeItemTooltip = true,
}
local isReadBack = {}

local function IsReadBackTooltip(tooltip)
    local v = isReadBack[tooltip]
    if v == nil then
        local name = tooltip:GetName()
        v = (name and READ_BACK_TOOLTIPS[name]) and true or false
        isReadBack[tooltip] = v
    end
    return v
end

local colorQueue = {}  -- tooltip -> skipElement (false for none)
local colorFrame = origCreateFrame("Frame")
colorFrame:Hide()
colorFrame:SetScript("OnUpdate", function()
    this:Hide()
    for tooltip, skip in pairs(colorQueue) do
        colorQueue[tooltip] = nil
        if tooltip:IsVisible() and IsShownToPlayer(tooltip) then
            ColorTooltipLines(tooltip, skip or nil)
        end
    end
end)

local function ProcessTooltipLines(tooltip, skipElement)
    if not cfgElementColor and not cfgClassColor then return end
    if IsReadBackTooltip(tooltip) then
        colorQueue[tooltip] = skipElement or false
        colorFrame:Show()
        return
    end
    colorQueue[tooltip] = nil
    ColorTooltipLines(tooltip, skipElement)
end

-- Advanced settings
-- ChromaticConfig.advanced switches the Advanced panel's choices on. They are
-- kept in ChromaticConfig.adv while it is off:
--   adv.rarity.off[quality]  / adv.rarity.color[quality]
--   adv.class.off[token]     / adv.class.color[token]     ("WARRIOR")
--   adv.element.off[name]    / adv.element.color[name]    ("Fire")
-- off[key] = true means not colored; color[key] = { r, g, b } (0 to 1).

local ADV_KINDS = { "rarity", "class", "element" }

local function IsColorTable(c)
    if type(c) ~= "table" then return false end
    local r, g, b = c.r, c.g, c.b
    return type(r) == "number" and type(g) == "number" and type(b) == "number"
        and r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1
end

-- Fills in missing settings and drops damaged ones.
local function SanitizeConfig()
    if type(ChromaticConfig) ~= "table" then ChromaticConfig = {} end
    local cfg = ChromaticConfig
    for key, value in pairs(DEFAULTS) do
        local v = cfg[key]
        if v == nil then
            cfg[key] = value
        elseif type(v) ~= "boolean" then
            cfg[key] = (v ~= 0 and v ~= "0" and v ~= "false") and true or false
        end
    end
    if type(cfg.adv) ~= "table" then cfg.adv = {} end
    for k = 1, table.getn(ADV_KINDS) do
        local kind = ADV_KINDS[k]
        local t = cfg.adv[kind]
        if type(t) ~= "table" then
            t = {}
            cfg.adv[kind] = t
        end
        if type(t.off) ~= "table" then t.off = {} end
        if type(t.color) ~= "table" then t.color = {} end
        for key, v in pairs(t.off) do
            if v ~= true then t.off[key] = nil end
        end
        for key, c in pairs(t.color) do
            if not IsColorTable(c) then t.color[key] = nil end
        end
    end
end

-- Reads the Advanced settings into the tables used while coloring.
local function RefreshAdvanced()
    local cfg = ChromaticConfig
    local on  = cfg.advanced
    local adv = cfg.adv

    local rarity = adv.rarity
    for q = MIN_QUALITY, MAX_QUALITY do
        local i = q * 3
        local c = on and rarity.color[q]
        BORDER_ON[q] = not (on and rarity.off[q])
        if c then
            BORDER_RGB[i], BORDER_RGB[i+1], BORDER_RGB[i+2] = c.r, c.g, c.b
        else
            BORDER_RGB[i], BORDER_RGB[i+1], BORDER_RGB[i+2] = QC[i], QC[i+1], QC[i+2]
        end
    end

    local class = adv.class
    for i = 1, numClasses do
        local token = CLASS_TOKENS[i]
        CLASS_ON[i]       = not (on and class.off[token])
        CLASS_OVERRIDE[i] = (on and class.color[token]) or false
    end

    local element = adv.element
    numSearch = 0
    for n = 1, table.getn(ELEMENTS) do
        local name  = ELEMENTS[n]
        local lower = strlower(name)
        local color = (on and element.color[name]) or ELEMENT_DEFAULT[name]
        for k = 1, table.getn(SUFFIXES) do
            local sfx = SUFFIXES[k]
            sfx[name] = WrapTextInColor(name .. sfx.text, color)
        end
        if on and element.off[name] then
            WRAP[name], WRAP[lower] = nil, nil
        else
            WRAP[name]  = WrapTextInColor(name, color)
            WRAP[lower] = WrapTextInColor(lower, color)
            SEARCH[numSearch + 1] = name
            SEARCH[numSearch + 2] = lower
            numSearch = numSearch + 2
        end
    end

    WipeLineCache()
end

-- With "## LoadSavedVariablesFirst: 1" the settings are already loaded here.
-- ADDON_LOADED loads them again if the client restored them later.
local loadedConfig
local function LoadConfig()
    SanitizeConfig()
    loadedConfig = ChromaticConfig
    RefreshConfig()
    RefreshAdvanced()
end
LoadConfig()

-- Tooltip hooks

-- OnTooltipSetItem / OnTooltipSetSpell postcalls run after every other
-- addon's handler, so those addons read the text before it is colored.
local function OnSetItem()
    local tooltip = this
    if not IsShownToPlayer(tooltip) then return end
    local _, _, id = tooltip:GetItem()
    id = id or lastLinkID[tooltip]
    ColorFromItemID(tooltip, id)
    ProcessTooltipLines(tooltip, id and ITEM_ELEMENT_SKIP[id])
end

local function OnSetSpell()
    local tooltip = this
    if not IsShownToPlayer(tooltip) then return end
    ProcessTooltipLines(tooltip)
end

-- A pending item load is kept on clear: the same item may be set again, and
-- the load callback checks what the tooltip shows.
local function OnCleared()
    local tooltip = this
    colorQueue[tooltip] = nil
    lastLinkID[tooltip] = nil
    foreignLinesFrom[tooltip] = nil
    ResetBorderColor(tooltip)
end

local function OnHidden()
    local tooltip = this
    colorQueue[tooltip] = nil
    CancelPending(tooltip)
    lastLinkID[tooltip] = nil
    foreignLinesFrom[tooltip] = nil
    ResetBorderColor(tooltip)
end

-- Setters that do not fire OnTooltipSetSpell: auras, trainer, craft and pet
-- actions. AddSpellByID adds a spell below the existing lines.
local LINE_ONLY_METHODS = {
    "SetPlayerBuff", "SetUnitBuff", "SetUnitDebuff", "SetUnitAura",
    "SetTrainerService", "SetCraftSpell", "SetPetAction", "AddSpellByID",
}

local hookedTooltips = {}
-- Tooltips whose HookScript was replaced by another addon; skipped for good.
local unsupportedTooltips = {}

local function OnLineOnlySet(self)
    if IsShownToPlayer(self) then ProcessTooltipLines(self) end
end

-- Show catches lines other addons add after the Set* call, and tooltips that
-- got their owner or position after being filled. Unit tooltips are skipped:
-- skins add names to them that could contain element words.
local function OnShow(self)
    if self:HasUnit() or not IsShownToPlayer(self) then return end
    local id = CurrentItemID(self)
    if id and cfgBorders and not borderRecolored[self] and not pendingCancel[self] then
        ColorFromItemID(self, id)
    end
    ProcessTooltipLines(self, id and ITEM_ELEMENT_SKIP[id])
end

-- Remembers the item of a link and colors the border. For an uncached item
-- this starts the wait, as GetItem returns nothing until it loads.
local function OnSetHyperlink(self, link)
    if type(link) ~= "string" or not strfind(link, "item:", 1, true) then return end
    local id = C_Item.GetItemInfoInstant(link)
    lastLinkID[self] = id
    if id and cfgBorders and IsShownToPlayer(self) then
        ColorFromItemID(self, id)
    end
end

local function HookTooltip(tooltip)
    if not tooltip or hookedTooltips[tooltip] or unsupportedTooltips[tooltip] then return end
    if not tooltip.GetItem or not tooltip.HookScript then return end

    if not pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", OnSetItem, POSTCALL) then
        unsupportedTooltips[tooltip] = true
        return
    end
    hookedTooltips[tooltip] = true

    tooltip:HookScript("OnTooltipSetSpell", OnSetSpell, POSTCALL)
    tooltip:HookScript("OnTooltipCleared",  OnCleared,  POSTCALL)
    tooltip:HookScript("OnHide",            OnHidden,   POSTCALL)

    if type(tooltip.SetHyperlink) == "function" then
        hooksecurefunc(tooltip, "SetHyperlink", OnSetHyperlink)
    end

    for i = 1, table.getn(LINE_ONLY_METHODS) do
        local method = LINE_ONLY_METHODS[i]
        if type(tooltip[method]) == "function" then
            hooksecurefunc(tooltip, method, OnLineOnlySet)
        end
    end

    if type(tooltip.Show) == "function" then
        hooksecurefunc(tooltip, "Show", OnShow)
    end
    return true
end

-- Hooks every GameTooltip-type frame (Blizzard's and addons' XML tooltips).
local function HookAllTooltips()
    local f = EnumerateFrames()
    while f do
        if f.GetObjectType and f:GetObjectType() == "GameTooltip" then
            -- One that is already showing gets its first pass now.
            if HookTooltip(f) and f:IsVisible() then OnShow(f) end
        end
        f = EnumerateFrames(f)
    end
end

-- Frame walk on the next frame update; several requests share one walk.
local scanFrame = origCreateFrame("Frame")
scanFrame:Hide()
scanFrame:SetScript("OnUpdate", function()
    this:Hide()
    HookAllTooltips()
end)
local function RequestTooltipScan()
    scanFrame:Show()
end

-- Tooltips created later from Lua: named ones are hooked at once, unnamed
-- ones by the next frame walk.
hooksecurefunc("CreateFrame", function(frameType, name)
    if frameType ~= "GameTooltip"
    and (type(frameType) ~= "string" or strlower(frameType) ~= "gametooltip") then return end
    local frame = type(name) == "string" and name ~= "" and getglobal(name)
    if type(frame) == "table" and frame.GetObjectType and frame:GetObjectType() == "GameTooltip" then
        HookTooltip(frame)
    else
        RequestTooltipScan()
    end
end)

-- aux fills some item tooltips with plain text, with no item set: auction
-- listings in GameTooltip (name on line 1) and its "Currently Equipped"
-- ShoppingTooltip1/2 (name on line 2). Their border follows the name color.

local function IsOwnedByAux(tooltip)
    local auxFrame = aux_frame
    if not auxFrame then return false end
    local f = TooltipGetOwner(tooltip)
    local depth = 0
    while f and depth < 20 do
        if f == auxFrame then return true end
        f = f.GetParent and f:GetParent()
        depth = depth + 1
    end
    return false
end

local function IsPlainTooltip(tooltip)
    if tooltip:HasItem() then return false end
    if tooltip.HasUnit and tooltip:HasUnit() then return false end
    if tooltip.HasSpell and tooltip:HasSpell() then return false end
    return true
end

local plainFallback = {}  -- tooltip -> its name-color border function

local function HookPlainItemShow(tt, lineIndex, ownerCheck)
    if not tt or type(tt.Show) ~= "function" or plainFallback[tt] then return end
    local function Apply(self)
        if cfgBorders and (not ownerCheck or ownerCheck(self))
        and IsPlainTooltip(self) and IsShownToPlayer(self) then
            ApplyFromLineColor(self, lineIndex)
        end
    end
    plainFallback[tt] = Apply
    hooksecurefunc(tt, "Show", Apply)
end

-- AdvancedTradeSkillWindow2: ATSWRecipeTooltip is the bordered box with the
-- recipe's name and reagents; the item's stats sit in a borderless tooltip on
-- top. The box never has an item set, so its border is colored from the item
-- the hovered recipe creates. Recipes that create no item keep the normal border.
local atswHooked = false

local function ATSWCreatedItemID(owner)
    if type(owner) ~= "table" then return nil end
    local link = owner.Link
    if type(link) == "string" and strfind(link, "item:", 1, true) then
        local id = C_Item.GetItemInfoInstant(link)
        if id then return id end
    end
    local index = owner.Position
    if type(index) ~= "number" then return nil end
    if type(ATSW_TradeSkill) == "function" and not ATSW_TradeSkill() then return nil end
    if GetTradeSkillItemID then
        local id = GetTradeSkillItemID(index)
        if id then return id end
    end
    -- Last resort: the item ATSW just put into its stats tooltip for this row.
    local inner = getglobal("ATSWRecipeItemTooltip")
    if type(inner) == "table" and inner.GetItem and inner:IsVisible()
    and TooltipGetOwner(inner) == owner then
        local _, _, id = inner:GetItem()
        return id
    end
end

-- `this` is the hovered recipe row.
local function OnATSWShowRecipeTooltip()
    local tt = getglobal("ATSWRecipeTooltip")
    if not tt or not hookedTooltips[tt] or not tt:IsVisible() then return end
    local owner = this
    if TooltipGetOwner(tt) ~= owner then return end
    local id = ATSWCreatedItemID(owner)
    lastLinkID[tt] = id   -- read back like a link's item
    ColorFromItemID(tt, id)
end

-- ATSW reuses the box without hiding it, so start from the normal border.
local function OnATSWSetOwner(self)
    lastLinkID[self] = nil
    CancelPending(self)
    ResetBorderColor(self)
end

local function HookATSW()
    if atswHooked then return end
    local tt = getglobal("ATSWRecipeTooltip")
    if type(ATSW_ShowRecipeTooltip) ~= "function" or type(tt) ~= "table"
    or type(tt.SetOwner) ~= "function" then return end
    HookTooltip(tt)
    if not hookedTooltips[tt] then return end
    atswHooked = true
    hooksecurefunc(tt, "SetOwner", OnATSWSetOwner)
    hooksecurefunc("ATSW_ShowRecipeTooltip", OnATSWShowRecipeTooltip)
end

HookAllTooltips()

-- MobInfo2 adds mob stats, loot and "Dropped By" lines to GameTooltip. Mob and
-- item names there ("Fire Elemental") must not be colored, so the first line
-- MobInfo2 adds starts a block that is skipped until the tooltip is cleared.
-- The line's origin is read from the call stack; MobInfo2 itself is untouched.
local MOBINFO_FILE = "[Mm][Oo][Bb][Ii][Nn][Ff][Oo]2[\\/][Mm][Oo][Bb][Ii][Nn][Ff][Oo]2%.[Ll][Uu][Aa]"
local mobInfoHooked = false

local function OnGameTooltipLineAdded(self)
    -- Lines are only added at the end, so once the block starts it covers them.
    if foreignLinesFrom[self] then return end
    local stack = debugstack(2, 6, 0)
    if type(stack) == "string" and strfind(stack, MOBINFO_FILE) then
        local n = TooltipNumLines(self)
        if n and n >= 1 then foreignLinesFrom[self] = n end
    end
end

local function HookMobInfo2()
    if mobInfoHooked or type(debugstack) ~= "function" then return end
    if type(MI2_BuildItemDataTooltip) ~= "function"
    and type(MI2_BuildMobInfoTooltip) ~= "function" then return end
    mobInfoHooked = true
    hooksecurefunc(GameTooltip, "AddLine", OnGameTooltipLineAdded)
    hooksecurefunc(GameTooltip, "AddDoubleLine", OnGameTooltipLineAdded)
end

-- Character and pet resistances. Their tooltips are plain strings in
-- frame.tooltip, so those are colored right after Blizzard fills them. The
-- originals are kept for when element coloring is switched off.
local resOrig, resLast = {}, {}

local function RecolorResistanceFrames(prefix, n)
    if not cfgElementColor then return end
    for i = 1, n do
        local frame = getglobal(prefix .. i)
        if frame and type(frame.tooltip) == "string" and frame.tooltip ~= resLast[frame] then
            local text = frame.tooltip
            local newText = ProcessDamageLine(text)
            if newText ~= text then
                resOrig[frame], resLast[frame] = text, newText
                frame.tooltip = newText
            end
        end
    end
end

local function RecolorPlayerResistances()
    RecolorResistanceFrames("MagicResFrame", NUM_RESISTANCE_TYPES or 5)
end

local function RecolorPetResistances()
    RecolorResistanceFrames("PetMagicResFrame", NUM_PET_RESISTANCE_TYPES or 5)
end

local function HookResistances()
    if type(PaperDollFrame_SetResistances) == "function" then
        hooksecurefunc("PaperDollFrame_SetResistances", RecolorPlayerResistances)
    end
    if type(PetPaperDollFrame_SetResistances) == "function" then
        hooksecurefunc("PetPaperDollFrame_SetResistances", RecolorPetResistances)
    end
end

-- Trainer and craft windows (load on demand) write the selected spell's
-- description straight into a font string.
local function RecolorFontString(fs)
    if not cfgElementColor or not fs then return end
    local text = fs:GetText()
    if not text or text == lastSetText[fs] then return end
    local newText = ProcessDamageLine(text)
    if newText ~= text then SetLineText(fs, newText, text) end
end

local function RecolorTrainerDescription()
    RecolorFontString(getglobal("ClassTrainerSkillDescription"))
end

local function RecolorCraftDescription()
    RecolorFontString(getglobal("CraftDescription"))
end

local hookedTrainer, hookedCraft = false, false

local function HookSelectionDescriptions()
    if not hookedTrainer and type(ClassTrainer_SetSelection) == "function" then
        hookedTrainer = true
        hooksecurefunc("ClassTrainer_SetSelection", RecolorTrainerDescription)
    end
    if not hookedCraft and type(CraftFrame_SetSelection) == "function" then
        hookedCraft = true
        hooksecurefunc("CraftFrame_SetSelection", RecolorCraftDescription)
    end
end

-- Events
-- Tooltips are looked for when this file loads, once all addons have loaded
-- (VARIABLES_LOADED), after login, and after each later addon load.
do
    local evFrame = origCreateFrame("Frame")
    local setupDone = false
    evFrame:RegisterEvent("VARIABLES_LOADED")
    evFrame:RegisterEvent("ADDON_LOADED")
    evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    evFrame:SetScript("OnEvent", function()
        if event == "ADDON_LOADED" then
            if arg1 == addonName then
                if ChromaticConfig ~= loadedConfig then LoadConfig() end
            elseif arg1 == "Blizzard_TrainerUI" or arg1 == "Blizzard_CraftUI" then
                HookSelectionDescriptions()
            elseif arg1 == "MobInfo2" and setupDone then
                HookMobInfo2()
            elseif arg1 == "AdvancedTradeSkillWindow2" and setupDone then
                HookATSW()
            end
            if setupDone then RequestTooltipScan() end
        elseif event == "VARIABLES_LOADED" and not setupDone then
            -- Every addon's files have run, so these hooks run after theirs.
            setupDone = true
            if ChromaticConfig ~= loadedConfig then LoadConfig() end
            HookAllTooltips()
            HookPlainItemShow(GameTooltip, 1, IsOwnedByAux)
            HookPlainItemShow(getglobal("ShoppingTooltip1"), 2)
            HookPlainItemShow(getglobal("ShoppingTooltip2"), 2)
            HookATSW()
            HookResistances()
            HookSelectionDescriptions()
            HookMobInfo2()
        elseif event == "PLAYER_ENTERING_WORLD" then
            this:UnregisterEvent("PLAYER_ENTERING_WORLD")
            RequestTooltipScan()
        end
    end)
end

-- Options panel (game menu > AddOn Options > Chromatic)
-- Every change applies at once, also to tooltips already open, so Okay and
-- Cancel have nothing to do.

local OPTIONS = {
    {
        key     = "borders",
        label   = "Rarity borders",
        tooltip = "Color item tooltip borders by item rarity.",
    },
    {
        key     = "classcolor",
        label   = "Class names",
        tooltip = "Color class names on the Classes line of item tooltips.",
    },
    {
        key     = "elementcolor",
        label   = "Element types",
        tooltip = "Color damage and resistance types in item and spell tooltips, trainer and craft descriptions, and character and pet resistances.",
    },
}

-- Puts back the text Chromatic replaced wherever it still shows, then colors
-- what is on screen again with the current settings.
local function RefreshShownText()
    for fs, text in pairs(lastSetText) do
        if fs:GetText() == text then fs:SetText(origText[fs]) end
    end
    wipe(lastSetText)
    wipe(origText)
    wipe(seenText)
    for frame, text in pairs(resLast) do
        if frame.tooltip == text then frame.tooltip = resOrig[frame] end
    end
    wipe(resLast)
    wipe(resOrig)

    for tooltip in pairs(hookedTooltips) do
        if tooltip:IsVisible() and not tooltip:HasUnit() and IsShownToPlayer(tooltip) then
            local id = CurrentItemID(tooltip)
            if id and cfgBorders and not borderRecolored[tooltip] then ColorFromItemID(tooltip, id) end
            if not id and plainFallback[tooltip] then plainFallback[tooltip](tooltip) end
            ProcessTooltipLines(tooltip, id and ITEM_ELEMENT_SKIP[id])
        end
    end
    RecolorPlayerResistances()
    RecolorPetResistances()
    RecolorTrainerDescription()
    RecolorCraftDescription()
end

-- Saves the main panel's settings and applies them.
local function ApplySettings(values)
    local cfg = ChromaticConfig
    local bordersWereOn = cfg.borders
    local textChanged = false
    for i = 1, table.getn(OPTIONS) do
        local key = OPTIONS[i].key
        local v = values[key] and true or false
        if key ~= "borders" and v ~= cfg[key] then textChanged = true end
        cfg[key] = v
    end
    RefreshConfig()
    if bordersWereOn and not cfg.borders then
        for tooltip in pairs(hookedTooltips) do
            CancelPending(tooltip)
            ResetBorderColor(tooltip)
        end
    end
    if textChanged or (cfg.borders and not bordersWereOn) then RefreshShownText() end
end

-- Applies the Advanced settings to borders and text already on screen.
local function ApplyAdvanced()
    RefreshAdvanced()
    for tooltip in pairs(hookedTooltips) do
        CancelPending(tooltip)
        ResetBorderColor(tooltip)
    end
    RefreshShownText()
end

-- The Color Picker reports many changes per frame; apply once per frame.
local advApplyFrame = origCreateFrame("Frame")
advApplyFrame:Hide()
advApplyFrame:SetScript("OnUpdate", function()
    this:Hide()
    ApplyAdvanced()
end)
local function ApplyAdvancedSoon()
    advApplyFrame:Show()
end

if InterfaceOptions_AddCategory then
    local panel = origCreateFrame("Frame", "ChromaticOptionsPanel")
    panel.name = "Chromatic"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetJustifyH("LEFT")
    title:SetText("Chromatic")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Color codes rarity borders, class names and element types.")

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -24)
    header:SetJustifyH("LEFT")
    header:SetText("Options")

    local function OnCheckClick()
        if not ChromaticConfig then return end
        local checked = this:GetChecked() and true or false
        if checked then
            PlaySound("igMainMenuOptionCheckBoxOn")
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
        local values = {}
        for i = 1, table.getn(OPTIONS) do
            local key = OPTIONS[i].key
            values[key] = ChromaticConfig[key]
        end
        values[this.optionKey] = checked
        ApplySettings(values)
    end

    local function OnCheckEnter()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(this.tooltipText, nil, nil, nil, nil, 1)
    end

    local function OnCheckLeave()
        GameTooltip:Hide()
    end

    local anchor, anchorX, anchorY = header, -2, -6
    for i = 1, table.getn(OPTIONS) do
        local opt = OPTIONS[i]
        local check = origCreateFrame("CheckButton", "ChromaticOptionsCheck" .. i, panel, "OptionsCheckButtonTemplate")
        check:SetWidth(26)
        check:SetHeight(26)
        check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchorX, anchorY)
        check.optionKey   = opt.key
        check.tooltipText = opt.tooltip

        local label = getglobal(check:GetName() .. "Text")
        label:SetFontObject(GameFontHighlight)
        label:ClearAllPoints()
        label:SetPoint("LEFT", check, "RIGHT", 0, 1)
        label:SetText(opt.label)
        check:SetHitRectInsets(0, -label:GetStringWidth(), 0, 0)

        check:SetScript("OnClick", OnCheckClick)
        check:SetScript("OnEnter", OnCheckEnter)
        check:SetScript("OnLeave", OnCheckLeave)

        opt.check = check
        anchor, anchorX, anchorY = check, 0, -2
    end

    panel.refresh = function()
        if not ChromaticConfig then return end
        for i = 1, table.getn(OPTIONS) do
            local opt = OPTIONS[i]
            opt.check:SetChecked(ChromaticConfig[opt.key] and 1 or nil)
        end
    end

    panel.okay   = function() end
    panel.cancel = function() end

    panel.default = function()
        if not ChromaticConfig then return end
        ApplySettings(DEFAULTS)
        panel.refresh()
    end

    InterfaceOptions_AddCategory(panel)

    -- Built in its own function: its locals would pass Lua's limit of 200
    -- locals in the file's main function.
    local function CreateAdvancedPanel()
        -- Advanced panel, listed under Chromatic: switch single rarities,
        -- classes and elements off or give them colors of their own. With
        -- "Enable advanced options" off, the choices are kept but not used.
        -- Rows sit in three columns that follow the page width.

        local ADV_COLUMNS     = 3
        local ADV_CHECK_SIZE  = 26
        local ADV_ROW_H       = 28
        local ADV_SWATCH      = 16
        local ADV_COL_GAP     = 12   -- swatch to the next column's check
        local ADV_LABEL_GAP   = 6    -- name to its swatch
        local ADV_SECTION_GAP = 14   -- last row to the next header
        local ADV_FALLBACK_WIDTH = 395

        local QUALITY_FALLBACK_NAMES = {
            [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact",
        }

        local ADV_SECTIONS = {
            { kind = "rarity",  title = "Rarity borders", option = "borders",      items = {} },
            { kind = "class",   title = "Class names",    option = "classcolor",   items = {} },
            { kind = "element", title = "Element types",  option = "elementcolor", items = {} },
        }

        do
            local items = ADV_SECTIONS[1].items
            for q = MIN_QUALITY, MAX_QUALITY do
                local quality = q
                local i = quality * 3
                local name = getglobal("ITEM_QUALITY" .. quality .. "_DESC")
                if type(name) ~= "string" or name == "" then
                    name = QUALITY_FALLBACK_NAMES[quality] or ("Quality " .. quality)
                end
                table.insert(items, {
                    key     = quality,
                    label   = name,
                    tooltip = "Color the tooltip border of " .. name .. " items.",
                    default = function() return QC[i] or 1, QC[i+1] or 1, QC[i+2] or 1 end,
                })
            end
        end

        do
            local items = ADV_SECTIONS[2].items
            local order = {}
            for i = 1, numClasses do order[i] = i end
            table.sort(order, function(a, b) return CLASS_NAMES[a] < CLASS_NAMES[b] end)
            for k = 1, numClasses do
                local i = order[k]
                local token = CLASS_TOKENS[i]
                table.insert(items, {
                    key     = token,
                    label   = CLASS_NAMES[i],
                    tooltip = "Color " .. CLASS_NAMES[i] .. " on the Classes line of item tooltips.",
                    default = function()
                        local c = C_ClassColor.GetClassColor(token)
                        if c then return c.r, c.g, c.b end
                        return 1, 1, 1
                    end,
                })
            end
        end

        do
            local items = ADV_SECTIONS[3].items
            for n = 1, table.getn(ELEMENTS) do
                local name = ELEMENTS[n]
                local c = ELEMENT_DEFAULT[name]
                table.insert(items, {
                    key     = name,
                    label   = name,
                    tooltip = "Color " .. name .. " in item and spell tooltips, trainer and craft descriptions, and character and pet resistances.",
                    default = function() return c.r, c.g, c.b end,
                })
            end
        end

        local adv = origCreateFrame("Frame", "ChromaticAdvancedOptionsPanel")
        adv.name   = "Advanced"
        adv.parent = panel.name

        local advTitle = adv:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        advTitle:SetPoint("TOPLEFT", adv, "TOPLEFT", 16, -16)
        advTitle:SetJustifyH("LEFT")
        advTitle:SetText("Advanced")

        local advSubtitle = adv:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        advSubtitle:SetPoint("TOPLEFT", advTitle, "BOTTOMLEFT", 0, -8)
        advSubtitle:SetPoint("RIGHT", adv, "RIGHT", -16, 0)
        advSubtitle:SetJustifyH("LEFT")
        advSubtitle:SetText("Choose what Chromatic colors, and the colors it uses.")

        local function AdvStore(kind)
            return ChromaticConfig.adv[kind]
        end

        -- A row's own color, or its normal one.
        local function RowColor(row)
            local c = AdvStore(row.kind).color[row.key]
            if c then return c.r, c.g, c.b, true end
            local r, g, b = row.default()
            return r, g, b, false
        end

        local function UpdateSwatch(row)
            local r, g, b = RowColor(row)
            row.swatch.color:SetVertexColor(r, g, b)
        end

        -- Sets a row's own color; r == nil clears it.
        local function SetRowColor(row, r, g, b)
            local store = AdvStore(row.kind).color
            if r then
                local c = store[row.key]
                if type(c) ~= "table" then
                    c = {}
                    store[row.key] = c
                end
                c.r, c.g, c.b = r, g, b
            else
                store[row.key] = nil
            end
            UpdateSwatch(row)
            ApplyAdvancedSoon()
        end

        -- Color Picker: raised above the options window while open for
        -- Chromatic, and put back to its own strata when it closes.
        local STRATA_RANK = {
            BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
            FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
        }
        local pickerFunc, pickerRow, pickerSavedStrata

        local function PickerIsOurs()
            return pickerFunc ~= nil and ColorPickerFrame ~= nil
                and ColorPickerFrame:IsShown() and ColorPickerFrame.func == pickerFunc
        end

        local function ClosePicker()
            if PickerIsOurs() then ColorPickerFrame:Hide() end
            pickerRow = nil
        end

        if ColorPickerFrame and ColorPickerFrame.HookScript then
            ColorPickerFrame:HookScript("OnHide", function()
                if pickerSavedStrata then
                    ColorPickerFrame:SetFrameStrata(pickerSavedStrata)
                    pickerSavedStrata = nil
                end
            end)
        end

        local function OpenPicker(row)
            local cpf = ColorPickerFrame
            if not cpf then return end
            if cpf:IsShown() then cpf:Hide() end

            local old = AdvStore(row.kind).color[row.key]
            local oldR, oldG, oldB
            if old then oldR, oldG, oldB = old.r, old.g, old.b end
            local r, g, b = RowColor(row)

            -- Cleared first: SetColorRGB calls func, which may still belong to
            -- whoever used the picker last.
            cpf.func, cpf.cancelFunc, cpf.opacityFunc = nil, nil, nil
            cpf.hasOpacity = nil
            cpf.previousValues = { r = r, g = g, b = b }
            cpf:SetColorRGB(r, g, b)

            pickerRow = row
            pickerFunc = function()
                local nr, ng, nb = cpf:GetColorRGB()
                SetRowColor(row, nr, ng, nb)
            end
            cpf.func = pickerFunc
            cpf.cancelFunc = function()
                SetRowColor(row, oldR, oldG, oldB)   -- nil goes back to the normal color
            end

            local optionsFrame = getglobal("InterfaceOptionsFrame")
            local rank = optionsFrame and STRATA_RANK[optionsFrame:GetFrameStrata()] or STRATA_RANK.DIALOG
            if not pickerSavedStrata then pickerSavedStrata = cpf:GetFrameStrata() end
            cpf:SetFrameStrata(rank < STRATA_RANK.FULLSCREEN_DIALOG and "FULLSCREEN_DIALOG" or "TOOLTIP")
            cpf:Show()
            if cpf.Raise then cpf:Raise() end
        end

        local advMaster

        local function OnAdvTooltipLeave()
            GameTooltip:Hide()
        end

        local function OnAdvCheckEnter()
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(this.tooltipText, nil, nil, nil, nil, 1)
        end

        local function OnRowCheckClick()
            local row = this.row
            local checked = this:GetChecked() and true or false
            if checked then
                PlaySound("igMainMenuOptionCheckBoxOn")
            else
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
            AdvStore(row.kind).off[row.key] = (not checked) or nil
            ApplyAdvanced()
        end

        local function ShowSwatchTooltip(swatch)
            local row = swatch.row
            local _, _, _, custom = RowColor(row)
            GameTooltip:SetOwner(swatch, "ANCHOR_RIGHT")
            GameTooltip:SetText(row.label)
            if custom then
                GameTooltip:AddLine("Custom color.", 1, 1, 1)
            else
                GameTooltip:AddLine("Default color.", 1, 1, 1)
            end
            GameTooltip:AddLine("Click to choose a color.", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
            if custom then
                GameTooltip:AddLine("Right-click to restore the default color.", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
            end
            GameTooltip:Show()
        end

        local function OnSwatchEnter()
            this.border:SetVertexColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
            ShowSwatchTooltip(this)
        end

        local function OnSwatchLeave()
            this.border:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
            GameTooltip:Hide()
        end

        local function OnSwatchClick()
            if not ChromaticConfig or not ChromaticConfig.advanced then return end
            local row = this.row
            if arg1 == "RightButton" then
                if AdvStore(row.kind).color[row.key] then
                    if pickerRow == row then ClosePicker() end
                    PlaySound("igMainMenuOptionCheckBoxOff")
                    SetRowColor(row, nil)
                end
            else
                PlaySound("igMainMenuOptionCheckBoxOn")
                OpenPicker(row)
            end
            if TooltipGetOwner(GameTooltip) == this then ShowSwatchTooltip(this) end
        end

        local advRowCount = 0
        local function CreateRow(section, item)
            advRowCount = advRowCount + 1
            local check = origCreateFrame("CheckButton", "ChromaticAdvancedCheck" .. advRowCount, adv, "OptionsCheckButtonTemplate")
            check:SetWidth(ADV_CHECK_SIZE)
            check:SetHeight(ADV_CHECK_SIZE)
            check.tooltipText = item.tooltip

            local text = getglobal(check:GetName() .. "Text")
            text:ClearAllPoints()
            text:SetPoint("LEFT", check, "RIGHT", 0, 1)
            text:SetJustifyH("LEFT")
            text:SetText(item.label)

            -- Drawn like the stock color swatch: a light square behind the
            -- tinted ChatFrameColorSwatch texture.
            local swatch = origCreateFrame("Button", nil, adv)
            swatch:SetWidth(ADV_SWATCH)
            swatch:SetHeight(ADV_SWATCH)
            swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            local border = swatch:CreateTexture(nil, "BACKGROUND")
            border:SetWidth(ADV_SWATCH - 2)
            border:SetHeight(ADV_SWATCH - 2)
            border:SetPoint("CENTER", swatch, "CENTER", 0, 0)
            border:SetTexture(1, 1, 1)
            border:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
            local color = swatch:CreateTexture(nil, "ARTWORK")
            color:SetTexture("Interface\\ChatFrame\\ChatFrameColorSwatch")
            color:SetAllPoints(swatch)
            swatch.border = border
            swatch.color  = color

            local row = {
                kind    = section.kind,
                key     = item.key,
                label   = item.label,
                default = item.default,
                check   = check,
                text    = text,
                swatch  = swatch,
            }
            check.row  = row
            swatch.row = row

            check:SetScript("OnClick", OnRowCheckClick)
            check:SetScript("OnEnter", OnAdvCheckEnter)
            check:SetScript("OnLeave", OnAdvTooltipLeave)
            swatch:SetScript("OnClick", OnSwatchClick)
            swatch:SetScript("OnEnter", OnSwatchEnter)
            swatch:SetScript("OnLeave", OnSwatchLeave)
            return row
        end

        advMaster = origCreateFrame("CheckButton", "ChromaticAdvancedCheckEnable", adv, "OptionsCheckButtonTemplate")
        advMaster:SetWidth(26)
        advMaster:SetHeight(26)
        advMaster:SetPoint("TOPLEFT", advSubtitle, "BOTTOMLEFT", -2, -12)
        advMaster.tooltipText = "Use the choices on this page. When off, every rarity, class name and element type is colored with its default color."
        do
            local label = getglobal(advMaster:GetName() .. "Text")
            label:SetFontObject(GameFontHighlight)
            label:ClearAllPoints()
            label:SetPoint("LEFT", advMaster, "RIGHT", 0, 1)
            label:SetText("Enable advanced options")
            advMaster:SetHitRectInsets(0, -label:GetStringWidth(), 0, 0)
        end

        -- Section headers, each below the previous section's last row.
        do
            local anchor, anchorX, anchorY = advMaster, 2, -14
            for k = 1, table.getn(ADV_SECTIONS) do
                local section = ADV_SECTIONS[k]
                local header = adv:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchorX, anchorY)
                header:SetJustifyH("LEFT")
                header:SetText(section.title)
                section.header = header

                -- Shown when the feature is off on the main page.
                local note = adv:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
                note:SetPoint("LEFT", header, "RIGHT", 8, 0)
                note:SetJustifyH("LEFT")
                note:SetText("(off on the Chromatic page)")
                note:Hide()
                section.note = note

                section.rows = {}
                for j = 1, table.getn(section.items) do
                    section.rows[j] = CreateRow(section, section.items[j])
                end

                local lines = math.ceil(table.getn(section.rows) / ADV_COLUMNS)
                anchor, anchorX, anchorY = header, 0, -(4 + lines * ADV_ROW_H + ADV_SECTION_GAP)
            end
        end

        -- Page width in layout units. GetWidth is not used: for a page sized
        -- by its anchors it is multiplied by the UI scale.
        local function AdvPageWidth()
            local width
            if adv.GetUnscaledWidth then width = adv:GetUnscaledWidth() end
            if type(width) ~= "number" or width <= 0 then
                local left, right = adv:GetLeft(), adv:GetRight()
                if left and right then width = right - left end
            end
            if type(width) ~= "number" or width < 240 then width = ADV_FALLBACK_WIDTH end
            return width
        end

        -- Columns span the page up to the 16 px right margin. Each swatch sits
        -- at its column's right end; a name too long for its room gets a
        -- smaller font.
        local advLayoutWidth
        local function LayoutAdvanced()
            local width = AdvPageWidth()
            if width == advLayoutWidth then return end
            advLayoutWidth = width

            local colW    = math.floor((width - 32 + ADV_COL_GAP) / ADV_COLUMNS)
            local swatchX = colW - ADV_COL_GAP - ADV_SWATCH + 2   -- from the check's left edge
            local labelW  = swatchX - ADV_CHECK_SIZE - ADV_LABEL_GAP
            for k = 1, table.getn(ADV_SECTIONS) do
                local section = ADV_SECTIONS[k]
                for j = 1, table.getn(section.rows) do
                    local row  = section.rows[j]
                    local col  = math.mod(j - 1, ADV_COLUMNS)
                    local line = math.floor((j - 1) / ADV_COLUMNS)
                    row.check:ClearAllPoints()
                    row.check:SetPoint("TOPLEFT", section.header, "BOTTOMLEFT",
                        -2 + col * colW, -4 - line * ADV_ROW_H)
                    row.swatch:ClearAllPoints()
                    row.swatch:SetPoint("LEFT", row.check, "LEFT", swatchX, 0)

                    local text = row.text
                    text:SetFontObject(GameFontHighlight)
                    text:SetWidth(0)
                    if text:GetStringWidth() > labelW then
                        text:SetFontObject(GameFontHighlightSmall)
                    end
                    local textW = text:GetStringWidth()
                    if textW > labelW then textW = labelW end
                    text:SetWidth(labelW)
                    text:SetHeight(14)
                    row.check:SetHitRectInsets(0, -textW, 0, 0)
                end
            end
        end

        local function SetCheckEnabled(check, text, enabled)
            if enabled then
                check:Enable()
                text:SetTextColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
            else
                check:Disable()
                text:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
            end
        end

        local function UpdateAdvanced()
            local cfg = ChromaticConfig
            if not cfg then return end
            local on = cfg.advanced and true or false
            advMaster:SetChecked(on and 1 or nil)
            for k = 1, table.getn(ADV_SECTIONS) do
                local section = ADV_SECTIONS[k]
                local store = AdvStore(section.kind)
                if on then
                    section.header:SetTextColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
                else
                    section.header:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
                end
                if cfg[section.option] then section.note:Hide() else section.note:Show() end
                for j = 1, table.getn(section.rows) do
                    local row = section.rows[j]
                    row.check:SetChecked((not store.off[row.key]) and 1 or nil)
                    SetCheckEnabled(row.check, row.text, on)
                    if on then
                        row.swatch:Enable()
                        row.swatch:SetAlpha(1)
                    else
                        row.swatch:Disable()
                        row.swatch:SetAlpha(0.4)
                    end
                    UpdateSwatch(row)
                end
            end
        end

        advMaster:SetScript("OnClick", function()
            if not ChromaticConfig then return end
            local checked = this:GetChecked() and true or false
            if checked then
                PlaySound("igMainMenuOptionCheckBoxOn")
            else
                PlaySound("igMainMenuOptionCheckBoxOff")
                ClosePicker()
            end
            ChromaticConfig.advanced = checked
            ApplyAdvanced()
            UpdateAdvanced()
        end)
        advMaster:SetScript("OnEnter", OnAdvCheckEnter)
        advMaster:SetScript("OnLeave", OnAdvTooltipLeave)

        adv:SetScript("OnShow", function()
            LayoutAdvanced()
            UpdateAdvanced()
        end)
        -- The options window can size the page after showing it.
        adv:SetScript("OnSizeChanged", function()
            LayoutAdvanced()
        end)
        -- Leaving the page closes the Color Picker; the color so far is kept.
        adv:SetScript("OnHide", function()
            ClosePicker()
        end)

        adv.refresh = function()
            LayoutAdvanced()
            UpdateAdvanced()
        end

        adv.okay   = function() end
        adv.cancel = function() end

        adv.default = function()
            local cfg = ChromaticConfig
            if not cfg then return end
            ClosePicker()
            cfg.advanced = false
            for k = 1, table.getn(ADV_KINDS) do
                local t = cfg.adv[ADV_KINDS[k]]
                wipe(t.off)
                wipe(t.color)
            end
            ApplyAdvanced()
            UpdateAdvanced()
        end

        InterfaceOptions_AddCategory(adv)
    end
    CreateAdvancedPanel()
end
