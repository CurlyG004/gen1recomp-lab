-- Private exact-body leases. Tokens expose no world/body/owner references.
local Continuity = {}
local bodies = setmetatable({}, {__mode = "k"})
local states = setmetatable({}, {__mode = "k"})
local Token, Record = {}, {}
Record.__index = Record
local tokenMetatable = {
  __index = Token, __metatable = "seamless position continuity token",
}

function Record:release()
  local body = self.refs and self.refs.body
  local leases = body and bodies[body]
  if leases then
    leases[self] = nil
    if not next(leases) then bodies[body] = nil end
  end
  if self.owner then self.owner:forget(self) end
  self.refs, self.owner = nil, nil
  return true
end

function Token:release()
  local record = states[self]
  if not record then return nil, "invalid seamless position continuity token" end
  return record:release()
end

local function valid(record, body, ow)
  local refs, owner = record.refs, record.owner
  if not refs or not owner or owner.closed or refs.body ~= body or refs.ow ~= ow
      or not ow.map or not ow.npcPool or ow.npcPool[body.id] ~= body
      or not body.def.runtime or body.def.owner ~= owner.modId then return false end
  local game = refs.game
  if not game or game.mods ~= refs.loader then return false end
  for _, state in ipairs(game.stack and game.stack.states or {}) do
    if state == ow then return true end
  end
  return false
end

function Continuity.acquire(handle)
  local owner, body, ow = handle.resourceOwner, handle.npc, handle.ow
  if not owner then return nil, "continuity requires a loader-owned mod" end
  if owner.closed then return nil, "mod resource owner is retired" end
  if not handle.modId or owner.modId ~= handle.modId
      or not body.def.runtime or body.def.owner ~= handle.modId then
    return nil, "NPC is not owned by this mod lifetime"
  end
  local record = setmetatable({owner = owner, refs = setmetatable({
    body = body, ow = ow, game = handle.game, loader = handle.resourceLoader,
  }, {__mode = "v"})}, Record)
  if not valid(record, body, ow) then return nil, "NPC body is not live" end
  local ok, err = owner:add(record)
  if not ok then return nil, err end
  bodies[body] = bodies[body] or {}
  bodies[body][record] = true
  -- Cancel an existing request without moving the body or changing its spawn.
  body.pendingSpawnReset = nil
  local token = setmetatable({}, tokenMetatable)
  states[token] = record
  return token
end

function Continuity.active(body, ow)
  local leases = bodies[body]
  if not leases then return false end
  local active = false
  for record in pairs(leases) do
    if valid(record, body, ow) then active = true else record:release() end
  end
  return active
end

function Continuity.invalidate(body)
  local leases = bodies[body]
  while leases and next(leases) do next(leases):release() end
end

-- Scan only leased bodies, including an old body displaced from the pool.
-- Call after live rosters settle; setMap's arming phase precedes that rebuild.
function Continuity.prune(ow, live)
  for body, leases in pairs(bodies) do
    for record in pairs(leases) do
      if record.refs and record.refs.ow == ow
          and (not live or not live[body] or not valid(record, body, ow)) then
        record:release()
      end
    end
  end
end

return Continuity
