-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod

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

local function tableHasKeys(t)
    for _ in pairs(t) do return true end
    return false
end

function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    -- UNCONDITIONAL CARD DUMP
    local cardDump = 'CARDS: '
    for pid, _ in pairs(players) do
        local pc = standing.Cards[pid]
        if pc ~= nil then
            local wc = 0
            local pieces = ''
            if pc.WholeCards ~= nil then
                for _ in pairs(pc.WholeCards) do wc = wc + 1 end
            end
            if pc.Pieces ~= nil then
                for cid, cnt in pairs(pc.Pieces) do
                    if cnt > 0 then pieces = pieces .. tostring(cid) .. 'x' .. tostring(cnt) .. ',' end
                end
            end
            cardDump = cardDump .. '[pid=' .. tostring(pid) .. ' whole=' .. wc .. ' pieces=(' .. pieces .. ')]'
        end
    end
    error('KGC_CARD_DUMP | ' .. cardDump)

    for playerID, player in pairs(players) do
        if not _KGC_wasAlive[playerID] then goto continue end

        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        -- Team check: only act when the last alive teammate is gone
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

        -- DIAGNOSTIC: crash when eliminated to show card lookup results
        if nowElim or nowSurr then
            local directPc = standing.Cards[playerID]
            local cardInfo = 'direct_nil=' .. tostring(directPc == nil) .. ' '
            -- Also check all other players' cards to find where team cards are stored
            for otherpid, _ in pairs(players) do
                local otherPc = standing.Cards[otherpid]
                if otherPc ~= nil then
                    local wc = 0
                    for _ in pairs(otherPc.WholeCards) do wc = wc + 1 end
                    cardInfo = cardInfo .. '[cards_under=' .. tostring(otherpid) .. ' whole=' .. wc .. ']'
                end
            end
            error('KGC_CARDS_DIAG | eliminated=' .. tostring(playerID)
                .. ' killer=' .. tostring(_KGC_killerOf[playerID])
                .. ' wasAlive=' .. tostring(_KGC_wasAlive[playerID])
                .. ' ' .. cardInfo)
        end

        local pc = standing.Cards[playerID]
        if pc == nil then goto continue end

        local wholeCards = {}
        if pc.WholeCards ~= nil then
            for _, instance in pairs(pc.WholeCards) do
                wholeCards[#wholeCards + 1] = instance
            end
        end

        local pieces = {}
        if pc.Pieces ~= nil then
            for cardID, count in pairs(pc.Pieces) do
                if count > 0 then pieces[cardID] = count end
            end
        end

        local hasWholeCards = #wholeCards > 0
        local hasPieces     = tableHasKeys(pieces)
        if not hasWholeCards and not hasPieces then goto continue end

        local killerID  = _KGC_killerOf[playerID]
        local loserName = players[playerID].DisplayName(nil, false)

        if nowSurr or killerID == nil then
            -- Discard
            local msg = nowSurr
                and (loserName .. ' surrendered. Their cards have been discarded.')
                or  (loserName .. ' was eliminated. Their cards have been discarded.')
            if hasPieces then
                local loserPieces = {}
                for cardID, count in pairs(pieces) do loserPieces[cardID] = -count end
                local cardPiecesOpt = {}
                cardPiecesOpt[playerID] = loserPieces
                local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
                event.AddCardPiecesOpt = cardPiecesOpt
                addNewOrder(event)
            else
                addNewOrder(WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil))
            end

        else
            -- Transfer to killer
            local killerName = players[killerID].DisplayName(nil, false)
            local msg = loserName .. '\'s cards have been transferred to ' .. killerName .. '.'

            if hasWholeCards then
                local newInstances = {}
                for _, instance in ipairs(wholeCards) do
                    if instance.CardID == WL.CardID.Reinforcement then
                        newInstances[#newInstances + 1] = WL.ReinforcementCardInstance.Create(instance.Armies)
                    else
                        newInstances[#newInstances + 1] = WL.NoParameterCardInstance.Create(instance.CardID)
                    end
                end
                addNewOrder(WL.GameOrderReceiveCard.Create(killerID, newInstances))
            end

            if hasPieces then
                local loserPieces  = {}
                local killerPieces = {}
                for cardID, count in pairs(pieces) do
                    loserPieces[cardID]  = -count
                    killerPieces[cardID] = count
                end
                local cardPiecesOpt = {}
                cardPiecesOpt[playerID] = loserPieces
                cardPiecesOpt[killerID] = killerPieces
                local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
                event.AddCardPiecesOpt = cardPiecesOpt
                addNewOrder(event)
            elseif hasWholeCards then
                local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
                addNewOrder(event)
            end
        end

        ::continue::
    end
end
