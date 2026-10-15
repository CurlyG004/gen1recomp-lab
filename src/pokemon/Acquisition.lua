-- Gen 1 acquisition of an existing persistent individual, without a battle.
local Creature = require("src.mods.CreatureAPI")
local Party = require("src.pokemon.Party")
local Boxes = require("src.pokemon.Boxes")
local StateStack = require("src.core.StateStack")
local TextBox = require("src.render.TextBox")
local Screens = require("src.ui.Screens")
local Runtime = require("src.mods.Runtime")
local Sound = require("src.core.Sound")
local Strings = require("src.core.Strings")
local Logger = require("src.core.Logger")
local Acquisition = {}
-- Native table identity is the key; no field is added to serialized mons.
-- Values cannot reveal or retain the mon. Weak keys expire with native storage.
local acquiredByMon = setmetatable({}, {__mode = "k"})
local opaque = {__metatable = "acquired creature association",
  __newindex = function() error("acquired association is opaque", 2) end}
local function association(mon)
  local ref = acquiredByMon[mon]
  if not ref then
    ref = setmetatable({}, opaque)
    acquiredByMon[mon] = ref
  end
  return ref
end
local active = setmetatable({}, {__mode = "k"})
local Session = {}
Session.__index = Session

local function plain(t) return type(t) == "table" and getmetatable(t) == nil end
local function list(t)
  if not plain(t) then return false end
  for k, v in pairs(t) do
    if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #t
        or type(v) ~= "table" then return false end
  end
  for i = 1, #t do if t[i] == nil then return false end end
  return true
end

-- Preview Boxes' current policy without invoking ensure (which mutates saves).
local function destination(save)
  if not plain(save) or not list(save.party) or #save.party > Party.MAX
      or not plain(save.player) or type(save.player.name) ~= "string" then
    return nil, "invalid player storage"
  end
  local id = save.player.id
  if id ~= nil and (type(id) ~= "number" or id ~= id or id % 1 ~= 0
      or id < 0 or id > 65535) then return nil, "invalid player Trainer ID" end
  local dex = save.pokedex
  if dex ~= nil and (not plain(dex) or not plain(dex.seen) or not plain(dex.owned)) then
    return nil, "invalid Pokedex"
  end
  if #save.party < Party.MAX then return "party" end
  if save.boxes == nil then
    if save.box ~= nil and not list(save.box) then return nil, "invalid legacy box" end
    return "box", save.box and #save.box >= Boxes.CAPACITY and 2 or 1
  end
  if not plain(save.boxes) then return nil, "invalid boxes" end
  for i = 1, Boxes.COUNT do
    if not list(save.boxes[i]) then return nil, "invalid box " .. i end
  end
  local current = save.currentBox or 1
  if type(current) ~= "number" or current ~= current or current % 1 ~= 0 then
    return nil, "invalid current box"
  end
  current = math.max(1, math.min(Boxes.COUNT, current))
  for off = 0, Boxes.COUNT - 1 do
    local i = ((current - 1 + off) % Boxes.COUNT) + 1
    if #save.boxes[i] < Boxes.CAPACITY then return "box", i end
  end
  return nil, "all boxes are full"
end

function Session:contextValid()
  local game = self.game
  if type(self.stack.states) ~= "table" then return false end
  local worldPresent = false
  for _, state in ipairs(self.stack.states) do
    if state == self.ow then worldPresent = true; break end
  end
  return worldPresent and game.save == self.save and game.data == self.data
    and game.stack == self.stack and self.ow.map == self.map
    and self.map.id == self.mapId
    and not self.ow.transitioning
end

function Session:snapshot()
  local out = {phase = self.phase, complete = self.done == true,
    transferred = self.transferred == true,
    disposition = self.transferred and "transferred_to_player" or "return_to_caller",
    destination = self.destination, box = self.box, ok = self.ok, error = self.error,
    isNew = self.isNew, acquired = self.acquired}
  if self.done and not self.transferred then out.profile = Creature.copy(self.original) end
  return out
end

function Session:notify(key)
  if self.notified[key] then return end
  self.notified[key] = true
  local fn = self.callbacks[key]
  if not fn then return end
  local ok, err = pcall(fn, self:snapshot())
  if not ok then
    self.ok, self.error = false, key .. " callback failed: " .. tostring(err)
    pcall(Logger.warn, "%s", self.error)
    return nil, self.error
  end
  return true
