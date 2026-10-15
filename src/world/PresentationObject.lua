local SpriteRenderer = require("src.render.SpriteRenderer")

local GroundShadow = require("src.render.GroundShadow")

local PresentationObject = {}
PresentationObject.__index = PresentationObject

local function finiteNumber(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

-- Construct every renderer before publishing any replacement. Layers are
-- render descriptions, not world objects or independently owned resources.
function PresentationObject.appearance(data, spec, id, palette, group)
  local sprites = data and data.sprites
  if not sprites then return nil, "no sprite dataset" end
  if spec.layers ~= nil then
    if spec.sprite ~= nil then return nil, "choose sprite or layers" end
    local layers = spec.layers
    if type(layers) ~= "table" or getmetatable(layers) ~= nil or #layers == 0 then
      return nil, "layers must be a non-empty array"
    end
    for k in pairs(layers) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #layers then
        return nil, "layers must be a dense array"
      end
    end
    local out = {}
    for i = 1, #layers do
      local layer = layers[i]
      if type(layer) ~= "table" or getmetatable(layer) ~= nil then
        return nil, "invalid layer"
      end
      for k in pairs(layer) do
        if k ~= "sprite" and k ~= "phase" and k ~= "order" then
          return nil, "unknown layer property: " .. tostring(k)
        end
      end
      if layer.phase ~= "beforeActors" and layer.phase ~= "afterActors" then
        return nil, "layer phase must be beforeActors or afterActors"
      end
      if layer.order ~= nil and not finiteNumber(layer.order) then
        return nil, "layer order must be finite"
      end
      if type(layer.sprite) ~= "string" or not sprites[layer.sprite] then
        return nil, "unknown layer sprite"
      end
      local ok, renderer = pcall(SpriteRenderer.new, sprites[layer.sprite], id)
      if not ok then return nil, "could not create layer: " .. tostring(renderer) end
      renderer:setGen1ObjPaletteOverride(palette, group)
      out[i] = {sprite = renderer, spriteId = layer.sprite, phase = layer.phase,
        order = layer.order or 0, index = i}
    end
    return {layers = out, sprite = out[1].sprite}
  end
  if type(spec.sprite) ~= "string" or not sprites[spec.sprite] then
    return nil, "unknown sprite: " .. tostring(spec.sprite)
  end
  local ok, renderer = pcall(SpriteRenderer.new, sprites[spec.sprite], id)
  if not ok then return nil, "could not create appearance: " .. tostring(renderer) end
  renderer:setGen1ObjPaletteOverride(palette, group)
  return {sprite = renderer, spriteId = spec.sprite}
end

function PresentationObject.new(data, mapId, spec, id, sequence, appearance)
  local self = setmetatable({}, PresentationObject)
  self.mapId = mapId
  self.id = id
  self.drawSequence = sequence
  self.drawOrder = spec.drawOrder
  self.terrainOcclusion = spec.terrainOcclusion == true
  self.spriteId = appearance.spriteId
  self.sprite = appearance.sprite
  self.renderLayers = appearance.layers
  self.visible = true
  self.groundShadow = false
  self.groundShadowOffsetX, self.groundShadowOffsetY = 0, 0
  self.shadowImg = GroundShadow.image(data)
  self.visualElevation = 0
  self.destroyed = false
  self:setPosition(spec.x, spec.y)
  return self
end

-- nil restores spatial sorting; explicit finite values draw after spatial actors.
function PresentationObject:setDrawOrder(order)
  if order ~= nil and not finiteNumber(order) then
    return nil, "draw order must be a finite number or nil"
  end
  if order ~= nil and self.terrainOcclusion then
    return nil, "terrain occlusion requires spatial draw order"
  end
  self.drawOrder = order
  return true
end

-- Visual terrain participation only; no entity, movement or shadow state.
function PresentationObject:setTerrainOcclusion(enabled)
  if type(enabled) ~= "boolean" then return nil, "terrain occlusion must be a boolean" end
  if enabled and (self.drawOrder ~= nil or self.renderLayers) then
    return nil, "terrain occlusion requires a single spatial appearance"
  end
  self.terrainOcclusion = enabled
  return true
end

-- Logical zero-based index; SpriteRenderer already applies frameOffset.
function PresentationObject:setFrame(index)
  if not finiteNumber(index) or index < 0 or index % 1 ~= 0
      or index >= self.sprite.frameCount then
    return nil, "frame index must be an integer in [0, " .. (self.sprite.frameCount - 1) .. "]"
  end
  for _, layer in ipairs(self.renderLayers or {}) do
    if index >= layer.sprite.frameCount then return nil, "frame is unavailable in a layer" end
  end
  self.frameIndex = index
  return true
end

function PresentationObject:setGroundShadow(enabled)
  if type(enabled) ~= "boolean" then return nil, "ground shadow must be a boolean" end
  self.groundShadow = enabled
  return true
end

function PresentationObject:setGroundShadowOffset(xPx, yPx)
  return GroundShadow.setOffset(self, xPx, yPx)
end

function PresentationObject:drawGroundShadow(camX, camY)
  if self.destroyed or not self.visible or not self.groundShadow then return end
  GroundShadow.draw(self.shadowImg, self.px, self.py, camX, camY,
                    self.groundShadowOffsetX, self.groundShadowOffsetY)
end

function PresentationObject:setPosition(x, y)
  if not finiteNumber(x) or not finiteNumber(y) then
    return nil, "position must contain finite x and y numbers"
  end
  self.x, self.y = x, y
  self.px, self.py = x * 16, y * 16
  return true
end

function PresentationObject:setVisualElevation(cells)
  if not finiteNumber(cells) or cells < 0 then
    return nil, "visual elevation must be a finite non-negative number of cells"
  end
  self.visualElevation = cells
  return true
end

function PresentationObject:setAppearance(spec, data)
  if type(spec) == "string" then spec = {sprite = spec} end
  if type(spec) ~= "table" then return nil, "invalid appearance" end
  if self.terrainOcclusion and spec.layers ~= nil then
    return nil, "terrain occlusion requires a single spatial appearance"
  end
  local appearance, err = PresentationObject.appearance(data, spec, self.id,
    self.objPaletteOverride, self.objPaletteGroup)
  if not appearance then return nil, err end
  self.spriteId, self.sprite, self.renderLayers = appearance.spriteId,
    appearance.sprite, appearance.layers
  self.frameIndex = nil -- Restore the new appearance's ordinary default pose.
  return true
end

function PresentationObject:drawLayer(layer, camX, camY)
  if self.destroyed or not self.visible then return end
  layer.sprite:draw(self.px, self.py - self.visualElevation * 16,
    camX, camY, "down", 0, false, nil, nil, self.frameIndex)
end

function PresentationObject:draw(camX, camY)
  if self.destroyed or not self.visible then return end
  self.sprite:draw(self.px, self.py - self.visualElevation * 16,
                   camX, camY, "down", 0, false,
                   nil, nil, self.frameIndex)
end

return PresentationObject
