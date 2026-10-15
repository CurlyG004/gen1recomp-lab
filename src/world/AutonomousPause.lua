-- Tokens never expose or strongly retain bodies, handles or overworlds.
local Pause = {}
local states = setmetatable({}, {__mode = "k"})
local Token = {}
local tokenMetatable = {__index = Token, __metatable = "autonomous pause token"}
local Record = {}
Record.__index = Record

function Record:release()
  local body = self.body and self.body[1]
  if body and body.autonomousPauses then
    body.autonomousPauses[self] = nil
    if not next(body.autonomousPauses) then body.autonomousPauses = nil end
  end
  if self.owner then self.owner:forget(self) end
  self.body, self.owner = nil, nil
  return true
end

function Token:release()
  local record = states[self]
  if not record then return nil, "invalid autonomous pause token" end
  return record:release()
end

function Pause.acquire(body, owner)
  if not owner then return nil, "autonomous pause requires a loader-owned mod" end
  local record = setmetatable({body = setmetatable({body}, {__mode = "v"}),
    owner = owner}, Record)
  local ok, err = owner:add(record)
  if not ok then return nil, err end
  body.autonomousPauses = body.autonomousPauses or {}
  body.autonomousPauses[record] = true
  local token = setmetatable({}, tokenMetatable)
  states[token] = record
  return token
end

function Pause.invalidate(body)
  while body.autonomousPauses do
    next(body.autonomousPauses):release()
  end
end

return Pause
