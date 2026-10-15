-- Gen 1 gameplay resolution only. No BattleState, profile or presentation.
local Catching = require("src.battle.Catching")
local Status = require("src.battle.Status")
local PokemonAPI = {}

local function integer(n)
  return type(n) == "number" and n == n and n > -math.huge
    and n < math.huge and n == math.floor(n)
end

function PokemonAPI.new(currentGame, currentGeneration)
  return {
    attemptCatch = function(_, spec)
      if currentGeneration and currentGeneration() ~= 1 then
        return nil, "attemptCatch supports Gen 1 only"
      end
      if type(spec) ~= "table" then return nil, "capture spec must be a table" end
      local game = currentGame()
      local data = game and game.data
      if not data or not data.pokemon then return nil, "no active Pokemon dataset" end
      if type(spec.species) ~= "string" or not data.pokemon[spec.species] then
        return nil, "unknown species (expected an active species id)"
      end
      local targetDef = data.pokemon[spec.species]
      local ballDef = type(spec.ball) == "string"
        and ((data.balls and data.balls[spec.ball]) or Catching.BALLS[spec.ball])
      if not ballDef then return nil, "unknown Ball (expected an active Ball id)" end
      if not integer(spec.maxHp) or spec.maxHp <= 0 then
        return nil, "maxHp must be a positive finite integer"
      end
      if not integer(spec.hp) or spec.hp <= 0 or spec.hp > spec.maxHp then
        return nil, "hp must be a positive finite integer <= maxHp"
      end
      local statuses = data.statuses or Status.RECORDS
      if spec.status ~= nil and (type(spec.status) ~= "string"
          or spec.status == "" or spec.status == "NONE" or not statuses[spec.status]) then
        return nil, "unknown status (omit status for a healthy Pokemon)"
      end
      if spec.rateOverride ~= nil and (not integer(spec.rateOverride)
          or spec.rateOverride < 0 or spec.rateOverride > 255) then
        return nil, "rateOverride must be an integer in 0..255"
      end
      local rate = spec.rateOverride or targetDef.catchRate
      if not integer(rate) or rate < 0 or rate > 255 then
        return nil, "species catchRate must be an integer in 0..255"
      end
      local targetMon = { hp = spec.hp, stats = { hp = spec.maxHp }, status = spec.status }
      -- No catch.rate hook: that hook's contract belongs to BattleState.
      -- Custom attempts receive battle=nil and the existing vanillaAttempt.
      local ok, caught, shakes = pcall(Catching.attempt, spec.ball, targetMon,
        targetDef, love.math.random, spec.rateOverride,
        { ballDef = ballDef, statuses = statuses, battle = nil })
      if not ok then return nil, "capture resolution failed: " .. tostring(caught) end
      if type(caught) ~= "boolean" or not integer(shakes) or shakes < 0
          or shakes > 3 or (caught and shakes ~= 3) then
        return nil, "capture resolution returned invalid caught/shakes"
      end
      return { caught = caught, shakes = shakes }
    end,
  }
end

return PokemonAPI
