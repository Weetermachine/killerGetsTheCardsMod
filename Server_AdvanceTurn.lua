-- Server_AdvanceTurn.lua (TRANSFER DIAGNOSTIC)
-- Crashes right before addNewOrder to confirm the transfer data is correct.

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

        -- Team check: only skip if the game actually has multiple teams
        -- and a teammate is still alive. In a no-teams game everyone shares
        -- team=0, so we must not treat all players as teammates.
        do
            local myTeam = player.Team
            local gameHasTeams = false
            for _, other in pairs(players) do
                if other.Team ~= myTeam then
                    gameHasTeams = true
                    break
                end
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

        -- Crash here with exactly what we're about to do
        local killerID = _KGC_killerOf[playerID]
        local wholeCount = pc ~= nil and #pc.wholeCards or 0
        local hasPieces = pc ~= nil and tableHasKeys(pc.pieces)
        error('KGC_TRANSFER_DIAG | pid=' .. tostring(playerID)
              .. ' elim=' .. tostring(nowElim)
              .. ' surr=' .. tostring(nowSurr)
              .. ' killer=' .. tostring(killerID)
              .. ' pc_nil=' .. tostring(pc == nil)
              .. ' wholeCards=' .. wholeCount
              .. ' hasPieces=' .. tostring(hasPieces))

        ::continue::
    end
end