end

function Session:finish(err)
  if self.done then return end
  self.done, self.ok = true, err == nil
  self.error, self.phase = err, "complete"
  -- Detach only our host, never pop a caller's unrelated UI.
  for i = #self.stack.states, 1, -1 do
    if self.stack.states[i] == self then table.remove(self.stack.states, i); break end
  end
  pcall(self.uiStack.clear, self.uiStack)
  if err and self.fanfare and self.fanfare.stop then pcall(self.fanfare.stop, self.fanfare) end
  self.fanfare = nil
  if active[self.game] == self then active[self.game] = nil end
  self:notify("onComplete")
  self.working = nil -- storage owns it after commit; no recoverable copy is retained
end

function Session:exit()
  self:finish("acquisition UI interrupted")
end

function Session:guard(fn)
  if self.done then return end
  if not self:contextValid() then self:finish("acquisition context changed"); return end
  local ok, err = pcall(fn)
  if not ok then self:finish(tostring(err)) end
end

function Session:update(dt)
  self:guard(function()
    if not self.started then
      self.started = true
      self:message("_ItemUseBallText05", "All right!\n%s was\vcaught!", "Caught_Mon",
        function() self:commit() end)
    else
      self.uiStack:update(dt)
      if not self.done and not self.uiStack:top() then
        self:finish("acquisition screen closed without completion")
      end
    end
    if not self.done then
      local base = self.uiStack.states[self.uiStack:visibleBase()]
      self.isOpaque = base and base.isOpaque or false
    end
  end)
end

function Session:draw()
  self:guard(function() self.uiStack:draw() end)
end

function Session:text(id, fallback)
  local raw = (self.data.text or {})[id]
  if type(raw) ~= "string" then return Strings(fallback, self.name) end
  return raw:gsub("\t", "\n"):gsub("{RAM:?[%w_]*}", function() return self.name end)
end

function Session:message(id, fallback, sound, nextStep)
  self.phase = id
  local opts
  if sound then
    opts = TextBox.soundOpts(self.uiGame, function()
      -- Audio is optional. Native TextBox still owns the wait and music ducking.
      local ok, src = pcall(Sound.play, self.data, sound)
      if not ok then pcall(Logger.warn, "acquisition SFX %s failed: %s", sound, tostring(src)) end
      self.fanfare = ok and src or nil
      return ok and src or nil
    end)
  end
  self.uiStack:push(TextBox.new(self.uiGame, self:text(id, fallback), nextStep, opts))
end

-- Detect insertion even when a storage implementation raises after inserting.
function Session:locate()
  for _, mon in ipairs(self.save.party) do
    if mon == self.working then return "party" end
  end
  for i, box in ipairs(self.save.boxes or {}) do
    for _, mon in ipairs(box) do if mon == self.working then return "box", i end end
  end
end

function Session:commit()
  if self.transferred or self.done then return end
  if not self:contextValid() then error("acquisition context changed") end
  local dest, box = destination(self.save)
  if not dest then error(box) end
  local dex, species = self.save.pokedex, self.working.species
  self.isNew = dex ~= nil and not dex.owned[species] or false
  -- Prepare OT on an isolated player record. No player/Dex mutation on refusal.
  local player = {}
  for k, v in pairs(self.save.player) do player[k] = v end
  require("src.battle.BattleState").stampOT({player = player}, self.working)
  local ok, result = pcall(function()
    if dest == "party" then return Party.add(self.save.party, self.working) end
    return Boxes.deposit(self.save, self.working)
  end)
  self.destination, self.box = self:locate()
  if not self.destination then error(ok and "storage refused acquisition" or result) end
  self.acquired = association(self.working)
  self.transferred, self.phase = true, "custodyConfirmed"
  self.original = nil
  self.save.player.id = player.id
  if dex then dex.seen[species], dex.owned[species] = true, true end
  local _, callbackError = self:notify("onCustodyConfirmed")
  if self.done then return end -- callbacks may interrupt/clear the host
  if callbackError then error(callbackError) end
  if not ok then error(result) end
  if not self:contextValid() then error("acquisition context changed") end
  Runtime.emit("pokemon.caught", {mon = self.working, species = species,
    isNew = self.isNew, destination = self.destination, box = self.box,
    transferred = true, source = "acquisition", game = self.game})
  if self.done then return end
  if self.isNew then
    self:message("_ItemUseBallText06", "New POKéDEX data\nwill be added for\n%s!",
      "Dex_Page_Added", function()
        self.phase = "pokedex"
        self.uiStack:push(Screens.build(self.uiGame, "DexEntryMenu", species,
          function() self:nickname() end))
      end)
  else self:nickname() end
