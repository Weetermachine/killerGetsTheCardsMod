-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod

_KGC_killerOf    = {}
_KGC_surrendered = {}

function Server_AdvanceTurn_Start(game, addNewOrder)
    _KGC_killerOf    = {}
    _KGC_surrendered = {}
    for _, player in pairs(game.Game.Players) do
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

local function getPlayerCards(standing, playerID)
    local pc = standing.Cards[playerID]
    if pc == nil then return nil end
    local wholeCards = {}
    if pc.WholeCards ~= nil then
        for _, instance in pairs(pc.WholeCards) do
            wholeCards[#wholeCards + 1] = instance
        end
    end
    local pieces = {}
    local hasPieces = false
    if pc.Pieces ~= nil then
        for cardID, count in pairs(pc.Pieces) do
            if count > 0 then
                pieces[cardID] = count
                hasPieces = true
            end
        end
    end
    if #wholeCards == 0 and not hasPieces then return nil end
    return { wholeCards = wholeCards, pieces = pieces }
end

local function tableHasKeys(t)
    for _ in pairs(t) do return true end
    return false
end

function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    for playerID, player in pairs(players) do
        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        -- Team check: only skip if the game has multiple teams and a teammate is alive
        do
            local myTeam = player.Team
            local gameHasTeams = false
            for _, other in pairs(players) do
                if other.Team ~= myTeam then gameHasTeams = true; break end
            end
            if gameHasTeams then
                local teammateAlive = false
                for _, other in pairs(players) do
                    if other.ID ~= playerID
                       and other.Team == myTeam
                       and other.State == WL.GamePlayerState.Playing then
                        teammateAlive = true
                        break
                    end
                end
                if teammateAlive then goto continue end
            end
        end

        local pc = getPlayerCards(standing, playerID)
        if pc == nil then goto continue end

        local loserName  = players[playerID].DisplayName(nil, false)
        local hasPieces  = tableHasKeys(pc.pieces)
        local killerID   = _KGC_killerOf[playerID]

        -- Build RemoveWholeCardsOpt: { [playerID] = {guid, ...} }
        local removeWholeCards = nil
        if #pc.wholeCards > 0 then
            local ids = {}
            for _, instance in ipairs(pc.wholeCards) do
                ids[#ids + 1] = instance.ID
            end
            removeWholeCards = {}
            removeWholeCards[playerID] = ids
        end

        if nowSurr or killerID == nil then
            -- Surrender or no human killer (blockade) -> discard
            local msg = nowSurr
                and (loserName .. ' surrendered. Their cards have been discarded.')
                or  (loserName .. ' was eliminated. Their cards have been discarded.')
            local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
            if removeWholeCards ~= nil then
                event.RemoveWholeCardsOpt = removeWholeCards
            end
            if hasPieces then
                local loserPieces = {}
                for cardID, count in pairs(pc.pieces) do
                    loserPieces[cardID] = -count
                end
                local removePieces = {}
                removePieces[playerID] = loserPieces
                event.AddCardPiecesOpt = removePieces
            end
            addNewOrder(event)

        else
            -- Transfer to killer
            local killerName = players[killerID].DisplayName(nil, false)
            local msg = loserName .. '\'s cards have been transferred to ' .. killerName .. '.'

            -- Build piece transfer: subtract from loser, add to killer
            local cardPiecesOpt = nil
            if hasPieces then
                local loserPieces  = {}
                local killerPieces = {}
                for cardID, count in pairs(pc.pieces) do
                    loserPieces[cardID]  = -count
                    killerPieces[cardID] = count
                end
                cardPiecesOpt = {}
                cardPiecesOpt[playerID] = loserPieces
                cardPiecesOpt[killerID] = killerPieces
            end

            local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
            if removeWholeCards ~= nil then
                event.RemoveWholeCardsOpt = removeWholeCards
            end
            if cardPiecesOpt ~= nil then
                event.AddCardPiecesOpt = cardPiecesOpt
            end
            addNewOrder(event)

            -- Give whole cards to killer
            if #pc.wholeCards > 0 then
                addNewOrder(WL.GameOrderReceiveCard.Create(killerID, pc.wholeCards))
            end
        end

        ::continue::
    end
end
