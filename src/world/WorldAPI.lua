-- mod.world: the supported way for mod code to act on the running
-- overworld.  Every method resolves the live OverworldState by scanning
-- the state stack for the isOverworld marker and returns nil, "no
-- overworld" when none is up -- called from the title screen this is a
-- quiet no-op, never a crash.  Reaching into OverworldState internals
-- stays unsupported; anything a mod legitimately needs belongs here.

local Collision = require("src.world.Collision")
local Logger = require("src.core.Logger")
local FieldDefaults = require("src.world.FieldDefaults")
local Flags = require("src.script.Flags")
local Map = require("src.world.Map")
local MapLoader = require("src.world.MapLoader")
local MapOverview = require("src.world.MapOverview")
local Party = require("src.pokemon.Party")
local Runtime = require("src.mods.Runtime")
local GameVersion = require("src.core.GameVersion")
local PresentationObject = require("src.world.PresentationObject")
local GroundShadow = require("src.render.GroundShadow")

local WorldAPI = {}
WorldAPI.__index = WorldAPI

-- Public tokens are capabilities; ownership and Overworld state stay private.
local playerControlLockStates = setmetatable({}, {__mode = "k"})
local PlayerControlLock = {}
local playerControlLockMetatable = {
  __index = PlayerControlLock, __metatable = "player control lock token",
}
local PlayerControlLockRecord = {}
PlayerControlLockRecord.__index = PlayerControlLockRecord
local PresentationHandle = {}
PresentationHandle.__index = PresentationHandle
local presentationSequence = 0

function PlayerControlLockRecord:release()
  local locks = self.ow and self.ow.playerControlLocks
  if locks then locks[self] = nil end
  if self.owner then self.owner:forget(self) end
  self.ow, self.owner = nil, nil
  return true
end

function PlayerControlLock:release()
  local record = playerControlLockStates[self]
  if not record then return nil, "invalid player control lock token" end
  return record:release()
end

local function livePresentation(handle)
  local object, ow = handle.presentation, handle.ow
  if object.destroyed then return nil, "presentation is destroyed" end
  if WorldAPI.new(handle.game, handle.modId):overworld() ~= ow then
    object.destroyed = true
    return nil, "presentation runtime is no longer live"
  end
  if not (ow.map and ow.map.id == object.mapId)
      and not (ow.isNeighborMap and ow:isNeighborMap(object.mapId)) then
    object.destroyed = true
    return nil, "presentation map is not live"
  end
  return object
end

function PresentationHandle:setDrawOrder(order)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setDrawOrder(order)
end

function PresentationHandle:setTerrainOcclusion(enabled)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setTerrainOcclusion(enabled)
end

function PresentationHandle:setGroundShadow(enabled)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setGroundShadow(enabled)
end

function PresentationHandle:setGroundShadowOffset(xPx, yPx)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setGroundShadowOffset(xPx, yPx)
end

function PresentationHandle:setFrame(index)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setFrame(index)
end

function PresentationHandle:setPosition(x, y)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setPosition(x, y)
end

function PresentationHandle:setVisualElevation(cells)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setVisualElevation(cells)
end

function PresentationHandle:setVisible(visible)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  if type(visible) ~= "boolean" then
    return nil, "visibility must be a boolean"
  end
  object.visible = visible
  return true
end

function PresentationHandle:setAppearance(spriteId)
  local object, err = livePresentation(self)
  if not object then return nil, err end
  return object:setAppearance(spriteId, self.game and self.game.data)
end

function PresentationHandle:destroy()
  local object = self.presentation
  if object.destroyed then return true end
  if WorldAPI.new(self.game, self.modId):overworld() ~= self.ow then
    object.destroyed = true
    return nil, "presentation runtime is no longer live"
  end
  object.destroyed = true
  local objects = self.ow.presentations[object.mapId] or {}
  for index, entry in ipairs(objects) do
    if entry == object then table.remove(objects, index); break end
  end
  if #objects == 0 then self.ow.presentations[object.mapId] = nil end
  return true
end

local NO_OVERWORLD = "no overworld"
local DIG_TILESETS = { FOREST = true, CEMETERY = true, CAVERN = true,
                       FACILITY = true, INTERIOR = true }
local RODS = { "OLD_ROD", "GOOD_ROD", "SUPER_ROD" }

local function acceptsMenuInput(game, ow)
  local stack = game and game.stack
  local runner = ow and ow.runner
  return ow and stack and stack.top and stack:top() == ow
    and not ow.transitioning and not ow.flyAnim and not ow.teleportOut
    and not ow.engaging and not ow.emote and not ow.pikaHop and not ow.healAnim
    and not (ow.player and (ow.player.moving or ow.player.inputLocked))
    and not (ow.hasPlayerControlLock and ow:hasPlayerControlLock())
    and not (runner and runner.isRunning and runner:isRunning())
    and #(ow.scriptMoves or {}) == 0
end

local function validPartySlot(party, slot)
  return type(slot) == "number" and slot == math.floor(slot)
    and party[slot] ~= nil
end

local function outside(game, ow)
  return Map.isOutside(ow.map.def,
    FieldDefaults.field(game.data, "outsideTilesets"))
end

local function knows(mon, moveId)
  for _, move in ipairs(mon.moves or {}) do
    if move.id == moveId then return true end
  end
  return false
end

local function monInfo(game, mon, slot)
  local def = game.data.pokemon[mon.species] or {}
  return { slot = slot, species = mon.species,
    name = mon.nickname or def.name or mon.species, level = mon.level,
    hp = mon.hp, maxHp = mon.stats and mon.stats.hp or mon.hp }
end

