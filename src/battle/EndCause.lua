-- Gen 1 final causes are recorded at the deciding branch, never inferred
-- from the legacy result. A direct/mod-written result has UNKNOWN provenance.
local EndCause = {}
local results = {
  POKEMON_KO = 'win', TRAINER_DEFEATED = 'win', PLAYER_DEFEATED = 'lose',
  PLAYER_FLED = 'run', TELEPORT = 'run', ROAR = 'run', WHIRLWIND = 'run',
  CAPTURED = 'caught', SKIPPED = 'lose', SAFARI_POKEMON_FLED = 'run',
  SAFARI_BALLS_EXHAUSTED = 'run', DEMO_ENDED = 'run',
  LINK_RUN = {draw=true, win=true, lose=true}, LINK_DESYNC = 'draw', LINK_DISCONNECTED = 'draw',
  LINK_PLAYER_FORFEITED = 'lose', LINK_OPPONENT_FORFEITED = 'win',
  LINK_PLAYER_DEFEATED = 'lose', LINK_OPPONENT_DEFEATED = 'win',
  LINK_SPECTATOR_RUN = 'ended', LINK_SPECTATOR_DISCONNECTED = 'ended',
  LINK_SPECTATOR_FORFEITED = 'ended', LINK_HOST_DEFEATED = 'guestWin',
  LINK_GUEST_DEFEATED = 'hostWin',
}
-- Official cable RUN distinguishes a local loss, remote win and joint draw.
local function matches(cause, result)
  local expected = results[cause]
  if type(expected) == 'table' then return expected[result] == true end
  return expected ~= nil and expected == result
end
function EndCause.set(battle, result, cause)
  assert(matches(cause, result), 'invalid Gen 1 battle end cause/result')
  battle.result = result
  battle.endCause = cause
  battle._endCauseResult = result
end
function EndCause.get(battle, result)
  result = result or battle.result
  local cause = battle.endCause
  if cause and matches(cause, result) and battle._endCauseResult == result then
    return cause
  end
  return 'UNKNOWN'
end
return EndCause
