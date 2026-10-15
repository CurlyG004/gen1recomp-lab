-- Local Porygonal prototype: controlled access to the vanilla Gen 1 Bag.
local Bag = require("src.inventory.Bag")
local BagAPI = {}

local function integer(n)
  return type(n) == "number" and n == n and n > -math.huge
    and n < math.huge and n == math.floor(n)
end

function BagAPI.new(currentGame, currentGeneration)
  local function resolve(id, mutate)
    if currentGeneration() ~= 1 then return nil, "bag supports Gen 1 only" end
    local game = currentGame()
    local save, data = game and game.save, game and game.data
    if not save or type(save.inventory) ~= "table" then
      return nil, "no active Bag save"
    end
    if not data or type(data.items) ~= "table" then return nil, "no active item dataset" end
    if type(id) ~= "string" or not data.items[id] or Bag.isBadge(id) then
      return nil, "unknown Bag item (expected an active item id)"
    end
    local states = game.stack and game.stack.states or {}
    local active, battle
    for i = 1, #states do
      local state = states[i]
      if state.isOverworld and state.map then active = true end
      if state.isBattleState or state.isBattle then active, battle = true, true end
    end
    if not active then return nil, "no active gameplay context" end
    local top = states[#states]
    if mutate and (battle or not top or not top.isOverworld or not top.map) then
      return nil, "Bag consumption requires the normal overworld without native UI or Battle"
    end
    local count = save.inventory[id]
    if count == nil then count = 0 end
    if not integer(count) or count < 0 then return nil, "invalid saved item quantity" end
    return save, count, data
  end
  -- Closures only: no save, inventory, game or data reference in the facade.
  return {
    quantity = function(_, id)
      local save, count = resolve(id, false)
      if not save then return nil, count end
      return count
    end,
    consume = function(_, id, qty)
      if not integer(qty) or qty <= 0 then
        return nil, "quantity must be a positive finite integer"
      end
      local save, count, data = resolve(id, true)
      if not save then return nil, count end
      if count < qty then return false, "insufficient quantity" end
      -- No yield, callbacks or gameplay effects between check and vanilla removal.
      Bag.remove(save, id, qty, data)
      return true
    end,
  }
end

return BagAPI