local function softboiledSources(game)
  local party, sources = game.save.party or {}, {}
  for sourceSlot, source in ipairs(party) do
    local heal = source.stats and math.floor(source.stats.hp / 5) or 0
    if knows(source, "SOFTBOILED") and source.hp > heal then
      local info = monInfo(game, source, sourceSlot)
      info.targets = {}
      for targetSlot, target in ipairs(party) do
        if target ~= source and target.hp > 0 and target.stats
            and target.hp < target.stats.hp then
          info.targets[#info.targets + 1] = monInfo(game, target, targetSlot)
        end
      end
      if #info.targets > 0 then sources[#sources + 1] = info end
    end
  end
  return sources
end

local function flyDestinationAvailable(game, mapId)
  local field, save = game.data.field or {}, game.save
  for _, id in ipairs(field.flyOrder or {}) do
    if id == mapId then
      local def = game.data.maps and game.data.maps[id]
      return not not (save.visited and save.visited[id]
        and field.flyWarps and field.flyWarps[id]
        and def and Map.isFlyTown(def))
    end
  end
  return false
end

function WorldAPI.new(game, modId, resourceOwner)
  if not resourceOwner and modId and game and game.mods and game.mods.resourceOwner then
    resourceOwner = game.mods:resourceOwner(modId)
  end
  return setmetatable({ game = game, modId = modId, resourceOwner = resourceOwner,
    resourceLoader = game and game.mods }, WorldAPI)
end

-- the live overworld, or nil.  Game.overworld is the fast path; the stack
-- scan is the authority, so a state pushed over the world (a battle, a
-- menu) still resolves to the world underneath it.
function WorldAPI:overworld()
  local game = self.game
  -- Retirement is final: a late callback must not resolve the replacement
  -- world through an outgoing mod facade, even when NPC IDs are reused.
  local owner, loader = self.resourceOwner, self.resourceLoader
  if owner and (owner.closed or (loader and game.mods ~= loader)) then return nil end
  local stack = game and game.stack
  local states = stack and stack.states
  if states then
    for i = #states, 1, -1 do
      if states[i].isOverworld then return states[i] end
    end
  end
  local ow = game and game.overworld
  if ow and ow.isOverworld and ow.map then return ow end
  return nil
end

function WorldAPI:current()
  local ow = self:overworld()
  if not ow or not ow.map then return nil, NO_OVERWORLD end
  local p = ow.player
  return { mapId = ow.map.id, x = p and p.cellX, y = p and p.cellY,
           facing = p and p.facing }
end

local function containsActor(list, actor)
  if type(list) ~= "table" then return false end
  for _, entry in ipairs(list) do
    if entry == actor then return true end
  end
  return false
end

-- Current native Ground Anchor, in continuous cells (X right, Y down).
-- Stack membership is mandatory: overworld() alone permits an old fallback.
-- This read does not certify gameplay readiness under a menu or Battle.
function WorldAPI:playerPhysicalPosition()
  local ow = self:overworld()
  if not ow or not ow.isOverworld or type(ow.map) ~= "table" then
    return nil, NO_OVERWORLD
  end
  local stack = self.game and self.game.stack
  if not containsActor(stack and stack.states, ow) then
    return nil, "overworld is not in the state stack"
  end
  local player = ow.player
  if type(player) ~= "table" then return nil, "no overworld player" end
  if not containsActor(ow.entities, player) then
    return nil, "current player is not in overworld entities"
  end
  local px, py = player.px, player.py
  local function finite(value)
    return type(value) == "number" and value == value
      and value ~= math.huge and value ~= -math.huge
  end
  if not finite(px) or not finite(py) then
    return nil, "player physical coordinates must be finite numbers"
  end
  return px / 16, py / 16
end

function WorldAPI:acquirePlayerControlLock()
  -- The facade captures its Loader lifetime in new(); never rebind through
  -- game.mods here, since an outgoing callback may run after replacement.
  local owner = self.resourceOwner
  if self.modId and not owner then
    return nil, "player control lock requires a loader-owned mod"
  end
  if owner and owner.closed then return nil, "mod resource owner is retired" end
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  local record = setmetatable({ow = ow, owner = owner}, PlayerControlLockRecord)
  if owner then
    local ok, err = owner:add(record)
    if not ok then return nil, err end
  end
  ow.playerControlLocks = ow.playerControlLocks or {}
  ow.playerControlLocks[record] = true
  local token = setmetatable({}, playerControlLockMetatable)
  playerControlLockStates[token] = record
  return token
end

-- Gen 1 runtime resource, independent of movement and native appearance policy.
local PlayerAppearanceOverride = {}
PlayerAppearanceOverride.__index = PlayerAppearanceOverride
local SpriteRenderer = require("src.render.SpriteRenderer")

function PlayerAppearanceOverride:release()
  if self.player.appearanceOverride == self then
    self.player.appearanceOverride = nil
  end
  self.released = true
  self.sprite = nil
  return true
end

function PlayerAppearanceOverride:isActive()
  if self.released then return false end
  local ow = WorldAPI.new(self.game, self.modId):overworld()
  if GameVersion.generation() ~= 1 or ow ~= self.ow
      or ow.player ~= self.player or self.player.appearanceOverride ~= self then
    self:release()
    return false
  end
  return true
end

local function appearanceRenderer(game, spriteId)
  local sprites = game and game.data and game.data.sprites
  if type(spriteId) ~= "string" or not (sprites and sprites[spriteId]) then
    return nil, "unknown sprite: " .. tostring(spriteId)
  end
  local ok, sprite = pcall(SpriteRenderer.new, sprites[spriteId], "player")
  if not ok then return nil, "could not create player appearance: " .. tostring(sprite) end
  return sprite
end

function PlayerAppearanceOverride:setAppearance(spriteId)
  if not self:isActive() then return nil, "player appearance token is inactive" end
  local sprite, err = appearanceRenderer(self.game, spriteId)
  if not sprite then return nil, err end
  self.sprite, self.spriteId = sprite, spriteId
  return true
end

function WorldAPI:acquirePlayerAppearanceOverride(spriteId)
  if GameVersion.generation() ~= 1 then
    return nil, "player appearance overrides are currently Gen 1 only"
  end
  local ow = self:overworld()
  if not (ow and ow.player) then return nil, "no overworld player" end
  local player = ow.player
  local active = player.appearanceOverride
  if active and active:isActive() then
    return nil, "player appearance override is already owned by " .. tostring(active.modId)
  end
  local sprite, err = appearanceRenderer(self.game, spriteId)
  if not sprite then return nil, err end
  local token = setmetatable({ game = self.game, ow = ow, player = player,
    modId = self.modId, sprite = sprite, spriteId = spriteId, released = false },
    PlayerAppearanceOverride)
  player.appearanceOverride = token
  return token
end

function WorldAPI:setPlayerFacing(direction)
  if GameVersion.generation() ~= 1 then
    return nil, "player facing setter is currently Gen 1 only"
  end
  if direction ~= "up" and direction ~= "down"
      and direction ~= "left" and direction ~= "right" then
    return nil, "player facing must be up, down, left or right"
  end
  local ow = self:overworld()
  if not (ow and ow.player) then return nil, "no overworld player" end
  ow.player.facing = direction
  return true
end

local function validBlockCoordinate(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and value == math.floor(value)
end

-- Read one block from the active Gen 1 map without exposing the mutable block
-- array.  Requiring the expected map id makes a stale signature fail closed
-- if a warp or reload moved the player before the caller completed its check.
-- Block coordinates are zero-based, matching replaceBlock.
function WorldAPI:activeBlockAt(mapId, bx, by)
  local ow = self:overworld()
  if not ow or not ow.map then return nil, NO_OVERWORLD end
  local map = ow.map
  if map.id ~= mapId then return nil, "map is not active" end
  if not validBlockCoordinate(bx) or not validBlockCoordinate(by) then
    return nil, "invalid block coordinates"
  end
  local def = map.def
  if not def or not validBlockCoordinate(def.width) or def.width <= 0
      or not validBlockCoordinate(def.height) or def.height <= 0 then
    return nil, "block unavailable"
  end
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then
    return nil, "block coordinates out of bounds"
  end
  if type(def.blocks) ~= "table" or type(map.blockAt) ~= "function" then
    return nil, "block unavailable"
  end
  local stored = def.blocks[by * def.width + bx + 1]
  if not validBlockCoordinate(stored) or stored < 0 then
    return nil, "block unavailable"
  end
  local ok, blockId = pcall(map.blockAt, map, bx, by)
  if not ok or not validBlockCoordinate(blockId) or blockId < 0
      or blockId ~= stored then
    return nil, "block unavailable"
  end
  return blockId
end

-- Companion UIs may offer party ordering while the player is in free roam.
-- The same guard that makes opening a menu safe keeps scripts, transitions,
-- movement and screens above the overworld from observing a mid-action swap.
function WorldAPI:canReorderParty()
  local game, ow = self.game, self:overworld()
  local party = game and game.save and game.save.party or {}
  return #party > 1 and not not acceptsMenuInput(game, ow)
end

function WorldAPI:reorderParty(fromSlot, toSlot)
  local game, ow = self.game, self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if not acceptsMenuInput(game, ow) then return nil, "world is busy" end
  local party = game.save and game.save.party or {}
  if not validPartySlot(party, fromSlot)
      or not validPartySlot(party, toSlot) then
    return nil, "invalid party slot"
  end
  if fromSlot ~= toSlot then
    party[fromSlot], party[toSlot] = party[toSlot], party[fromSlot]
    require("src.core.Sound").play(game.data, "Swap")
  end
  return true
end

-- Contextual field-item shortcuts. Only actions that can start immediately
-- are listed; callers receive copied labels and never inspect world internals.
function WorldAPI:availableFieldActions()
  local game, ow, out = self.game, self:overworld(), {}
  if not (game and game.save and ow and ow.map and ow.player) then
    return out, NO_OVERWORLD
  end
  if not acceptsMenuInput(game, ow) then return out, "world is busy" end
  local save, inventory = game.save, game.save.inventory or {}
  local items = game.data and game.data.items or {}

  if (inventory.BICYCLE or 0) > 0 and not ow.player.surfing
      and not (save.onBike and save.forcedBike)
      and (save.onBike or ow:bikeAllowed(ow.map.id)) then
    out[#out + 1] = { id = "bicycle",
      label = save.onBike and "BIKE OFF" or "BICYCLE" }
  end

  if not ow.player.surfing and ow:facingIsShoreOrWater() then
    local rods = {}
    for _, id in ipairs(RODS) do
      if (inventory[id] or 0) > 0 then
        local def = items[id]
        rods[#rods + 1] = { id = id, label = def and def.name or id }
      end
    end
    if #rods > 0 then
      out[#out + 1] = { id = "fish", label = "FISH", rods = rods }
    end
  end

  if ow:useCutFieldMove() == "ok" then
    out[#out + 1] = { id = "cut", label = "CUT" }
  end
  local surf = ow:useSurfFieldMove()
  if surf == "ok" or surf == "dismount" then
    out[#out + 1] = { id = "surf",
      label = surf == "dismount" and "LEAVE WATER" or "SURF" }
  end

  if not ow.strengthActive and ow:partyKnows("STRENGTH") then
    out[#out + 1] = { id = "strength", label = "STRENGTH" }
  end
  if ow.dark and ow:partyKnows("FLASH") then
    out[#out + 1] = { id = "flash", label = "FLASH" }
  end
  if DIG_TILESETS[ow.map.def.tileset] and ow.map.id ~= "AGATHAS_ROOM"
      and ow:partyKnows("DIG") then
    out[#out + 1] = { id = "dig", label = "DIG" }
  end
  if ow:partyKnows("TELEPORT") and outside(game, ow) then
    out[#out + 1] = { id = "teleport", label = "TELEPORT" }
  end
  local sources = softboiledSources(game)
  if #sources > 0 then
    out[#out + 1] = { id = "softboiled", label = "SOFTBOILED",
      sources = sources }
  end
  return out
end

function WorldAPI:useFieldAction(id, opts)
  local game, ow = self.game, self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if not acceptsMenuInput(game, ow) then return nil, "world is busy" end
  local found
  for _, action in ipairs(self:availableFieldActions()) do
    if action.id == id then found = action break end
  end
  if not found then return nil, "field action unavailable" end

  if id == "bicycle" then
    if ow:useBicycle() then return true end
  elseif id == "cut" then
    local x, y = ow.player:facingCell()
    if ow:tryCut(x, y) then return true end
  elseif id == "surf" then
    local mode = ow:useSurfFieldMove()
    if mode == "dismount" then
      ow:stopSurfing()
      return true
    elseif mode == "ok" then
      local x, y = ow.player:facingCell()
      ow:trySurf(x, y)
      return true
    end
  elseif id == "fish" then
    local rod = opts and opts.rod
    if not rod and #found.rods == 1 then rod = found.rods[1].id end
    for _, choice in ipairs(found.rods) do
      if choice.id == rod and ow:useFishingRod(rod) then return true end
    end
    return nil, "fishing rod unavailable"
  elseif id == "strength" then
    if ow:useStrengthFieldMove() then return true end
  elseif id == "flash" then
    if ow:useFlashFieldMove() then return true end
  elseif id == "dig" or id == "teleport" then
    ow:beginTeleportOut()
    return true
  elseif id == "softboiled" then
    local sourceSlot = opts and tonumber(opts.sourceSlot)
    local targetSlot = opts and tonumber(opts.targetSlot)
    local allowed
    for _, source in ipairs(found.sources or {}) do
      if source.slot == sourceSlot then
        for _, target in ipairs(source.targets or {}) do
          if target.slot == targetSlot then allowed = true break end
        end
      end
    end
    if not allowed then return nil, "softboiled target unavailable" end
    if ow:useSoftboiledFieldMove(game.save.party[sourceSlot],
        game.save.party[targetSlot]) then return true end
  end
  return nil, "field action unavailable"
end

-- FLY needs a destination choice, so it is exposed separately from the
-- immediate actions above. The request is still checked against the same
-- visited-town list as the native Town Map picker before the world may warp.
function WorldAPI:canFly()
  local game, ow = self.game, self:overworld()
  return not not (ow and ow.map and outside(game, ow) and ow:partyKnows("FLY"))
end

function WorldAPI:flyTo(mapId)
  local game, ow = self.game, self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if not self:canFly() then return nil, "fly unavailable" end
  if not acceptsMenuInput(game, ow) then return nil, "world is busy" end
  if not flyDestinationAvailable(game, mapId) then
    return nil, "destination unavailable"
  end
  ow:flyTo(mapId)
  return true
end

-- A compact, read-only view of the active map for minimaps and companion UIs.
-- `rows` describes collision terrain; optional `tileRows` reduces each real
-- 8x8 map tile to its average Game Boy shade ("0" lightest, "3" darkest).
-- `tileDetailRows` preserves one shade per 4x4 quadrant. Markers identify
-- exits and item spots that are still active without exposing world internals.
function WorldAPI:mapOverview()
  local ow = self:overworld()
  if not ow or not ow.map then return nil, NO_OVERWORLD end
  local map, markers = ow.map, {}
  local def = map.def or {}
  for _, warp in ipairs(def.warps or {}) do
    markers[#markers + 1] = { kind = "warp", x = warp.x, y = warp.y }
  end
  local game, save = self.game, self.game.save or {}
  for _, obj in ipairs(def.objects or {}) do
    if obj.item and obj.item ~= "0" and obj.item ~= 0
        and ow.objectVisible(save, map.id, obj) then
      markers[#markers + 1] = { kind = "item", x = obj.x, y = obj.y }
    end
  end
  local hidden = game.data and game.data.field and game.data.field.hiddenItems
  for _, item in ipairs(hidden and hidden[map.id] or {}) do
    local key = map.id .. "_" .. item.x .. "_" .. item.y
    if not (save.hiddenTaken and save.hiddenTaken[key]) then
      markers[#markers + 1] = { kind = "hidden", x = item.x, y = item.y }
    end
  end
  return MapOverview.build(map, markers)
end

-- opts.arrive = "fly" | "teleport" picks the arrival FX; anything else
-- lands the player without one, like a scripted warp.
function WorldAPI:warpTo(mapId, x, y, facing, opts)
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if not self.game.data.maps[mapId] then
    return nil, "unknown map: " .. tostring(mapId)
  end
  if opts and (opts.arrive == "fly" or opts.arrive == "teleport") then
    ow.arriveWarp = opts.arrive
  end
  ow:startWarpTo(mapId, x, y, facing or "down", opts and opts.onDone,
                 { via = "warp", keepMusic = opts and opts.keepMusic })
  return true
end

-- save.objectToggles is the same store the spawn filter reads, so a toggle
-- on an inactive map takes effect the next time it is entered.
function WorldAPI:toggleObject(mapId, objName, visible)
  local save = self.game and self.game.save
  if not save then return nil, "no save" end
  save.objectToggles = save.objectToggles or {}
  save.objectToggles[mapId] = save.objectToggles[mapId] or {}
  save.objectToggles[mapId][objName] = visible and true or false
  Runtime.emit("world.object_toggled",
    { mapId = mapId, objName = objName, visible = visible and true or false })
  local ow = self:overworld()
  if ow and ow.map and ow.map.id == mapId then
    ow:setMap(mapId, ow.player.cellX, ow.player.cellY, ow.player.facing,
              { seamless = true, via = "reload", keepMusic = true })
  end
  return true
end

function WorldAPI:setFlag(name, value)
  local save = self.game and self.game.save
  if not save or not save.flags then return nil, "no save" end
  if value then Flags.set(save, name) else Flags.clear(save, name) end
  return true
end

function WorldAPI:getFlag(name)
  local save = self.game and self.game.save
  return save and save.flags and save.flags[name]
end

local ENCOUNTER_TERRAIN = { grass = true, water = true, indoor = true }

-- The effective wild-encounter distribution for a map/terrain, composed with
-- any encounter.table wrapper, without touching the RNG. Unlike a real roll
-- (encounter.roll/encounter.species), this needs no live overworld: mapId is
-- an explicit argument, so a caller can ask about any map from a menu, not
-- only the one the player is standing on.
--
-- "indoor" (caves) has no table of its own -- it reads the same grass table
-- Encounter.roll already gives every cave floor; that is an existing engine
-- behavior, not something new here.
--
-- Weights are the raw per-slot values the vanilla table already encodes
-- (consecutive .buckets/encounterBuckets differences), not normalized to a
-- probability, and are only comparable within one dist. chance is the
-- separate vanilla probability that a step produces any encounter at all;
-- it does not run through encounter.table -- biasing whether an encounter
-- happens at all, as opposed to which species, is a different question this
-- RFC scopes out the same way it scopes out fishing.
function WorldAPI:effectiveEncounters(mapId, terrain, opts)
  if not ENCOUNTER_TERRAIN[terrain] then
    return nil, "invalid terrain: " .. tostring(terrain)
  end
  local data = self.game and self.game.data
  if not (data and type(data.encounters) == "table") then
    return nil, "encounters data not loaded"
  end
  local encDef = data.encounters[mapId]
  local key = (terrain == "indoor") and "grass" or terrain
  local slotDef = encDef and encDef[key]
  local chance = (slotDef and tonumber(slotDef.rate) or 0) / 256
  local dist = {}
  if slotDef and chance > 0 and slotDef.slots then
    local weights = slotDef.buckets
      or FieldDefaults.constant(data, "encounterBuckets")
    local prev = 0
    for i, threshold in ipairs(weights) do
      local slot = slotDef.slots[i]
      if slot and slot.species then
        dist[slot.species] = (dist[slot.species] or 0) + (threshold - prev)
      end
      prev = threshold
    end
  end
  if Runtime.wantsHook("encounter.table") then
    -- A wrapper that forgets to return anything makes Runtime.call itself
    -- return nothing (Hooks:call unpacks an empty pcall result), which would
    -- otherwise turn dist into nil here. Keep the pre-hook dist instead of
    -- handing a caller a nil they will pairs() over and crash on.
    local transformed = Runtime.call("encounter.table",
      function(d) return d end, dist,
      { mapId = mapId, terrain = terrain, preview = true })
    if type(transformed) == "table" then dist = transformed end
  end
  return { chance = chance, dist = dist }
end

-- active map only: this mutates the runtime Map and rebuilds the renderer.
-- A layout change that must survive a reload belongs in a maps patch.
function WorldAPI:replaceBlock(bx, by, block)
  local ow = self:overworld()
  if not ow or not ow.map then return nil, NO_OVERWORLD end
  ow:replaceBlock(bx, by, block)
  return true
end

-- objDef uses the same shape as maps[].objects.  Runtime objects are not
-- serialized: a permanent NPC belongs in a maps patch, this is for
-- scripted and dynamic actors the mod re-spawns on map.entered.
function WorldAPI:spawnNpc(mapId, objDef)
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if type(objDef) ~= "table" then return nil, "objDef must be a table" end
  local copy = {}
  for k, v in pairs(objDef) do copy[k] = v end
  return ow:addRuntimeObject(mapId, copy, self.modId)
end

local function copyPresentationPalette(colors)
  if type(colors) ~= "table" or #colors ~= 4 then
    return nil, "OBJ palette must contain exactly four RGB colors"
  end
  local copy, key = {}, {}
  for colorIndex = 1, 4 do
    local color = colors[colorIndex]
    if type(color) ~= "table" or #color ~= 3 then
      return nil, ("OBJ palette color %d must contain exactly three components")
        :format(colorIndex)
    end
    copy[colorIndex] = {}
    for component = 1, 3 do
      local value = color[component]
      if type(value) ~= "number" or value ~= value or value == math.huge
          or value == -math.huge or value ~= math.floor(value)
          or value < 0 or value > 255 then
        return nil, ("OBJ palette color %d component %d must be an integer in 0..255")
          :format(colorIndex, component)
      end
      copy[colorIndex][component] = value
      key[#key + 1] = ("%02x"):format(value)
    end
  end
  return copy, "gen1-mod-obj:" .. table.concat(key)
end


function WorldAPI:createPresentation(mapId, spec)
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if GameVersion.generation() ~= 1 then
    return nil, "presentation objects are currently Gen 1 only"
  end
  if type(spec) ~= "table" then return nil, "presentation spec must be a table" end
  if not (ow.map and ow.map.id == mapId)
      and not (ow.isNeighborMap and ow:isNeighborMap(mapId)) then
    return nil, "map is not live"
  end
  if type(spec.x) ~= "number" or spec.x ~= spec.x
      or spec.x == math.huge or spec.x == -math.huge
      or type(spec.y) ~= "number" or spec.y ~= spec.y
      or spec.y == math.huge or spec.y == -math.huge then
    return nil, "position must contain finite x and y numbers"
  end
  if spec.drawOrder ~= nil and (type(spec.drawOrder) ~= "number"
      or spec.drawOrder ~= spec.drawOrder
      or spec.drawOrder == math.huge or spec.drawOrder == -math.huge) then
    return nil, "draw order must be a finite number or nil"
  end
  if spec.terrainOcclusion ~= nil and type(spec.terrainOcclusion) ~= "boolean" then
    return nil, "terrain occlusion must be a boolean"
  end
  if spec.terrainOcclusion and (spec.drawOrder ~= nil or spec.layers ~= nil) then
    return nil, "terrain occlusion requires a single spatial appearance"
  end
  local palette, paletteGroup
  if spec.objPaletteOverride ~= nil then
    palette, paletteGroup = copyPresentationPalette(spec.objPaletteOverride)
    if not palette then return nil, paletteGroup end
  end
  presentationSequence = presentationSequence + 1
  local id = tostring(self.modId) .. "_presentation_" .. presentationSequence
  local appearance, err = PresentationObject.appearance(self.game.data, spec, id,
    palette, paletteGroup)
  if not appearance then return nil, err end
  local object = PresentationObject.new(self.game.data, mapId, spec, id,
    presentationSequence, appearance)
  object.objPaletteOverride, object.objPaletteGroup = palette, paletteGroup
  object.sprite:setGen1ObjPaletteOverride(palette, paletteGroup)
  ow.presentations = ow.presentations or {}
  ow.presentations[mapId] = ow.presentations[mapId] or {}
  table.insert(ow.presentations[mapId], object)
  return setmetatable({ ow = ow, game = self.game, id = id,
                        modId = self.modId, presentation = object },
                       PresentationHandle)
end

function WorldAPI:liveMaps()
  local ow = self:overworld()
  if not ow or not ow.map then return nil, NO_OVERWORLD end
  return ow:liveMaps()
end

function WorldAPI:removeNpc(npcId)
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  return ow:removeRuntimeObject(npcId, self.modId)
end

-- a handle onto a live NPC: scriptMove / marchInPlace / face, which is
-- everything the scripted-movement queue exposes
local Handle = {}
Handle.__index = Handle

-- Ground contact resources belong to the spawning mod's loader lifetime.
function Handle:canStartOffensiveStep(dir, options)
  return require("src.world.OffensiveContact").canStart(self, dir, options)
end

function Handle:startOffensiveStep(dir, options)
  local token, err = require("src.world.OffensiveContact").start(self, dir, options)
  if not token then return nil, err end
  return require("src.world.TransitionImpact").wrap(token, self)
end

function Handle:scriptMove(dir, tiles, onDone)
  self.ow:scriptMove(self.npc, dir, tiles or 1, onDone)
  return true
end

function Handle:marchInPlace(onDone)
  self.ow:marchInPlace(self.npc, onDone)
  return true
end

function Handle:face(dir)
  self.npc.facing = dir
  return true
end

-- Compose with other owners without taking script, collision or player locks.
function Handle:acquireAutonomousPause()
  return require("src.world.AutonomousPause").acquire(self.npc, self.resourceOwner)
end

-- Opt-in protection against deferred seam resets, scoped to the spawning mod.
function Handle:acquireSeamlessPositionContinuity()
  return require("src.world.SeamlessPositionContinuity").acquire(self)
end

-- Native gameplay facing; liveNpc guards identity and live-map membership.
function Handle:getFacing()
  local stack = self.game and self.game.stack
  if not containsActor(stack and stack.states, self.ow) then
    return nil, "NPC runtime is no longer live"
  end
  local facing = self.npc.facing
  if facing ~= "up" and facing ~= "right" and facing ~= "down" and facing ~= "left" then
    return nil, "NPC facing must be up, right, down or left"
  end
  return facing
end

function Handle:position()
  return self.npc.cellX, self.npc.cellY
end

function Handle:physicalPosition()
  return self.npc:physicalPosition()
end

-- Local Porygonal prototype: cells and cells per engine second.
function Handle:moveDirect(x, y, speed, facing)
  local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
  end
  if not finite(x) or not finite(y) or not finite(x * 16) or not finite(y * 16) then
    return nil, "destination must contain finite cell coordinates and pixel positions"
  end
  if not finite(speed) or speed <= 0 then return nil, "speed must be finite and positive (cells/second)" end
  if facing ~= nil and not Collision.DELTA[facing] then return nil, "bad direction: " .. tostring(facing) end
  local npc = self.npc
  if npc.moving then return nil, "already moving" end
  if not npc.passable then return nil, "direct movement requires a passable NPC" end
  for _, move in ipairs(self.ow.scriptMoves or {}) do
    if move.entity == npc then return nil, "NPC has queued scripted movement" end
  end
  if self.ow.marchers and self.ow.marchers[npc] then return nil, "NPC is marching" end
  return npc:moveDirect(x, y, speed, facing)
end

-- Per-body native step speed; nil restores the body's original cadence.
function Handle:getStepSpeed()
  return self.npc:getStepSpeed()
end

function Handle:setStepSpeed(cellsPerSecond)
  return self.npc:setStepSpeed(cellsPerSecond)
end

function Handle:directMovementState()
  return self.npc:directMovementState()
end

function Handle:cancelDirectMovement()
  self.npc:cancelDirectMovement()
  return true
end

-- Walk one tile starting NOW, outside the scripted-movement queue.
--
-- scriptMove queues onto OverworldState.scriptMoves, and a non-empty
-- scriptMoves is how the overworld knows a cutscene is running -- it gates
-- handleInput (OverworldController "local scripted = ... #self.scriptMoves >
-- 0"), so an actor animated that way freezes the player's controls for as
-- long as it walks.  That is right for Oak marching to his lab and wrong for
-- an actor that moves on its own schedule: a networked player's ghost, an
-- ambient walker.  This is the same per-tile state scriptMove sets, minus
-- the queue and therefore minus the lockout.
--
-- Collision is deliberately not checked.  The caller is replaying a move
-- that was already decided somewhere else (validated on the peer's machine,
-- or authored), and re-judging it here would let the two copies disagree
-- about where the actor is.  Use canStep first if you want the check.
function Handle:stepNow(dir)
  local npc = self.npc
  if not Collision.DELTA[dir] then return nil, "bad direction: " .. tostring(dir) end
  if npc.moving then return nil, "already moving" end
  npc.directMovementResult = nil
  npc.facing = dir
  npc.targetX, npc.targetY = Collision.target(npc.cellX, npc.cellY, dir)
  npc.moving = true
  npc.progress = 0
  return true
end

-- Would stepNow land somewhere legal?  Exposed separately so a caller that
-- does want the map's opinion can ask for it without giving up the "replay
-- verbatim" default above.
function Handle:canStep(dir)
  local ow = self.ow
  if not (ow and ow.map) then return false end
  if self.ghost then
    return Collision.canMove(self.ghost.map, self.ghost.peers, self.npc, dir)
      and true or false
  end
  return Collision.canMove(ow.map, ow.entities, self.npc, dir) and true or false
end

-- Snap to a cell with no animation: a warp arrival, or a resync that has
-- drifted too far to walk off.  Clears any step in flight so the entity
-- cannot land on its old target a frame later.
function Handle:placeAt(x, y, facing)
  local npc = self.npc
  npc:cancelDirectMovement()
  npc.moving = false
  npc.marching = false
  npc.targetX, npc.targetY = nil, nil
  npc.progress = 0
  npc.cellX, npc.cellY = x, y
  npc.px, npc.py = x * 16, y * 16
  if facing then npc.facing = facing end
  return true
end

-- True while a step is still animating, so a driver can pace itself rather
-- than stomping a move in flight.
function Handle:isMoving()
  return self.npc.moving and true or false
end

-- Fraction of the current native NPC step; nil while idle.
function Handle:movementProgress()
  return self.npc:movementProgress()
end

-- Whether the player may walk through this object (Collision.occupied skips
-- passable entities -- Yellow's companion Pikachu is the engine's own user
-- of the flag).  It still draws and can still be talked to; it just stops
-- being an obstacle, which is what a dynamic actor wants when standing in a
-- doorway would otherwise wall someone in.
function Handle:setPassable(passable)
  if self.npc.directMovement and not passable then
    return nil, "cannot make an active direct movement solid; cancel it first"
  end
  self.npc.passable = passable and true or false
  return true
end

-- Runtime NPC OBJ override; SpriteRenderer applies it only in Gen 1 Advanced.
function Handle:setObjPaletteOverride(colors)
  return self.npc:setObjPaletteOverride(colors)
end

-- Runtime presentation flag, independent of the selected sprite.
-- Temporary instance visibility: no save, movement or collision changes.
-- Reacquire by identity so pooled seamless crossings remain valid, while
-- removed/reconstructed bodies and outgoing overworld handles are refused.
function Handle:setVisible(visible)
  local api = WorldAPI.new(self.game)
  if api:overworld() ~= self.ow then return nil, "NPC runtime is no longer live" end
  local live, err = api:npc(self.mapId, self.id)
  if not live or live.npc ~= self.npc then return nil, err or "NPC is no longer live" end
  if type(visible) ~= "boolean" then return nil, "visibility must be a boolean" end
  self.npc.visible = visible
  return true
end

function Handle:setGroundShadow(enabled)
  self.npc.groundShadow = enabled and true or false
  return true
end

-- Resolve again so removed NPCs, invalidated maps and stale runtimes reject
-- updates, while seamless promotion/demotion keeps the same actor state.
function Handle:setGroundShadowOffset(xPx, yPx)
  local api = WorldAPI.new(self.game)
  if api:overworld() ~= self.ow then return nil, "NPC runtime is no longer live" end
  local live, err = api:npc(self.npc.mapId or self.mapId or
    (self.ghost and self.ghost.map.id) or self.ow.map.id, self.id)
  if not live or live.npc ~= self.npc then return nil, err or "NPC is no longer live" end
  return GroundShadow.setOffset(self.npc, xPx, yPx)
end

-- Presentation only: overworld cells above the physical Ground Anchor.
function Handle:setVisualElevation(cells)
  if type(cells) ~= "number" or cells < 0 or cells ~= cells
      or cells == math.huge then
    return nil, "visual elevation must be a finite non-negative number of cells"
  end
  self.npc.visualElevation = cells
  return true
end

function Handle:setAppearance(spriteId)
  local data = self.game and self.game.data
  local spriteDef = data and data.sprites and data.sprites[spriteId]
  if not spriteDef then return nil, "unknown sprite: " .. tostring(spriteId) end
  self.npc:setAppearance(spriteId, spriteDef)
  return true
end

local function matches(npc, indexOrName)
  return npc.def.index == indexOrName or npc.def.name == indexOrName
    or npc.id == indexOrName
end

-- All public NPC operations resolve the original body in the live runtime.
-- A pooled map promotion retains identity; reconstruction with the same ID
-- does not. Validation precedes every read/mutation, including placeAt.
local function liveNpc(handle)
  if not (handle.ow and handle.ow.map) then return nil, "NPC runtime is no longer live" end
  local api = WorldAPI.new(handle.game)
  if api:overworld() ~= handle.ow then return nil, "NPC runtime is no longer live" end
  local mapId = handle.npc.mapId or handle.mapId
  local current, err = api:npc(mapId, handle.id)
  if not current or current.npc ~= handle.npc then
    return nil, err or "NPC is no longer live"
  end
  return true
end

for _, name in ipairs({"scriptMove", "marchInPlace", "face", "getFacing", "position",
    "physicalPosition", "stepNow", "canStep", "placeAt", "isMoving",
    "canStartOffensiveStep", "startOffensiveStep",
    "acquireAutonomousPause", "acquireSeamlessPositionContinuity", "movementProgress", "getStepSpeed", "setStepSpeed", "moveDirect", "directMovementState", "cancelDirectMovement",
    "setPassable", "setObjPaletteOverride", "setGroundShadow",
    "setGroundShadowOffset", "setVisualElevation", "setAppearance", "setVisible"}) do
  local method = Handle[name]
  Handle[name] = function(self, ...)
    local ok, err = liveNpc(self)
    if not ok then return nil, err end
    local contact = self.npc.offensiveContact
    if contact and ({scriptMove=true, marchInPlace=true, face=true,
        stepNow=true, placeAt=true, moveDirect=true, cancelDirectMovement=true,
        setPassable=true, setStepSpeed=true, setVisualElevation=true,
        setAppearance=true})[name] then
      return nil, "offensive segment owns NPC physics; reconcile first"
    end
    return method(self, ...)
  end
end

-- Rosters can still contain outgoing bodies between pool replacement and
-- rebuildGhosts. The native pool certifies exact identity, not just a reused ID.
-- Small roster-only fixtures have no pool; native Gen 1 worlds always do.
local function currentNpc(ow, mapId, npc)
  return npc.mapId == mapId
    and (not ow.npcPool or ow.npcPool[npc.id] == npc)
end

function WorldAPI:npc(mapId, indexOrName)
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if ow.map and ow.map.id ~= mapId then
    if not (ow.isNeighborMap and ow:isNeighborMap(mapId)) then
      return nil, "map is not live"
    end
    for _, g in ipairs(ow.ghosts or {}) do
      if g.map.id == mapId and currentNpc(ow, mapId, g.npc)
          and matches(g.npc, indexOrName) then
        return setmetatable({ ow = ow, game = self.game, npc = g.npc,
                              id = g.npc.id, mapId = mapId, ghost = g,
                              resourceOwner = self.resourceOwner, modId = self.modId,
                              resourceLoader = self.resourceLoader }, Handle)
      end
    end
    return nil, "no such object: " .. tostring(indexOrName)
  end
  for _, npc in ipairs(ow.npcs or {}) do
    if currentNpc(ow, mapId, npc) and matches(npc, indexOrName) then
      return setmetatable({ ow = ow, game = self.game, npc = npc, id = npc.id, mapId = mapId,
                            resourceOwner = self.resourceOwner, modId = self.modId,
                              resourceLoader = self.resourceLoader },
                          Handle)
    end
  end
  return nil, "no such object: " .. tostring(indexOrName)
end

-- Resolve the current map and roster, never the ghost/peers captured by a
-- handle. Reads require the original world in the stack and a current caller
-- lifetime, including for vanilla NPCs queried through a mod facade.
local function navigationContext(handle)
  local game, ow, body = handle.game, handle.ow, handle.npc
  if not game or not ow or not ow.map
      or not containsActor(game.stack and game.stack.states, ow)
      or WorldAPI.new(game):overworld() ~= ow then
    return nil, "NPC runtime is no longer live"
  end
  local owner, loader = handle.resourceOwner, handle.resourceLoader
  if game.mods ~= loader or (owner and owner.closed)
      or (handle.modId and (not owner or owner.modId ~= handle.modId
        or not loader or not loader.resourceOwners
        or loader.resourceOwners[handle.modId] ~= owner)) then
    return nil, "NPC navigation owner context is no longer live"
  end
  if ow.preparingLiveMaps then return nil, "live maps are being prepared" end
  if not body or body.id ~= handle.id or body.mapId ~= handle.mapId
      or (ow.npcPool and ow.npcPool[handle.id] ~= body) then
    return nil, "NPC is no longer live"
  end
  local map, peers
  if ow.map.id == handle.mapId then
    map, peers = ow.map, ow.entities or {}
    if not containsActor(ow.npcs, body) then return nil, "NPC is no longer live" end
  else
    for _, neighbor in ipairs(ow.neighbors or {}) do
      if neighbor.map.id == handle.mapId then map = neighbor.map; break end
    end
    if not map then return nil, "map is not live" end
    peers = {}
    for _, ghost in ipairs(ow.ghosts or {}) do
      if ghost.map == map then peers[#peers + 1] = ghost.npc end
    end
  end
  if not containsActor(peers, body) then return nil, "NPC is no longer live" end
  return map, peers
end

-- Detached booleans for any zero-based integer cell on the body's live map.
-- Solid terrain remains inspectable: callers apply their own landing/perch
-- rules. Only non-passable native bodies occupy/reserve; ignore this exact NPC.
function Handle:navigationCell(x, y)
  local map, peers = navigationContext(self)
  if not map then return nil, peers end
  if not validBlockCoordinate(x) or not validBlockCoordinate(y) then
    return nil, "cell coordinates must be finite integers"
  end
  local result = {inBounds = map:inBounds(x, y), walkable = false,
    water = false, warp = false, occupied = false, reserved = false}
  if not result.inBounds then return result end
  result.walkable = not not map:isWalkableCell(x, y)
  result.water = not not map:isWaterCell(x, y)
  result.warp = not not map:warpAtCell(x, y)
  for _, body in ipairs(peers) do
    if body ~= self.npc and not body.passable then
      if body.cellX == x and body.cellY == y then result.occupied = true end
      local contact = body.offensiveContact
      if (body.targetX == x and body.targetY == y)
          or (contact and contact.destination.x == x and contact.destination.y == y) then
        result.reserved = true
      end
    end
  end
  return result
end

-- Native bounds/terrain/ingress/warp/occupancy verdict for a candidate source,
-- without relocating or copying the requester (identity and surfing stay real).
-- true; false, bounds/tile/warp/entity; or nil, invalid-context/input error.
-- Observations do not reserve a destination: revalidate immediately before
-- executing a movement command, and again at landing if the world can change.
function Handle:canStepFrom(x, y, dir)
  local map, peers = navigationContext(self)
  if not map then return nil, peers end
  if not validBlockCoordinate(x) or not validBlockCoordinate(y) then
    return nil, "cell coordinates must be finite integers"
  end
  if not Collision.DELTA[dir] then return nil, "bad direction: " .. tostring(dir) end
  return Collision.queryMove(map, peers, self.npc, dir, x, y)
end

-- FIFO queueing is owned by the script runner; until it lands this runs
-- the rows when nothing else is running and refuses otherwise, so a mod
-- never silently loses a script.
function WorldAPI:queueScript(rows, extra)
  local ow = self:overworld()
  if not ow or not ow.runner then return nil, NO_OVERWORLD end
  if ow.runner:isRunning() then return nil, "a script is already running" end
  ow.runner:run(rows, extra)
  return true
end

-- The supported way to start a wild encounter.  Hand-rolling this -- build a
-- BattleState, push it -- silently costs evolutions and blackout-on-loss
-- (both hang off onFinish -> afterBattle) plus the entry wipe and battle
-- theme (both owned by pushBattle).  Nothing raises when they are missing.
function WorldAPI:startWildBattle(species, level)
  local contactWorld = self:overworld()
  if contactWorld and next(contactWorld.offensiveContacts or {}) then
    return nil, "reconcile offensive segments before Battle entry"
  end
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if not self.game.data.pokemon[species] then
    return nil, "unknown species: " .. tostring(species)
  end
  -- Pokemon.new writes the level through verbatim -- into level, the stat
  -- calc and the exp curve -- so a fraction has to be refused here rather
  -- than round somewhere downstream.  The % test also catches NaN, which
  -- passes both range comparisons.
  level = tonumber(level)
  if not level or level % 1 ~= 0 or level < 1 or level > 100 then
    return nil, "level must be a whole number 1..100"
  end
  -- overworld() resolves the world from UNDER whatever sits on top of it,
  -- so from a battle hook this would otherwise stack a second battle over
  -- the live one -- and on a loss its afterBattle blacks out and warps
  -- with the outer battle still on the stack.
  local BattleTransition = require("src.render.BattleTransition")
  for _, state in ipairs(self.game.stack and self.game.stack.states or {}) do
    if state.isCreatureAcquisition then return nil, "an acquisition is already running" end
    if state.awardExp or getmetatable(state) == BattleTransition then
      return nil, "a battle is already running"
    end
  end
  if ow.transitioning then return nil, "the world is mid-warp" end
  -- BattleState.newWild marks the species SEEN before it reports an empty
  -- party, so the party check comes first: a refused call must not leave a
  -- Pokedex entry behind.
  local save = self.game.save
  if not (save and Party.firstHealthy(save.party or {})) then
    return nil, "no healthy party"
  end
  local battle = require("src.battle.BattleState")
    .newWild(self.game, species, level)
  battle.onFinish = function(result) ow:afterBattle(result, battle) end
  ow:pushBattle(battle)
  return true
end

-- Resolve an owned public handle once; the guard never resolves by ID alone.
local function transitionSurvivor(api, ow, handle)
  if getmetatable(handle) ~= Handle or handle.game ~= api.game
      or handle.ow ~= ow or handle.mapId ~= ow.map.id then
    return nil, "transition survivor must be a live NPC handle on the active map"
  end
  local owner, body = api.resourceOwner, handle.npc
  if not owner or owner.closed or handle.resourceOwner ~= owner
      or owner.modId ~= api.modId or type(body) ~= "table"
      or type(body.def) ~= "table" or not body.def.runtime or body.def.owner ~= api.modId then
    return nil, "transition survivor is not owned by this mod lifetime"
  end
  local map, loader = ow.map, api.game.mods
  local generation = ow.offensiveGeneration or 0
  local original = {game=api.game, ow=ow, npc=body, mapId=handle.mapId, id=handle.id}
  local function valid()
    if owner.closed or api.game.mods ~= loader or api:overworld() ~= ow
        or ow.map ~= map or (ow.offensiveGeneration or 0) ~= generation
        or body.visible == false or body.def.owner ~= api.modId then return false end
    local live = liveNpc(original)
    if not live then return false end
    for _, entity in ipairs(ow.entities or {}) do
      if entity == body then return true end
    end
    return false
  end
  if not valid() then return nil, "transition survivor is not live and visible" end
  return body, valid
end

-- Gen 1 additive profile entry. Completion runs once at native onFinish,
-- after afterBattle has been invoked (its queued evolution UI may remain).
function WorldAPI:startWildBattleWithProfile(profile, opts)
  local contactWorld = self:overworld()
  if contactWorld and next(contactWorld.offensiveContacts or {}) then
    return nil, "reconcile offensive segments before Battle entry"
  end
  if GameVersion.generation() ~= 1 then return nil, "creature profiles support Gen 1 only" end
  local ow = self:overworld()
  if not ow then return nil, NO_OVERWORLD end
  if opts ~= nil and (type(opts) ~= "table" or getmetatable(opts) ~= nil) then
    return nil, "opts must be a plain table"
  end
  opts = opts or {}
  for key in pairs(opts) do
    if key ~= "onComplete" and key ~= "transitionSurvivor" and key ~= "transitionImpactProof" then return nil, "unknown profile battle option" end
  end
  if opts.onComplete ~= nil and type(opts.onComplete) ~= "function" then
    return nil, "onComplete must be a function"
  end
  local survivor, survivorValid
  if opts.transitionSurvivor ~= nil then
    survivor, survivorValid = transitionSurvivor(self, ow, opts.transitionSurvivor)
    if not survivor then return nil, survivorValid end
  end
  if opts.transitionImpactProof ~= nil and not survivor then
    return nil, "transitionImpactProof requires transitionSurvivor"
  end
  local CreatureAPI = require("src.mods.CreatureAPI")
  local ok, err = CreatureAPI.validate(self.game.data, profile)
  if not ok then return nil, err end
  if profile.hp <= 0 then return nil, "profile is fainted" end
  local BattleTransition = require("src.render.BattleTransition")
  for _, state in ipairs(self.game.stack and self.game.stack.states or {}) do
    if state.isCreatureAcquisition then return nil, "an acquisition is already running" end
    if state.awardExp or getmetatable(state) == BattleTransition then
      return nil, "a battle is already running"
    end
  end
  if ow.transitioning then return nil, "the world is mid-warp" end
  local save = self.game.save
  if not (save and Party.firstHealthy(save.party or {})) then return nil, "no healthy party" end
  local impact
  if opts.transitionImpactProof ~= nil then
    local err
    impact, err = require("src.world.TransitionImpact").prepare(
      opts.transitionImpactProof, self.game, ow, survivor, self.resourceOwner, survivorValid)
    if not impact then return nil, err end
  end
  local working = CreatureAPI.copy(profile)
  local battle = require("src.battle.BattleState").newWild(self.game,
    working.species, working.level, nil, working)
  local complete, callback = false, opts.onComplete
  battle.onFinish = function(result, endCause)
    if complete then return end
    complete = true
    local disposition = "return_to_caller"
    if result == "caught" then
      disposition = battle.captureStored and "transferred_to_player" or "capture_unconfirmed"
    end
    local outcome = {result=result, disposition=disposition, battle=battle,
      endCause=endCause or require("src.battle.EndCause").get(battle, result)}
    if disposition ~= "transferred_to_player" then outcome.profile = CreatureAPI.copy(working) end
    ow:afterBattle(result, battle)
    if callback then callback(outcome) end
  end
  if survivorValid and not survivorValid() then
    return nil, "transition survivor invalidated during Battle construction"
  end
  if impact then
    local ok, err = impact:claim()
    if not ok then return nil, err end
  end
  ow:pushBattle(battle, survivor, survivorValid, impact)
  return true
end

-- drop a map's cached instance so the next load re-reads its record; when
-- it is the active map the world reloads around the player in place
function WorldAPI:invalidateMap(mapId)
  local ow = self:overworld()
  if not ow then
    local had = MapLoader.invalidate(mapId)
    Runtime.emit("map.reloaded", { mapId = mapId, reason = "invalidate" })
    return had
  end
  local ok, err = pcall(ow.reloadMap, ow, mapId, "invalidate")
  if not ok then
    Logger.warn("[%s] invalidateMap %s failed: %s", tostring(self.modId),
                tostring(mapId), tostring(err))
    return nil, tostring(err)
  end
  return true
end

return WorldAPI
