-- Client_PresentSettingsUI.lua
-- Shows a description of the mod's rules in the in-game Game Settings panel.

function Client_PresentSettingsUI(rootParent)
    local vert = UI.CreateVerticalLayoutGroup(rootParent)

    UI.CreateLabel(vert)
        .SetText('Killer Gets the Cards')
        .SetColor('#FFD700')

    UI.CreateLabel(vert)
        .SetText('When a player is eliminated, their cards are transferred to whoever killed them.\n\n'
                 .. '• Attacker kills your commander or last territory → attacker gets your cards.\n'
                 .. '• Your commander attacks and dies → defender gets your cards.\n'
                 .. '• Eliminated by a blockade (neutral) → cards are discarded.\n'
                 .. '• You surrender → cards are discarded.')
end
