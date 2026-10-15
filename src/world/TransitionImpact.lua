-- Presentation receipt boundary. OffensiveContact remains the physics owner.
local SpriteRenderer = require('src.render.SpriteRenderer')
local GroundShadow = require('src.render.GroundShadow')
local receipts = setmetatable({}, {__mode='k'})
local Impact = {}
local function copy(v)
  if type(v)~='table' then return v end
  local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function same(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~='table' then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function visualExtras(body)
  local sprite=body:pose()
  return {colors=copy(sprite.gen1ObjColors),group=sprite.gen1ObjGroup,
    shadow=body.shadowImg,hasShadow=body.groundShadow or body.hopShadowY~=nil,
    offsetX=body.groundShadowOffsetX,offsetY=body.groundShadowOffsetY,
    drawOrder=body.drawOrder,drawSequence=body.drawSequence}
end

-- Preserve the four opaque native token methods. Only successful public
-- consumption produces a receipt; snapshots, clones and invented tables do not.
function Impact.wrap(native,h)
  local context=setmetatable({game=h.game,ow=h.ow,map=h.ow.map,body=h.npc,
    player=h.ow.player,loader=h.game.mods,owner=h.resourceOwner},{__mode='v'})
  local methods={}
  function methods:snapshot() return native:snapshot() end
  function methods:reconcile() return native:reconcile() end
  function methods:release() return native:release() end
  function methods:consumeContact()
    local npcExtras,playerExtras
    local snapshot=native:snapshot()
    if snapshot and snapshot.status=='contact' and context.body and context.player
        and context.ow and context.ow.map==context.map and context.ow.player==context.player
        and context.owner and not context.owner.closed then
      npcExtras,playerExtras=visualExtras(context.body),visualExtras(context.player)
    end
    local proof,reason,placement=native:consumeContact()
    if proof and proof.restored==true then
      receipts[proof]={context=context,proof=copy(proof),npc=npcExtras,player=playerExtras}
    end
    return proof,reason,placement
  end
  return setmetatable({}, {__index=methods,__metatable='offensive contact token'})
end

local function actor(sample,extras)
  local r=copy(sample.render)
  local sprite=SpriteRenderer.new(copy(r.definition),r.seed)
  assert(sprite.frameWidth==r.frameWidth and sprite.frameHeight==r.frameHeight
    and sprite.anchorX==r.anchorX and sprite.anchorY==r.anchorY and sprite.frames[r.frame],
    'impact sprite geometry changed')
  if extras.colors then sprite:setGen1ObjPaletteOverride(copy(extras.colors),extras.group) end
  local a={id=sample.id,px=sample.physicalPixels.x,py=sample.physicalPixels.y,
    visualElevation=sample.elevation,visible=true,terrainOcclusion=true,
    isTransitionImpact=true,sprite=sprite,render=r,drawOrder=extras.drawOrder,drawSequence=extras.drawSequence}
  function a:drawGroundShadow(cx,cy)
    if self.destroyed then return true end
    if extras.hasShadow then
      GroundShadow.draw(extras.shadow,self.px,self.py,cx,cy,extras.offsetX,extras.offsetY)
    end
    return true
  end
  function a:draw(cx,cy,shadowDrawn)
    if self.destroyed then return end
    if not shadowDrawn then self:drawGroundShadow(cx,cy) end
    -- Explicit frame and mirror are final pose data, not a fresh pose decision.
    local mirror=r.frameOverride==nil and r.mirror or false
    self.sprite:draw(r.x,r.y,cx,cy,r.facing,r.phase,r.stepFlip,nil,mirror,r.frame)
  end
  function a:retire()
    self.destroyed=true; self.visible=false; self.sprite=nil; self.render=nil
    r=nil; extras={}
  end
  return a
end

function Impact.prepare(proof,game,ow,body,owner,survivorValid)
  local receipt=type(proof)=='table' and receipts[proof]
  if not receipt or receipt.used then return nil,'impact proof was not publicly consumed or was already used' end
  local c,p=receipt.context,receipt.proof
  if not same(proof,p) then return nil,'impact proof was modified' end
  if not p.restored or c.game~=game or c.ow~=ow or c.map~=ow.map or c.body~=body
      or c.player~=ow.player or c.loader~=game.mods or c.owner~=owner or not owner
      or owner.closed or p.mapId~=ow.map.id or p.generation~=(ow.offensiveGeneration or 0)
      or type(p.tick)~='number' or p.tick~=game.logicStep or not p.impact or not receipt.npc or not receipt.player
      or p.npc.identity~=p.impact.npc.identity or p.player.identity~=p.impact.player.identity
      or p.npc.id~=body.id or body.moving or body.px~=p.anchor.x*16 or body.py~=p.anchor.y*16
      or ow.player.px~=p.player.physicalPixels.x or ow.player.py~=p.player.physicalPixels.y
      or ow.engaging or (ow.runner and ow.runner:isRunning()) or #(ow.scriptMoves or {})>0
      or not game.stack or game.stack:top()~=ow or not survivorValid() then
    return nil,'impact proof identity, world or contact tick is no longer current'
  end
  local ok,npc,player=pcall(function()
    return actor(p.impact.npc,receipt.npc),actor(p.impact.player,receipt.player)
  end)
  if not ok then return nil,'impact rendering unavailable: '..tostring(npc) end
  local freeze={npc=npc,player=player,body=body,hero=ow.player,ow=ow,owner=owner}
  function freeze:valid()
    return not self.retired and self.ow.player==self.hero and not self.ow.playerHidden
      and not self.ow.flyAnim and not self.ow.flyArrive and survivorValid()
  end
  function freeze:release()
    if self.retired then return true end
    self.retired=true
    self.npc:retire(); self.player:retire()
    if self.ow.battleImpact==self then self.ow.battleImpact=nil end
    self.owner:forget(self)
    self.npc,self.player,self.body,self.hero,self.ow,self.owner=nil,nil,nil,nil,nil,nil
    survivorValid=nil
    return true
  end
  function freeze:claim()
    if receipt.used or not self:valid() then return nil,'impact proof invalidated before entry' end
    local accepted,err=self.owner:add(self)
    if not accepted then return nil,err end
    receipt.used=true; receipt.context=nil; receipt.proof=nil; receipt.npc=nil; receipt.player=nil
    return true
  end
  return freeze
end
return Impact
