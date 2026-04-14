-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod

_KGC_teamKiller  = {}  -- [teamID] = killerID, updated every attack on a team member
_KGC_surrendered = {}
_KGC_wasAlive    = {}

function Server_AdvanceTurn_Start(game, addNewOrder)
    _KGC_teamKiller  = {}
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

    if defenderID == WL.PlayerID.Neutral then return end

    local defenderTeam = standing.Territories[order.To].OwnerPlayerID
    -- Get the defender's team from the game players
    local defenders = game.Game.Players
    local defenderPlayer = defenders[defenderID]
    if defenderPlayer == nil then return end
    local teamID = defenderPlayer.Team

    if orderResult.IsSuccessful then
        -- Successful attack on a team member: overwrite with this attacker
        _KGC_teamKiller[teamID] = attackerID
    end

    if not orderResult.IsSuccessful then
        -- Failed attack: attacker's commander may have died, killing them
        -- The defender's team gets credit for killing the attacker's team
        local attackerPlayer = defenders[attackerID]
        if attackerPlayer ~= nil then
            _KGC_teamKiller[attackerPlayer.Team] = defenderID
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

    -- Track which teams we've already processed this turn
    local processedTeams = {}

    for playerID, player in pairs(players) do
        if not _KGC_wasAlive[playerID] then goto continue end

        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        local myTeam = player.Team

        -- Only process each team once
        if processedTeams[myTeam] then goto continue end

        -- Team check: only act when no teammates are still alive
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

        processedTeams[myTeam] = true

        -- Collect cards from ALL team members
        local wholeCards     = {}
        local pieces         = {}
        local piecesPerPlayer = {}
        for _, other in pairs(players) do
            if other.Team == myTeam then
                local pc = standing.Cards[other.ID]
                if pc ~= nil then
                    if pc.WholeCards ~= nil then
                        for _, instance in pairs(pc.WholeCards) do
                            wholeCards[#wholeCards + 1] = instance
                        end
                    end
                    if pc.Pieces ~= nil then
                        local playerPieces = {}
                        for cardID, count in pairs(pc.Pieces) do
                            if count > 0 then
                                pieces[cardID] = (pieces[cardID] or 0) + count
                                playerPieces[cardID] = count
                            end
                        end
                        if tableHasKeys(playerPieces) then
                            piecesPerPlayer[other.ID] = playerPieces
                        end
                    end
                end
            end
        end

        local hasWholeCards = #wholeCards > 0
        local hasPieces     = tableHasKeys(pieces)
        if not hasWholeCards and not hasPieces then goto continue end

        local loserName = players[playerID].DisplayName(nil, false)

        -- Determine killer: use _KGC_teamKiller for the team,
        -- but not if the team surrendered
        local killerID = nil
        if not nowSurr then
            killerID = _KGC_teamKiller[myTeam]
        end

        if killerID == nil then
            -- Surrender or no recorded killer (blockade etc.) -> discard
            local msg = nowSurr
                and (loserName .. ' surrendered. Their cards have been discarded.')
                or  (loserName .. ' was eliminated. Their cards have been discarded.')
            if hasPieces then
                local cardPiecesOpt = {}
                for pid, playerPieces in pairs(piecesPerPlayer) do
                    local loserPieces = {}
                    for cardID, count in pairs(playerPieces) do
                        loserPieces[cardID] = -count
                    end
                    cardPiecesOpt[pid] = loserPieces
                end
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
                local cardPiecesOpt = {}
                for pid, playerPieces in pairs(piecesPerPlayer) do
                    local loserPieces = {}
                    for cardID, count in pairs(playerPieces) do
                        loserPieces[cardID] = -count
                    end
                    cardPiecesOpt[pid] = loserPieces
                end
                local killerPieces = {}
                for cardID, count in pairs(pieces) do
                    killerPieces[cardID] = count
                end
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
