-- Caller-owned persistent Gen 1 creature profiles. No world identity here.
local Pokemon = require("src.pokemon.Pokemon")
local Stats = require("src.pokemon.Stats")
local Status = require("src.battle.Status")
local CreatureAPI = {}
local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n >= lo and n <= hi
    and n == math.floor(n)
end
local function plain(t)
  return type(t) == "table" and getmetatable(t) == nil
end
local function fields(t, allowed)
  if not plain(t) then return false end
  for k in pairs(t) do if not allowed[k] then return false end end
  return true
end
local statKeys = {hp=true, attack=true, defense=true, speed=true, special=true}
local profileKeys = {species=true, level=true, exp=true, dvs=true, statExp=true,
  stats=true, hp=true, status=true, moves=true, catchRate=true,
  nickname=true, ot=true, otId=true, traded=true}
local function active(data, species, level)
  if not data or not data.pokemon or not data.moves then
    return nil, "no active creature dataset"
  end
  local def = type(species) == "string" and data.pokemon[species]
  if not def then return nil, "unknown species" end
  if not integer(level, 1, 100) then return nil, "level must be an integer 1..100" end
  -- Check every constructor dependency before its first DV draw.
  if not plain(def.baseStats) or not plain(def.level1Moves) or not plain(def.learnset)
      or not integer(def.catchRate, 0, 255) then return nil, "invalid species dataset" end
  for _, k in ipairs(Stats.ORDER) do
    if not integer(def.baseStats[k], 1, 255) then return nil, "invalid base stats" end
  end
  for _, id in ipairs(def.level1Moves) do
    if type(id) ~= "string" or not data.moves[id] then return nil, "invalid starting move" end
  end
  for _, row in ipairs(def.learnset) do
    if not plain(row) or not integer(row.level, 1, 100)
        or type(row.move) ~= "string" or not data.moves[row.move] then
      return nil, "invalid learnset"
    end
  end
  for _, id in ipairs(Pokemon.movesAtLevel(def, level)) do
    if not integer(data.moves[id].pp, 1, 63) then return nil, "invalid move PP" end
  end
  return true
end
function CreatureAPI.validate(data, profile)
  if not fields(profile, profileKeys) then return nil, "invalid profile fields" end
  local ok, err = active(data, profile.species, profile.level)
  if not ok then return nil, err end
  if not integer(profile.exp, 0, 16777215) or not integer(profile.catchRate, 0, 255) then
    return nil, "invalid exp or catchRate"
  end
  for _, block in ipairs({"dvs", "statExp", "stats"}) do
    if not fields(profile[block], statKeys) then return nil, "invalid " .. block end
    for _, k in ipairs(Stats.ORDER) do
      local lo, hi = 0, 65535
      if block == "dvs" then hi = 15 elseif block == "stats" then lo = 1 end
      if not integer(profile[block][k], lo, hi) then return nil, "invalid " .. block .. "." .. k end
    end
  end
  local d = profile.dvs
  if d.hp ~= (d.attack % 2)*8 + (d.defense % 2)*4 + (d.speed % 2)*2 + d.special % 2 then
    return nil, "invalid derived HP DV"
  end
  if not integer(profile.hp, 0, profile.stats.hp) then return nil, "invalid hp" end
  if profile.status ~= nil and (type(profile.status) ~= "string"
      or not (data.statuses or Status.RECORDS)[profile.status]) then return nil, "invalid status" end
  if not plain(profile.moves) or #profile.moves < 1 or #profile.moves > 4 then
    return nil, "invalid moves"
  end
  for k in pairs(profile.moves) do
    if not integer(k, 1, #profile.moves) then return nil, "invalid move slot" end
  end
  for i = 1, #profile.moves do
    local mv = profile.moves[i]
    if not fields(mv, {id=true, pp=true, ppUps=true}) or type(mv.id) ~= "string"
        or not data.moves[mv.id] then return nil, "invalid move" end
    local ups = mv.ppUps or 0
    local pp = data.moves[mv.id].pp
    if not integer(pp, 1, 63) or not integer(ups, 0, 3)
        or not integer(mv.pp, 0, pp + ups * math.floor(pp / 5)) then return nil, "invalid PP" end
  end
  for _, key in ipairs({"nickname", "ot"}) do
    if profile[key] ~= nil and (type(profile[key]) ~= "string" or #profile[key] > 128) then
      return nil, "invalid " .. key
    end
  end
  if profile.otId ~= nil and not integer(profile.otId, 0, 65535) then return nil, "invalid otId" end
  if profile.traded ~= nil and type(profile.traded) ~= "boolean" then return nil, "invalid traded" end
  return true
end
-- Explicit projection excludes all battler/turn/presentation state.
function CreatureAPI.copy(profile)
  local out = {}
  for key in pairs(profileKeys) do
    local value = profile[key]
    if key == "moves" then
      out.moves = {}
      for i, mv in ipairs(value) do out.moves[i] = {id=mv.id, pp=mv.pp, ppUps=mv.ppUps} end
    elseif type(value) == "table" then
      out[key] = {}
      for k in pairs(statKeys) do out[key][k] = value[k] end
    else out[key] = value end
  end
  return out
end
function CreatureAPI.new(currentGame, currentGeneration)
  local function data()
    if currentGeneration and currentGeneration() ~= 1 then return nil, "creature profiles support Gen 1 only" end
    local game = currentGame()
    return game and game.data
  end
  return {
    createWildProfile = function(_, spec)
      local dataset, err = data()
      if err then return nil, err end
      if not fields(spec, {species=true, level=true}) then return nil, "invalid creation spec" end
      local ok; ok, err = active(dataset, spec.species, spec.level)
      if not ok then return nil, err end
      return Pokemon.new(dataset, spec.species, spec.level, love.math.random)
    end,
    validateProfile = function(_, profile)
      local dataset, err = data()
      if err then return nil, err end
      return CreatureAPI.validate(dataset, profile)
    end,
    acquireProfile = function(_, profile, opts)
      local dataset, err = data()
      if err then return nil, err end
      local ok; ok, err = CreatureAPI.validate(dataset, profile)
      if not ok then return nil, err end
      return require("src.pokemon.Acquisition").start(currentGame(), profile, opts)
    end,
  }
end
return CreatureAPI
