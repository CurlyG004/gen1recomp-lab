-- Map object (NPC/item) built from a generated object_event entry.

local Collision = require("src.world.Collision")
local SpriteRenderer = require("src.render.SpriteRenderer")
local GroundShadow = require("src.render.GroundShadow")

local NPC = {}
NPC.__index = NPC

local STEP_FRAMES = 32

local FACING_FROM_RANGE = {
  DOWN = "down", UP = "up", LEFT = "left", RIGHT = "right",
}

-- .randomMovement -- pokered engine/overworld/movement.asm:190
local ROAM_DIRS = {
  ANY_DIR = { "up", "down", "left", "right" },
  NONE = { "up", "down", "left", "right" },
  UP_DOWN = { "up", "down" },
  LEFT_RIGHT = { "left", "right" },
}

-- The sprite sheet path NPC.new will load for a map object (nil when the
-- object's sprite is unknown).  Pure; shares SpriteRenderer.imagePath.
function NPC.spriteImagePath(data, objDef)
  local spriteDef = data and data.sprites and data.sprites[objDef.sprite]
  return SpriteRenderer.imagePath(spriteDef)
end

function NPC.new(data, mapId, objDef)
  local self = setmetatable({}, NPC)
  self.mapId = mapId
  self.def = objDef
  self.id = string.format("%s_obj_%d", mapId, objDef.index)
  local spriteDef = data.sprites[objDef.sprite]
  assert(spriteDef, "unknown sprite " .. tostring(objDef.sprite))
  self.sprite = SpriteRenderer.new(spriteDef, self.id)
  -- pokeyellow engine/pikachu/pikachu_movement.asm:917
  self.shadowImg = GroundShadow.image(data)
  -- object_event coordinates are already walk-grid cells
  self.cellX, self.cellY = objDef.x, objDef.y
  self.px, self.py = self.cellX * 16, self.cellY * 16
  self.facing = FACING_FROM_RANGE[objDef.range] or "down"
  self.moving = false
  self.progress = 0
  self.animClock = 0
  self.stepFlip = false
  self.visible = true -- runtime representation only; movement/collision are independent
  self.groundShadow = false
  self.groundShadowOffsetX, self.groundShadowOffsetY = 0, 0
  self.visualElevation = 0
  self.frozen = false -- scripts freeze NPCs while talking
  -- pokered engine/overworld/movement.asm:611
  local turnDirs = ROAM_DIRS[objDef.range or "NONE"]
  self.steps = objDef.movement == "WALK"
  -- .determineDirection -- pokered engine/overworld/movement.asm:193
  self.pinnedFacing = objDef.movement == "STAY"
                      and FACING_FROM_RANGE[objDef.range] or nil
  self.wanders = (self.steps or objDef.movement == "STAY")
                 and (turnDirs ~= nil or self.pinnedFacing ~= nil)
  self.roamDirs = turnDirs or ROAM_DIRS.ANY_DIR
  self.timer = love.math.random(30, 120)
  return self
end

-- LoadMapHeader .loadSpriteData zeroes the sprite state data and re-seeds
-- MAPY/MAPX from the map header -- home/overworld.asm:2133
function NPC:setAppearance(spriteId, spriteDef)
  if not spriteDef then return false end
  self.appearances = self.appearances or { [self.def.sprite] = self.sprite }
  local renderer = self.appearances[spriteId]
  if not renderer then
    renderer = SpriteRenderer.new(spriteDef, self.id)
    if self.objPaletteOverride then
      renderer:setGen1ObjPaletteOverride(self.objPaletteOverride, self.objPaletteGroup)
    end
    self.appearances[spriteId] = renderer
  end
  self.sprite = renderer
  self.appearance = spriteId
  return true
end

local function copyObjPalette(colors)
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

function NPC:setObjPaletteOverride(colors)
  local palette, group
  if colors ~= nil then
    palette, group = copyObjPalette(colors)
    if not palette then return nil, group end
  end
  self.objPaletteOverride = palette
  self.objPaletteGroup = group
  local function apply(renderer)
    if renderer then renderer:setGen1ObjPaletteOverride(palette, group) end
  end
  apply(self.sprite)
  for _, renderer in pairs(self.appearances or {}) do apply(renderer) end
  return true
end

-- Direct motion is an optional segment in the existing NPC update/pose lifecycle.
function NPC:cancelDirectMovement()
  if not self.directMovement then self.directMovementResult = nil; return end
  self.directMovement, self.directMovementResult = nil, nil
  self.targetX, self.targetY = nil, nil
  self.moving, self.marching, self.hopStep = false, false, nil
  self.progress = 0
end

function NPC:moveDirect(x, y, speed, facing)
  local sx, sy = self:physicalPosition()
  local dx, dy = x - sx, y - sy
  local scale = math.max(math.abs(dx), math.abs(dy))
  local distance = scale == 0 and 0 or scale * math.sqrt((dx / scale)^2 + (dy / scale)^2)
  if distance ~= distance or distance == math.huge then return nil, "segment length must be finite" end
  local duration = distance / speed
  if duration == math.huge or (distance > 0 and duration == 0) then
    return nil, "segment duration must be finite and positive"
  end
  if facing then
    self.facing = facing
  elseif distance > 0 then
    if math.abs(dx) > math.abs(dy) then
      self.facing = dx > 0 and "right" or "left"
    else
      self.facing = dy > 0 and "down" or "up"
    end
  end
  self.directMovementResult = nil
  self.marching, self.hopStep = false, nil
  self.progress = 0
  self.cellX, self.cellY = sx, sy
  if distance == 0 then
    self.px, self.py = x * 16, y * 16
    self.cellX, self.cellY = x, y
    self.targetX, self.targetY = nil, nil
    self.moving = false
    self.directMovementResult = {status = "arrived", progress = 1}
    return true
  end
  self.directMovement = {x = sx, y = sy, dx = dx, dy = dy, duration = duration, elapsed = 0}
  self.targetX, self.targetY = x, y
  self.moving = true
  return true
end

function NPC:directMovementState()
  if self.directMovement then return {status = "moving", progress = self.progress} end
  if self.directMovementResult then return {status = "arrived", progress = 1} end
  return nil
end

function NPC:resetToSpawn()
  self:cancelDirectMovement()
  local def = self.def
  self.cellX, self.cellY = def.x, def.y
  self.px, self.py = self.cellX * 16, self.cellY * 16
  self.facing = FACING_FROM_RANGE[def.range] or "down"
  self.targetX, self.targetY = nil, nil
  self.moving = false
  self.marching = false
  self.hopStep = nil
  self.progress = 0
  self.animClock = 0
  self.stepFlip = false
  self.timer = love.math.random(30, 120)
end

function NPC:facePlayer(player)
  local dx = player.cellX - self.cellX
  local dy = player.cellY - self.cellY
  if math.abs(dx) > math.abs(dy) then
    self.facing = dx > 0 and "right" or "left"
  else
    self.facing = dy > 0 and "down" or "up"
  end
end

-- Native locomotion remains tick-based; the override never changes direct motion.
function NPC:nativeStepLength()
  return self.stepSpeedFrames or self.stepFrames or STEP_FRAMES
end

function NPC:getStepSpeed()
  return 60 / self:nativeStepLength(), self.stepSpeedOverride
end

function NPC:setStepSpeed(speed)
  local frames
  if speed ~= nil then
    if type(speed) ~= "number" or speed ~= speed or speed <= 0 or speed == math.huge then
      return nil, "step speed must be finite and positive (cells/second), or nil"
    end
    frames = 60 / speed
    if frames < 1 or frames > 9007199254740991 then
      return nil, "step duration must be representable and at least one logic tick"
    end
  end
  if self.moving then return nil, "already moving" end
  self.stepSpeedOverride, self.stepSpeedFrames = speed, frames
  return true
end

function NPC:update(map, entities, dt)
  if self.offensiveContact and self.offensiveContact.halted then return end
  local segment = self.directMovement
  if segment then
    -- Default remains one fixed 60 Hz engine tick for existing callers.
    dt = dt or 1 / 60
    if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt == math.huge then
      error("NPC update dt must be finite and non-negative")
    end
    segment.elapsed = math.min(segment.duration, segment.elapsed + dt)
    -- Roundoff at the last tick must not leave a microscopic residual move.
    if segment.duration - segment.elapsed <= segment.duration * 1e-14 then
      segment.elapsed = segment.duration
    end
    self.progress = segment.elapsed / segment.duration
    self.animClock = (self.animClock or 0) + dt * 60
    local x = segment.x + self.progress * segment.dx
    local y = segment.y + self.progress * segment.dy
    if self.progress >= 1 then x, y = self.targetX, self.targetY end
    self.cellX, self.cellY = x, y
    self.px, self.py = x * 16, y * 16
    if self.progress >= 1 then
      self.directMovement = nil
      self.targetX, self.targetY = nil, nil
      self.moving = false
      self.progress = 0
      self.stepFlip = not self.stepFlip
      self.directMovementResult = {status = "arrived", progress = 1}
    end
    return
  end
  -- engine/overworld/movement.asm:301, 32 frames per NPC cell; stepFrames is
  -- the follower's own step length (#410, #409).
  local stepLen = self:nativeStepLength()
  local span = self.hopStep and 2 or 1
  if self.moving then
    self.progress = self.progress + 1
    self.animClock = (self.animClock or 0) + 1
    -- NPC_CHANGE_FACING (movement.asm ChangeFacingDirection): walk cycle in
    -- place, no translation.
    if self.marching then
      if self.progress >= stepLen then
        self.progress = 0
        self.moving = false
        self.marching = false
        self.stepFlip = not self.stepFlip
      end
      return
    end
    local d = Collision.DELTA[self.facing]
    -- 1px per 2 frames at the default length; a shortened step scales instead,
    -- so the cell still lands on a 16px boundary (Player:update does the
    -- same for the bicycle)
    local moved = math.floor(self.progress * 16 * span / stepLen)
    self.px = self.cellX * 16 + d[1] * moved
    self.py = self.cellY * 16 + d[2] * moved
    if self.progress >= stepLen then
      self.cellX, self.cellY = self.targetX, self.targetY
      self.targetX, self.targetY = nil, nil
      self.px, self.py = self.cellX * 16, self.cellY * 16
      self.moving = false
      self.hopStep = nil
      self.stepFlip = not self.stepFlip
    end
    return
  end
  if self.frozen or self.autonomousPauses or not self.wanders then return end
  self.timer = self.timer - 1
  if self.timer > 0 then return end
  -- TryWalking + CanWalkOntoTile .impassable -- movement.asm:262, 673
  if self.pinnedFacing then
    self.timer = love.math.random(1, 128)
    self.facing = self.pinnedFacing
    return
  end
  self.timer = love.math.random(30, 180)
  local dir = self.roamDirs[love.math.random(#self.roamDirs)]
  self.facing = dir
  -- pokered engine/overworld/movement.asm:262
  if not self.steps then return end
  if love.math.random() < 0.5 then return end -- sometimes just turn
  -- never wander onto warps, so NPCs don't walk out of the map
  local tx, ty = Collision.target(self.cellX, self.cellY, dir)
  if map:warpAtCell(tx, ty) then return end
  if Collision.canMove(map, entities, self, dir) then
    self.targetX, self.targetY = tx, ty
    self.moving = true
    self.progress = 0
  end
end

-- UpdateNPCSprite branches to NotYetMoving while BIT_FONT_LOADED is set
-- -- engine/overworld/movement.asm:139
local function textBoxUp()
  local stack = require("src.core.Game").stack
  local top = stack and stack.top and stack:top()
  return top ~= nil and not top.isOverworld
end

function NPC:walkPhase()
  if not self.moving or textBoxUp() then return 0 end
  -- engine/overworld/movement.asm:301
  local p = (self.animClock or 0) % 16
  return (p >= 4 and p < 12) and 1 or 0
end

-- Same contract as Player:pose; an NPC never hops, so the trailing hop
-- flag is always false.
function NPC:movementProgress()
  if self.directMovement then return self.progress end
  if not self.moving then return nil end
  local stepLen = self:nativeStepLength()
  return math.min(1, math.max(0, self.progress / stepLen))
end

function NPC:physicalPosition()
  return self.px / 16, self.py / 16
end

function NPC:pose()
  local flip = self.stepFlip
  if self.moving then
    flip = math.floor((self.animClock or 0) / 16) % 2 == 1
  end
  local renderedPy = self.py - self.visualElevation * 16
  return self.sprite, self.px, renderedPy, self.facing,
         self:walkPhase(), flip, false
end

-- Configured offsets opt into the projected ground pass. Keep the zero
-- offset's legacy draw path exactly intact (including vanilla tilt/hops).
function NPC:drawGroundShadow(camX, camY)
  if self.visible == false then return true end
  if self.groundShadowOffsetX == 0 and self.groundShadowOffsetY == 0 then return false end
  if self.shadowImg and (self.hopShadowY or self.groundShadow) then
    GroundShadow.draw(self.shadowImg, self.px, self.hopShadowY or self.py,
      camX, camY, self.groundShadowOffsetX, self.groundShadowOffsetY)
  end
  return true
end

function NPC:draw(camX, camY, shadowAlreadyDrawn)
  if self.visible == false then return end
  local sprite, px, py, facing, phase, flip = self:pose()
  -- pokeyellow engine/pikachu/pikachu_movement.asm:865
  if not shadowAlreadyDrawn and self.shadowImg and (self.hopShadowY or self.groundShadow) then
    -- Project from the physical ground anchor, including during a hop.
    local groundY = self.hopShadowY or self.py
    GroundShadow.draw(self.shadowImg, self.px, groundY, camX, camY,
                      self.groundShadowOffsetX, self.groundShadowOffsetY)
  end
  sprite:draw(px, py, camX, camY, facing, phase, flip, nil, nil,
              self.frameOverride)
end

return NPC
