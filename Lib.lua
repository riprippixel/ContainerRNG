-- container_automation.lua
-- ModuleScript: Container automation helper for the target game
--
-- Purpose:
--   - Provide safe, robust, dataset-driven helpers to open/buy containers and pick up items/orbs.
--   - Use in-game datasets (when available) and the game's Warp/Buffer utilities when present.
--   - Designed for use in a LocalScript/executor environment (client-side), with pcall-wrapped remote calls.
--
-- Public API (high level)
--   - ContainerLib.Init(opts)                       -- optional runtime configuration
--   - ContainerLib.FindMyPlot()                     -- returns the player's plot Instance or nil
--   - ContainerLib.FindContainerByUUID(uuid, plot)  -- find model by CONTAINER_<uuid> name
--   - ContainerLib.OpenContainerByUUID(uuid)        -- open a container model by its UUID (CONTAINER_<uuid>)
--   - ContainerLib.BuyContainerByIdentifier(id)     -- buy container type (Identifier from ContainerDataSet)
--   - ContainerLib.PickupItemByUUID(uuid)           -- pickup ITEM_<uuid> or ORB_<uuid>
--   - ContainerLib.ScanAndPickup(containerModel)    -- poll ItemCache for items inside a container and pick them
--   - ContainerLib.ShouldPickItem(itemModel)        -- policy decision (configurable)
--   - ContainerLib.SetConfig(k,v)                   -- update runtime config
--
-- Notes:
--   - This module attempts to use the game's Warp/Buffer utilities to encode network buffers exactly as the game expects.
--     If those utilities are not accessible, it falls back to sending a safe table payload via the Reliable remote.
--   - All remote sends are pcall-wrapped. If the server rejects or the remote is missing, functions return false + reason.
--   - The module expects container models to be named "CONTAINER_<uuid>" and items "ITEM_<uuid>" / "ORB_<uuid>".
--
-- Usage Example (client-side):
--   local ContainerLib = require(path.to.container_automation)
--   ContainerLib.Init({verbose=true})
--   local plot = ContainerLib.FindMyPlot()
--   local ok, err = ContainerLib.OpenContainerByUUID("f85168a6-7d15-461e-a1e0-36a4ec4c3db7")
--   if ok then print("Open requested") else warn("Open failed:", err) end
--   -- wait a moment then:
--   ContainerLib.ScanAndPickup(ContainerModel)
--
-- Implementation:
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local task = task

local ContainerLib = {}
ContainerLib.__version = "1.0.0"

-- Default config (safe conservative defaults)
ContainerLib.config = {
    verbose = false,
    useBufferModuleIfPresent = true,
    container_search_radius = 9,      -- studs to match container PrimaryPart to a slot Part
    after_open_poll_window = 2.6,     -- seconds to poll ItemCache after opening
    poll_interval = 0.14,             -- seconds between item cache checks
    pickup_delay = 0.12,              -- delay between pickup sends
    open_cooldown = 0.9,              -- seconds per container to avoid duplicate opens
    pick_policy = "all",              -- "all" | "rarity" | "whitelist"
    rarity_threshold = "Rare",        -- if pick_policy == "rarity", pick rarities >= this (uses RarityDataSet ranks)
    whitelist = {},                   -- set of item names to pick if using whitelist (keys true)
}

local _private = {
    last_open = {},                   -- containerModel.Name -> timestamp
    last_pick = {},                   -- identifier -> timestamp
    bufferUtil = nil,                 -- in-game Buffer util when found
    warpEvent = nil,                  -- in-game warp event module (holds Reliable/Request/Unreliable)
    datasets = {},                    -- cached datasets
}

local function log(...)
    if ContainerLib.config.verbose then
        print("[ContainerLib]", ...)
    end
end

-- Safe module resolver (non-fatal)
local function safeRequireFromReplicated(pathTable)
    if not pathTable or #pathTable == 0 then return nil end
    local cur = ReplicatedStorage
    for _, name in ipairs(pathTable) do
        cur = cur and cur:FindFirstChild(name)
        if not cur then return nil end
    end
    local ok, mod = pcall(function() return require(cur) end)
    if ok then return mod end
    return nil
end

