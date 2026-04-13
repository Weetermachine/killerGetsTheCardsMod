-- Server_AdvanceTurn.lua
-- "Killer Gets the Cards" mod
--
-- Rules:
--   1. Commander attacks a territory, fails, commander dies -> defending territory
--      owner gets the eliminated player's cards.
--   2. Attack hits a blockade (neutral territory) -> no one gets cards.
--   3. Player kills your last territory or commander -> killer gets cards.
--   4. Player surrenders -> no one gets cards (cards are simply removed).
--
-- Approach:
--   _Start : snapshot which players are surrendering (to suppress card transfer).
--   _Order : for every attack order, record a mapping of
--              "if playerX ends up eliminated this turn, playerY is their killer"
--            using the standing BEFORE the order is applied (per hook docs).
--            We record both directions:
--              - successful attack: if defender ends up eliminated, attacker killed them
--              - failed attack:     if attacker ends up eliminated, defender killed them
--            Neutral (blockade) defenders produce no killer entry.
--   _End   : find all newly eliminated players. Look up their killer. If found,
--            transfer whole cards via GameOrderReceiveCard + RemoveWholeCardsOpt.
--            If surrendered, just remove cards with no transfer.

-----------------------------------------------------------------------
-- Turn-global state
-----------------------------------------------------------------------
-- _KGC_killerOf[loserID] = killerID  (or nil if no human killer, e.g. blockade)
_KGC_killerOf      = {}
-- _KGC_surrendered[playerID] = true  for players surrendering this turn
_KGC_surrendered   = {}
-- _KGC_wasAlive[playerID] = true  for players alive at start of turn
_KGC_wasAlive      = {}

-----------------------------------------------------------------------
-- _Start: snapshot alive players and surrenders
-----------------------------------------------------------------------
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

-----------------------------------------------------------------------
-- _Order: record killer mappings from attack results
-----------------------------------------------------------------------
function Server_AdvanceTurn_Order(game, order, orderResult, skipThisOrder, addNewOrder)
    if order.proxyType ~= 'GameOrderAttackTransfer' then return end
    if not orderResult.IsAttack then return end

    local attackerID = order.PlayerID
    local standing   = game.ServerGame.LatestTurnStanding
    local defenderID = standing.Territories[order.To].OwnerPlayerID

    -- Case: successful attack
    -- If the defender ends up eliminated this turn, the attacker killed them.
    -- Skip if defender is neutral (blockade).
    if orderResult.IsSuccessful then
        if defenderID ~= WL.PlayerID.Neutral then
            -- Only record if not already recorded (first kill is the kill)
            if _KGC_killerOf[defenderID] == nil then
                _KGC_killerOf[defenderID] = attackerID
            end
        end
        -- No else: blockade -> no killer recorded, cards will be discarded
    end

    -- Case: failed attack
    -- If the attacker's commander was on order.From and dies, attacker may be eliminated.
    -- The killer is whoever owns order.To (the defender).
    -- We record this regardless of whether attacker actually gets eliminated;
    -- we only act on it in _End if they did.
    if not orderResult.IsSuccessful then
        if defenderID ~= WL.PlayerID.Neutral then
            if _KGC_killerOf[attackerID] == nil then
                _KGC_killerOf[attackerID] = defenderID
            end
        end
        -- If defender is neutral (blockade), attacker commander dies to neutral ->
        -- no killer entry, cards will be discarded per rule 2.
    end
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

-- Returns { wholeCards = [...CardInstance], pieces = {cardID -> count} }
-- for a player, or nil if they have no cards or pieces at all.
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

-----------------------------------------------------------------------
-- _End: transfer or discard cards+pieces for eliminated/surrendered players
-----------------------------------------------------------------------
function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    for playerID, _ in pairs(_KGC_wasAlive) do
        local player  = players[playerID]
        local nowElim = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        -- In a team game, cards are shared. Only transfer when the last member
        -- of a team is eliminated/surrendered. If any teammate is still alive, skip.
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
        if pc == nil then goto continue end

        local loserName = players[playerID].DisplayName(nil, false)

        -- RemoveWholeCardsOpt: Table<PlayerID, CardInstanceID[]>
        local removeWholeCards = nil
        if #pc.wholeCards > 0 then
            local ids = {}
            for _, instance in ipairs(pc.wholeCards) do
                ids[#ids + 1] = instance.ID
            end
            removeWholeCards = {}
            removeWholeCards[playerID] = ids
        end

        -- AddCardPiecesOpt for removing pieces from loser: negative counts
        local removePieces = nil
        local hasPieces = false
        for _ in pairs(pc.pieces) do hasPieces = true; break end
        if hasPieces then
            local loserPieces = {}
            for cardID, count in pairs(pc.pieces) do
                loserPieces[cardID] = -count
            end
            removePieces = {}
            removePieces[playerID] = loserPieces
        end

        if nowSurr then
            -- Rule 4: surrender -> discard everything, no transfer
            local event = WL.GameOrderEvent.Create(
                playerID,
                loserName .. ' surrendered. Their cards have been discarded.',
                nil, nil, nil, nil
            )
            if removeWholeCards ~= nil then
                event.RemoveWholeCardsOpt = removeWholeCards
            end
            if removePieces ~= nil then
                event.AddCardPiecesOpt = removePieces
            end
            addNewOrder(event)

        elseif nowElim then
            local killerID = _KGC_killerOf[playerID]

            if killerID == nil then
                -- No human killer (e.g. blockade) -> discard
                local event = WL.GameOrderEvent.Create(
                    playerID,
                    loserName .. ' was eliminated. Their cards have been discarded.',
                    nil, nil, nil, nil
                )
                if removeWholeCards ~= nil then
                    event.RemoveWholeCardsOpt = removeWholeCards
                end
                if removePieces ~= nil then
                    event.AddCardPiecesOpt = removePieces
                end
                addNewOrder(event)
            else
                local killerName = players[killerID].DisplayName(nil, false)

                -- Build AddCardPiecesOpt: remove from loser AND add to killer
                -- in the same event so pieces don't get lost.
                local cardPiecesOpt = nil
                if hasPieces then
                    cardPiecesOpt = {}
                    -- Remove from loser
                    local loserPieces = {}
                    for cardID, count in pairs(pc.pieces) do
                        loserPieces[cardID] = -count
                    end
                    cardPiecesOpt[playerID] = loserPieces
                    -- Add to killer
                    local killerPieces = {}
                    for cardID, count in pairs(pc.pieces) do
                        killerPieces[cardID] = count
                    end
                    cardPiecesOpt[killerID] = killerPieces
                end

                -- Event: strip whole cards + transfer pieces
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

                -- Give whole cards to killer via GameOrderReceiveCard
                if #pc.wholeCards > 0 then
                    addNewOrder(WL.GameOrderReceiveCard.Create(killerID, pc.wholeCards))
                end
            end
        end

        ::continue::
    end
end