end

function Session:nickname()
  if self.done then return end
  if Runtime.wantsHook("catch.nickname") then
    local verdict = Runtime.call("catch.nickname", function() return true end,
      self.working, {name = self.name, game = self.game, source = "acquisition"})
    if self.done then return end
    if verdict == false then self:afterNaming(); return end
    if type(verdict) == "string" then
      verdict = verdict:sub(1, 10) -- existing hook convention
      if #verdict > 0 then self.working.nickname = verdict end
      self:afterNaming(); return
    end
  end
  self.phase = "nickname"
  self.uiStack:push(TextBox.new(self.uiGame,
    self:text("_DoYouWantToNicknameText", "Do you want to\ngive a nickname\nto %s?"), nil,
    {choice = function(yes)
      if not yes then self:afterNaming(); return end
      self.phase = "naming"
      self.uiStack:push(Screens.build(self.uiGame, "NamingScreen", {
        title = Strings("NICKNAME?"), maxLen = 10, mon = self.working,
        onDone = function(name)
          if name and #name > 0 then self.working.nickname = name end
          self:afterNaming()
        end,
      }))
    end}))
end

function Session:afterNaming()
  if self.done then return end
  if self.destination == "box" then
    local metBill = self.save.flags and self.save.flags.EVENT_MET_BILL
    self:message(metBill and "_ItemUseBallText07" or "_ItemUseBallText08",
      metBill and "%s was\ntransferred to\nBILL's PC!"
        or "%s was\ntransferred to\nsomeone's PC!", nil, function() self:finish() end)
  else self:finish() end
end

function Acquisition.start(game, profile, opts)
  if opts == nil then opts = {} end
  if not plain(opts) then return nil, "opts must be a plain table" end
  for k, v in pairs(opts) do
    if (k ~= "onCustodyConfirmed" and k ~= "onComplete") or type(v) ~= "function" then
      return nil, "invalid acquisition option: " .. tostring(k)
    end
  end
  if not game or not game.stack or type(game.stack.push) ~= "function"
      or type(game.stack.top) ~= "function" or type(game.stack.states) ~= "table"
      or not game.input or type(game.input.wasPressed) ~= "function"
      or type(game.input.isDown) ~= "function" then return nil, "no acquisition UI context" end
  if active[game] then return nil, "an acquisition is already running" end
  local ow = game.stack:top()
  if not ow or not ow.isOverworld or not ow.map then return nil, "overworld must be the top state" end
  if ow.transitioning or (ow.runner and ow.runner:isRunning())
      or #(ow.scriptMoves or {}) > 0 then return nil, "overworld is busy" end
  local dest, err = destination(game.save)
  if not dest then return nil, err end
  local s = setmetatable({game = game, save = game.save, data = game.data,
    stack = game.stack, ow = ow, map = ow.map, mapId = ow.map.id, original = Creature.copy(profile),
    working = Creature.copy(profile), callbacks = {onCustodyConfirmed = opts.onCustodyConfirmed,
      onComplete = opts.onComplete}, notified = {}, phase = "pending",
    isCreatureAcquisition = true}, Session)
  s.name = profile.nickname or game.data.pokemon[profile.species].name or profile.species
  s.uiStack = setmetatable({}, {__index = StateStack}); s.uiStack:init()
  -- Native screens share input/save/data/renderer; only their stack is scoped.
  s.uiGame = setmetatable({stack = s.uiStack}, {__index = game})
  active[game] = s
  local ok, pushError = pcall(game.stack.push, game.stack, s)
  if not ok then
    -- Synchronous refusal: no notifications, no mutation, input still caller-owned.
    s.callbacks = {}; s:finish("UI push failed: " .. tostring(pushError))
    return nil, s.error
  end
  local handle = {}
  function handle:getState()
    if not s.done then
      local present = false
      for _, state in ipairs(s.stack.states or {}) do if state == s then present = true end end
      if not present or not s:contextValid() then s:finish("acquisition UI interrupted") end
    end
    return s:snapshot()
  end
  return handle
end

return Acquisition