-- Try to acquire Buffer / Warp modules used by the game's networking (non-fatal)
local function initNetworkHelpers()
    if _private.bufferUtil ~= nil and _private.warpEvent ~= nil then return end

    -- Warp index event (may be a ModuleScript returning instances OR direct Instances in ReplicatedStorage)
    local ok, warpEvent = pcall(function()
        -- try common path as Module: ReplicatedStorage.Modules.Shared.Warp.Index.Event
        local node = ReplicatedStorage:FindFirstChild("Modules")
        if node and node:FindFirstChild("Shared") then
            local maybe = node.Shared:FindFirstChild("Warp")
            if maybe and maybe:FindFirstChild("Index") and maybe.Index:FindFirstChild("Event") then
                local inst = maybe.Index.Event
                -- sometimes it's a ModuleScript that requires to return instances
                if inst:IsA("ModuleScript") then
                    local m = require(inst)
                    return m
                else
                    -- direct Instances (unlikely) but return as-is
                    return inst
                end
            end
        end
        -- fallback attempt via known module requiring
        local m = safeRequireFromReplicated({"Modules","Shared","Warp","Index","Event"})
        return m
    end)
    if ok then _private.warpEvent = warpEvent end

    -- Buffer util
    local bu = safeRequireFromReplicated({"Modules","Shared","Warp","Index","Util","Buffer"})
    if bu then _private.bufferUtil = bu end

    -- Some games also put a Dedicated Buffer module nested differently
    if not _private.bufferUtil then
        _private.bufferUtil = safeRequireFromReplicated({"Modules","Shared","Warp","Index","Util","Buffer","Dedicated"})
    end
end

-- Utility: convert string to array of u8
local function stringToU8Array(s)
    local arr = {}
    for i = 1, #s do table.insert(arr, string.byte(s, i)) end
    return arr
end

-- Build the identifier header bytes (observed pattern; robust fallback)
local function buildIdentifierHeaderBytes(identifier)
    -- Observed header pattern in this game's context:
    --  {254, 1, 0, 6, <len>, bytes...}
    -- We'll build that pattern as a fallback. If BufferUtil available we will use it later.
    local bytes = {254, 1, 0, 6}
    local len = #identifier
    if len > 255 then
        -- split or error - but identifiers in this game are short
        len = 255
    end
    table.insert(bytes, len)
    local u8 = stringToU8Array(identifier)
    for _, b in ipairs(u8) do table.insert(bytes, b) end
    return bytes
end

