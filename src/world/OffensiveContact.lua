-- Gen 1 Ground segment, independent of behavior and Battle custody.
local Collision = require('src.world.Collision')
local Runtime = require('src.mods.Runtime')
local Contact = {DEFAULT_IMPACT_DEPTH_PX=8,DEFAULT_IMPACT_TRANSVERSE_PX=8}
local function threshold(options)
  if options~=nil and type(options)~='table' then return nil,'invalid contact options' end
  local n=Contact.DEFAULT_IMPACT_DEPTH_PX
  if options and options.impactDepthPx~=nil then n=options.impactDepthPx end
  if type(n)~='number' or n~=n or n<=0 or n==math.huge then
    return nil,'invalid impact depth'
  end
  local transverse=Contact.DEFAULT_IMPACT_TRANSVERSE_PX
  if options and options.impactTransversePx~=nil then transverse=options.impactTransversePx end
  if type(transverse)~='number' or transverse~=transverse or transverse<=0 or transverse==math.huge then
    return nil,'invalid transverse overlap'
  end
  return n,transverse
end
local Token, Record = {}, {}
Token.__index, Record.__index = Token, Record
local tokens = setmetatable({}, {__mode='k'})
local identities = setmetatable({}, {__mode='k'})
local sequence = 0
local function identity(body)
  if not identities[body] then sequence=sequence+1; identities[body]=sequence end
  return identities[body]
end
local function copy(value)
  if type(value) ~= 'table' then return value end
  local out={}; for k,v in pairs(value) do out[k]=copy(v) end; return out
end
local function same(a,b)
  if type(a)~='table' or type(b)~='table' then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function contains(list, body)
  for _,v in ipairs(list or {}) do if v==body then return true end end
  return false
end
local function live(r,physical)
  local ow, body = r.ow, r.body
  if not ow or not body then return false end
  return ow.map==r.map and ow.player==r.player and contains(ow.npcs,body)
    and contains(ow.entities,body) and body.offensiveContact==r
    and body.def.runtime and body.def.owner==r.modId
    and (physical or r.game.mods==r.loader)
    and contains(r.game.stack and r.game.stack.states,ow)
end
local function ready(r)
  local stack=r.game.stack
  return live(r) and stack and stack:top()==r.ow
    and not r.ow.transitioning and not r.ow.engaging
    and not (r.ow.runner and r.ow.runner:isRunning())
    and #(r.ow.scriptMoves or {})==0
end
local function sample(body, player)
  local sprite, px, py, facing, phase, flip = body:pose()
  local geometry=sprite:getPoseGeometry(facing,phase,flip)
  local x = px+8-sprite.anchorX
  local y = py+12-sprite.anchorY
  local progress
  if body.moving then
    progress=player and math.min(1,body.progress/(body.stepFramesCur or body.stepFrames or 16))
      or body:movementProgress()
  end
  return {identity=identity(body), id=body.id or 'player',
    source={x=body.cellX,y=body.cellY},
    destination=body.targetX and {x=body.targetX,y=body.targetY} or nil,
    physical={x=body.px/16,y=body.py/16},physicalPixels={x=body.px,y=body.py},
    moving=body.moving==true,
    progress=progress, facing=facing, elevation=(body.py-py)/16,
    render={x=px,y=py,facing=facing,phase=phase,stepFlip=flip,
      frame=body.frameOverride or geometry.frame,mirror=geometry.mirror,
      frameOverride=body.frameOverride,definition=copy(sprite.def),
      seed=sprite.seed,frameWidth=sprite.frameWidth,frameHeight=sprite.frameHeight,
      anchorX=sprite.anchorX,anchorY=sprite.anchorY},
    envelope={left=x,top=y,right=x+sprite.frameWidth,bottom=y+sprite.frameHeight}}
end
-- Nominal intersection extents in world pixels; a shared edge has zero extent.
local function overlap(a,b)
  return math.max(0,math.min(a.right,b.right)-math.max(a.left,b.left)),
    math.max(0,math.min(a.bottom,b.bottom)-math.max(a.top,b.top))
