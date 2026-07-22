module Frontend.View.ShipUI exposing (view)

{-| Presents the ship HUD: how the ship is doing, and what can be done to it right now.

This is the one part of the client that is not a window. It lives in `l_viewstate`, below
`l_view_overlays`, and the client draws it as gauges and arcs rather than as text, so almost
nothing here can be read out of the tree as a sentence. Each number below comes from somewhere
different: the hitpoint gauges carry a `_lastValue`, the capacitor is counted in cells, and the
speed is the one value the client formats into a label of its own.

What is absent for now is the name of each module. The client identifies a module button only by an
item id in `_name` and an icon texture path, and puts the real name in a tooltip it shows while the
pointer rests on the slot. So a module is presented by the slot it sits in, which the client does
tell us, and the player learns which is which once.

That is a starting point rather than a limit. Pointing at a slot does *not* mean moving the
player's mouse: the input path posts window messages, and the client takes its pointer position
from those rather than from the real cursor -- measured on 2026-07-22, where the tooltip named
`Core Probe Launcher I` while the physical cursor sat six hundred pixels away. What it does cost is
a posted move, a settle of at least 60ms and a tree read per slot, and it overwrites the client's
single hover slot, replacing whatever tooltip the player was reading. Both are affordable once per
slot and cached; neither is affordable on every refresh. The alternative -- a table mapping icon
texture paths to names -- is the kind of debt rule 4 of CONVENTIONS.md warns about, and goes stale
the first time CCP redraws an icon.

-}

import EveOnline.ParseUserInterface
    exposing
        ( ShipUI
        , ShipUIModuleButton
        , UITreeNodeWithDisplayRegion
        )
import Frontend.View.Common as Common exposing (Context)
import Html


view : Context event -> ShipUI -> Html.Html event
view context shipUI =
    Common.section context
        "Your ship"
        (\contextForContent ->
            Common.textLines (statusLines shipUI)
                :: (modulesSection contextForContent shipUI
                        ++ controlsSection contextForContent shipUI
                   )
        )


{-| The ship's condition, most urgent first.

The indication comes before the gauges because it is the client telling the player that something
is happening to the ship right now -- warping, jumping, docking -- and it is the line that stops
being true soonest.

-}
statusLines : ShipUI -> List String
statusLines shipUI =
    indicationLines shipUI
        ++ (case shipUI.speedText of
                Nothing ->
                    []

                Just speedText ->
                    [ "Speed: " ++ speedText ]
           )
        ++ [ "Shield: " ++ percentText shipUI.hitpointsPercent.shield
           , "Armor: " ++ percentText shipUI.hitpointsPercent.armor
           , "Structure: " ++ percentText shipUI.hitpointsPercent.structure
           ]
        ++ (case shipUI.capacitor.levelFromPmarksPercent of
                Nothing ->
                    []

                Just capacitorPercent ->
                    [ "Capacitor: " ++ percentText capacitorPercent ]
           )
        ++ heatLines shipUI


percentText : Int -> String
percentText percent =
    String.fromInt percent ++ "%"


{-| What the client is announcing about the ship, in its own words.

`ShipUIIndication` also carries a `maneuverType` the parser recognises from a handful of known
strings, but presenting that would mean translating it back into English and losing every case the
list does not cover. The text the client drew is already the right words in the player's own
language, so it is passed through as it is.

The container holds a message node per kind of indication and hides the ones that do not apply, so
the invisible ones are dropped rather than announced.

-}
indicationLines : ShipUI -> List String
indicationLines shipUI =
    case shipUI.indication of
        Nothing ->
            []

        Just indication ->
            indication.uiNode
                |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                |> List.filter (Tuple.second >> Common.isVisible)
                |> List.filterMap
                    (Tuple.first >> EveOnline.ParseUserInterface.discardUnreadableText)
                |> List.map Common.plainText
                |> List.filter (String.isEmpty >> not)
                |> withoutRepeats


{-| Heat, but only once there is heat to report.

A ship that has never overloaded reads zero on all three racks, and three lines of `0%` on every
refresh is noise that pushes the shield and capacitor further down the page.

The racks are named from the order the gauges sit in, which is the order of their resting
rotations -- the same order the overload buttons run in down the HUD. That ordering has only been
seen on a cold ship, where all three read zero, so it is the one label here that has not been
confirmed against a client actually running hot. It is read-only: the overload controls the player
would act on are separate nodes that the client names `overloadBtnHi`, `overloadBtnMed` and
`overloadBtnLo` outright.

-}
heatLines : ShipUI -> List String
heatLines shipUI =
    case shipUI.heatGauges of
        Nothing ->
            []

        Just heatGauges ->
            let
                named =
                    List.map2 Tuple.pair
                        [ "high", "medium", "low" ]
                        (heatGauges.gauges |> List.map .heatPercent)
            in
            if named |> List.all (\( _, heatPercent ) -> Maybe.withDefault 0 heatPercent <= 0) then
                []

            else
                named
                    |> List.filterMap
                        (\( rackName, maybeHeatPercent ) ->
                            maybeHeatPercent
                                |> Maybe.map
                                    (\heatPercent ->
                                        "Heat, " ++ rackName ++ " rack: " ++ percentText heatPercent
                                    )
                        )


