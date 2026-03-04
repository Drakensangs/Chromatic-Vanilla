# 🎨 **Chromatic** (Vanilla 1.12.1)

A lightweight addon that color codes elemental damage/resistances in item & spell tooltips, color codes item tooltip borders based on rarity, and class names in item tooltips.

# ✨ **Features**

**Item tooltip class name colors.** Class restriction lines (for example `Class: Warrior`) on item tooltips have each class name colored in its official class color.

**Item tooltip rarity borders.** Borders are colored based on the item's rarity.

**Color coded damage/resistance type.** Tooltip lines containing damage/resistance types are colored automatically. Fire, Frost, Arcane, Holy, Nature, and Shadow each get color coded.

# ⚙️ **Slash Commands**

Type  `/chromatic` or `/chrc` and one of these commands:

`class`   - toggle item tooltip class name color coding

`border`  - toggle color coded item tooltip borders

`element` - toggle damage/resistance type color coding

`status`  - show current addon settings

# 🔌 **Addon Compatibility**

Chromatic detects and color codes tooltips from the following addons:

**AdvancedTradeSkillWindow2**

**AtlasLoot**

**aux**

**pfUI**

**ShaguTweaks**

**Tmog**

# **⚠️ Known Issues**

Element color coding is not context-aware — any occurrence of Fire, Frost, Arcane, Holy, Nature, or Shadow in a tooltip will be colorized, including spell names, item names, and even mob names. An exception list exists in `Chromatic.lua` (search for `local EXCEPTIONS`) but is not exhaustive. If you encounter a false match, add the offending name to that list.

# 👨‍💻 **Author**
Drakensangs

## 📸 **Screenshots**

<p align="left">
<img width="400" height="154" alt="Untitled4" src="https://github.com/user-attachments/assets/04175a88-a805-4256-9004-e4aa7ba23114" />
<img width="328" height="138" alt="Untitled3" src="https://github.com/user-attachments/assets/e50fad0c-fae0-48fc-8302-f35d9e796c33" />
</p>
<img width="265" height="245" alt="Untitled2" src="https://github.com/user-attachments/assets/9afa68fc-a29e-4c80-96ea-25e99800a323" />
<img width="403" height="79" alt="Untitled6" src="https://github.com/user-attachments/assets/e7d98f4c-43e2-4d84-bd3b-3ec0b4813cf2" />
<img width="400" height="752" alt="Untitled" src="https://github.com/user-attachments/assets/316332a9-956b-4c29-ae45-444c98f6e204" />
<img width="542" height="397" alt="Untitled5" src="https://github.com/user-attachments/assets/d7a421bd-b0d4-479b-afe0-9dc5ef7a1ce1" />