end
-- Leading-edge penetration, in world pixels along the authorized direction.
local function depth(a,b,dir)
  if dir=='right' then return a.right-b.left end
  if dir=='left' then return b.right-a.left end
  if dir=='down' then return a.bottom-b.top end
  return b.bottom-a.top
end
local function interpolate(a,b,t)
  local out=copy(b)
  for _,field in ipairs({'physical','physicalPixels','envelope'}) do
    for k,v in pairs(a[field]) do out[field][k]=v+(b[field][k]-v)*t end
  end
  out.render.x=a.render.x+(b.render.x-a.render.x)*t
  out.render.y=a.render.y+(b.render.y-a.render.y)*t
  return out
end
-- Intersect all closed two-axis overlap constraints and positive translation
-- in one interval. Include each rectangle's own extent: crossed edges alone
-- do not imply the threshold when one rectangle contains a smaller rectangle.
local function impact(previous,now,dir,required,transverse,anchor)
  local a,b,c,d=previous.npc.envelope,previous.player.envelope,
    now.npc.envelope,now.player.envelope
  local lo,hi=0,1
  local delta=Collision.DELTA[dir]
  local horizontal=delta[1]~=0
  local requiredX,requiredY=horizontal and required or transverse,
    horizontal and transverse or required
  local function translation(n)
    return (n.physicalPixels.x-anchor.x*16)*delta[1]
      +(n.physicalPixels.y-anchor.y*16)*delta[2]
  end
  for _,v in ipairs({
      {a.right-b.left-requiredX,c.right-d.left-requiredX,false},
      {b.right-a.left-requiredX,d.right-c.left-requiredX,false},
      {a.right-a.left-requiredX,c.right-c.left-requiredX,false},
      {b.right-b.left-requiredX,d.right-d.left-requiredX,false},
      {a.bottom-b.top-requiredY,c.bottom-d.top-requiredY,false},
      {b.bottom-a.top-requiredY,d.bottom-c.top-requiredY,false},
      {a.bottom-a.top-requiredY,c.bottom-c.top-requiredY,false},
      {b.bottom-b.top-requiredY,d.bottom-d.top-requiredY,false},
      {depth(a,b,dir)-required,depth(c,d,dir)-required,false},
      {translation(previous.npc),translation(now.npc),true}}) do
    local start,delta=v[1],v[2]-v[1]
    if delta==0 then
      if start<0 or (v[3] and start==0) then return nil end
    elseif delta>0 then lo=math.max(lo,-start/delta)
    else hi=math.min(hi,-start/delta) end
  end
  if lo>hi or hi<0 or lo>1 then return nil end
  lo,hi=math.max(0,lo),math.min(1,hi)
  local function witness(t)
    local npc=interpolate(previous.npc,now.npc,t)
    local player=interpolate(previous.player,now.player,t)
    local n=depth(npc.envelope,player.envelope,dir)
    local x,y=overlap(npc.envelope,player.envelope)
    if x>=requiredX and y>=requiredY and n>=required and translation(npc)>0 then
      return {fraction=t,npc=npc,player=player,depthPx=n,
        overlapXPx=x,overlapYPx=y},lo,hi
    end
  end
  local result=witness(lo)
  if result then return result,lo,hi end
  if lo<hi then return witness((lo+hi)/2) end
end
local function clearMotion(body)
  body.moving=false; body.marching=false; body.hopStep=nil
  body.targetX,body.targetY=nil,nil; body.progress=0
end
local function forget(r)
  if r.owner then r.owner:forget(r); r.owner=nil end
end
local function detach(r,status)
  if r.body and r.body.offensiveContact==r then
    if status=='invalidated' then clearMotion(r.body) end
    r.body.offensiveContact=nil
  end
  if r.ow and r.ow.offensiveContacts then r.ow.offensiveContacts[r]=nil end
  forget(r); r.status=status; r.halted=true; r.evidence=nil
  r.body,r.ow,r.map,r.player,r.game,r.loader=nil,nil,nil,nil,nil,nil
