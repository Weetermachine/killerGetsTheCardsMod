-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod
--
-- Rules:
--   1. Commander attacks a territory, fails, commander dies -> defending territory
--      owner gets the eliminated player's cards.
--   2. Attack hits a blockade (neutral territory) -> no one gets cards.
--   3. Player kills your last territory or commander -> killer gets cards.
--   4. You surrender -> no one gets cards (cards are simply removed).
--
-- In team games, cards are shared. Only transfer when the LAST alive teammate
-- is eliminated/surrendered.

-----------------------------------------------------------------------
-- Turn-global state
-----------------------------------------------------------------------
_KGC_killerOf    = {}
_KGC_surrendered = {}

-----------------------------------------------------------------------
-- _Start
-----------------------------------------------------------------------
function Server_AdvanceTurn_Start(game, addNewOrder)
    _KGC_killerOf    = {}
    _KGC_surrendered = {}

    for _, player in pairs(game.Game.Players) do
        if player.Surrendered == true then
            _KGC_surrendered[player.ID] = true
        end
    end
end

-----------------------------------------------------------------------
-- _Order: record killer mappings
-----------------------------------------------------------------------
function Server_AdvanceTurn_Order(game, order, orderResult, skipThisOrder, addNewOrder)
    if order.proxyType ~= 'GameOrderAttackTransfer' then return end
    if not orderResult.IsAttack then return end

    local attackerID = order.PlayerID
    local standing   = game.ServerGame.LatestTurnStanding
    local defenderID = standing.Territories[order.To].OwnerPlayerID

    -- Successful attack: if defender ends up eliminated, attacker is the killer
    if orderResult.IsSuccessful then
        if defenderID ~= WL.PlayerID.Neutral then
            if _KGC_killerOf[defenderID] == nil then
                _KGC_killerOf[defenderID] = attackerID
            end
        end
    end

    -- Failed attack: if attacker ends up eliminated (commander died), defender is the killer
    if not orderResult.IsSuccessful then
        if defenderID ~= WL.PlayerID.Neutral then
            if _KGC_killerOf[attackerID] == nil then
                _KGC_killerOf[attackerID] = defenderID
            end
        end
    end
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

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

-----------------------------------------------------------------------
-- _End: transfer or discard cards+pieces
-----------------------------------------------------------------------
function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    -- UNCONDITIONAL DIAGNOSTIC: dump key vs player.ID
    local info = 'Elim=' .. tostring(WL.GamePlayerState.Eliminated) .. ' '
    for playerID, player in pairs(players) do
        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        info = info .. '[key=' .. tostring(playerID)
                    .. ' id=' .. tostring(player.ID)
                    .. ' state=' .. tostring(player.State)
                    .. ' nowElim=' .. tostring(nowElim)
                    .. ' surr=' .. tostring(player.Surrendered) .. ']'
    end
    error('KGC_END_DUMP | ' .. info)

    for playerID, player in pairs(players) do
        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        -- Team game: skip if a teammate is still alive (cards stay with the team)
        do
            local myTeam = player.Team
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

        local pc = getPlayerCards(standing, playerID)

        -- DIAGNOSTIC: crash with card state at _End time for eliminated/surrendered
        if nowElim or nowSurr then
            local rawPc = standing.Cards[playerID]
            local wholeCount = 0
            local pieceInfo = ''
            if rawPc ~= nil then
                if rawPc.WholeCards ~= nil then
                    for _ in pairs(rawPc.WholeCards) do wholeCount = wholeCount + 1 end
                end
                if rawPc.Pieces ~= nil then
                    for cid, cnt in pairs(rawPc.Pieces) do
                        pieceInfo = pieceInfo .. tostring(cid) .. 'x' .. tostring(cnt) .. ','
                    end
                end
            end
            error('KGC_END_DIAG | pid=' .. tostring(playerID)
                  .. ' elim=' .. tostring(nowElim)
                  .. ' surr=' .. tostring(nowSurr)
                  .. ' killer=' .. tostring(_KGC_killerOf[playerID])
                  .. ' pc_nil=' .. tostring(pc == nil)
                  .. ' rawCards_nil=' .. tostring(rawPc == nil)
                  .. ' wholeCount=' .. wholeCount
                  .. ' pieces=(' .. pieceInfo .. ')')
        end

        if pc == nil then goto continue end

        local loserName = players[playerID].DisplayName(nil, false)
        local hasPieces = tableHasKeys(pc.pieces)

        -- Build RemoveWholeCardsOpt: { [playerID] = {guid, guid, ...} }
        local removeWholeCards = nil
        if #pc.wholeCards > 0 then
            local ids = {}
            for _, instance in ipairs(pc.wholeCards) do
                ids[#ids + 1] = instance.ID
            end
            removeWholeCards = {}
            removeWholeCards[playerID] = ids
        end

        if nowSurr then
            -- Discard everything, no transfer
            local event = WL.GameOrderEvent.Create(
                playerID,
                loserName .. ' surrendered. Their cards have been discarded.',
                nil, nil, nil, nil
            )
            if removeWholeCards ~= nil then
                event.RemoveWholeCardsOpt = removeWholeCards
            end
            if hasPieces then
                local removePieces = {}
                local loserPieces = {}
                for cardID, count in pairs(pc.pieces) do
                    loserPieces[cardID] = -count
                end
                removePieces[playerID] = loserPieces
                event.AddCardPiecesOpt = removePieces
            end
            addNewOrder(event)

        elseif nowElim then
            local killerID = _KGC_killerOf[playerID]

            if killerID == nil then
                -- No human killer (blockade etc.) -> discard
                local event = WL.GameOrderEvent.Create(
                    playerID,
                    loserName .. ' was eliminated. Their cards have been discarded.',
                    nil, nil, nil, nil
                )
                if removeWholeCards ~= nil then
                    event.RemoveWholeCardsOpt = removeWholeCards
                end
                if hasPieces then
                    local removePieces = {}
                    local loserPieces = {}
                    for cardID, count in pairs(pc.pieces) do
                        loserPieces[cardID] = -count
                    end
                    removePieces[playerID] = loserPieces
                    event.AddCardPiecesOpt = removePieces
                end
                addNewOrder(event)
            else
                local killerName = players[killerID].DisplayName(nil, false)

                -- Build AddCardPiecesOpt: subtract from loser, add to killer
                local cardPiecesOpt = nil
                if hasPieces then
                    cardPiecesOpt = {}
                    local loserPieces = {}
                    local killerPieces = {}
                    for cardID, count in pairs(pc.pieces) do
                        loserPieces[cardID]  = -count
                        killerPieces[cardID] = count
                    end
                    cardPiecesOpt[playerID] = loserPieces
                    cardPiecesOpt[killerID] = killerPieces
                end

                -- Strip loser's whole cards and transfer pieces in one event
                local event = WL.GameOrderEvent.Create(
                    playerID,
                    loserName .. '\'s cards have been transferred to ' .. killerName .. '.',
                    nil, nil, nil, nil
                )
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
        end

        ::continue::
    end
end