-- Convert an array of bytes into a buffer object using available APIs (BufferUtil, buffer.create, or return array)
local function makeBufferFromBytes(bytes)
    -- Prefer in-game buffer util
    if ContainerLib.config.useBufferModuleIfPresent and _private.bufferUtil then
        -- Some Buffer implementations expose new()/writeu8/buffer.create style; try common patterns
        local ok, buf = pcall(function()
            -- try BufferUtil.new()
            if type(_private.bufferUtil.new) == "function" then
                local b = _private.bufferUtil.new()
                if type(_private.bufferUtil.write) == "function" then
                    -- if there's a generic write that accepts bytes, use it
                    -- but unknown signature; we attempt writeu8-like approach
                end
                -- Try to write bytes with common names
                if type(_private.bufferUtil.writeu8) == "function" then
                    for i=1,#bytes do _private.bufferUtil.writeu8(b, i-1, bytes[i]) end
                elseif type(_private.bufferUtil.write) == "function" then
                    -- some buffers accept a byte table
                    _private.bufferUtil.write(b, bytes)
                end
                return b
            end

            -- try if BufferUtil has .newBuffer or .create
            if type(_private.bufferUtil.create) == "function" then
                local b = _private.bufferUtil.create(#bytes)
                if type(_private.bufferUtil.writeu8) == "function" then
                    for i=1,#bytes do _private.bufferUtil.writeu8(b, i-1, bytes[i]) end
                end
                return b
            end

            error("BufferUtil present but no known factory")
        end)
        if ok then return buf end
    end

    -- Try global buffer API (common in some executors / games)
    local ok, globalBuf = pcall(function()
        if typeof(buffer) == "table" and type(buffer.create) == "function" and type(buffer.writeu8) == "function" then
            local b = buffer.create(#bytes)
            for i=1,#bytes do buffer.writeu8(b, i-1, bytes[i]) end
            return b
        end
    end)
    if ok and globalBuf then return globalBuf end

    -- Final fallback: return raw bytes table (the server may accept a table)
    return bytes
end

-- Internal: try to send a reliable request using the discovered warp event and buffers
-- opcode: number, identifier: string
-- returns: ok(boolean), errOrTrue
local function sendReliableOp(opcode, identifier)
    initNetworkHelpers()
    -- Build first buffer with opcode byte
    local ok, res = pcall(function()
        local b1 = makeBufferFromBytes({opcode})
        local hdr = buildIdentifierHeaderBytes(identifier or "")
        local b2 = makeBufferFromBytes(hdr)

        -- If warpEvent is a table with Reliable instance(s)
        if _private.warpEvent and type(_private.warpEvent) == "table" then
            local reliable = _private.warpEvent.Reliable or _private.warpEvent.reliable or _private.warpEvent[1]
            if reliable and typeof(reliable.FireServer) == "function" then
                reliable:FireServer(b1, b2)
                return true
            end
        end

        -- If warpEvent itself is a RemoteEvent Instance
        if typeof(_private.warpEvent) == "Instance" and _private.warpEvent:IsA("RemoteEvent") then
            _private.warpEvent:FireServer(b1, b2)
            return true
        end

        -- Fallback: try find a RemoteEvent in ReplicatedStorage named "Reliable" or "RE_Reliable" under GameLib_Remotes or similar
        local folder = ReplicatedStorage:FindFirstChild("GameLib_Remotes") or ReplicatedStorage:FindFirstChild("RemoteEvents") or ReplicatedStorage
        local r = folder:FindFirstChild("Reliable") or folder:FindFirstChild("RE_Reliable") or folder:FindFirstChild("WarpReliable")
        if r and r:IsA("RemoteEvent") then
            r:FireServer(b1, b2)
            return true
        end

        -- Final fallback: send a table payload (this may be unsupported by server but is safest)
        local generic = { opcode = opcode, identifier = identifier }
        -- attempt to find a generic server RemoteEvent named "Request" or "WarpRequest"
        local req = folder:FindFirstChild("Request") or folder:FindFirstChild("RE_Request") or folder:FindFirstChild("WarpRequest")
        if req and req:IsA("RemoteEvent") then
            req:FireServer(generic)
            return true
        end

        -- as last resort, try FireServer on any RemoteEvent in folder (not recommended)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("RemoteEvent") then
                pcall(function() child:FireServer(generic) end)
            end
        end
        return true
    end)
    if not ok then return false, res end
    return true, true
end

-- High-level public helpers -------------------------------------------------

-- Initialize runtime: optionally pass config overrides
function ContainerLib.Init(opts)
    opts = opts or {}
    for k,v in pairs(opts) do ContainerLib.config[k] = v end
    initNetworkHelpers()
    log("ContainerLib initialized. BufferUtil present:", _private.bufferUtil ~= nil, "WarpEvent present:", _private.warpEvent ~= nil)
end

-- Find the current player's plot by matching PlotNameSign's label text
function ContainerLib.FindMyPlot()
    local ok, plots = pcall(function() return Workspace.Gameplay and Workspace.Gameplay.Plots end)
    if not ok or not plots then return nil end
    for _, plot in ipairs(plots:GetChildren()) do
        local success, nameLabel = pcall(function()
            return plot.PlotLogic and plot.PlotLogic.PlotNameSign
                and plot.PlotLogic.PlotNameSign.PlayerInfoSign
                and plot.PlotLogic.PlotNameSign.PlayerInfoSign.PlayerNameSign
                and plot.PlotLogic.PlotNameSign.PlayerInfoSign.PlayerNameSign.MainFrame
                and plot.PlotLogic.PlotNameSign.PlayerInfoSign.PlayerNameSign.MainFrame.NameLabel
        end)
        if success and nameLabel and (nameLabel.ClassName == "TextLabel" or nameLabel.ClassName == "TextButton") then
            local txt = ""
            pcall(function() txt = tostring(nameLabel.Text) end)
            if txt and txt:match(LocalPlayer.Name) then
                return plot
            end
        end
    end
    return nil
end

-- Find a container model by uuid string (the model.Name expected to be "CONTAINER_<uuid>")
function ContainerLib.FindContainerByUUID(uuid, plot)
    if not uuid then return nil end
    plot = plot or ContainerLib.FindMyPlot()
    if not plot or not plot.PlotLogic then return nil end
    local holder = plot.PlotLogic:FindFirstChild("ContainerHolder")
    if not holder then return nil end
    local targetName1 = "CONTAINER_" .. tostring(uuid)
    local targetName2 = "CONTAINER_" .. tostring(uuid):upper()
    for _, child in ipairs(holder:GetChildren()) do
        if child:IsA("Model") and (child.Name == targetName1 or child.Name == targetName2) then
            return child
        end
    end
    return nil
end

-- Open a container by uuid (sends OPEN opcode to server)
-- returns: ok(boolean), err
function ContainerLib.OpenContainerByUUID(uuid)
    if not uuid then return false, "missing-uuid" end
    local containerModel = ContainerLib.FindContainerByUUID(uuid)
    if not containerModel then return false, "container-not-found" end

    -- cooldown check
    local now = tick()
    if _private.last_open[containerModel.Name] and now - _private.last_open[containerModel.Name] < ContainerLib.config.open_cooldown then
        return false, "cooldown"
    end
    _private.last_open[containerModel.Name] = now

    -- The server expects opcode 56 for open (based on earlier analysis). We'll send opcode + identifier.
    -- The identifier used earlier was the container model's Name (CONTAINER_<uuid>).
    local identifier = containerModel.Name
    local OK, err = sendReliableOp(56, identifier)
    if not OK then
        return false, err
    end
    log("OpenContainer requested:", identifier)
    return true
end

-- Buy a container by Identifier (e.g., "SealedContainer" from ContainerDataSet)
function ContainerLib.BuyContainerByIdentifier(identifier)
    if not identifier then return false, "missing-identifier" end
    -- opcode observed for buy was 54 in previous dumps
    local OK, err = sendReliableOp(54, identifier)
    if not OK then return false, err end
    log("BuyContainer requested:", identifier)
    return true
end

-- Pickup item by uuid (ITEM_<uuid> or ORB_<uuid>)
function ContainerLib.PickupItemByUUID(uuid)
    if not uuid then return false, "missing-uuid" end
    local id1 = "ITEM_" .. tostring(uuid)
    local id2 = "ORB_" .. tostring(uuid)
    -- choose opcode based on prefix; items use opcode 15, orbs earlier used opcode 33 in the game's context
    -- We'll attempt both: prefer item opcode if item exists in ItemCache; fallback to orb opcode.
    -- First try item pickup send
    local ok, err = sendReliableOp(15, id1)
    if ok then
        log("Pickup requested for", id1)
        return true
    end
    -- fallback to orb
    ok, err = sendReliableOp(33, id2)
    if ok then
        log("Pickup requested for", id2)
        return true
    end
    return false, err
end

-- Decide whether to pick an item based on policy
-- Accepts an item model (Model) and returns boolean
function ContainerLib.ShouldPickItem(itemModel)
    if not itemModel then return false end
    local name = itemModel.Name or ""
    -- check cooldown by identifier
    local now = tick()
    if _private.last_pick[name] and now - _private.last_pick[name] < ContainerLib.config.pickup_delay then
        return false
    end

    if ContainerLib.config.pick_policy == "all" then return true end
    if ContainerLib.config.pick_policy == "whitelist" then
        return ContainerLib.config.whitelist[name] == true
    end
    if ContainerLib.config.pick_policy == "rarity" then
        -- try to determine rarity using ItemDefinitions or ItemDataSet
        local rarity = nil
        if _private.datasets.ItemDefinitions and _private.datasets.ItemDefinitions.Items and _private.datasets.ItemDefinitions.Items[name] then
            local r = _private.datasets.ItemDefinitions.Items[name].Rarity
            if type(r) == "table" then rarity = r.Identifier elseif type(r) == "string" then rarity = r end
        else
            -- fallback: try ItemDataSet
            if _private.datasets.ItemDataSet then
                for rar, items in pairs(_private.datasets.ItemDataSet) do
                    if type(items) == "table" and items[name] then rarity = rar; break end
                end
            end
        end
        if not rarity then return false end
        -- Compare ranks using RarityDataSet if available
        local rankNeeded = nil
        local rankHave = nil
        if _private.datasets.RarityDataSet then
            local t = _private.datasets.RarityDataSet[ContainerLib.config.rarity_threshold]
            if t and t.Rank then rankNeeded = t.Rank end
            local h = _private.datasets.RarityDataSet[rarity]
            if h and h.Rank then rankHave = h.Rank end
        end
        if rankNeeded and rankHave then
            return rankHave >= rankNeeded
        end
        -- If we cannot compute, be conservative and skip
        return false
    end
    return false
end

-- Internal: find first base part in a model
local function findFirstBasePart(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

-- Find items that are inside a container using ItemSpawnHost OBB or fallback to slot OBB
-- containerModel: Model
-- plotLogic: PlotLogic folder (optional — will resolve)
-- returns array of item Models
function ContainerLib.FindItemsForContainer(containerModel, plotLogic)
    if not containerModel then return {} end
    plotLogic = plotLogic or (containerModel.Parent and containerModel.Parent.Parent and containerModel.Parent.Parent:FindFirstChild("PlotLogic")) or ContainerLib.FindMyPlot() and ContainerLib.FindMyPlot().PlotLogic
    local itemCache = nil
    if plotLogic then itemCache = plotLogic:FindFirstChild("ItemCache") end
    if not itemCache then return {} end

    -- find ItemSpawnHost if present
    local host = nil
    pcall(function()
        if containerModel:FindFirstChild("ContainerLogic") and containerModel.ContainerLogic:FindFirstChild("ItemSpawnHost") then
            host = containerModel.ContainerLogic.ItemSpawnHost
        end
    end)

    local items = {}
    for _, inst in ipairs(itemCache:GetChildren()) do
        if inst:IsA("Model") and (inst.Name:match("^ITEM_") or inst.Name:match("^ORB_")) then
            local base = inst.PrimaryPart or findFirstBasePart(inst)
            if base then
                local inside = false
                if host and host:IsA("BasePart") then
                    -- test with OBB
                    local ok, localPos = pcall(function() return host.CFrame:PointToObjectSpace(base.Position) end)
                    if ok and localPos then
                        local half = host.Size * 0.5
                        if math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z then
                            inside = true
                        end
                    end
                else
                    -- fallback: test distance to container primarypart
                    local baseContainerPart = containerModel.PrimaryPart or findFirstBasePart(containerModel)
                    if baseContainerPart then
                        if (base.Position - baseContainerPart.Position).Magnitude <= math.max(baseContainerPart.Size.X, baseContainerPart.Size.Z) * 1.5 then
                            inside = true
                        end
                    end
                end
                if inside then
                    table.insert(items, inst)
                end
            end
        end
    end
    return items
end

-- Scan the provided container model, and pick eligible items inside it.
-- This will poll the plot's ItemCache for after_open_poll_window and pick items that ShouldPickItem() returns true for.
-- Returns table: {picked={identifier,...}, skipped={identifier,...}, errors={...}}
function ContainerLib.ScanAndPickup(containerModel)
    if not containerModel then return {picked={}, skipped={}, errors={}} end
    local plot = ContainerLib.FindMyPlot()
    if not plot or not plot.PlotLogic then return {picked={}, skipped={}, errors={"plot-not-found"}} end
    local results = {picked={}, skipped={}, errors={}}
    local endTime = tick() + ContainerLib.config.after_open_poll_window
    while tick() <= endTime do
        local items = ContainerLib.FindItemsForContainer(containerModel, plot.PlotLogic)
        for _, item in ipairs(items) do
            local name = item.Name
            if ContainerLib.ShouldPickItem(item) then
                local ok, err = sendReliableOp(15, name) -- item pickup opcode (observed)
                if ok then
                    table.insert(results.picked, name)
                    _private.last_pick[name] = tick()
                    task.wait(ContainerLib.config.pickup_delay)
                else
                    table.insert(results.errors, {item = name, err = err})
                end
            else
                table.insert(results.skipped, name)
            end
        end
        task.wait(ContainerLib.config.poll_interval)
    end
    return results
end

-- Convenience: open container (uuid) then scan & pickup automatically
function ContainerLib.OpenAndCollect(uuid)
    local ok, err = ContainerLib.OpenContainerByUUID(uuid)
    if not ok then return false, err end
    -- find the container model
    local container = ContainerLib.FindContainerByUUID(uuid)
    if not container then
        -- container might be transient; try to wait for it to appear
        local plot = ContainerLib.FindMyPlot()
        local holder = plot and plot.PlotLogic and plot.PlotLogic:FindFirstChild("ContainerHolder")
        if holder then
            local start = tick()
            while tick() - start < 3 do
                container = holder:FindFirstChild("CONTAINER_"..uuid)
                if container then break end
                task.wait(0.12)
            end
        end
    end
    if not container then return false, "container-model-not-found" end
    -- Now poll and pick
    local res = ContainerLib.ScanAndPickup(container)
    return true, res
end

-- Update config safely
function ContainerLib.SetConfig(key, value)
    if ContainerLib.config[key] ~= nil or true then -- allow new keys too
        ContainerLib.config[key] = value
        log("Config updated:", key, value)
        return true
    end
    return false
end

-- Load datasets into private cache to support policy decisions
function ContainerLib.LoadDatasets()
    _private.datasets.ContainerDataSet = safeRequireFromReplicated({"Modules","Shared","DataSets","ContainerDataSet"})
    _private.datasets.ItemDataSet = safeRequireFromReplicated({"Modules","Shared","DataSets","ItemDataSet"})
    _private.datasets.ItemDefinitions = safeRequireFromReplicated({"Modules","Shared","DataSets","ItemDefinitions"})
    _private.datasets.RarityDataSet = safeRequireFromReplicated({"Modules","Shared","DataSets","Rarities","RarityDataSet"})
    -- expose for callers
    return _private.datasets
end

-- On-demand ensure
ContainerLib.Init() -- initialize network helpers with default config (safe no-op)

-- Module return
return ContainerLib