end
local function anchorAllowed(r)
  local map,body,a=r.map,r.body,r.anchor
  if not map:inBounds(a.x,a.y) then return nil,'bounds' end
  if not map:isWalkableCell(a.x,a.y) then return nil,'tile' end
  if map:warpAtCell(a.x,a.y) then return nil,'warp' end
  if Collision.occupied(r.ow.entities,a.x,a.y,body) then return nil,'entity' end
  if Runtime.wantsHook('movement.collision') then
    local ctx={map=map,mover=body,dir=r.direction,fromX=a.x,fromY=a.y,
      toX=a.x,toY=a.y,restoring=true,offensive=true}
    if not Runtime.call('movement.collision',function(v) return v end,true,ctx) then
      return nil,ctx.reason or 'hook'
    end
  end
  -- A hook is external code: recheck hard placement constraints after it.
  if not live(r,true) or not map:inBounds(a.x,a.y)
      or not map:isWalkableCell(a.x,a.y) or map:warpAtCell(a.x,a.y)
      or Collision.occupied(r.ow.entities,a.x,a.y,body) then return nil,'invalidated' end
  return true
end
function Record:reconcile()
  if self.status=='restored' then return true,'restored' end
  if self.status=='invalidated' then return nil,'invalidated' end
  if self.reconciling then return nil,'reconciling' end
  self.halted=true; self.evidence=nil
  if not live(self,true) then
    detach(self,'invalidated'); return nil,'invalidated'
  end
  self.reconciling=true
  local ok,why=anchorAllowed(self)
  self.reconciling=nil
  if not live(self,true) then detach(self,'invalidated'); return nil,'invalidated' end
  if not ok then
    clearMotion(self.body)
    self.status='deferred'; self.reason=why
    return nil,'deferred',why
  end
  local b,a=self.body,self.anchor
  clearMotion(b); b.cellX,b.cellY=a.x,a.y; b.px,b.py=a.x*16,a.y*16
  detach(self,'restored'); return true,'restored'
end
-- Owner retirement cancels the proof and movement immediately. If A cannot
-- be used, the engine holds/retries placement, without an owner or callback.
function Record:release()
  self.retired=true; self.consumed=true
  if self.reconciling then forget(self); return nil,'reconciling' end
  local ok,status,reason=self:reconcile()
  forget(self)
  return ok,status,reason
end
function Token:snapshot()
  local r=tokens[self]
  if not r then return nil,'invalid token' end
  if r.status~='restored' and r.status~='invalidated' and not live(r) then
    r:release()
  end
  return copy({status=r.status,reason=r.reason,anchor=r.anchor,
    segment=r.segment,mapId=r.mapId,generation=r.generation,tick=r.tick,
    direction=r.direction,impactDepthPx=r.impactDepthPx,impactTransversePx=r.impactTransversePx,
    npc=r.snapshot and r.snapshot.npc,player=r.snapshot and r.snapshot.player,
    contact=r.evidence})
end
function Token:reconcile()
  local r=tokens[self]
  if not r then return nil,'invalid token' end
  if r.status=='restored' then return true,'restored' end
  if r.status=='invalidated' then return nil,'invalidated' end
  r.consumed=true; return r:reconcile()
end
function Token:release()
  local r=tokens[self]
  if not r then return nil,'invalid token' end
  if r.status=='restored' then return true,'restored' end
  if r.status=='invalidated' then return nil,'invalidated' end
  return r:release()
