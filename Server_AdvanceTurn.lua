-- Server_AdvanceTurn.lua (CRASH DIAGNOSTIC)
-- Only crashes when it detects a player who was alive at start but isn't Playing at end.

_KGC_killerOf    = {}
_KGC_surrendered = {}
_KGC_wasAlive    = {}

function Server_AdvanceTurn_Start(game, addNewOrder)
    _KGC_killerOf    = {}
    _KGC_surrendered = {}
    _KGC_wasAlive    = {}

    for _, player in pairs(game.Game.Players) do
        if player.State == WL.GamePlayerState.Playing then
            _KGC_wasAlive[player.ID] = true
        end
        if player.Surrendered == true then
            _KGC_surrendered[player.ID] = true
        end
    end
end

function Server_AdvanceTurn_Order(game, order, orderResult, skipThisOrder, addNewOrder)
    if order.proxyType ~= 'GameOrderAttackTransfer' then return end
    if not orderResult.IsAttack then return end

    local attackerID = order.PlayerID
    local standing   = game.ServerGame.LatestTurnStanding
    local defenderID = standing.Territories[order.To].OwnerPlayerID

    if orderResult.IsSuccessful and defenderID ~= WL.PlayerID.Neutral then
        if _KGC_killerOf[defenderID] == nil then
            _KGC_killerOf[defenderID] = attackerID
        end
    end
    if not orderResult.IsSuccessful and defenderID ~= WL.PlayerID.Neutral then
        if _KGC_killerOf[attackerID] == nil then
            _KGC_killerOf[attackerID] = defenderID
        end
    end
end

function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    -- Find any player who was alive at start but is no longer Playing
    local found = false
    local info  = 'ELIM_CHECK: '

    for playerID, _ in pairs(_KGC_wasAlive) do
        local player = players[playerID]
        local state  = player.State
        if state ~= WL.GamePlayerState.Playing then
            found = true
            -- Check their cards
            local pc = standing.Cards[playerID]
            local wholeCount = 0
            local pieceInfo  = ''
            if pc ~= nil then
                if pc.WholeCards ~= nil then
                    for _ in pairs(pc.WholeCards) do wholeCount = wholeCount + 1 end
                end
                if pc.Pieces ~= nil then
                    for cardID, count in pairs(pc.Pieces) do
                        pieceInfo = pieceInfo .. cardID .. 'x' .. count .. ','
                    end
                end
            end
            local killerID = _KGC_killerOf[playerID]
            info = info .. '[pid=' .. tostring(playerID)
                       .. ' state=' .. tostring(state)
                       .. ' surrendered=' .. tostring(player.Surrendered)
                       .. ' wholeCards=' .. wholeCount
                       .. ' pieces=(' .. pieceInfo .. ')'
                       .. ' killer=' .. tostring(killerID) .. ']'
        end
    end

    if found then
        error('KGC_DIAG | Eliminated enum=' .. tostring(WL.GamePlayerState.Eliminated)
              .. ' | ' .. info)
    end
end
