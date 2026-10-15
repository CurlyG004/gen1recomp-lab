-- Loader-owned transient resources. A retired scope cannot acquire again.
local ResourceOwner = {}
ResourceOwner.__index = ResourceOwner

function ResourceOwner.new(modId)
  return setmetatable({modId = modId, resources = {}, closed = false}, ResourceOwner)
end

function ResourceOwner:add(resource)
  if self.closed then return nil, "mod resource owner is retired" end
  self.resources[resource] = true
  return true
end

function ResourceOwner:forget(resource)
  self.resources[resource] = nil
end

function ResourceOwner:releaseAll()
  self.closed = true
  while next(self.resources) do
    local resource = next(self.resources)
    resource:release()
  end
end

return ResourceOwner
