-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod
--
-- When a player is eliminated, create new card instances matching their hand
-- and give them to the killer via GameOrderReceiveCard.
-- Warzone automatically clears the eliminated player's cards, so we don't
-- need to explicitly remove them.
-- Pieces are transferred via AddCardPiecesOpt on a GameOrderEvent.
-- Surrenders and blockade kills result in cards being discarded (nothing given).

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

        -- Team check: only act if no teammates are still alive
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

        local pc = standing.Cards[playerID]
        if pc == nil then goto continue end

        -- Check for whole cards
        local wholeCards = {}
        if pc.WholeCards ~= nil then
            for _, instance in pairs(pc.WholeCards) do
                wholeCards[#wholeCards + 1] = instance
            end
        end

        -- Check for pieces
        local pieces = {}
        if pc.Pieces ~= nil then
            for cardID, count in pairs(pc.Pieces) do
                if count > 0 then
                    pieces[cardID] = count
                end
            end
        end

        local hasWholeCards = #wholeCards > 0
        local hasPieces     = tableHasKeys(pieces)
        if not hasWholeCards and not hasPieces then goto continue end

        local killerID  = _KGC_killerOf[playerID]
        local loserName = players[playerID].DisplayName(nil, false)

        if nowSurr or killerID == nil then
            -- Discard: Warzone clears whole cards on elimination automatically.
            -- For pieces, subtract them via AddCardPiecesOpt.
            if hasPieces then
                local loserPieces = {}
                for cardID, count in pairs(pieces) do
                    loserPieces[cardID] = -count
                end
                local cardPiecesOpt = {}
                cardPiecesOpt[playerID] = loserPieces
                local msg = nowSurr
                    and (loserName .. ' surrendered. Their cards have been discarded.')
                    or  (loserName .. ' was eliminated. Their cards have been discarded.')
                local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
                event.AddCardPiecesOpt = cardPiecesOpt
                addNewOrder(event)
            end

        else
            -- Transfer to killer
            local killerName = players[killerID].DisplayName(nil, false)
            local msg = loserName .. '\'s cards have been transferred to ' .. killerName .. '.'

            -- Create new card instances matching the loser's whole cards and give to killer.
            -- We cannot pass the existing CardInstance objects directly as they belong to
            -- the eliminated player; we must create fresh instances of the same card types.
            if hasWholeCards then
                local newInstances = {}
                for _, instance in ipairs(wholeCards) do
                    -- Use NoParameterCardInstance for all card types.
                    -- Reinforcement cards store their armies in a separate field but
                    -- GameOrderReceiveCard handles this via the CardID.
                    newInstances[#newInstances + 1] = WL.NoParameterCardInstance.Create(instance.CardID)
                end
                addNewOrder(WL.GameOrderReceiveCard.Create(killerID, newInstances))
            end

            -- Transfer pieces via AddCardPiecesOpt: subtract from loser, add to killer
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
                -- Still emit a visible event even if no pieces to transfer
                local event = WL.GameOrderEvent.Create(playerID, msg, nil, nil, nil, nil)
                addNewOrder(event)
            end
        end

        ::continue::
    end
end
