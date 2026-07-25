module Frontend.View.HackingWindow exposing (view)

{-| The data/relic hacking minigame.

The board is a hex grid, and almost none of it reaches the memory reading: the client draws the
node art, the connection lines, the virus marker and the bracket that marks a legal move purely in
the renderer. Measured 2026-07-25 against a live client, an unrevealed node, a node marked as a
legal move, and a node on the far side of the board are byte-identical in the tree, and no hover
readout exists -- `tileHintLabel` answers reveals, never the pointer, posted or physical.

What does reach us is enough to play. A revealed empty node carries a `distanceIndicatorCont`
label, and those accumulate, so the set of revealed connector nodes is known. Reach follows from
that plus the grid geometry, which is why this view can offer legal moves without the client ever
telling us which they are.

The exception is the opening. A fresh board has no revealed nodes and the starting position is
renderer-only, so reach cannot be computed for the first move. The view says that plainly and
offers the whole board rather than appearing to have no moves; a click on a node that is not
adjacent to the start is a confirmed harmless no-op.

-}

import EveOnline.ParseUserInterface exposing (HackingTile, HackingWindow)
import Frontend.View.Common as Common exposing (Context)
import Html
import Set


view : Context event -> HackingWindow -> Html.Html event
view context hackingWindow =
    Common.section context
        "Hacking"
        (\contextForContent ->
            statusHtml hackingWindow
                :: movesHtml contextForContent hackingWindow
                ++ revealedHtml contextForContent hackingWindow
        )


{-| The virus, and what the last click uncovered. `lastRevealedNode` is the client's own name for
the node -- `Empty Node`, `Defense Subsystem: Firewall`, `System Core` -- so nothing here is
translated by hand.
-}
statusHtml : HackingWindow -> Html.Html event
statusHtml hackingWindow =
    let
        statLine label maybeValue =
            maybeValue
                |> Maybe.map (\value -> [ label ++ ": " ++ String.fromInt value ])
                |> Maybe.withDefault []
    in
    (statLine "Virus coherence" hackingWindow.virusCoherence
        ++ statLine "Virus strength" hackingWindow.virusStrength
        ++ (hackingWindow.lastRevealedNode
                |> Maybe.map (\name -> [ "Last revealed: " ++ Common.plainText name ])
                |> Maybe.withDefault []
           )
    )
        |> Common.textLines


{-| The nodes a click can reveal. This is the only part needed to make a move.
-}
movesHtml : Context event -> HackingWindow -> List (Html.Html event)
movesHtml context hackingWindow =
    let
        visibleTiles =
            hackingWindow.tiles |> List.filter (.uiNode >> Common.isVisible)

        reachableTiles =
            EveOnline.ParseUserInterface.hackingReachableTiles hackingWindow
                |> List.filter (.uiNode >> Common.isVisible)

        entryForTile tile =
            Common.controlActivateOnly (tileLabel visibleTiles tile) tile.uiNode
    in
    if List.isEmpty reachableTiles then
        {-  Either the board has just opened, or the parse has lost track of it. Offering the whole
            board is honest in the first case and harmless in the second.
        -}
        [ Common.textLines
            [ "No revealed nodes yet, so the starting position is not known — the game client"
                ++ " draws it without telling us where it is. Any node below may be tried; the"
                ++ " ones not next to the start do nothing."
            ]
        , visibleTiles
            |> Common.inReadingOrder
            |> List.map entryForTile
            |> Common.actionList context
        ]

    else
        [ Common.section context
            "Moves"
            (\contextForContent ->
                [ reachableTiles
                    |> Common.inReadingOrder
                    |> List.map entryForTile
                    |> Common.actionList contextForContent
                ]
            )
        ]


{-| The nodes already revealed, nearest the core first, so the strongest lead is announced first.

The number comes from the client's own `distanceIndicatorCont`, which it keeps at zero alpha and
never draws. It is reported here because without it the board cannot be navigated without sight at
all; remove this section to keep the view to what the client shows on screen.
-}
revealedHtml : Context event -> HackingWindow -> List (Html.Html event)
revealedHtml context hackingWindow =
    let
        visibleTiles =
            hackingWindow.tiles |> List.filter (.uiNode >> Common.isVisible)

        revealedTiles =
            visibleTiles
                |> List.filterMap
                    (\tile ->
                        tile.distanceToCore |> Maybe.map (\distance -> ( distance, tile ))
                    )
                |> List.sortBy Tuple.first
    in
    if List.isEmpty revealedTiles then
        []

    else
        [ Common.section context
            "Revealed"
            (\_ ->
                [ revealedTiles
                    |> List.map
                        (\( distance, tile ) ->
                            tileLabel visibleTiles tile
                                ++ ", "
                                ++ String.fromInt distance
                                ++ " from the core"
                        )
                    |> Common.textLines
                ]
            )
        ]


{-| Where a node sits on the board, as a row and a position within that row.

The client gives every tile a display region and nothing else -- no index, no coordinate -- so the
position has to be recovered from geometry. Rows are the distinct centre heights in order down the
board, and the position is the node's place along that row from the left. Odd rows are offset by
half a column on a hex grid, which is why a single column number across the whole board would not
describe it.

-}
tileLabel : List HackingTile -> HackingTile -> String
tileLabel allTiles tile =
    let
        centerOf candidate =
            candidate.uiNode.totalDisplayRegion
                |> EveOnline.ParseUserInterface.centerFromDisplayRegion

        tileCenter =
            centerOf tile

        rowHeights =
            allTiles |> List.map (centerOf >> .y) |> Set.fromList |> Set.toList

        indexIn list value =
            list
                |> List.indexedMap (\index candidate -> ( index, candidate ))
                |> List.filter (Tuple.second >> (==) value)
                |> List.head
                |> Maybe.map (Tuple.first >> (+) 1)

        rowNumber =
            indexIn rowHeights tileCenter.y

        positionInRow =
            allTiles
                |> List.filter (\candidate -> (centerOf candidate).y == tileCenter.y)
                |> List.map (centerOf >> .x)
                |> List.sort
                |> (\rowXs -> indexIn rowXs tileCenter.x)
    in
    case ( rowNumber, positionInRow ) of
        ( Just row, Just position ) ->
            "Row " ++ String.fromInt row ++ ", node " ++ String.fromInt position

        _ ->
            "Node"
