--- === ClipboardHistory ===
---
--- A clipboard history manager for Hammerspoon.
---
--- Polls the system pasteboard and keeps a searchable history of text, URLs,
--- file paths and images, presented in a fuzzy-searchable chooser. History
--- persists across restarts. Images are stored on disk; text-like entries are
--- kept inline.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ClipboardHistory"
obj.version = "1.0"
obj.author = "necrom4"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/necrom4/ClipboardHistory.spoon"

local maxHistory    = 100
local maxTextLength = 1024 * 1024 -- 1 MB
local pollInterval  = 0.4

-- Resolved in :init().
local imageDir      = nil
local historyFile   = nil

-- One of nil, "text", "url", "file", "image", "pinned".
local activeFilter  = nil
local activeQuery   = ""

local iconCache     = {}

local function shorten(s, n)
	s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	if #s > n then
		return s:sub(1, n) .. "…"
	end
	return s
end

local function humanBytes(n)
	if n < 1024 then
		return string.format("%d B", n)
	end
	if n < 1024 * 1024 then
		return string.format("%.1f KB", n / 1024)
	end
	return string.format("%.1f MB", n / 1024 / 1024)
end

local function looksLikeURL(s)
	return s:match("^%a[%w+.-]*://") ~= nil
end

local function looksLikeFilePath(s)
	return s:sub(1, 1) == "/" and not s:find("\n") and hs.fs.attributes(s) ~= nil
end

-- Subsequence fuzzy match. Returns a score (higher is better) or nil if the
-- needle's characters don't all appear in haystack in order. Consecutive
-- matches and matches at word boundaries score higher.
local function fuzzyScore(haystack, needle)
	haystack, needle = haystack:lower(), needle:lower()
	local nLen = #needle
	local ni, score, prevMatched = 1, 0, false
	for hi = 1, #haystack do
		if ni > nLen then break end
		if haystack:sub(hi, hi) == needle:sub(ni, ni) then
			score = score + 1
			if prevMatched then score = score + 4 end
			local prev = hi > 1 and haystack:sub(hi - 1, hi - 1) or " "
			if prev:match("[%s%p]") then score = score + 3 end
			ni, prevMatched = ni + 1, true
		else
			prevMatched = false
		end
	end
	return ni > nLen and score or nil
end

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()
	return raw
end

-- Write to a temp file then rename so a crash mid-write can't corrupt the
-- destination.
local function atomicWrite(path, contents)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return end
	f:write(contents)
	f:close()
	os.rename(tmp, path)
end

