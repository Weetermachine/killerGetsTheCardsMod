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

-- Collect all whole cards belonging to a player from the standing
local function getWholeCards(standing, playerID)
    local cards = standing.Cards[playerID]
    if cards == nil then return {} end
    local instances = {}
    for _, instance in pairs(cards.WholeCards) do
        instances[#instances + 1] = instance
    end
    return instances
end

-----------------------------------------------------------------------
-- _End: transfer or discard cards for eliminated/surrendered players
-----------------------------------------------------------------------
function Server_AdvanceTurn_End(game, addNewOrder)
    local players  = game.Game.Players
    local standing = game.ServerGame.LatestTurnStanding

    for playerID, _ in pairs(_KGC_wasAlive) do
        local player    = players[playerID]
        local nowElim   = (player.State == WL.GamePlayerState.Eliminated)
        local nowSurr   = _KGC_surrendered[playerID]

        if not nowElim and not nowSurr then goto continue end

        local cards = getWholeCards(standing, playerID)
        if #cards == 0 then goto continue end

        -- Build the RemoveWholeCardsOpt table (cardInstanceID -> playerID)
        -- needed to strip the cards from the loser regardless of transfer.
        local removeCards = {}
        for _, instance in ipairs(cards) do
            removeCards[instance.ID] = playerID
        end

        if nowSurr then
            -- Rule 4: surrender -> discard cards, no transfer
            local event = WL.GameOrderEvent.Create(
                playerID,
                players[playerID].DisplayName(nil, false)
                    .. ' surrendered. Their cards have been discarded.',
                nil, nil, nil, nil
            )
            event.RemoveWholeCardsOpt = removeCards
            addNewOrder(event)

        elseif nowElim then
            local killerID = _KGC_killerOf[playerID]

            if killerID == nil then
                -- Eliminated with no recorded killer (e.g. blockade commander death)
                -- -> discard cards
                local event = WL.GameOrderEvent.Create(
                    playerID,
                    players[playerID].DisplayName(nil, false)
                        .. ' was eliminated. Their cards have been discarded.',
                    nil, nil, nil, nil
                )
                event.RemoveWholeCardsOpt = removeCards
                addNewOrder(event)
            else
                -- Transfer cards to killer:
                -- 1. Remove from loser
                local removeEvent = WL.GameOrderEvent.Create(
                    playerID,
                    players[playerID].DisplayName(nil, false)
                        .. '\'s cards have been transferred to '
                        .. players[killerID].DisplayName(nil, false) .. '.',
                    nil, nil, nil, nil
                )
                removeEvent.RemoveWholeCardsOpt = removeCards
                addNewOrder(removeEvent)

                -- 2. Give to killer via GameOrderReceiveCard
                addNewOrder(WL.GameOrderReceiveCard.Create(killerID, cards))
            end
        end

        ::continue::
    end
end