modulesSection : Context event -> ShipUI -> List (Html.Html event)
modulesSection context shipUI =
    if List.isEmpty shipUI.moduleButtons then
        []

    else
        [ Common.section context
            "Modules"
            (\_ ->
                [ shipUI.moduleButtons
                    |> Common.inReadingOrder
                    |> List.map moduleEntry
                    |> Common.actionList context
                ]
            )
        ]


moduleEntry : ShipUIModuleButton -> Common.Entry
moduleEntry moduleButton =
    { label = describeSlot moduleButton.slotUINode ++ moduleStateSuffix moduleButton
    , actions =
        [ Common.activate moduleButton.uiNode
        , Common.menu moduleButton.uiNode
        ]
    }


{-| What the client says about the module's state, and nothing more.

`isActive` is read from a `ramp_active` entry that the client leaves out entirely on some modules
rather than setting it to false, so an absent entry is not evidence the module is off and says
nothing here.

-}
moduleStateSuffix : ShipUIModuleButton -> String
moduleStateSuffix moduleButton =
    [ case moduleButton.isActive of
        Just True ->
            Just "active"

        Just False ->
            Just "inactive"

        Nothing ->
            Nothing
    , if moduleButton.isBusy then
        Just "busy"

      else
        Nothing
    ]
        |> List.filterMap identity
        |> (\states ->
                if List.isEmpty states then
                    ""

                else
                    ": " ++ String.join ", " states
           )


{-| The slot a module sits in, from the name the client gives the slot.

The client writes these as `inFlightHighSlot1`, which is structure rather than vocabulary: the
rack and the number are both in there, so splitting it is not the same kind of debt as a table
translating the client's words into ours. A name in any other shape is passed through unchanged
rather than guessed at.

-}
describeSlot : UITreeNodeWithDisplayRegion -> String
describeSlot slotNode =
    case slotNode.uiNode |> EveOnline.ParseUserInterface.getNameFromDictEntries of
        Nothing ->
            "Module"

        Just name ->
            let
                withoutPrefix =
                    if String.startsWith "inFlight" name then
                        String.dropLeft (String.length "inFlight") name

                    else
                        name
            in
            case String.split "Slot" withoutPrefix of
                [ rackName, indexText ] ->
                    rackName ++ " slot " ++ indexText

                _ ->
                    name


{-| The controls that act on the ship as a whole.

Only the two the client labels itself are offered. The rack overload buttons sit beside them on
the HUD and carry the same `Overload Rack` tooltip as each other, so telling them apart means
reading their internal names, which is work for the parser rather than for a view.

-}
controlsSection : Context event -> ShipUI -> List (Html.Html event)
controlsSection context shipUI =
    let
        entries =
            [ shipUI.stopButton |> Maybe.map (controlEntry "Stop the ship")
            , shipUI.maxSpeedButton |> Maybe.map (controlEntry "Maximum speed")
            ]
                |> List.filterMap identity
                |> List.filter (.actions >> List.all (.uiNode >> Common.isVisible))
    in
    if List.isEmpty entries then
        []

    else
        [ Common.section context
            "Ship controls"
            (\_ -> [ Common.actionList context entries ])
        ]


{-| A control named by the client's own tooltip where there is one.

`fallbackLabel` is the debt this view carries: the client leaves `MaxSpeedButton` without a
tooltip, a name, or any text, so there is nothing to read it from. Observed on a docked and an
in-flight client on 2026-07-22. Drop the fallback as soon as the client is seen to supply the name
itself.

-}
controlEntry : String -> UITreeNodeWithDisplayRegion -> Common.Entry
controlEntry fallbackLabel node =
    { label =
        node.uiNode
            |> EveOnline.ParseUserInterface.getHintTextFromDictEntries
            |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
            |> Maybe.map Common.plainText
            |> Maybe.withDefault fallbackLabel
    , actions = [ Common.activate node ]
    }


withoutRepeats : List String -> List String
withoutRepeats =
    List.foldl
        (\item kept ->
            if List.member item kept then
                kept

            else
                item :: kept
        )
        []
        >> List.reverse