local function loadHistory()
	local raw = readFile(historyFile)
	if not raw or raw == "" then return {} end
	local ok, decoded = pcall(hs.json.decode, raw)
	if not (ok and type(decoded) == "table") then return {} end

	for _, entry in ipairs(decoded) do
		entry.kind = entry.kind or (entry.path and "image" or "text")
		entry.time = entry.time or 0
		if entry.kind ~= "image" then
			entry.bytes = entry.bytes or (entry.text and #entry.text or 0)
		end
	end
	return decoded
end

local function saveHistory()
	local ok, encoded = pcall(hs.json.encode, obj.history)
	if ok then atomicWrite(historyFile, encoded) end
end

local function getAppIcon(bundleID)
	if not bundleID then return nil end
	local cached = iconCache[bundleID]
	if cached ~= nil then return cached or nil end
	local img = hs.image.imageFromAppBundle(bundleID)
	iconCache[bundleID] = img or false -- false = remembered miss
	return img
end

local function getFrontmostInfo()
	local app = hs.application.frontmostApplication()
	return app and { name = app:name(), bundleID = app:bundleID() } or nil
end

local function classifyText(text)
	if looksLikeURL(text) then return "url" end
	if looksLikeFilePath(text) then return "file" end
	return "text"
end

local function captureImage(source)
	local img = hs.pasteboard.readImage()
	if not img then return nil end
	local filename = string.format("%s/clip-%d-%d.png", imageDir, os.time(), math.random(100000, 999999))
	if not img:saveToFile(filename, "png") then return nil end
	local size = img:size()
	local attrs = hs.fs.attributes(filename) or {}
	return {
		kind = "image",
		path = filename,
		width = math.floor(size.w),
		height = math.floor(size.h),
		bytes = attrs.size or 0,
		time = os.time(),
		source = source,
	}
end

local function captureText(source)
	local text = hs.pasteboard.getContents()
	if type(text) ~= "string" or text == "" or #text > maxTextLength then
		return nil
	end
	return {
		kind = classifyText(text),
		text = text,
		bytes = #text,
		time = os.time(),
		source = source,
	}
end

-- Images compared by dimensions+size (no pixel hashing), text by content.
local function entryEquals(a, b)
	if a.kind ~= b.kind then return false end
	if a.kind == "image" then
		return a.bytes == b.bytes and a.width == b.width and a.height == b.height
	end
	return a.text == b.text
end

local function deleteImageFile(entry)
	if entry.kind == "image" and entry.path then
		os.remove(entry.path)
	end
end

local function addEntry(entry)
	if not entry then return false end

	-- A duplicate keeps the older entry's pinned flag and image file.
	for i, item in ipairs(obj.history) do
		if entryEquals(item, entry) then
			entry.pinned = entry.pinned or item.pinned
			if entry.kind == "image" and item.path ~= entry.path then
				os.remove(entry.path)
				entry.path = item.path
			end
			table.remove(obj.history, i)
			break
		end
	end

	table.insert(obj.history, 1, entry)

	-- Pinned entries don't count toward maxHistory and are never evicted.
	local kept, nonPinned = {}, 0
	for _, item in ipairs(obj.history) do
		if item.pinned then
			table.insert(kept, item)
		else
			nonPinned = nonPinned + 1
			if nonPinned <= maxHistory then
				table.insert(kept, item)
			else
				deleteImageFile(item)
			end
		end
	end
	obj.history = kept
	saveHistory()
	return true
end

local function checkPasteboard()
	local cc = hs.pasteboard.changeCount()
	if cc == obj.lastChangeCount then return end
	obj.lastChangeCount = cc

	local source = getFrontmostInfo()
	local types = hs.pasteboard.typesAvailable()

	-- Prefer text when both text and image representations exist, falling
	-- back to image only when no usable text was found.
	if (types.string or types.styledText) and addEntry(captureText(source)) then
		return
	end
	if types.image then
		addEntry(captureImage(source))
	end
end

local function restoreEntry(entry)
	if entry.kind == "image" then
		local img = hs.image.imageFromPath(entry.path)
		if img then hs.pasteboard.writeObjects(img) end
	else
		hs.pasteboard.setContents(entry.text)
	end
	obj.lastChangeCount = hs.pasteboard.changeCount()
end

local function entryMatchesFilter(entry)
	if not activeFilter then return true end
	if activeFilter == "pinned" then return entry.pinned == true end
	return entry.kind == activeFilter
end

local function entryAppName(entry)
	return entry.source and entry.source.name or nil
end

local function entryFormattedTime(entry)
	return os.date("%Y-%m-%d %H:%M:%S", entry.time)
end

local function searchableText(entry)
	local body = entry.kind == "image"
		and (entry.path:match("[^/]+$") or "")
		or (entry.text or "")
	return table.concat({ body, entryAppName(entry) or "", entryFormattedTime(entry), entry.kind }, " ")
end

local function describeSize(entry)
	if entry.kind == "image" then
		return string.format("%d×%d · %s", entry.width, entry.height, humanBytes(entry.bytes))
	end
	return humanBytes(entry.bytes or #(entry.text or ""))
end

local function buildSubText(entry)
	local app = entryAppName(entry)
	local parts = { entry.kind }
	if app then table.insert(parts, "from " .. app) end
	table.insert(parts, entryFormattedTime(entry))
	table.insert(parts, describeSize(entry))
	if entry.pinned then table.insert(parts, "pinned") end
	return table.concat(parts, " • ")
end

local function rowTitle(entry)
	if entry.kind == "image" then
		return string.format("Image (%d×%d)", entry.width, entry.height)
	end
	return shorten(entry.text, 120)
end

local function rowImage(entry)
	if entry.kind == "image" then return hs.image.imageFromPath(entry.path) end
	return getAppIcon(entry.source and entry.source.bundleID)
end

-- Suffix the active query as zero-size styled text so every row our fuzzy
-- scorer kept survives the chooser's built-in substring matcher.
local function withHiddenQuery(text)
	if activeQuery == "" then return text end
	return hs.styledtext.new(text)
		.. hs.styledtext.new(" " .. activeQuery, { font = { size = 0.01 } })
end

local function buildChoices()
	local matches = {}
	for i, entry in ipairs(obj.history) do
		if entryMatchesFilter(entry) then
			local score = activeQuery == "" and 0 or fuzzyScore(searchableText(entry), activeQuery)
			if score then
				matches[#matches + 1] = { entry = entry, index = i, score = score }
			end
		end
	end

	if activeQuery ~= "" then
		table.sort(matches, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			return a.index < b.index
		end)
	end

	local choices = {}
	for _, m in ipairs(matches) do
		choices[#choices + 1] = {
			text = rowTitle(m.entry),
			subText = withHiddenQuery(buildSubText(m.entry)),
			image = rowImage(m.entry),
			index = m.index,
		}
	end
	return choices
end

local function refreshChooser()
	obj.chooser:choices(buildChoices())
end

local function pasteAfterDismiss()
	-- Wait until focus has returned to the previous app before pressing ⌘V.
	hs.timer.doAfter(0.08, function()
		hs.eventtap.keyStroke({ "cmd" }, "v")
	end)
end

local function indexOf(entry)
	for i, item in ipairs(obj.history) do
		if item == entry then return i end
	end
end

local actions = {
	copy = function(entry)
		restoreEntry(entry)
	end,
	paste = function(entry)
		restoreEntry(entry)
		local i = indexOf(entry)
		if i then
			table.remove(obj.history, i)
			table.insert(obj.history, 1, entry)
		end
		saveHistory()
		pasteAfterDismiss()
	end,
	togglePin = function(entry)
		entry.pinned = not entry.pinned
		saveHistory()
		hs.alert.show(entry.pinned and "Pinned" or "Unpinned")
	end,
	delete = function(entry)
		local i = indexOf(entry)
		if i then
			deleteImageFile(entry)
			table.remove(obj.history, i)
		end
		saveHistory()
	end,
}

local function performAction(entry, action)
	if entry and actions[action] then actions[action](entry) end
end

local validTags = {
	text = true, url = true, file = true, image = true, pinned = true,
}

-- Modal active only while the chooser is open.
local pickerKeys = nil

local function selectedEntry()
	local choice = buildChoices()[obj.chooser:selectedRow()]
	return choice and obj.history[choice.index] or nil
end

local function bindPickerAction(mods, key, action, opts)
	opts = opts or {}
	pickerKeys:bind(mods, key, nil, function()
		local entry = selectedEntry()
		if not entry then return end
		if opts.hide then obj.chooser:hide() end
		performAction(entry, action)
		if opts.refresh then refreshChooser() end
	end)
end

local function moveSelection(delta)
	local total = #buildChoices()
	if total == 0 then return end
	local current = math.max(1, obj.chooser:selectedRow())
	obj.chooser:selectedRow((current - 1 + delta) % total + 1)
end

local function bindPickerNav(mods, key, delta)
	local fn = function() moveSelection(delta) end
	pickerKeys:bind(mods, key, nil, fn, nil, fn)
end

local function buildChooser()
	obj.chooser = hs.chooser.new(function(choice)
		if choice then performAction(obj.history[choice.index], "paste") end
	end)

	obj.chooser:rows(10)
	obj.chooser:width(45)
	obj.chooser:placeholderText("Search content, app, date… or :image / :url / :file / :pinned")
	obj.chooser:searchSubText(true)

	obj.chooser:queryChangedCallback(function(query)
		local newFilter = nil
		local rest = query

		local tag, after = query:match("^:(%a+)%s*(.*)$")
		if tag and validTags[tag:lower()] then
			newFilter = tag:lower()
			rest = after or ""
		end

		rest = rest:gsub("^%s+", ""):gsub("%s+$", "")

		if newFilter ~= activeFilter or rest ~= activeQuery then
			activeFilter = newFilter
			activeQuery = rest
			refreshChooser()
		end
	end)

	obj.chooser:rightClickCallback(function(row)
		if row == 0 then return end
		local choice = buildChoices()[row]
		local entry = choice and obj.history[choice.index]
		if not entry then return end

		local function hideThen(name) return function()
			obj.chooser:hide()
			performAction(entry, name)
		end end
		local function refreshAfter(name) return function()
			performAction(entry, name)
			refreshChooser()
		end end

		local items = {
			{ title = "Paste",                  fn = hideThen("paste") },
			{ title = "Copy to Clipboard",      fn = hideThen("copy") },
			{ title = "-" },
			{ title = entry.pinned and "Unpin" or "Pin", fn = refreshAfter("togglePin") },
			{ title = "Delete",                 fn = refreshAfter("delete") },
		}
		if entry.kind == "image" then
			table.insert(items, { title = "-" })
			table.insert(items, { title = "Reveal in Finder",
				fn = function() hs.execute(string.format("open -R %q", entry.path)) end })
		elseif entry.kind == "url" then
			table.insert(items, { title = "-" })
			table.insert(items, { title = "Open URL",
				fn = function() hs.urlevent.openURL(entry.text) end })
		end

		local menu = hs.menubar.new(false)
		menu:setMenu(items)
		menu:popupMenu(hs.mouse.absolutePosition(), true)
	end)

	pickerKeys = hs.hotkey.modal.new()

	bindPickerAction({ "cmd" }, "return", "copy",      { hide = true })
	bindPickerAction({ "cmd" }, ".",      "togglePin", { refresh = true })
	bindPickerAction({ "cmd" }, "delete", "delete",    { refresh = true })

	bindPickerNav({},          "down", 1)
	bindPickerNav({},          "up",  -1)
	bindPickerNav({},          "tab",  1)
	bindPickerNav({ "shift" }, "tab", -1)
	bindPickerNav({ "ctrl" },  "j",    1)
	bindPickerNav({ "ctrl" },  "k",   -1)

	obj.chooser:showCallback(function() pickerKeys:enter() end)
	obj.chooser:hideCallback(function() pickerKeys:exit() end)
end

--- ClipboardHistory:show()
--- Method
--- Opens the clipboard history chooser.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:show()
	checkPasteboard()
	if #self.history == 0 then
		hs.alert.show("Clipboard history is empty")
		return self
	end
	activeFilter, activeQuery = nil, ""
	self.chooser:query("")
	refreshChooser()
	self.chooser:show()
	return self
end

--- ClipboardHistory:clear()
--- Method
--- Clears all clipboard history, including pinned entries and stored images.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:clear()
	for _, item in ipairs(self.history) do deleteImageFile(item) end
	self.history = {}
	saveHistory()
	hs.alert.show("Clipboard history cleared")
	return self
end

--- ClipboardHistory:init()
--- Method
--- Initializes the Spoon: resolves its data directory, loads any persisted
--- history and prepares the chooser. Called automatically by hs.loadSpoon().
--- Does not start the background pasteboard poller (see :start()).
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:init()
	self.spoonPath = hs.spoons.scriptPath()
	local dataDir = self.spoonPath .. "data"
	imageDir = dataDir .. "/clipboard_images"
	historyFile = dataDir .. "/clipboard_history.json"

	hs.fs.mkdir(dataDir)
	hs.fs.mkdir(imageDir)

	self.history = loadHistory()
	self.lastChangeCount = hs.pasteboard.changeCount()

	buildChooser()
	return self
end

--- ClipboardHistory:start()
--- Method
--- Starts the background timer that polls the system pasteboard for changes.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:start()
	if not self.pollTimer then
		self.pollTimer = hs.timer.new(pollInterval, checkPasteboard)
	end
	self.lastChangeCount = hs.pasteboard.changeCount()
	self.pollTimer:start()
	return self
end

--- ClipboardHistory:stop()
--- Method
--- Stops the background pasteboard poller.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:stop()
	if self.pollTimer then self.pollTimer:stop() end
	return self
end

--- ClipboardHistory:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for this Spoon.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the
---    following items:
---    * show  - Open the clipboard history chooser
---    * clear - Clear all clipboard history
---
--- Returns:
---  * The ClipboardHistory object
function obj:bindHotkeys(mapping)
	local spec = {
		show  = hs.fnutils.partial(self.show, self),
		clear = hs.fnutils.partial(self.clear, self),
	}
	hs.spoons.bindHotkeysToSpec(spec, mapping)
	return self
end

--- ClipboardHistory:debug()
--- Method
--- Prints internal state (history contents, timer status, active filter) to
--- the Hammerspoon console for troubleshooting.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:debug()
	print("--- ClipboardHistory ---")
	print("history entries:", #self.history)
	print("lastChangeCount:", self.lastChangeCount)
	print("pasteboard changeCount:", hs.pasteboard.changeCount())
	print("pollTimer running:", self.pollTimer and self.pollTimer:running())
	print("active filter:", activeFilter or "(none)")
	for i, item in ipairs(self.history) do
		local desc
		if item.kind == "image" then
			desc = string.format("[image %dx%d]", item.width or 0, item.height or 0)
		else
			desc = string.format("[%s] %s", item.kind, (item.text or ""):sub(1, 60))
		end
		print(i, item.pinned and "[pinned]" or "        ",
			os.date("%H:%M:%S", item.time),
			entryAppName(item) or "?", desc)
	end
	return self
end

return obj