end
function Token:consumeContact()
  local r=tokens[self]
  if not r or r.consumed or not r.evidence then return nil,'no fresh contact' end
  r.consumed=true -- before hooks, restoration, or caller callbacks
  local proof=copy(r.evidence)
  if not ready(r) or (r.owner and r.owner.closed) then
    r:release(); return nil,'invalidated'
  end
  local current={npc=sample(r.body),player=sample(r.player,true)}
  for _,name in ipairs({'npc','player'}) do
    local a,b=current[name],r.snapshot[name]
    if a.physical.x~=b.physical.x or a.physical.y~=b.physical.y
        or a.elevation~=b.elevation or a.facing~=b.facing or not same(a.render,b.render) then
      r:release(); return nil,'snapshot changed'
    end
    for _,edge in ipairs({'left','right','top','bottom'}) do
      if a.envelope[edge]~=b.envelope[edge] then
        r:release(); return nil,'snapshot changed'
      end
    end
  end
  local ok,status,reason=r:reconcile()
  if not ok then return nil,status,reason end
  if r.retired then return nil,'invalidated' end
  proof.anchor=copy(r.anchor); proof.restored=true
  return proof
end
function Contact.canStart(h,dir,options)
  local required,transverse=threshold(options); if not required then return nil,transverse end
  if not Collision.DELTA[dir] then return nil,'direction' end
  local b,ow,owner=h.npc,h.ow,h.resourceOwner
  if not owner or owner.closed or not b.def.runtime or b.def.owner~=owner.modId then
    return nil,'owner'
  end
  if h.ghost or not ow.map or ow.map.id~=h.mapId then return nil,'map' end
  if b.offensiveContact or b.moving or b.directMovement or b.marching
      or b.passable or (b.visualElevation or 0)~=0 or b.hopStep
      or b.cellX%1~=0 or b.cellY%1~=0
      or b.px~=b.cellX*16 or b.py~=b.cellY*16 then return nil,'unstable body' end
  -- live() expects the lease; readiness here has the equivalent admission checks.
  if not ow.player or not contains(ow.entities,ow.player)
      or not contains(ow.npcs,b) or not contains(ow.entities,b)
      or h.game.stack:top()~=ow or ow.transitioning or ow.engaging
      or (ow.runner and ow.runner:isRunning()) or #(ow.scriptMoves or {})>0
      or (ow.marchers and ow.marchers[b]) then return nil,'world busy' end
  local p=ow.player
  if (p.hopFrames and p.hopFrames > 0) or p.ledgeHop or p.spinning or p.fishing or p.holeSink or p.surfing
      or ow.playerHidden or b.visible==false then return nil,'unsupported pose' end
  local tx,ty=Collision.target(b.cellX,b.cellY,dir)
  if tx~=p.cellX or ty~=p.cellY then return nil,'not player cell' end
  if not ow.map:inBounds(b.cellX,b.cellY) or not ow.map:isWalkableCell(b.cellX,b.cellY)
      or ow.map:warpAtCell(b.cellX,b.cellY)
      or Collision.occupied(ow.entities,b.cellX,b.cellY,b) then return nil,'illegal anchor' end
  local map,sx,sy=ow.map,b.cellX,b.cellY
  local ok,why=Collision.canMoveTowardPlayer(map,ow.entities,b,dir,p)
  if not ok then return nil,why end
  if ow.map~=map or ow.player~=p or b.cellX~=sx or b.cellY~=sy
      or b.px~=sx*16 or b.py~=sy*16 or b.moving or b.passable
      or b.offensiveContact or owner.closed or b.def.owner~=owner.modId
      or not contains(ow.npcs,b) or not contains(ow.entities,b)
      or h.game.stack:top()~=ow then return nil,'invalidated' end
  return true
