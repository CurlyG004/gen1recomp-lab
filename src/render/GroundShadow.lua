-- Compose the version's extracted LedgeHoppingShadow at a physical ground
-- position. Red/Blue use a 2x2 mirrored tile; Yellow uses one mirrored row.
local GameVersion = require('src.core.GameVersion')

local GroundShadow = {}
local imageCache = {}

function GroundShadow.image(data)
  local fx = data.field and data.field.overworldFx
  local path = fx and fx.shadow and fx.shadow.path
  if not path then return nil end
  local hit = imageCache[path]
  if hit ~= nil then return hit or nil end
  local ok, img = pcall(love.graphics.newImage, path)
  imageCache[path] = ok and img or false
  return imageCache[path] or nil
end

-- Integer render pixels in the ground canvas (before the tilt projection).
-- Validation is shared by NPC and Presentation Object; failed updates are atomic.
function GroundShadow.setOffset(actor, x, y)
  local function valid(v)
    return type(v) == "number" and v == v and v ~= math.huge
      and v ~= -math.huge and v % 1 == 0
  end
  if not valid(x) or not valid(y) then
    return nil, "ground shadow offset must contain finite integer pixels"
  end
  actor.groundShadowOffsetX, actor.groundShadowOffsetY = x, y
  return true
end

function GroundShadow.bounds(px, groundY, camX, camY, offsetX, offsetY)
  local yellow = GameVersion.isYellow()
  local sx = math.floor(px - camX) + (offsetX or 0)
  local sy = math.floor(groundY - camY) + (yellow and 8 or 4) + (offsetY or 0)
  return sx, sy, 16, yellow and 8 or 16
end

function GroundShadow.draw(image, px, groundY, camX, camY, offsetX, offsetY)
  if not image then return end
  local yellow = GameVersion.isYellow()
  local sx, sy = GroundShadow.bounds(px, groundY, camX, camY, offsetX, offsetY)
  love.graphics.draw(image, sx, sy)
  love.graphics.draw(image, sx + 16, sy, 0, -1, 1)
  if not yellow then
    love.graphics.draw(image, sx, sy + 16, 0, 1, -1)
    love.graphics.draw(image, sx + 16, sy + 16, 0, -1, -1)
  end
end

return GroundShadow
