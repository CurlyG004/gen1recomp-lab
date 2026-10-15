-- Renderer-owned entries. One presentation may contribute several draws, but
-- transforms, lifecycle and ground shadows belong exclusively to its owner.
local Entries = {}

local function spatialOrder(a, b)
  local aa, bb = a.actor, b.actor
  if (aa.drawOrder ~= nil) ~= (bb.drawOrder ~= nil) then return aa.drawOrder == nil end
  if aa.drawOrder ~= nil then
    if aa.drawOrder ~= bb.drawOrder then return aa.drawOrder < bb.drawOrder end
    return aa.drawSequence < bb.drawSequence
  end
  local ay, by = aa.py + a.oy, bb.py + b.oy
  if ay ~= by then return ay < by end
  if (aa.pikachuFollower == true) ~= (bb.pikachuFollower == true) then
    return aa.pikachuFollower == true
  end
  return a.ordinal < b.ordinal
end

local function layerOrder(a, b)
  if a.layer.order ~= b.layer.order then return a.layer.order < b.layer.order end
  if a.actor.drawSequence ~= b.actor.drawSequence then
    return a.actor.drawSequence < b.actor.drawSequence
  end
  return a.layer.index < b.layer.index
end

local function clear(t)
  for key in pairs(t) do t[key] = nil end
end

local function entry(cache, list, actor, layer, ox, oy, neighbor, active, ghost, map)
  cache.used = cache.used + 1
  local e = cache.pool[cache.used]
  if not e then e = {}; cache.pool[cache.used] = e end
  e.actor, e.layer, e.ox, e.oy = actor, layer, ox, oy
  e.neighbor, e.activeEntity, e.ghost = neighbor, active, ghost
  e.terrainMap = map
  e.ordinal = #list + 1
  list[#list + 1] = e
end

local function add(cache, actor, ox, oy, neighbor, active, ghost, map)
  if actor.destroyed or actor.visible == false then return end
  if actor.renderLayers then
    for _, layer in ipairs(actor.renderLayers) do
      local list = layer.phase == "beforeActors" and cache.before or cache.after
      entry(cache, list, actor, layer, ox, oy, neighbor)
    end
  else
    entry(cache, cache.spatial, actor, nil, ox, oy, neighbor, active, ghost, map)
  end
end

function Entries.collect(ow)
  local cache = ow.presentationEntryCache
  if not cache then
    cache = {before={}, spatial={}, after={}, pool={}, used=0}
    ow.presentationEntryCache = cache
  end
  local before, spatial, after = cache.before, cache.spatial, cache.after
  clear(before); clear(spatial); clear(after)
  local previousUsed = cache.used
  cache.used = 0
  for _, g in ipairs(ow.ghosts or {}) do add(cache, g.npc, g.ox, g.oy, true, nil, g) end
  for _, n in ipairs(ow.neighbors or {}) do
    for _, o in ipairs(ow.presentations and ow.presentations[n.map.id] or {}) do
      add(cache, o, n.ox, n.oy, true, nil, nil, n.map)
    end
  end
  for _, e in ipairs(ow.entities or {}) do
    local actor = ow.transitionActor and ow:transitionActor(e) or e
    add(cache, actor, 0, 0, nil, actor == e and true or nil, nil, ow.map)
  end
  for _, o in ipairs(ow.presentations and ow.presentations[ow.map.id] or {}) do
    add(cache, o, 0, 0)
  end
  -- Reuse the slots without retaining owners retired by a map transition.
  for i = cache.used + 1, previousUsed do clear(cache.pool[i]) end
  table.sort(before, layerOrder)
  table.sort(spatial, spatialOrder)
  table.sort(after, layerOrder)
  return before, spatial, after
end

function Entries.shadows(ow, before, spatial, after, camX, camY, visible)
  local seen = ow.presentationShadowSeen or {}
  local drawn = ow.presentationShadowDrawn or {}
  ow.presentationShadowSeen, ow.presentationShadowDrawn = seen, drawn
  clear(seen); clear(drawn)
  for phase = 1, 3 do
    local list = phase == 1 and before or (phase == 2 and spatial or after)
    for _, entry in ipairs(list) do
      local actor = entry.actor
      if not seen[actor] and actor.drawGroundShadow and visible(entry) then
        seen[actor] = true
        local result = actor:drawGroundShadow(camX - entry.ox, camY - entry.oy)
        -- NPC's zero-offset legacy path returns false and draws in draw().
        drawn[actor] = result ~= false
      end
    end
  end
  return drawn
end

-- Existing active entities retain their source/target cells. Opted-in
-- presentations cover the one-cell ground footprint at their continuous XY:
-- floor/ceil on each axis, including negative coordinates (up to four cells).
function Entries.eachTerrainCell(entry, visit)
  local actor = entry.actor
  if entry.activeEntity then
    visit(actor.cellX, actor.cellY)
    if actor.targetX then visit(actor.targetX, actor.targetY) end
  elseif actor.terrainOcclusion and not entry.layer and actor.drawOrder == nil
      and actor.visualElevation == 0 then
    local x, y = actor.px / 16, actor.py / 16
    local x0, x1, y0, y1 = math.floor(x), math.ceil(x), math.floor(y), math.ceil(y)
    visit(x0, y0)
    if x1 ~= x0 then visit(x1, y0) end
    if y1 ~= y0 then
      visit(x0, y1)
      if x1 ~= x0 then visit(x1, y1) end
    end
  end
end

return Entries