end
function Contact.start(h,dir,options)
  local required,transverse=threshold(options); if not required then return nil,transverse end
  local ok,why=Contact.canStart(h,dir,options); if not ok then return nil,why end
  local b,ow=h.npc,h.ow
  -- Middleware may mutate the runtime. Do not engage a stale body or target.
  if ow.map.id~=h.mapId or not contains(ow.npcs,b) or b.moving or b.offensiveContact
      or h.resourceOwner.closed then return nil,'invalidated' end
  local tx,ty=Collision.target(b.cellX,b.cellY,dir)
  if tx~=ow.player.cellX or ty~=ow.player.cellY then return nil,'target changed' end
  sequence=sequence+1
  local r=setmetatable({body=b,ow=ow,map=ow.map,player=ow.player,game=h.game,
    loader=h.game.mods,owner=h.resourceOwner,modId=h.resourceOwner.modId,
    mapId=ow.map.id,anchor={x=b.cellX,y=b.cellY},
    destination={x=tx,y=ty},direction=dir,impactDepthPx=required,
    impactTransversePx=transverse,segment=sequence,
    generation=ow.offensiveGeneration or 0,status='moving'},Record)
  ok,why=r.owner:add(r); if not ok then return nil,why end
  b.offensiveContact=r
  ow.offensiveContacts=ow.offensiveContacts or {}; ow.offensiveContacts[r]=true
  b.directMovementResult=nil; b.facing=dir; b.targetX,b.targetY=tx,ty
  b.moving=true; b.progress=0
  r.snapshot={npc=sample(b),player=sample(r.player,true)}
  local token=setmetatable({}, {__index=Token,__metatable='offensive contact token'})
  tokens[token]=r; return token
end
function Contact.afterPhysics(ow,tick)
  local records={}; for r in pairs(ow.offensiveContacts or {}) do records[#records+1]=r end
  for _,r in ipairs(records) do
    if not live(r) then r:release()
    elseif r.status=='deferred' then r:reconcile()
    elseif r.halted and (not ready(r) or r.owner.closed) then r:release()
    elseif not r.halted then
      local b=r.body
      local allowed=Collision.canMoveTowardPlayer(r.map,ow.entities,b,r.direction,
        r.player,r.anchor.x,r.anchor.y)
      if not allowed or not ready(r) or r.owner.closed or b.facing~=r.direction
          or b.passable or (b.visualElevation or 0)~=0
          or (b.moving and (b.targetX~=r.destination.x or b.targetY~=r.destination.y))
          or (r.player.hopFrames and r.player.hopFrames > 0)
          or r.player.ledgeHop or r.player.spinning or r.player.surfing
          or r.player.fishing or ow.playerHidden then r:release()
      else
        local now={npc=sample(b),player=sample(r.player,true)}
        now.npc.source=copy(r.anchor); now.npc.destination=copy(r.destination)
        local previous=r.snapshot
        local moved=now.npc.physical.x~=r.anchor.x or now.npc.physical.y~=r.anchor.y
        local hit,lo,hi=impact(previous,now,r.direction,r.impactDepthPx,r.impactTransversePx,r.anchor)
        if hit then hit.fromTick=r.tick or (tick and tick-1); hit.tick=tick end
        r.snapshot=now; r.tick=tick
        if moved and hit then
          r.status='contact'; r.halted=true
          r.evidence={segment=r.segment,generation=r.generation,mapId=r.map.id,
            tick=tick,npc=copy(now.npc),player=copy(now.player),
            direction=r.direction,impactDepthPx=r.impactDepthPx,depthPx=hit.depthPx,
            impactTransversePx=r.impactTransversePx,overlapXPx=hit.overlapXPx,overlapYPx=hit.overlapYPx,
            anchor=copy(r.anchor),impact=hit,
            sweep={from=lo,to=hi}}
        elseif not b.moving then r:release() end
      end
    end
  end
  if ow.map and Runtime.wants('world.physics_updated') then
    Runtime.emit('world.physics_updated',{mapId=ow.map.id,tick=tick,
      generation=ow.offensiveGeneration or 0})
  end
end
function Contact.invalidateBody(body)
  local r=body and body.offensiveContact
  if r then clearMotion(body); detach(r,'invalidated') end
end
function Contact.invalidateWorld(ow)
  local records={}; for r in pairs(ow.offensiveContacts or {}) do records[#records+1]=r end
  for _,r in ipairs(records) do
    -- Reconcile only in the outgoing, still authoritative map.
    r:release()
    if r.status=='deferred' then Contact.invalidateBody(r.body) end
  end
  ow.offensiveGeneration=(ow.offensiveGeneration or 0)+1
end
return Contact
