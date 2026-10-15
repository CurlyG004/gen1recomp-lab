-- Shared, dataset-specific symbolic SFX requests; no backend resource is exposed.
local Sound = require("src.core.Sound")
local AudioAPI = {}

function AudioAPI.new(currentGame, currentGeneration)
  -- Keep engine dependencies in closures, not on the mod-facing table.
  return {
    playSfx = function(_, id)
      if currentGeneration and currentGeneration() == 3 then
        return nil, "playSfx has no Gen 3 adapter"
      end
      if type(id) ~= "string" or id == "" then
        return nil, "SFX id must be a non-empty string"
      end
      local game = currentGame()
      local data = game and game.data
      local sfx = data and data.audio and data.audio.sfx
      if not sfx then return nil, "no active SFX dataset" end
      -- Exact membership is deliberate: internal UI aliases are not public IDs.
      if not sfx[id] then return nil, "unknown SFX id: " .. id end
      local ok, err = pcall(Sound.play, data, id)
      if not ok then return nil, "SFX request failed: " .. tostring(err) end
      -- Valid request forwarded, even if headless or filtered by native policy.
      return true
    end,
  }
end

return AudioAPI
