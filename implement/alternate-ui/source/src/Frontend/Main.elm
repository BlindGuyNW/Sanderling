module Frontend.Main exposing (Event(..), State, init, main, update, view)

import Browser
import Browser.Dom
import Browser.Navigation as Navigation
import Common.App
import Common.EffectOnWindow
import CompilationInterface.GenerateJsonConverters
import Dict
import EveOnline.MemoryReading
import EveOnline.ParseUserInterface exposing (UITreeNodeWithDisplayRegion)
import EveOnline.VolatileProcessInterface
import File
import File.Download
import File.Select
import Frontend.InspectParsedUserInterface
    exposing
        ( ExpandableViewNode
        , InputOnUINode(..)
        , InputRoute
        , ParsedUITreeViewPathNode(..)
        , TreeViewNode
        , TreeViewNodeChildren(..)
        , maybeInputOfferHtml
        , renderTreeNodeFromParsedUserInterface
        , treeViewNodeFromMemoryReadingUITreeNode
        )
import Frontend.View.Common
import Frontend.View.GenericWindow
import Frontend.View.HackingWindow
import Frontend.View.Overview
import Frontend.View.ShipUI
import Html
import Html.Attributes as HA
import Html.Attributes.Aria
import Html.Events as HE
import Http
import InterfaceToFrontendClient
import Json.Decode
import List.Extra
import Process
import Set
import Svg
import Svg.Attributes
import Task
import Time
import Url


{-| 2020-01-29 Observation: In this case, I used the alternate UI on the same desktop as the game client. When using a mouse button to click the HTML button, it seemed like sometimes that click interfered with the click on the game client. Using keyboard input on the web page might be sufficient to avoid this issue.
-}
inputDelayDefaultMilliseconds : Int
inputDelayDefaultMilliseconds =
    300


effectSequenceSpacingMilliseconds : Int
effectSequenceSpacingMilliseconds =
    30


{-| How long the pointer has to rest on a node before the game client shows its tooltip. Measured
2026-07-26 against a live client: a tooltip was already present 360 ms after a posted hover on the
Neocom's character button, and absent 230 ms after one on the skills button. The wait is spent
inside the effect sequence rather than in the page, so the volatile process comes back free
exactly when there is something to read, and the reading that follows needs no second attempt in
the common case.
-}
tooltipSettleDelayMilliseconds : Int
tooltipSettleDelayMilliseconds =
    400


{-| When to stop asking and answer "no tooltip". Generous next to the 400 ms the client takes,
because a reading of ours can still be queued behind a whole-tree reading that was already on its
way when the gesture was pressed, and those take up to five seconds.
-}
tooltipInspectionTimeoutMilliseconds : Int
tooltipInspectionTimeoutMilliseconds =
    9000


{-| How many readings of the tooltip layer one inspection may cost. The hover has already waited
for the client before the first of them, so a node with a tooltip answers on that one; the rest
are there for the case where the first reading was queued behind a whole-tree reading and so
arrived describing a moment before the hover landed.
-}
tooltipInspectionReadsPerGesture : Int
tooltipInspectionReadsPerGesture =
    3


{-| The layer the client puts tooltips in. Measured 2026-07-26 by hovering a spread of controls
and reporting where the `TooltipPanel` landed: the Neocom's character and inventory buttons and
the notification feed's icon all produced one in `l_menu`, and `l_hint`, despite the name, stayed
empty throughout. A tooltip that appears somewhere else is not lost -- the inspection falls back
to searching whole readings, it just answers at the speed of one.
-}
tooltipLayerName : String
tooltipLayerName =
    "l_menu"


main : Program () State Event
main =
    Browser.application
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        , onUrlRequest = UrlRequest
        , onUrlChange = UrlChange
        }


type alias State =
    { navigationKey : Navigation.Key
    , timeMilli : Int
    , selectedSource : MemoryReadingSource
    , readFromFileResult : Maybe ParseMemoryReadingCompleted
    , readFromLiveProcess : ReadFromLiveProcessState
    , uiTreeView : UITreeViewState
    , selectedViewMode : ViewMode
    , parsedUITreeView : ParsedUITreeViewState
    , tooltipInspection : TooltipInspectionState
    , inputSequence : InputSequenceState
    }


{-| Effect sequences go to the game client one at a time, the next starting only when the host
has answered for the last.

They used to go the moment they were raised, which was survivable while every one of them came
from a deliberate click. Sending a text field on focus loss ended that: the click that moves the
focus *is* what raises the send, so a field's send and the click on the button next to it are
raised microseconds apart. Both are one request carrying a whole sequence -- and setting a field
is a long one, a click plus End plus a Backspace per character plus a character per character,
spaced 30 ms -- so the two ran concurrently in the host and their messages interleaved. The
button was pressed somewhere in the middle of the typing, acting on the amount the field held
before. On a market order that is the wrong quantity bought.

Queueing makes the order the page raised them in the order the client sees, and it holds for any
two effects raised close together, not only this pair.

-}
type alias InputSequenceState =
    { inFlight : Bool
    , queued : List UserInputSendInputToUINodeStructure
    }


{-| The Shift+F11 gesture: hover a node of the game client, then read back the tooltip the client
shows in response. Waiting is not open-ended -- an element with no tooltip would otherwise wait
forever, so after a few seconds the answer is "no tooltip".

The result is kept until the next inspection so the answer can be read again by navigating to
it, not only heard once from the live region announcement.

The answer does not come from the ordinary readings, because those are far too slow to answer a
gesture: measured against a live client 2026-07-26, one whole-tree reading is 1.25 MB and takes
4.0-5.1 seconds, so waiting for the next one put the announcement about six seconds after the
keypress -- long enough that the feature read as broken. Instead the inspection reads back only
the layer the tooltip appears in, which is 40 KB and takes about 250 ms. `tooltipLayerAddress` is
that layer's address, taken from the reading that was current when the gesture was pressed;
`Nothing` when it could not be resolved, and then the slow path of watching whole readings still
applies, so nothing is worse than before.

-}
type TooltipInspectionState
    = NoTooltipInspection
    | TooltipInspectionPending TooltipInspectionPendingStruct
    | TooltipInspectionCompleted { texts : List String }


type alias TooltipInspectionPendingStruct =
    { beginTimeMilli : Int
    , windowId : EveOnline.VolatileProcessInterface.WindowId
    , tooltipLayerAddress : Maybe String

    {- Whether a request of ours is already on its way to the volatile process. It runs one
       request at a time, so issuing another before the last answered would only queue behind it.
    -}
    , requestOutstanding : Bool

    {- How many more times to look before answering "no tooltip". Counted rather than only timed,
       because most nodes have no tooltip at all: asking again for as long as the timeout allows
       would keep the volatile process busy for seconds on end -- and it is the same one the page
       reads the game through, so that time is taken from the reading the player is looking at.
    -}
    , readsLeft : Int
    }


type alias ReadFromLiveProcessState =
    { listEveOnlineClientProcessesResult : Maybe (Result String (List EveOnline.VolatileProcessInterface.GameClientProcessSummaryStruct))
    , searchUIRootAddressResponse :
        Maybe
            ( EveOnline.VolatileProcessInterface.SearchUIRootAddressStructure
            , Result String EveOnline.VolatileProcessInterface.SearchUIRootAddressResponseStruct
            )
    , readMemoryResult : Maybe (Result String ReadFromLiveProcessCompleted)
    , lastPendingRequestToReadFromGameClientTimeMilli : Maybe Int
    }


type alias ReadFromLiveProcessCompleted =
    { windowId : String
    , memoryReading : ParseMemoryReadingCompleted
    }


type alias ParseMemoryReadingCompleted =
    { serialRepresentationJson : String
    , parseResult : Result Json.Decode.Error ParseMemoryReadingSuccess
    }


type alias ParseMemoryReadingSuccess =
    { uiTree : EveOnline.MemoryReading.UITreeNode
    , uiNodesWithDisplayRegion : Dict.Dict String UITreeNodeWithDisplayRegion
    , parsedUserInterface : EveOnline.ParseUserInterface.ParsedUserInterface

    {- The client's class inheritance, keyed by type name, most-derived first. Empty for a
       reading loaded from a file, which carries no hierarchy - the views that use it fall back
       to what they can tell from the tree alone.
    -}
    , typeHierarchy : Dict.Dict String (List String)
    }


type MemoryReadingSource
    = FromLiveProcess
    | FromFile


type ViewMode
    = ViewAlternateUI
    | ViewUITree
    | ViewParsedUI


type Event
    = BackendResponse { request : InterfaceToFrontendClient.RequestFromClient, result : Result HttpRequestErrorStructure ResponseFromServer }
    | UrlRequest Browser.UrlRequest
    | UrlChange Url.Url
    | UserInputSelectMemoryReadingSource MemoryReadingSource
    | UserInputSelectMemoryReadingFile (Maybe File.File)
    | ReadMemoryReadingFile String
    | UserInputSelectViewMode ViewMode
    | UserInputUISetTreeViewNodeIsExpanded (List ExpandableViewNode) Bool
    | UserInputParsedUISetTreeViewNodeIsExpanded (List ParsedUITreeViewPathNode) Bool
    | ContinueReadFromLiveProcess Time.Posix
    | UserInputDownloadJsonFile String
    | UserInputSendInputToUINode UserInputSendInputToUINodeStructure
    | UserInputFocusInUITree (List ExpandableViewNode)
    | UserInputFocusInParsedUI (List ParsedUITreeViewPathNode)
    | UserInputNavigateToElement String
    | DiscardEvent


type alias HttpRequestErrorStructure =
    { error : Http.Error, bodyString : Maybe String }


type alias UserInputSendInputToUINodeStructure =
    { uiNode : EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion
    , input : InputOnUINode
    , windowId : EveOnline.VolatileProcessInterface.WindowId
    , delayMilliseconds : Maybe Int
    }


type alias ParsedUITreeViewState =
    { expandedNodes : List (List ParsedUITreeViewPathNode)
    , focused : List ParsedUITreeViewPathNode
    }


type alias UITreeViewState =
    { expandedNodes : List (List ExpandableViewNode)
    , focused : List ExpandableViewNode
    }


type ResponseFromServer
    = RunInVolatileProcessResponse InterfaceToFrontendClient.RunInVolatileProcessResponseStructure
    | ReadLogResponse (List String)


type alias InputRouteConfig =
    { windowId : EveOnline.VolatileProcessInterface.WindowId
    }


subscriptions : State -> Sub Event
subscriptions state =
    case state.selectedSource of
        FromFile ->
            Sub.none

        FromLiveProcess ->
            Time.every 1000 ContinueReadFromLiveProcess


init : () -> Url.Url -> Navigation.Key -> ( State, Cmd Event )
init _ url navigationKey =
    { navigationKey = navigationKey
    , timeMilli = 0
    , selectedSource = FromFile
    , readFromLiveProcess =
        { listEveOnlineClientProcessesResult = Nothing
        , searchUIRootAddressResponse = Nothing
        , readMemoryResult = Nothing
        , lastPendingRequestToReadFromGameClientTimeMilli = Nothing
        }
    , readFromFileResult = Nothing
    , uiTreeView = { expandedNodes = [], focused = [] }
    , selectedViewMode = ViewAlternateUI
    , parsedUITreeView = { expandedNodes = [], focused = [] }
    , tooltipInspection = NoTooltipInspection
    , inputSequence = { inFlight = False, queued = [] }
    }
        |> update (UrlChange url)


apiRequestCmd : InterfaceToFrontendClient.RequestFromClient -> Cmd Event
apiRequestCmd request =
    let
        responseDecoder =
            case request of
                InterfaceToFrontendClient.ReadLogRequest ->
                    -- TODO
                    Json.Decode.succeed (ReadLogResponse [])

                InterfaceToFrontendClient.RunInVolatileProcessRequest _ ->
                    CompilationInterface.GenerateJsonConverters.jsonDecodeRunInVolatileProcessResponseStructure
                        |> Json.Decode.map RunInVolatileProcessResponse
    in
    Http.post
        { url = "/api/"
        , expect = httpExpectJson (\result -> BackendResponse { request = request, result = result }) responseDecoder
        , body = Http.jsonBody (request |> CompilationInterface.GenerateJsonConverters.jsonEncodeRequestFromFrontendClient)
        }


update : Event -> State -> ( State, Cmd Event )
update event stateBefore =
    case event of
        BackendResponse { request, result } ->
            let
                ( state, tooltipCmd ) =
                    stateBefore
                        |> integrateBackendResponse { request = request, result = result }
                        |> continueTooltipInspection
            in
            case request of
                --  Answered, so the client is free for whatever was raised while it ran.
                InterfaceToFrontendClient.RunInVolatileProcessRequest (EveOnline.VolatileProcessInterface.EffectSequenceOnWindow _) ->
                    let
                        ( stateAfterQueue, queueCmd ) =
                            continueInputSequenceQueue state
                    in
                    ( stateAfterQueue, Cmd.batch [ tooltipCmd, queueCmd ] )

                _ ->
                    ( state, tooltipCmd )

        UrlChange url ->
            ( stateBefore, Cmd.none )

        UrlRequest urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( stateBefore, Navigation.pushUrl stateBefore.navigationKey (Url.toString url) )

                Browser.External url ->
                    ( stateBefore, Navigation.load url )

        UserInputSelectMemoryReadingSource selectedSource ->
            ( { stateBefore | selectedSource = selectedSource }, Cmd.none )

        UserInputSelectViewMode selectedViewMode ->
            ( { stateBefore | selectedViewMode = selectedViewMode }, Cmd.none )

        UserInputSelectMemoryReadingFile Nothing ->
            ( stateBefore, File.Select.file [ "application/json" ] (Just >> UserInputSelectMemoryReadingFile) )

        UserInputSelectMemoryReadingFile (Just file) ->
            ( stateBefore, Task.perform ReadMemoryReadingFile (File.toString file) )

        ReadMemoryReadingFile serialRepresentationJson ->
            let
                memoryReading =
                    { serialRepresentationJson = serialRepresentationJson
                    , parseResult = serialRepresentationJson |> parseMemoryReadingFromJson Dict.empty
                    }
            in
            ( { stateBefore | readFromFileResult = Just memoryReading }, Cmd.none )

        UserInputUISetTreeViewNodeIsExpanded treeViewNode isExpanded ->
            let
                expandedNodes =
                    if isExpanded then
                        treeViewNode :: stateBefore.uiTreeView.expandedNodes

                    else
                        stateBefore.uiTreeView.expandedNodes |> List.filter ((/=) treeViewNode)

                uiTreeViewBefore =
                    stateBefore.uiTreeView
            in
            ( { stateBefore | uiTreeView = { uiTreeViewBefore | expandedNodes = expandedNodes } }, Cmd.none )

        UserInputParsedUISetTreeViewNodeIsExpanded treeViewNode isExpanded ->
            let
                expandedNodes =
                    if isExpanded then
                        treeViewNode :: stateBefore.parsedUITreeView.expandedNodes

                    else
                        stateBefore.parsedUITreeView.expandedNodes |> List.filter ((/=) treeViewNode)

                parsedUITreeViewBefore =
                    stateBefore.parsedUITreeView
            in
            ( { stateBefore | parsedUITreeView = { parsedUITreeViewBefore | expandedNodes = expandedNodes } }, Cmd.none )

        ContinueReadFromLiveProcess time ->
            let
                timeMilli =
                    Time.posixToMillis time

                {- A whole reading started now would occupy the volatile process for several
                   seconds, and the tooltip the player is waiting for would have to queue behind
                   it. The page goes without one refresh; the gesture answers in about a second
                   instead of six. Only for an inspection that reads a layer of its own -- the
                   slow path resolves from these very readings and would wait forever without
                   them.
                -}
                inspectionReadsForItself =
                    case stateBefore.tooltipInspection of
                        TooltipInspectionPending pending ->
                            pending.tooltipLayerAddress /= Nothing

                        _ ->
                            False

                ( readFromLiveProcessState, cmd ) =
                    if inspectionReadsForItself then
                        ( stateBefore.readFromLiveProcess, Cmd.none )

                    else
                        (stateBefore.readFromLiveProcess |> decideNextStepToReadFromLiveProcess { timeMilli = timeMilli })
                            |> Tuple.mapSecond .nextCmd

                ( state, inspectionCmd ) =
                    { stateBefore | timeMilli = timeMilli, readFromLiveProcess = readFromLiveProcessState }
                        |> continueTooltipInspection
            in
            ( state, Cmd.batch [ cmd, inspectionCmd ] )

        UserInputDownloadJsonFile jsonString ->
            ( stateBefore, File.Download.string "memory-reading.json" "application/json" jsonString )

        UserInputSendInputToUINode sendInput ->
            case sendInput.delayMilliseconds of
                Just delayMilliseconds ->
                    let
                        delayedInputCmd =
                            Task.perform
                                (always (UserInputSendInputToUINode { sendInput | delayMilliseconds = Nothing }))
                                (Process.sleep (toFloat delayMilliseconds))
                    in
                    ( stateBefore, delayedInputCmd )

                Nothing ->
                    let
                        lastParsedReading =
                            stateBefore.readFromLiveProcess
                                |> decideNextStepToReadFromLiveProcess { timeMilli = stateBefore.timeMilli }
                                |> Tuple.second
                                |> .lastMemoryReading
                                |> Maybe.andThen (.memoryReading >> .parseResult >> Result.toMaybe)

                        {- The scroll state of the game client is not something the player should
                           have to know about: an entry the page lists is an entry that can be
                           clicked. When the node sits outside its scroll container's visible
                           area, the click is preceded by the wheel rotation that brings it into
                           view, and aimed at where the node will be afterwards.
                        -}
                        maybeScrollToReveal =
                            case sendInput.input of
                                --  A page scroll targets the scroll container itself.
                                VerticalScrollPage _ ->
                                    Nothing

                                _ ->
                                    lastParsedReading
                                        |> Maybe.andThen (scrollToRevealNode sendInput.uiNode)

                        targetRegion =
                            case maybeScrollToReveal of
                                Just scrollToReveal ->
                                    scrollToReveal.predictedRegion

                                Nothing ->
                                    case sendInput.input of
                                        --  A fraction is measured along the whole control, not
                                        --  along whatever slice of it happens to be unoccluded.
                                        MouseClickAtHorizontalFraction _ ->
                                            sendInput.uiNode.totalDisplayRegion

                                        _ ->
                                            sendInput.uiNode.totalDisplayRegionVisible

                        clickLocation =
                            case sendInput.input of
                                MouseClickAtHorizontalFraction fraction ->
                                    { x =
                                        targetRegion.x
                                            + round (fraction * toFloat (max 0 (targetRegion.width - 1)))
                                    , y = targetRegion.y + targetRegion.height // 2
                                    }

                                _ ->
                                    targetRegion |> EveOnline.ParseUserInterface.centerFromDisplayRegion

                        sequenceElements spacingMilliseconds effects =
                            effects
                                |> List.map (effectOnWindowAsVolatileHostEffectOnWindow >> EveOnline.VolatileProcessInterface.Effect)
                                |> List.intersperse (EveOnline.VolatileProcessInterface.DelayMilliseconds spacingMilliseconds)

                        clickTask =
                            case sendInput.input of
                                {- Scroll the container by whole pages: enough ticks to move
                                   about four fifths of its height per page, so consecutive pages
                                   overlap a little and no row is skipped over.
                                -}
                                VerticalScrollPage pages ->
                                    let
                                        ticksPerPage =
                                            max 1 ((sendInput.uiNode.totalDisplayRegion.height * 4) // (5 * pixelsPerWheelTick))

                                        deltaTicks =
                                            -(pages * ticksPerPage)
                                    in
                                    (Common.EffectOnWindow.MouseMoveTo clickLocation
                                        :: (deltaTicks
                                                |> splitIntoWheelMessages
                                                |> List.map
                                                    (\ticks ->
                                                        Common.EffectOnWindow.VerticalScrollAt
                                                            { location = clickLocation, deltaTicks = ticks }
                                                    )
                                           )
                                    )
                                        |> sequenceElements effectSequenceSpacingMilliseconds

                                MouseClickRight ->
                                    Common.EffectOnWindow.effectsMouseClickAtLocation
                                        Common.EffectOnWindow.MouseButtonRight
                                        clickLocation
                                        |> sequenceElements effectSequenceSpacingMilliseconds

                                MouseClickLeft ->
                                    Common.EffectOnWindow.effectsMouseClickAtLocation
                                        Common.EffectOnWindow.MouseButtonLeft
                                        clickLocation
                                        |> sequenceElements effectSequenceSpacingMilliseconds

                                {- Parking the pointer is the whole effect: the game client shows
                                   the tooltip on its own once the pointer rests there. The wait
                                   for it to do so is part of the sequence, so that the request
                                   comes back at the moment there is something to read rather
                                   than before it.
                                -}
                                MouseHover ->
                                    ([ Common.EffectOnWindow.MouseMoveTo clickLocation ]
                                        |> sequenceElements effectSequenceSpacingMilliseconds
                                    )
                                        ++ [ EveOnline.VolatileProcessInterface.DelayMilliseconds
                                                tooltipSettleDelayMilliseconds
                                           ]

                                --  The slower spacing gives the client a frame to see each stage
                                --  of the drag while the button is down; 150 ms per step moved
                                --  an item stack reliably on a live client, 2026-07-23.
                                MouseDragTo endLocation ->
                                    Common.EffectOnWindow.effectsForDragAndDrop
                                        { startLocation = clickLocation
                                        , mouseButton = Common.EffectOnWindow.MouseButtonLeft
                                        , endLocation = endLocation
                                        }
                                        |> sequenceElements 150

                                {- Setting a slider is a press-move-release rather than a click.
                                   The press already jumps the handle to the pressed position, but
                                   two plain clicks near the same spot in quick succession fall to
                                   the client's double-click detection and set nothing -- observed
                                   on the settings window's master volume slider, 2026-07-23. The
                                   one-pixel drag between press and release keeps repeated
                                   adjustments from ever forming a double-click, and the slower
                                   spacing lets the client see the move while the button is down.
                                -}
                                MouseClickAtHorizontalFraction _ ->
                                    Common.EffectOnWindow.effectsForDragAndDrop
                                        { startLocation = clickLocation
                                        , mouseButton = Common.EffectOnWindow.MouseButtonLeft
                                        , endLocation = { x = clickLocation.x + 1, y = clickLocation.y }
                                        }
                                        |> sequenceElements 100

                                {- Replacing a field's content is a click to focus it, then the
                                   caret to the end of what is there, one Backspace per character
                                   to clear it, and the new text -- and a Return only when the
                                   caller asked for one, because Return commits the dialog around
                                   the field rather than the field. Posted modifier keys do not
                                   register as held -- a posted Ctrl+A typed a literal "a",
                                   measured against a live client 2026-07-23 -- so there is no
                                   select-all, and clearing has to be counted out. The messages
                                   are processed in queue order, so the caret is always placed
                                   before the first character arrives.

                                   The text itself goes as `TypeCharacter`, not as key-downs:
                                   the same absent modifiers that rule out select-all also put
                                   every capital and every shifted symbol out of reach of a key,
                                   which is survivable in a search box and not in a corporation
                                   application.
                                -}
                                TypeTextIntoField typing ->
                                    let
                                        keystroke key =
                                            [ Common.EffectOnWindow.KeyDown key
                                            , Common.EffectOnWindow.KeyUp key
                                            ]

                                        {- A free-text area differs from a one-line field in
                                           three ways, all of them because it has lines. End
                                           reaches the end of the caret's line and no further,
                                           so the caret is walked to the last line first --
                                           Down past the last line does nothing, which makes
                                           overshooting safe where undershooting would leave
                                           the earlier lines behind. Return is a line break
                                           rather than a commit, so the text carries its own
                                           breaks and none is appended at the end. And the
                                           content is the widget's paragraphs rather than a
                                           `textLabel` child, which a text area does not have.
                                        -}
                                        isTextArea =
                                            EveOnline.ParseUserInterface.isEditableTextArea
                                                sendInput.uiNode.uiNode

                                        caretToEnd =
                                            (if isTextArea then
                                                List.repeat
                                                    (linesInTextArea sendInput.uiNode)
                                                    Common.EffectOnWindow.vkey_DOWN

                                             else
                                                []
                                            )
                                                ++ [ Common.EffectOnWindow.vkey_END ]
                                                ++ List.repeat
                                                    (charactersToClearFromTextField sendInput.uiNode)
                                                    Common.EffectOnWindow.vkey_BACK

                                        typeEffects =
                                            typing.text
                                                |> String.toList
                                                |> List.concatMap
                                                    (\character ->
                                                        if character == '\n' then
                                                            keystroke Common.EffectOnWindow.vkey_RETURN

                                                        else
                                                            [ Common.EffectOnWindow.TypeCharacter character ]
                                                    )

                                        commitEffects =
                                            if typing.thenPressReturn && not isTextArea then
                                                keystroke Common.EffectOnWindow.vkey_RETURN

                                            else
                                                []
                                    in
                                    (Common.EffectOnWindow.effectsMouseClickAtLocation
                                        Common.EffectOnWindow.MouseButtonLeft
                                        clickLocation
                                        ++ (caretToEnd |> List.concatMap keystroke)
                                        ++ typeEffects
                                        ++ commitEffects
                                    )
                                        |> sequenceElements effectSequenceSpacingMilliseconds

                        task =
                            case maybeScrollToReveal of
                                Nothing ->
                                    clickTask

                                Just scrollToReveal ->
                                    sequenceElements effectSequenceSpacingMilliseconds scrollToReveal.effects
                                        ++ [ EveOnline.VolatileProcessInterface.DelayMilliseconds scrollSettleDelayMilliseconds ]
                                        ++ clickTask

                        requestSendInputToGameClient =
                            apiRequestCmd
                                (InterfaceToFrontendClient.RunInVolatileProcessRequest
                                    (EveOnline.VolatileProcessInterface.EffectSequenceOnWindow
                                        { windowId = sendInput.windowId
                                        , bringWindowToForeground = False
                                        , task = task
                                        }
                                    )
                                )

                        -- TODO: Remember sending input, to syncronize with get next reading.
                        state =
                            case sendInput.input of
                                MouseHover ->
                                    { stateBefore
                                        | tooltipInspection =
                                            TooltipInspectionPending
                                                { beginTimeMilli = stateBefore.timeMilli
                                                , windowId = sendInput.windowId
                                                , tooltipLayerAddress =
                                                    lastParsedReading |> Maybe.andThen tooltipLayerAddressFromReading
                                                , requestOutstanding = True
                                                , readsLeft = tooltipInspectionReadsPerGesture
                                                }
                                    }

                                _ ->
                                    stateBefore

                        sequenceBefore =
                            stateBefore.inputSequence
                    in
                    if sequenceBefore.inFlight then
                        {- Note that the queued item is the request as the player raised it, not
                           the effects derived from it here: those are derived again when it goes
                           out, from the reading current then. A node that moved while the queue
                           drained is then still aimed at correctly.
                        -}
                        ( { stateBefore
                            | inputSequence =
                                { sequenceBefore | queued = sequenceBefore.queued ++ [ sendInput ] }
                          }
                        , Cmd.none
                        )

                    else
                        ( { state | inputSequence = { sequenceBefore | inFlight = True } }
                        , requestSendInputToGameClient
                        )

        UserInputFocusInUITree focusedPath ->
            let
                uiTreeViewBefore =
                    stateBefore.uiTreeView
            in
            ( { stateBefore | uiTreeView = { uiTreeViewBefore | focused = focusedPath } }, Cmd.none )

        UserInputFocusInParsedUI focusedPath ->
            let
                parsedUITreeViewBefore =
                    stateBefore.parsedUITreeView
            in
            ( { stateBefore | parsedUITreeView = { parsedUITreeViewBefore | focused = focusedPath } }, Cmd.none )

        UserInputNavigateToElement elementId ->
            ( stateBefore, Task.attempt (always DiscardEvent) (Browser.Dom.focus elementId) )

        DiscardEvent ->
            ( stateBefore, Cmd.none )


{-| Send the next queued effect sequence, if the last one left anything waiting.

The queue is released on the answer whether it was a success or an error, so one failed request
does not wedge every later one behind it.

-}
continueInputSequenceQueue : State -> ( State, Cmd Event )
continueInputSequenceQueue stateBefore =
    let
        sequenceBefore =
            stateBefore.inputSequence
    in
    case sequenceBefore.queued of
        [] ->
            ( { stateBefore | inputSequence = { sequenceBefore | inFlight = False } }, Cmd.none )

        next :: rest ->
            { stateBefore | inputSequence = { inFlight = False, queued = rest } }
                |> update (UserInputSendInputToUINode next)


{-| One tick of the mouse wheel moves a scroll container of the game client by this many pixels.
Measured against the settings window's panel on 2026-07-23: single ticks moved the content 50 px
each, and five ticks in one message moved it 252 px. The click after a scroll aims to land the
node at the middle of the viewport, so a container that scrolls somewhat faster or slower than
this still leaves the node within reach.
-}
pixelsPerWheelTick : Int
pixelsPerWheelTick =
    50


{-| How many Down-arrows put the caret on the last line of a free-text area.

The client leaves one node per drawn line under the widget, so counting them is counting the
lines -- as they wrapped on screen, which is what the caret moves through. Two spare, because
Down on the last line does nothing while one short of the last line leaves text behind, and
because the player may have typed since the reading was taken.

-}
linesInTextArea : EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion -> Int
linesInTextArea fieldNode =
    (fieldNode
        |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
        |> List.filter (.uiNode >> .pythonObjectTypeName >> String.contains "EditTextline")
        |> List.length
    )
        + 2


{-| How many Backspaces clear a text field: the length of the text its `textLabel` child shows,
or -- for a free-text area, which has no such child -- the length of the paragraphs the widget
renders. The one-line field also holds a `hintTextLabel`, the placeholder drawn only while the
field is empty, whose text is not content and does not count. Content the reading could not
recover means an unknown length, so a generous fixed count: Backspace in an already-empty field
does nothing, so overshooting is safe where undershooting leaves old text in front of the new.
The few extra on a readable length cover characters typed since the reading was taken.
-}
charactersToClearFromTextField : EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion -> Int
charactersToClearFromTextField fieldNode =
    if EveOnline.ParseUserInterface.isEditableTextArea fieldNode.uiNode then
        {- The margin applies to the empty case too, and deliberately. `getParagraphsText`
           answers `Nothing` both for a box that is empty and for one whose text could not be
           read, and clearing nothing at all is only right for the first: a box that took a
           character after the reading was taken would keep it, in front of whatever is typed
           next. This is a margin, not a cure -- the count still comes from a sample, and only
           reading the field back after the send would actually settle it.
        -}
        fieldNode.uiNode
            |> EveOnline.ParseUserInterface.getParagraphsText
            |> Maybe.map String.length
            |> Maybe.withDefault 0
            |> (+) 4

    else
        charactersToClearFromOneLineField fieldNode


charactersToClearFromOneLineField : EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion -> Int
charactersToClearFromOneLineField fieldNode =
    case
        fieldNode
            |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
            |> List.filter
                (.uiNode
                    >> EveOnline.ParseUserInterface.getNameFromDictEntries
                    >> (==) (Just "textLabel")
                )
            |> List.filterMap (.uiNode >> EveOnline.ParseUserInterface.getDisplayText)
            |> List.head
    of
        Nothing ->
            0

        Just displayText ->
            case EveOnline.ParseUserInterface.discardUnreadableText displayText of
                Nothing ->
                    30

                Just readableText ->
                    String.length readableText + 4


{-| How long to give the game client to complete a scroll before clicking where the node is
predicted to be. Scrolling settles well within this on the settings window.
-}
scrollSettleDelayMilliseconds : Int
scrollSettleDelayMilliseconds =
    300


{-| The wheel delta field of a window message is 16 bits, so one message can carry only so many
ticks. Splitting far scrolls into several messages keeps each within range; 25 ticks is 1250 px.
-}
maximumWheelTicksPerMessage : Int
maximumWheelTicksPerMessage =
    25


type alias ScrollToRevealStructure =
    { effects : List Common.EffectOnWindow.EffectOnWindowStructure
    , predictedRegion : EveOnline.ParseUserInterface.DisplayRegion
    }


{-| The wheel rotations that bring the given node into the visible part of its scroll container,
and where the node will be once they have happened -- or `Nothing` when the node needs no
scrolling to be clicked.

The node the view carried may come from an older reading than the latest one, so it is first
re-resolved by its address. The scroll distance aims to land the node at the middle of the
viewport, capped at the end of the container's content so the prediction cannot outrun the
client's own clamping -- without the cap, asking for a node near the content's end would predict
a position the clamped scroll never reaches, and the click would land far from it.

-}
scrollToRevealNode : EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion -> ParseMemoryReadingSuccess -> Maybe ScrollToRevealStructure
scrollToRevealNode nodeAsCarried parseSuccess =
    let
        node =
            parseSuccess.uiNodesWithDisplayRegion
                |> Dict.get nodeAsCarried.uiNode.pythonObjectAddress
                |> Maybe.withDefault nodeAsCarried

        nodeCenter =
            node.totalDisplayRegion |> EveOnline.ParseUserInterface.centerFromDisplayRegion
    in
    ancestorsOfNode node.uiNode.pythonObjectAddress parseSuccess.parsedUserInterface.uiTree
        |> Maybe.withDefault []
        |> List.filter (Frontend.View.Common.isScrollingContainer parseSuccess.typeHierarchy)
        --  The nearest enclosing scroll container: ancestors arrive root-first.
        |> List.reverse
        |> List.head
        |> Maybe.andThen
            (\scrollContainer ->
                let
                    viewport =
                        scrollContainer.totalDisplayRegion

                    viewportTop =
                        viewport.y

                    viewportBottom =
                        viewport.y + viewport.height

                    viewportMiddle =
                        viewport.y + viewport.height // 2

                    margin =
                        min 100 (viewport.height // 4)

                    descendantRegions =
                        scrollContainer
                            |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                            |> List.map .totalDisplayRegion

                    contentTop =
                        descendantRegions |> List.map .y |> List.minimum |> Maybe.withDefault viewportTop

                    contentBottom =
                        descendantRegions
                            |> List.map (\region -> region.y + region.height)
                            |> List.maximum
                            |> Maybe.withDefault viewportBottom

                    scrollPixels =
                        if viewportBottom - margin < nodeCenter.y then
                            --  Below the fold: scroll the view down, at most to the content's end.
                            min (nodeCenter.y - viewportMiddle) (contentBottom - viewportBottom) |> max 0

                        else if nodeCenter.y < viewportTop + margin then
                            --  Above the fold: scroll the view up, at most to the content's start.
                            -(min (viewportMiddle - nodeCenter.y) (viewportTop - contentTop) |> max 0)

                        else
                            0

                    --  Wheel convention: negative ticks scroll the view down.
                    deltaTicks =
                        -((abs scrollPixels + pixelsPerWheelTick // 2) // pixelsPerWheelTick)
                            * (if 0 < scrollPixels then
                                1

                               else
                                -1
                              )

                    wheelLocation =
                        viewport |> EveOnline.ParseUserInterface.centerFromDisplayRegion

                    nodeRegion =
                        node.totalDisplayRegion

                    predictedRegion =
                        { nodeRegion | y = nodeRegion.y + deltaTicks * pixelsPerWheelTick }
                in
                if deltaTicks == 0 then
                    Nothing

                else
                    Just
                        { effects =
                            Common.EffectOnWindow.MouseMoveTo wheelLocation
                                :: (deltaTicks
                                        |> splitIntoWheelMessages
                                        |> List.map
                                            (\ticks ->
                                                Common.EffectOnWindow.VerticalScrollAt
                                                    { location = wheelLocation, deltaTicks = ticks }
                                            )
                                   )
                        , predictedRegion = predictedRegion
                        }
            )


splitIntoWheelMessages : Int -> List Int
splitIntoWheelMessages totalTicks =
    if totalTicks == 0 then
        []

    else
        let
            step =
                clamp (negate maximumWheelTicksPerMessage) maximumWheelTicksPerMessage totalTicks
        in
        step :: splitIntoWheelMessages (totalTicks - step)


{-| The nodes above the one with the given address, from the root down, excluding the node itself.
-}
ancestorsOfNode : String -> EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion -> Maybe (List EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion)
ancestorsOfNode nodeAddress fromNode =
    if fromNode.uiNode.pythonObjectAddress == nodeAddress then
        Just []

    else
        fromNode
            |> EveOnline.ParseUserInterface.listChildrenWithDisplayRegion
            |> List.filterMap (ancestorsOfNode nodeAddress >> Maybe.map ((::) fromNode))
            |> List.head


effectOnWindowAsVolatileHostEffectOnWindow : Common.EffectOnWindow.EffectOnWindowStructure -> EveOnline.VolatileProcessInterface.EffectOnWindowStructure
effectOnWindowAsVolatileHostEffectOnWindow effectOnWindow =
    case effectOnWindow of
        Common.EffectOnWindow.MouseMoveTo mouseMoveTo ->
            EveOnline.VolatileProcessInterface.MouseMoveTo { location = mouseMoveTo }

        Common.EffectOnWindow.VerticalScrollAt verticalScrollAt ->
            EveOnline.VolatileProcessInterface.VerticalScrollAt
                { location = verticalScrollAt.location
                , deltaTicks = verticalScrollAt.deltaTicks
                }

        Common.EffectOnWindow.KeyDown key ->
            EveOnline.VolatileProcessInterface.KeyDown key

        Common.EffectOnWindow.KeyUp key ->
            EveOnline.VolatileProcessInterface.KeyUp key

        Common.EffectOnWindow.TypeCharacter character ->
            EveOnline.VolatileProcessInterface.TypeCharacter (Char.toCode character)


integrateBackendResponse : { request : InterfaceToFrontendClient.RequestFromClient, result : Result HttpRequestErrorStructure ResponseFromServer } -> State -> State
integrateBackendResponse { request, result } stateBefore =
    case request of
        -- TODO: Consolidate unpack response common parts.
        InterfaceToFrontendClient.RunInVolatileProcessRequest EveOnline.VolatileProcessInterface.ListGameClientProcessesRequest ->
            let
                listEveOnlineClientProcessesResult =
                    result
                        |> Result.mapError describeHttpError
                        |> Result.andThen
                            (\response ->
                                case response of
                                    ReadLogResponse _ ->
                                        Err "Unexpected response"

                                    RunInVolatileProcessResponse runInVolatileProcessResponse ->
                                        case runInVolatileProcessResponse of
                                            InterfaceToFrontendClient.SetupNotCompleteResponse status ->
                                                Err ("Volatile process setup not complete: " ++ status)

                                            InterfaceToFrontendClient.RunInVolatileProcessCompleteResponse runInVolatileHostCompleteResponse ->
                                                case runInVolatileHostCompleteResponse.exceptionToString of
                                                    Just exception ->
                                                        Err ("Failed with exception: " ++ exception)

                                                    Nothing ->
                                                        runInVolatileHostCompleteResponse.returnValueToString
                                                            |> Maybe.withDefault ""
                                                            |> EveOnline.VolatileProcessInterface.deserializeResponseFromVolatileHost
                                                            |> Result.mapError Json.Decode.errorToString
                                                            |> Result.andThen
                                                                (\responseFromVolatileHost ->
                                                                    case responseFromVolatileHost of
                                                                        EveOnline.VolatileProcessInterface.ListGameClientProcessesResponse gameClientProcesses ->
                                                                            Ok gameClientProcesses

                                                                        EveOnline.VolatileProcessInterface.SearchUIRootAddressResponse _ ->
                                                                            Err "Unexpected response: SearchUIRootAddressResponse"

                                                                        EveOnline.VolatileProcessInterface.ReadFromWindowResult _ ->
                                                                            Err "Unexpected response: ReadFromWindowResult"

                                                                        EveOnline.VolatileProcessInterface.FailedToBringWindowToFront failedToBringWindowToFront ->
                                                                            Err ("Unexpected response: FailedToBringWindowToFront: " ++ failedToBringWindowToFront)

                                                                        EveOnline.VolatileProcessInterface.CompletedEffectSequenceOnWindow ->
                                                                            Err "Unexpected response: CompletedEffectSequenceOnWindow"
                                                                )
                            )

                readFromLiveProcessBefore =
                    stateBefore.readFromLiveProcess
            in
            { stateBefore
                | readFromLiveProcess =
                    { readFromLiveProcessBefore
                        | listEveOnlineClientProcessesResult = Just listEveOnlineClientProcessesResult
                        , searchUIRootAddressResponse = Nothing
                        , readMemoryResult = Nothing
                    }
            }

        InterfaceToFrontendClient.RunInVolatileProcessRequest (EveOnline.VolatileProcessInterface.ReadFromWindow readFromWindow) ->
            let
                readMemoryResult =
                    result
                        |> Result.mapError describeHttpError
                        |> Result.andThen
                            (\response ->
                                case response of
                                    ReadLogResponse _ ->
                                        Err "Unexpected response"

                                    RunInVolatileProcessResponse runInVolatileProcessResponse ->
                                        case runInVolatileProcessResponse of
                                            InterfaceToFrontendClient.SetupNotCompleteResponse status ->
                                                Err ("Volatile process setup not complete: " ++ status)

                                            InterfaceToFrontendClient.RunInVolatileProcessCompleteResponse runInVolatileProcessCompleteResponse ->
                                                case runInVolatileProcessCompleteResponse.exceptionToString of
                                                    Just exception ->
                                                        Err ("Failed with exception: " ++ exception)

                                                    Nothing ->
                                                        runInVolatileProcessCompleteResponse.returnValueToString
                                                            |> Maybe.withDefault ""
                                                            |> EveOnline.VolatileProcessInterface.deserializeResponseFromVolatileHost
                                                            |> Result.mapError Json.Decode.errorToString
                                                            |> Result.andThen
                                                                (\responseFromVolatileProcess ->
                                                                    case responseFromVolatileProcess of
                                                                        EveOnline.VolatileProcessInterface.ListGameClientProcessesResponse _ ->
                                                                            Err "Unexpected response: ListGameClientProcessesResponse"

                                                                        EveOnline.VolatileProcessInterface.SearchUIRootAddressResponse _ ->
                                                                            Err "Unexpected response: SearchUIRootAddressResponse"

                                                                        EveOnline.VolatileProcessInterface.ReadFromWindowResult readFromWindowResult ->
                                                                            case readFromWindowResult of
                                                                                EveOnline.VolatileProcessInterface.ProcessNotFound ->
                                                                                    Err "Process not found"

                                                                                EveOnline.VolatileProcessInterface.Completed memoryReadingCompleted ->
                                                                                    Ok memoryReadingCompleted

                                                                        EveOnline.VolatileProcessInterface.FailedToBringWindowToFront failedToBringWindowToFront ->
                                                                            Err ("Unexpected response: FailedToBringWindowToFront: " ++ failedToBringWindowToFront)

                                                                        EveOnline.VolatileProcessInterface.CompletedEffectSequenceOnWindow ->
                                                                            Err "Unexpected response: CompletedEffectSequenceOnWindow"
                                                                )
                            )
                        |> Result.andThen
                            (\readingCompleted ->
                                case readingCompleted.memoryReadingSerialRepresentationJson of
                                    Nothing ->
                                        Err "Memory reading completed, but 'serialRepresentationJson' is null. Please configure EVE Online client and restart."

                                    Just memoryReadingSerialRepresentationJson ->
                                        Ok
                                            { windowId = readFromWindow.windowId
                                            , memoryReading =
                                                { serialRepresentationJson = memoryReadingSerialRepresentationJson
                                                , parseResult =
                                                    memoryReadingSerialRepresentationJson
                                                        |> parseMemoryReadingFromJson
                                                            (decodePythonTypeHierarchyFromJson
                                                                readingCompleted.pythonTypeHierarchySerialRepresentationJson
                                                            )
                                                }
                                            }
                            )

                readFromLiveProcessBefore =
                    stateBefore.readFromLiveProcess

                parsedReading =
                    readMemoryResult
                        |> Result.toMaybe
                        |> Maybe.andThen (.memoryReading >> .parseResult >> Result.toMaybe)

                {- Which of the two kinds of reading this answer belongs to. They are told apart
                   by the address the reading started from, and telling them apart matters: a
                   tooltip inspection reads back a single layer, and letting that stand as the
                   last whole-tree reading would replace everything the page shows with the
                   contents of that one layer.
                -}
                tooltipLayerReadingPending =
                    case stateBefore.tooltipInspection of
                        TooltipInspectionPending pending ->
                            if pending.tooltipLayerAddress == Just readFromWindow.uiRootAddress then
                                Just pending

                            else
                                Nothing

                        _ ->
                            Nothing

                --  The slow path, for an inspection that could not resolve a layer to read.
                tooltipInspection =
                    case stateBefore.tooltipInspection of
                        TooltipInspectionPending pending ->
                            case ( pending.tooltipLayerAddress, parsedReading ) of
                                ( Nothing, Just parseSuccess ) ->
                                    resolveTooltipInspection
                                        { readingRequestTimeMilli =
                                            readFromLiveProcessBefore.lastPendingRequestToReadFromGameClientTimeMilli
                                                |> Maybe.withDefault stateBefore.timeMilli
                                        }
                                        pending
                                        parseSuccess

                                _ ->
                                    stateBefore.tooltipInspection

                        other ->
                            other
            in
            case tooltipLayerReadingPending of
                Just pending ->
                    { stateBefore
                        | tooltipInspection =
                            resolveTooltipInspectionFromLayerReading
                                { timeMilli = stateBefore.timeMilli }
                                pending
                                parsedReading
                    }

                Nothing ->
                    { stateBefore
                        | readFromLiveProcess =
                            { readFromLiveProcessBefore
                                | readMemoryResult = Just readMemoryResult
                                , lastPendingRequestToReadFromGameClientTimeMilli = Nothing
                            }
                        , tooltipInspection = tooltipInspection
                    }

        {- The hover of a tooltip inspection is sent as an effect sequence that ends in the wait
           for the client to show the tooltip, so this answer means the volatile process is free
           again and there is something to read. `continueTooltipInspection` sends that reading.
        -}
        InterfaceToFrontendClient.RunInVolatileProcessRequest (EveOnline.VolatileProcessInterface.EffectSequenceOnWindow _) ->
            case stateBefore.tooltipInspection of
                TooltipInspectionPending pending ->
                    { stateBefore | tooltipInspection = TooltipInspectionPending { pending | requestOutstanding = False } }

                _ ->
                    stateBefore

        InterfaceToFrontendClient.RunInVolatileProcessRequest (EveOnline.VolatileProcessInterface.SearchUIRootAddress searchUIRootRequest) ->
            let
                searchUIRootResult =
                    result
                        |> Result.mapError describeHttpError
                        |> Result.andThen
                            (\response ->
                                case response of
                                    ReadLogResponse _ ->
                                        Err "Unexpected response"

                                    RunInVolatileProcessResponse runInVolatileProcessResponse ->
                                        case runInVolatileProcessResponse of
                                            InterfaceToFrontendClient.SetupNotCompleteResponse status ->
                                                Err ("Volatile process setup not complete: " ++ status)

                                            InterfaceToFrontendClient.RunInVolatileProcessCompleteResponse runInVolatileHostCompleteResponse ->
                                                case runInVolatileHostCompleteResponse.exceptionToString of
                                                    Just exception ->
                                                        Err ("Failed with exception: " ++ exception)

                                                    Nothing ->
                                                        runInVolatileHostCompleteResponse.returnValueToString
                                                            |> Maybe.withDefault ""
                                                            |> EveOnline.VolatileProcessInterface.deserializeResponseFromVolatileHost
                                                            |> Result.mapError Json.Decode.errorToString
                                                            |> Result.andThen
                                                                (\responseFromVolatileHost ->
                                                                    case responseFromVolatileHost of
                                                                        EveOnline.VolatileProcessInterface.ListGameClientProcessesResponse _ ->
                                                                            Err "Unexpected response: ListGameClientProcessesResponse"

                                                                        EveOnline.VolatileProcessInterface.SearchUIRootAddressResponse searchUIRootAddressResponse ->
                                                                            Ok searchUIRootAddressResponse

                                                                        EveOnline.VolatileProcessInterface.ReadFromWindowResult _ ->
                                                                            Err "Unexpected response: ReadFromWindowResult"

                                                                        EveOnline.VolatileProcessInterface.FailedToBringWindowToFront failedToBringWindowToFront ->
                                                                            Err ("Unexpected response: FailedToBringWindowToFront: " ++ failedToBringWindowToFront)

                                                                        EveOnline.VolatileProcessInterface.CompletedEffectSequenceOnWindow ->
                                                                            Err "Unexpected response: CompletedEffectSequenceOnWindow"
                                                                )
                            )

                readFromLiveProcessBefore =
                    stateBefore.readFromLiveProcess
            in
            { stateBefore
                | readFromLiveProcess =
                    { readFromLiveProcessBefore
                        | searchUIRootAddressResponse = Just ( searchUIRootRequest, searchUIRootResult )
                        , lastPendingRequestToReadFromGameClientTimeMilli = Nothing
                    }
            }

        _ ->
            stateBefore


{-| What to do next about a pending tooltip inspection: send the reading that answers it, give up
on it, or wait for an answer that is already on its way.

The reading covers only the layer tooltips appear in, so it costs a fraction of a whole-tree
reading and the gesture can answer in about a second instead of six. One request at a time,
because the volatile process serves one at a time anyway.

-}
continueTooltipInspection : State -> ( State, Cmd Event )
continueTooltipInspection stateBefore =
    case stateBefore.tooltipInspection of
        TooltipInspectionPending pending ->
            case pending.tooltipLayerAddress of
                --  Nothing to read from: the slow path answers this one, from whole readings.
                Nothing ->
                    ( stateBefore, Cmd.none )

                Just tooltipLayerAddress ->
                    if pending.requestOutstanding then
                        ( stateBefore, Cmd.none )

                    else if
                        (pending.readsLeft < 1)
                            || (pending.beginTimeMilli + tooltipInspectionTimeoutMilliseconds < stateBefore.timeMilli)
                    then
                        ( { stateBefore | tooltipInspection = TooltipInspectionCompleted { texts = [] } }, Cmd.none )

                    else
                        ( { stateBefore
                            | tooltipInspection =
                                TooltipInspectionPending
                                    { pending | requestOutstanding = True, readsLeft = pending.readsLeft - 1 }
                          }
                        , apiRequestCmd
                            (InterfaceToFrontendClient.RunInVolatileProcessRequest
                                (EveOnline.VolatileProcessInterface.ReadFromWindow
                                    { windowId = pending.windowId
                                    , uiRootAddress = tooltipLayerAddress
                                    }
                                )
                            )
                        )

        _ ->
            ( stateBefore, Cmd.none )


{-| Whether a reading of the tooltip layer settles the inspection that asked for it.

An empty layer is not yet an answer: the client may still be about to show the tooltip, and a
reading that was queued behind a whole-tree reading can be older than it looks. So an empty one
only asks again, until the inspection times out and the answer becomes "no tooltip" -- ending the
wait is what keeps the page from promising a tooltip that is never coming.

-}
resolveTooltipInspectionFromLayerReading :
    { timeMilli : Int }
    -> TooltipInspectionPendingStruct
    -> Maybe ParseMemoryReadingSuccess
    -> TooltipInspectionState
resolveTooltipInspectionFromLayerReading { timeMilli } pending maybeParseSuccess =
    case maybeParseSuccess |> Maybe.map tooltipTextsFromReading of
        --  The reading failed. Asking again would most likely fail the same way.
        Nothing ->
            TooltipInspectionCompleted { texts = [] }

        Just [] ->
            if pending.beginTimeMilli + tooltipInspectionTimeoutMilliseconds < timeMilli then
                TooltipInspectionCompleted { texts = [] }

            else
                TooltipInspectionPending { pending | requestOutstanding = False }

        Just texts ->
            TooltipInspectionCompleted { texts = texts }


{-| The address of the layer the client shows tooltips in, to read back on its own.
-}
tooltipLayerAddressFromReading : ParseMemoryReadingSuccess -> Maybe String
tooltipLayerAddressFromReading parseSuccess =
    parseSuccess.parsedUserInterface.layers
        |> List.filter (.name >> (==) tooltipLayerName)
        |> List.head
        |> Maybe.map (.uiNode >> .uiNode >> .pythonObjectAddress)


{-| Whether a whole reading settles a pending tooltip inspection. The slow path, for an inspection
that could not resolve a layer of its own to read.

A reading requested before the hover had time to land -- the effect's own latency plus the
client's delay before showing a tooltip -- can only show the state from before the gesture,
including a leftover tooltip from wherever the pointer previously rested, so it neither confirms
nor denies. From then on, the first reading with tooltip text answers the inspection.

-}
resolveTooltipInspection :
    { readingRequestTimeMilli : Int }
    -> TooltipInspectionPendingStruct
    -> ParseMemoryReadingSuccess
    -> TooltipInspectionState
resolveTooltipInspection { readingRequestTimeMilli } pending parseSuccess =
    if readingRequestTimeMilli < pending.beginTimeMilli + 800 then
        TooltipInspectionPending pending

    else
        case tooltipTextsFromReading parseSuccess of
            [] ->
                if pending.beginTimeMilli + tooltipInspectionTimeoutMilliseconds < readingRequestTimeMilli then
                    TooltipInspectionCompleted { texts = [] }

                else
                    TooltipInspectionPending pending

            texts ->
                TooltipInspectionCompleted { texts = texts }


{-| The texts of the tooltip panels a reading contains, in the order they are laid out.

The panel is told by the `TooltipPanel` class in its inheritance chain, falling back to the type
name itself for a reading that carries no hierarchy. Observed 2026-07-23: the multibuy window's
price comparison tooltip is a `TooltipPanel` in the `l_menu` layer, a grid of label and value
cells reading "Price per unit", "6.90 ISK", "Regional average 117.7%", ...

-}
tooltipTextsFromReading : ParseMemoryReadingSuccess -> List String
tooltipTextsFromReading memoryReading =
    memoryReading.parsedUserInterface.uiTree
        |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
        |> List.filter
            (\node ->
                let
                    typeName =
                        node.uiNode.pythonObjectTypeName
                in
                Dict.get typeName memoryReading.typeHierarchy
                    |> Maybe.withDefault [ typeName ]
                    |> List.member "TooltipPanel"
            )
        |> List.filter Frontend.View.Common.isVisible
        |> List.concatMap
            (\panel ->
                panel
                    |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                    |> List.map (\( text, textNode ) -> { uiNode = textNode, text = text })
                    |> Frontend.View.Common.inReadingOrder
                    |> List.filterMap (.text >> EveOnline.ParseUserInterface.discardUnreadableText)
                    |> List.map Frontend.View.Common.plainText
                    |> List.filter (String.isEmpty >> not)
            )


decideNextStepToReadFromLiveProcess :
    { timeMilli : Int }
    -> ReadFromLiveProcessState
    ->
        ( ReadFromLiveProcessState
        , { describeState : String
          , lastMemoryReading : Maybe ReadFromLiveProcessCompleted
          , nextCmd : Cmd.Cmd Event
          }
        )
decideNextStepToReadFromLiveProcess { timeMilli } stateBefore =
    let
        requestListGameClientProcesses =
            apiRequestCmd
                (InterfaceToFrontendClient.RunInVolatileProcessRequest
                    EveOnline.VolatileProcessInterface.ListGameClientProcessesRequest
                )

        requestSearchUIRootFrequently config =
            let
                gameClientProcessId =
                    config.selectGameClientResult.selectedProcess.processId

                requestSearchUIRoot =
                    apiRequestCmd
                        (InterfaceToFrontendClient.RunInVolatileProcessRequest
                            (EveOnline.VolatileProcessInterface.SearchUIRootAddress { processId = gameClientProcessId })
                        )

                searchStillPending =
                    stateBefore.lastPendingRequestToReadFromGameClientTimeMilli
                        |> Maybe.map (\pendingReadingTimeMilli -> timeMilli < pendingReadingTimeMilli + 1000)
                        |> Maybe.withDefault False

                ( state, nextCmd ) =
                    if searchStillPending then
                        ( stateBefore, Cmd.none )

                    else
                        ( { stateBefore | lastPendingRequestToReadFromGameClientTimeMilli = Just timeMilli }
                        , requestSearchUIRoot
                        )

                inProgressAddition =
                    case config.searchInProgress of
                        Nothing ->
                            ""

                        Just searchInProgress ->
                            " since "
                                ++ String.fromInt ((searchInProgress.currentTimeMilliseconds - searchInProgress.searchBeginTimeMilliseconds) // 1000)
                                ++ " seconds"

                describeState =
                    (("Searching the address of the UI root in process "
                        ++ String.fromInt gameClientProcessId
                        ++ inProgressAddition
                        ++ "..."
                     )
                        :: config.selectGameClientResult.report
                    )
                        |> String.join "\n"
            in
            ( state
            , { describeState = describeState
              , lastMemoryReading = Nothing
              , nextCmd = nextCmd
              }
            )
    in
    case stateBefore.listEveOnlineClientProcessesResult of
        Nothing ->
            ( stateBefore
            , { describeState = "Did not yet search for the IDs of the EVE Online client processes."
              , lastMemoryReading = Nothing
              , nextCmd = requestListGameClientProcesses
              }
            )

        Just (Err error) ->
            ( stateBefore
            , { describeState = "Failed to get IDs of the EVE Online client processes: " ++ error
              , lastMemoryReading = Nothing
              , nextCmd = requestListGameClientProcesses
              }
            )

        Just (Ok eveOnlineClientProcesses) ->
            case eveOnlineClientProcesses |> selectGameClientProcess of
                Err error ->
                    ( stateBefore
                    , { describeState = error ++ " Looks like there is no EVE Online client process started. I continue looking in case one is started..."
                      , lastMemoryReading = Nothing
                      , nextCmd = requestListGameClientProcesses
                      }
                    )

                Ok selectGameClientResult ->
                    case stateBefore.searchUIRootAddressResponse of
                        Nothing ->
                            requestSearchUIRootFrequently
                                { selectGameClientResult = selectGameClientResult
                                , searchInProgress = Nothing
                                }

                        Just ( searchUIRootRequest, Err error ) ->
                            ( stateBefore
                            , { describeState =
                                    "Failed to search the UI root in process "
                                        ++ (searchUIRootRequest.processId |> String.fromInt)
                                        ++ ": "
                                        ++ error
                              , lastMemoryReading = Nothing
                              , nextCmd = Cmd.none
                              }
                            )

                        Just ( _, Ok searchUIRootAddressResponse ) ->
                            case searchUIRootAddressResponse.stage of
                                EveOnline.VolatileProcessInterface.SearchUIRootAddressInProgress searchInProgress ->
                                    requestSearchUIRootFrequently
                                        { selectGameClientResult = selectGameClientResult
                                        , searchInProgress = Just searchInProgress
                                        }

                                EveOnline.VolatileProcessInterface.SearchUIRootAddressCompleted searchUIRootAddressResult ->
                                    case searchUIRootAddressResult.uiRootAddress of
                                        Nothing ->
                                            ( stateBefore
                                            , { describeState =
                                                    "Did not find the UI root in process "
                                                        ++ String.fromInt searchUIRootAddressResponse.processId
                                              , lastMemoryReading = Nothing
                                              , nextCmd = Cmd.none
                                              }
                                            )

                                        Just uiRootAddress ->
                                            case
                                                stateBefore.listEveOnlineClientProcessesResult
                                                    |> Maybe.andThen Result.toMaybe
                                                    |> Maybe.andThen (List.filter (.processId >> (==) searchUIRootAddressResponse.processId) >> List.head)
                                            of
                                                Nothing ->
                                                    ( stateBefore
                                                    , { describeState = "Did not find a matching entry in the list of the EVE Online client processes."
                                                      , lastMemoryReading = Nothing
                                                      , nextCmd = requestListGameClientProcesses
                                                      }
                                                    )

                                                Just gameClientProcess ->
                                                    let
                                                        requestReadMemory =
                                                            apiRequestCmd
                                                                (InterfaceToFrontendClient.RunInVolatileProcessRequest
                                                                    (EveOnline.VolatileProcessInterface.ReadFromWindow
                                                                        { windowId = gameClientProcess.mainWindowId
                                                                        , uiRootAddress = uiRootAddress
                                                                        }
                                                                    )
                                                                )

                                                        ( describeLastReadResult, lastMemoryReading ) =
                                                            case stateBefore.readMemoryResult of
                                                                Nothing ->
                                                                    ( "", Nothing )

                                                                Just (Err error) ->
                                                                    ( "The last attempt to read from the game client process failed: " ++ error, Nothing )

                                                                Just (Ok lastMemoryReadingCompleted) ->
                                                                    ( "The last attempt to read from the game client process was successful.", Just lastMemoryReadingCompleted )

                                                        memoryReadingStillPending =
                                                            stateBefore.lastPendingRequestToReadFromGameClientTimeMilli
                                                                |> Maybe.map (\pendingReadingTimeMilli -> timeMilli < pendingReadingTimeMilli + 10000)
                                                                |> Maybe.withDefault False

                                                        ( state, nextCmd ) =
                                                            if memoryReadingStillPending then
                                                                ( stateBefore, Cmd.none )

                                                            else
                                                                ( { stateBefore | lastPendingRequestToReadFromGameClientTimeMilli = Just timeMilli }
                                                                , requestReadMemory
                                                                )
                                                    in
                                                    ( state
                                                    , { describeState =
                                                            "I try to read the memory from process "
                                                                ++ (searchUIRootAddressResponse.processId |> String.fromInt)
                                                                ++ " starting from root address "
                                                                ++ uiRootAddress
                                                                ++ ". "
                                                                ++ describeLastReadResult
                                                      , nextCmd = nextCmd
                                                      , lastMemoryReading = lastMemoryReading
                                                      }
                                                    )


selectGameClientProcess :
    List EveOnline.VolatileProcessInterface.GameClientProcessSummaryStruct
    -> Result String { selectedProcess : EveOnline.VolatileProcessInterface.GameClientProcessSummaryStruct, report : List String }
selectGameClientProcess gameClientProcesses =
    case gameClientProcesses |> List.sortBy .mainWindowZIndex |> List.head of
        Nothing ->
            Err "I did not find an EVE Online client process."

        Just selectedProcess ->
            let
                report =
                    if [ selectedProcess ] == gameClientProcesses then
                        []

                    else
                        [ "I found "
                            ++ (gameClientProcesses |> List.length |> String.fromInt)
                            ++ " game client processes. I selected process "
                            ++ (selectedProcess.processId |> String.fromInt)
                            ++ " ('"
                            ++ selectedProcess.mainWindowTitle
                            ++ "') because its main window was the topmost."
                        ]
            in
            Ok { selectedProcess = selectedProcess, report = report }


view : State -> Browser.Document Event
view state =
    let
        sourceSpecificHtml =
            case state.selectedSource of
                FromFile ->
                    viewSourceFromFile state

                FromLiveProcess ->
                    viewSourceFromLiveProcess state

        selectedSourceText =
            case state.selectedSource of
                FromFile ->
                    "file"

                FromLiveProcess ->
                    "live process"

        body =
            [ globalStylesHtmlElement
            , globalGuideHtmlElement
            , verticalSpacerFromHeightInEm 1
            , selectSourceHtml state
            , verticalSpacerFromHeightInEm 1
            , [ ("Reading from " ++ selectedSourceText) |> Html.text ] |> Html.h3 []
            , sourceSpecificHtml
            ]
    in
    { title = "Alternate EVE Online UI version " ++ Common.App.versionId, body = body }


globalGuideHtmlElement : Html.Html a
globalGuideHtmlElement =
    Html.span []
        [ Html.text "For a guide on the structures in the parsed memory reading, see "
        , linkHtmlFromUrl "https://to.botlab.org/guide/parsed-user-interface-of-the-eve-online-game-client"
        ]


viewSourceFromFile : State -> Html.Html Event
viewSourceFromFile state =
    let
        buttonLoadFromFileHtml =
            [ "Click here to load a reading from a JSON file" |> Html.text ]
                |> Html.button [ HE.onClick (UserInputSelectMemoryReadingFile Nothing) ]

        memoryReadingFromFileHtml =
            case state.readFromFileResult of
                Nothing ->
                    [ "No reading loaded" |> Html.text
                    , verticalSpacerFromHeightInEm 0.5
                    , [ "Want to load a memory reading from a bot session? You can use the devtools to export it from the session into a file to load it here. To export readings from a botting session, see the guide at " |> Html.text
                      , linkHtmlFromUrl "https://to.botlab.org/guide/observing-and-inspecting-a-bot"
                      ]
                        |> Html.span []
                    ]
                        |> Html.div []

                Just memoryReadingCompleted ->
                    case memoryReadingCompleted.parseResult of
                        Err error ->
                            ("Failed to decode reading loaded from file: " ++ (error |> Json.Decode.errorToString)) |> Html.text

                        Ok parseSuccess ->
                            [ "Successfully read the reading from the file." |> Html.text
                            , presentParsedMemoryReading Nothing parseSuccess state
                            ]
                                |> List.map (List.singleton >> Html.div [])
                                |> Html.div []
    in
    [ buttonLoadFromFileHtml
    , verticalSpacerFromHeightInEm 1
    , memoryReadingFromFileHtml
    ]
        |> Html.div []


viewSourceFromLiveProcess : State -> Html.Html Event
viewSourceFromLiveProcess state =
    let
        ( _, nextStep ) =
            decideNextStepToReadFromLiveProcess { timeMilli = state.timeMilli } state.readFromLiveProcess

        memoryReadingHtml =
            case nextStep.lastMemoryReading of
                Nothing ->
                    "" |> Html.text

                Just parsedReadMemoryResult ->
                    let
                        downloadButton =
                            [ "Click here to download this reading to a JSON file." |> Html.text ]
                                |> Html.button [ HE.onClick (UserInputDownloadJsonFile parsedReadMemoryResult.memoryReading.serialRepresentationJson) ]

                        inputRoute =
                            { windowId = parsedReadMemoryResult.windowId }

                        parsedHtml =
                            case parsedReadMemoryResult.memoryReading.parseResult of
                                Err parseError ->
                                    ("Failed to parse this reading: " ++ (parseError |> Json.Decode.errorToString)) |> Html.text

                                Ok parseSuccess ->
                                    presentParsedMemoryReading (Just inputRoute) parseSuccess state
                    in
                    [ "Successfully read from the memory of the live process." |> Html.text
                    , downloadButton
                    , verticalSpacerFromHeightInEm 1
                    , parsedHtml
                    ]
                        |> List.map (List.singleton >> Html.div [])
                        |> Html.div []
    in
    [ nextStep.describeState |> Html.text
    , verticalSpacerFromHeightInEm 1
    , memoryReadingHtml
    ]
        |> Html.div []


presentParsedMemoryReading : Maybe InputRouteConfig -> ParseMemoryReadingSuccess -> State -> Html.Html Event
presentParsedMemoryReading maybeInputRoute memoryReading state =
    let
        continueWithTitle title htmlElements =
            ([ title |> Html.text ] |> Html.h3 []) :: htmlElements

        selectedViewHtml =
            case state.selectedViewMode of
                ViewAlternateUI ->
                    continueWithTitle
                        "Using the Alternate UI"
                        (displayMessageBoxes maybeInputRoute memoryReading.parsedUserInterface.messageBoxes
                            ++ [ displayOrientation maybeInputRoute memoryReading.typeHierarchy memoryReading.parsedUserInterface
                               , verticalSpacerFromHeightInEm 0.5
                               ]
                            ++ displayTutorialPointer memoryReading.parsedUserInterface
                            --  While a hack is open it is the only thing being played, so it comes
                            --  before the ship and the overview rather than in window order.
                            ++ (case memoryReading.parsedUserInterface.hackingWindow of
                                    Nothing ->
                                        []

                                    Just hackingWindow ->
                                        [ Frontend.View.HackingWindow.view
                                            (viewContextFromInputRouteConfig maybeInputRoute 3)
                                            hackingWindow
                                        , verticalSpacerFromHeightInEm 0.5
                                        ]
                               )
                            ++ (case memoryReading.parsedUserInterface.shipUI of
                                    Nothing ->
                                        []

                                    Just shipUI ->
                                        [ Frontend.View.ShipUI.view
                                            (viewContextFromInputRouteConfig maybeInputRoute 3)
                                            shipUI
                                        , verticalSpacerFromHeightInEm 0.5
                                        ]
                               )
                            ++ (case memoryReading.parsedUserInterface.neocom of
                                    Nothing ->
                                        []

                                    Just neocom ->
                                        [ displayNeocom maybeInputRoute neocom
                                        , verticalSpacerFromHeightInEm 0.5
                                        ]
                               )
                            --  The inventory renders through the generic shell: its specialized
                            --  view was retired 2026-07-23 for repeatedly dropping parts of the
                            --  window -- first the container tree, then the filters -- the same
                            --  reason the station view went. Curation may reorder, never drop.
                            ++ displayOverviewWindows maybeInputRoute memoryReading.parsedUserInterface.overviewWindows
                            ++ [ [ ((memoryReading.parsedUserInterface.contextMenus |> List.length |> String.fromInt) ++ " Context menus") |> Html.text ] |> Html.h3 []
                               , displayParsedContextMenus maybeInputRoute memoryReading.parsedUserInterface.contextMenus
                               , verticalSpacerFromHeightInEm 0.5
                               ]
                            ++ displayUtilMenus maybeInputRoute memoryReading.typeHierarchy memoryReading.parsedUserInterface
                            ++ displayInventoryMoveActions maybeInputRoute memoryReading.parsedUserInterface
                            ++ displaySkillQueueReorderActions maybeInputRoute memoryReading.parsedUserInterface
                            ++ displayOtherWindows maybeInputRoute memoryReading.typeHierarchy memoryReading.parsedUserInterface
                            ++ displayNotificationsWidget maybeInputRoute memoryReading.parsedUserInterface
                        )

                ViewUITree ->
                    continueWithTitle
                        "Inspecting the UI tree"
                        [ "Below is an interactive tree view to explore this reading. You can expand and collapse individual nodes." |> Html.text
                        , viewTreeMemoryReadingUITreeNode maybeInputRoute memoryReading.uiNodesWithDisplayRegion state.uiTreeView memoryReading.uiTree
                        ]

                ViewParsedUI ->
                    continueWithTitle
                        "Inspecting the parsed user interface"
                        [ "Below is an interactive tree view to explore the parsed user interface. You can expand and collapse individual nodes." |> Html.text
                        , viewTreeParsedUserInterface maybeInputRoute memoryReading.uiNodesWithDisplayRegion state.parsedUITreeView memoryReading.parsedUserInterface
                        ]

        uiTreeSvg =
            viewUITreeSvg memoryReading.parsedUserInterface.uiTree

        visualSectionHtml =
            continueWithTitle "Visualization of the UI tree" [ uiTreeSvg ]
    in
    [ selectViewModeHtml state
    , tooltipInspectionHtml state.tooltipInspection
    , selectedViewHtml
        |> List.map (List.singleton >> Html.div [])
        |> Html.div []
    , visualSectionHtml |> Html.div []
    ]
        |> Html.div []


{-| Where the answer to a Shift+F11 tooltip inspection arrives. A live region, so the answer is
announced without moving the reader's position -- the gesture is pressed somewhere deep in the
page, and yanking the reading position up here would cost more than the tooltip is worth. The
element is present even while empty, because a live region only announces changes to a region
that already existed. The last answer stays until the next inspection, so it can also be
navigated to and read again.

A pending inspection says nothing: the gesture answers in about a second, so a "reading..." notice
would be spoken over by the answer more often than it would inform. Going empty while pending also
means a repeated inspection of the same node still announces, which an unchanged live region
would not.
-}
tooltipInspectionHtml : TooltipInspectionState -> Html.Html Event
tooltipInspectionHtml inspection =
    Html.div
        [ HA.attribute "role" "status"
        , HA.attribute "aria-atomic" "true"
        ]
        (case inspection of
            NoTooltipInspection ->
                []

            TooltipInspectionPending _ ->
                []

            TooltipInspectionCompleted { texts } ->
                case texts of
                    [] ->
                        [ Html.text "No tooltip." ]

                    _ ->
                        [ Html.text ("Tooltip: " ++ String.join "; " texts) ]
        )


viewContextFromInputRouteConfig : Maybe InputRouteConfig -> Int -> Frontend.View.Common.Context Event
viewContextFromInputRouteConfig maybeInputRouteConfig headingLevel =
    { inputRoute = maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig
    , headingLevel = headingLevel
    }


{-| The guidance pointer the game's career program overlays on the screen: an arrow parked at
some control, with a line like "Click here to open the Industry window". It has nothing to do
with where the player's cursor or focus is -- the game decides when to show it and what to aim
it at.

It lives in the `l_hint` layer, which is otherwise tooltips and stays unpresented; before this
section its text still reached a screen reader through the SVG visualization at the bottom of
the page, unlabeled, where it read like a focus announcement. The `UiPointer` type name and the
`l_hint` home were observed 2026-07-23, docked, with the career program's pointer at the station
services panel.

Read-only on purpose: the pointer names a control that is somewhere else on the page; the thing
to act on is that control, not the arrow pointing at it.

-}
displayTutorialPointer : EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displayTutorialPointer parsedUserInterface =
    case
        parsedUserInterface.layers
            |> List.filter (.name >> (==) "l_hint")
            |> List.concatMap (.uiNode >> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion)
            |> List.filter (.uiNode >> .pythonObjectTypeName >> (==) "UiPointer")
            |> List.filter Frontend.View.Common.isVisible
            |> List.concatMap
                (\pointer ->
                    pointer
                        |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                        |> List.map (Tuple.first >> Frontend.View.Common.plainText)
                        |> List.filterMap EveOnline.ParseUserInterface.discardUnreadableText
                )
    of
        [] ->
            []

        pointerTexts ->
            [ [ "The game's tutorial pointer" |> Html.text ] |> Html.h3 []
            , Frontend.View.Common.textLines pointerTexts
            , verticalSpacerFromHeightInEm 0.5
            ]


{-| A modal dialog blocks the game client until it is answered, so it comes before everything
else on the page.
-}
displayMessageBoxes : Maybe InputRouteConfig -> List EveOnline.ParseUserInterface.MessageBox -> List (Html.Html Event)
displayMessageBoxes maybeInputRouteConfig messageBoxes =
    if List.isEmpty messageBoxes then
        []

    else
        let
            context =
                viewContextFromInputRouteConfig maybeInputRouteConfig 3
        in
        [ Frontend.View.Common.section
            context
            "The game is waiting for an answer"
            (\contextForContent -> messageBoxes |> List.map (displayMessageBox contextForContent))
        , verticalSpacerFromHeightInEm 0.5
        ]


displayMessageBox : Frontend.View.Common.Context Event -> EveOnline.ParseUserInterface.MessageBox -> Html.Html Event
displayMessageBox context messageBox =
    let
        {-
           The text of a button sits in nodes below the button, so excluding only the button
           nodes themselves would still read every button caption twice: once as part of the
           message, and again on the button.
        -}
        buttonAddresses =
            messageBox.buttons
                |> List.concatMap
                    (\button ->
                        button.uiNode
                            :: EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion button.uiNode
                    )
                |> List.map (.uiNode >> .pythonObjectAddress)
                |> Set.fromList

        messageLines =
            messageBox.uiNode
                |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                |> List.filter
                    (\( _, node ) -> not (Set.member node.uiNode.pythonObjectAddress buttonAddresses))
                |> List.map (Tuple.first >> Frontend.View.Common.plainText)
                |> List.filterMap EveOnline.ParseUserInterface.discardUnreadableText

        buttonEntries =
            messageBox.buttons
                |> Frontend.View.Common.inReadingOrder
                |> List.map
                    (\button ->
                        Frontend.View.Common.controlActivateOnly
                            (button.mainText
                                |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
                                |> Maybe.withDefault
                                    (Frontend.View.Common.labelForControl
                                        Frontend.View.Common.noNameTable
                                        button.uiNode
                                    )
                            )
                            button.uiNode
                    )
    in
    [ Frontend.View.Common.textLines messageLines
    , Frontend.View.Common.actionList context buttonEntries
    ]
        |> Html.div []


{-| The menu a panel's small ⋯/menu button has open, which the client builds into `l_utilmenu` --
directly after the context menus, which is where that layer sits in the client's own stack.

Read through the generic content walk rather than as a list of menu entries: a util menu is a small
panel of checkboxes, fields and buttons, not a menu. See `parseUtilMenusFromUITreeRoot`.

The section is titled by hand because the client draws no caption over the menu; `Options` is what
the ⋯ button opens everywhere it appears, and nothing in the reading says which panel opened this
one. Treat it as the debt `CONVENTIONS.md` rule 4 describes.

-}
displayUtilMenus : Maybe InputRouteConfig -> Dict.Dict String (List String) -> EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displayUtilMenus maybeInputRouteConfig typeHierarchy parsedUserInterface =
    let
        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3

        menus =
            parsedUserInterface.utilMenus |> List.filter Frontend.View.Common.isVisible
    in
    if List.isEmpty menus then
        []

    else
        [ Frontend.View.Common.section
            context
            "Options menu"
            (\contextForContent ->
                menus
                    |> List.concatMap
                        (Frontend.View.GenericWindow.panelBodyHtml typeHierarchy contextForContent)
            )
        , verticalSpacerFromHeightInEm 0.5
        ]


{-| Every window the game client is showing that does not have a view of its own here, read
through the generic window shell. Which windows exist and in what order comes from the client's
own layer stack, so a window we have never seen before still turns up in the right place.
-}
displayOtherWindows : Maybe InputRouteConfig -> Dict.Dict String (List String) -> EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displayOtherWindows maybeInputRouteConfig typeHierarchy parsedUserInterface =
    let
        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3

        addressesShownSeparately =
            [ parsedUserInterface.overviewWindows |> List.map .uiNode
            , parsedUserInterface.hackingWindow
                |> Maybe.map (.uiNode >> List.singleton)
                |> Maybe.withDefault []
            ]
                |> List.concat
                |> List.map (.uiNode >> .pythonObjectAddress)
                |> Set.fromList

        windowIsShownSeparately window =
            (window.uiNode :: EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion window.uiNode)
                |> List.any (\node -> Set.member node.uiNode.pythonObjectAddress addressesShownSeparately)

        windows =
            EveOnline.ParseUserInterface.layerNamesInPresentationOrder
                |> List.concatMap
                    (\layerName ->
                        parsedUserInterface.layers
                            |> List.filter (.name >> (==) layerName)
                            |> List.concatMap (EveOnline.ParseUserInterface.parseGenericWindowsFromLayer typeHierarchy)
                    )
                |> List.filter (.uiNode >> Frontend.View.Common.isVisible)
                |> List.filter (windowIsShownSeparately >> not)
    in
    if List.isEmpty windows then
        []

    else
        [ Frontend.View.Common.section
            context
            "Other windows"
            (\contextForContent ->
                windows |> List.map (Frontend.View.GenericWindow.view typeHierarchy contextForContent)
            )
        ]


{-| The notification widget at the bottom right of the screen: the unread-count badge, the bell,
and — while the player has the history expanded — the recent notifications. Before this section
the badge's count reached a screen reader only through the SVG visualization at the bottom of the
page, as a bare number with nothing saying what it counted.

Each notification is one control — clicking it opens what it refers to (verified 2026-07-23: a
kill-report entry opened the kill report window), and right-click opens the client's menu for it
(Mark as Read, Turn off history visibility, Turn off popup), which lands in the context-menus
section like any other menu.

The entry's own ✕ close button is deliberately NOT offered: posted clicks on it do nothing.
Measured 2026-07-23 against a live client — plain click, click after a 400 ms hover dwell, and
press-jiggle-release all left the entry in place, while the same posted hover visibly faded the
✕ in and the probe reported input deliverable; the bell and the entries accept the same clicks.
Whatever that button requires, the message path does not provide it, and a Dismiss button that
does nothing is worse than none.

The history panel closes when the client processes a click anywhere outside it, so it may be
gone again by the next reading after any other control is pressed.

-}
displayNotificationsWidget : Maybe InputRouteConfig -> EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displayNotificationsWidget maybeInputRouteConfig parsedUserInterface =
    case parsedUserInterface.layerAbovemain |> Maybe.andThen .notificationsWidget of
        Nothing ->
            []

        Just widget ->
            let
                context =
                    viewContextFromInputRouteConfig maybeInputRouteConfig 3

                countEntries =
                    case widget.unreadCountText of
                        Nothing ->
                            []

                        Just count ->
                            [ Frontend.View.Common.prose (count ++ " unread") ]

                buttonEntries =
                    widget.buttons
                        |> List.filter Frontend.View.Common.isVisible
                        |> Frontend.View.Common.nodesInReadingOrder
                        |> List.map
                            (\buttonNode ->
                                Frontend.View.Common.controlActivateOnly
                                    (Frontend.View.Common.labelForControl notificationsWidgetName buttonNode)
                                    buttonNode
                            )

                entryEntries =
                    widget.entries
                        |> List.filter (.uiNode >> Frontend.View.Common.isVisible)
                        |> Frontend.View.Common.inReadingOrder
                        |> List.concatMap notificationEntryItems
            in
            [ Frontend.View.Common.section
                context
                "Notifications"
                (\contextForContent ->
                    [ Frontend.View.Common.actionList contextForContent
                        (countEntries ++ buttonEntries ++ entryEntries)
                    ]
                )
            , verticalSpacerFromHeightInEm 0.5
            ]


notificationEntryItems : EveOnline.ParseUserInterface.NotificationsWidgetEntry -> List Frontend.View.Common.Entry
notificationEntryItems entry =
    let
        subject =
            entry.subjectText
                |> Maybe.map Frontend.View.Common.plainText
                |> Maybe.withDefault "Notification"

        label =
            case entry.timeText of
                Nothing ->
                    subject

                Just time ->
                    subject ++ ", " ++ Frontend.View.Common.plainText time
    in
    Frontend.View.Common.control label entry.uiNode
        :: (case entry.subtextText of
                Nothing ->
                    []

                Just subtext ->
                    [ Frontend.View.Common.prose (Frontend.View.Common.plainText subtext) ]
           )


{-| CONVENTIONS.md rule 4: the bell carries no `_hint` and no text, so its name is translated by
hand. Observed 2026-07-23, docked; the settings button next to it supplies its own hint
("Notification Settings") and stays off this table.
-}
notificationsWidgetName : String -> Maybe String
notificationsWidgetName name =
    case name of
        "WidgetIcon" ->
            Just "Show or hide recent notifications"

        _ ->
            Nothing


{-| Moving an item between inventory containers is drag and drop in the game client -- it offers
no menu path for it -- so the page offers each move as a button: the drag a sighted player
performs by hand becomes one posted press-move-release. Verified 2026-07-23 by moving a 64-unit
Tritanium stack from the item hangar to the ship's cargo on a live client.

This is additive on top of the generic shell, in the sense of the curation policy set when the
station view was retired: the shell renders the inventory window itself; this section only adds
actions the shell cannot express, and never replaces anything.

The offered targets are the window's own container tree entries, except the selected one -- the
items already sit there. The drop lands on the entry's header row, which is where the client
itself accepts a drop for that container; dropping on the ship's entry puts the item in its
cargo hold.

-}
displayInventoryMoveActions : Maybe InputRouteConfig -> EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displayInventoryMoveActions maybeInputRouteConfig parsedUserInterface =
    let
        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3

        maximumItemsOffered =
            12

        flattenTreeEntries entries =
            entries
                |> List.concatMap
                    (\entry ->
                        entry
                            :: flattenTreeEntries
                                (entry.children
                                    |> List.map
                                        (\(EveOnline.ParseUserInterface.InventoryWindowLeftTreeEntryChild child) ->
                                            child
                                        )
                                )
                    )

        entryHeaderNode entry =
            entry.selectRegion |> Maybe.withDefault entry.uiNode

        --  The same marking the generic shell reads: the client draws its selection line inside
        --  the selected entry's header row.
        entryIsSelected entry =
            EveOnline.ParseUserInterface.subtreeShowsSelectionIndicator (entryHeaderNode entry)

        itemLabel item =
            case ( item.name, item.quantity ) of
                ( Just name, Just quantity ) ->
                    if 1 < quantity then
                        String.fromInt quantity ++ " " ++ name

                    else
                        name

                ( Just name, Nothing ) ->
                    name

                ( Nothing, _ ) ->
                    "unnamed item"

        {- Drop targets other windows offer: the reprocessing service takes its input by the
           same drag gesture as the inventory containers, so while its window is open, every
           item also offers a move into it. Labeled with the client's own caption inside the
           container -- "Input materials". Observed 2026-07-23.
        -}
        dropTargetsOutsideInventory =
            case parsedUserInterface.reprocessingWindow |> Maybe.andThen .inputContainer of
                Nothing ->
                    []

                Just inputContainer ->
                    if not (Frontend.View.Common.isVisible inputContainer) then
                        []

                    else
                        [ { label =
                                inputContainer
                                    |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                                    |> List.sortBy (Tuple.second >> .totalDisplayRegion >> (\region -> ( region.y, region.x )))
                                    |> List.map (Tuple.first >> Frontend.View.Common.plainText)
                                    |> List.filter (String.isEmpty >> not)
                                    |> List.head
                                    |> Maybe.withDefault "Reprocessing input"
                          , node = inputContainer
                          }
                        ]

        moveEntriesForWindow inventoryWindow =
            let
                items =
                    inventoryWindow.items
                        |> List.filter (.uiNode >> Frontend.View.Common.isVisible)

                containerTargets =
                    inventoryWindow.leftTreeEntries
                        |> flattenTreeEntries
                        |> List.filter (entryHeaderNode >> Frontend.View.Common.isVisible)
                        |> List.filter (entryIsSelected >> not)
                        |> List.map
                            (\entry ->
                                { label = Frontend.View.Common.plainText entry.text
                                , node = entryHeaderNode entry
                                }
                            )

                targets =
                    containerTargets ++ dropTargetsOutsideInventory

                moveEntry item target =
                    { label =
                        "Move "
                            ++ itemLabel item
                            ++ " to "
                            ++ target.label
                    , target =
                        Just
                            { node = item.uiNode
                            , canMenu = False
                            , activate =
                                MouseDragTo
                                    (EveOnline.ParseUserInterface.centerFromDisplayRegion
                                        target.node.totalDisplayRegionVisible
                                    )
                            }
                    , checkState = Nothing
                    , sliderPercent = Nothing
                    , fieldText = Nothing
                    , expandedState = Nothing
                    }

                offeredItems =
                    items |> List.take maximumItemsOffered

                notOfferedCount =
                    List.length items - List.length offeredItems

                cutoffEntries =
                    if notOfferedCount < 1 then
                        []

                    else
                        [ Frontend.View.Common.prose
                            (String.fromInt notOfferedCount
                                ++ " further items in this container are not offered here."
                            )
                        ]
            in
            if List.isEmpty items || List.isEmpty targets then
                []

            else
                (offeredItems
                    |> List.concatMap (\item -> targets |> List.map (moveEntry item))
                )
                    ++ cutoffEntries

        moveEntries =
            parsedUserInterface.inventoryWindows
                |> List.filter (.uiNode >> Frontend.View.Common.isVisible)
                |> List.concatMap moveEntriesForWindow
    in
    if List.isEmpty moveEntries then
        []

    else
        [ Frontend.View.Common.section
            context
            "Moving items"
            (\contextForContent -> [ Frontend.View.Common.actionList contextForContent moveEntries ])
        , verticalSpacerFromHeightInEm 0.5
        ]


{-| Reordering the skill queue is drag and drop in the game client -- the entry's right-click
menu covers every other queue operation, but not moving an entry -- so the page offers each move
as a button, the same way the inventory offers item moves. Additive on top of the generic shell,
which renders the Skill Planner itself.

Drop semantics measured against a live client 2026-07-24, Skill Planner docked, three entries in
the queue:

  - A drop with the pointer over a queue row inserts the dragged entry BEFORE that row, in both
    drag directions.
  - A drop in the open space below the last row moves the dragged entry to the end. The client's
    own `SkillQueueLastDropEntry` -- a 2 px slot after the last row -- did not take a drop aimed
    at its exact coordinates; a point 20 px below the last row does.

So moving an entry up one place drops it on the row above, and moving it down one place drops it
on the row two below -- or below the last row, when no such row exists. "Move to top" and "move
to end" are offered only where they differ from those.

The end-of-queue drop is offered only while the `SkillQueueLastDropEntry` is visible: that slot
only sits after the queue's true last row, so its visibility is the client's own statement that
the row above it is the last one, rather than the last one scrolled into view.

-}
displaySkillQueueReorderActions : Maybe InputRouteConfig -> EveOnline.ParseUserInterface.ParsedUserInterface -> List (Html.Html Event)
displaySkillQueueReorderActions maybeInputRouteConfig parsedUserInterface =
    let
        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3

        maximumRowsOffered =
            12

        {- One queue is the visible rows sharing a parent node, so if the client ever shows two
           queues at once, each reorders within itself instead of computing drop points across
           windows.
        -}
        collectQueues node =
            let
                children =
                    EveOnline.ParseUserInterface.listChildrenWithDisplayRegion node

                rows =
                    children
                        |> List.filter (.uiNode >> .pythonObjectTypeName >> (==) "SkillQueueSkillEntry")
            in
            if List.isEmpty rows then
                children |> List.concatMap collectQueues

            else
                [ { parent = node
                  , rows =
                        rows
                            |> List.filter Frontend.View.Common.isVisible
                            |> List.sortBy (.totalDisplayRegion >> .y)
                  , lastDropSlot =
                        children
                            |> List.filter (.uiNode >> .pythonObjectTypeName >> (==) "SkillQueueLastDropEntry")
                            |> List.filter Frontend.View.Common.isVisible
                            |> List.head
                  }
                ]

        --  The row's own texts, leftmost first: the skill name and level, then the time left.
        rowLabel row =
            row
                |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                |> List.sortBy (Tuple.second >> .totalDisplayRegion >> .x)
                |> List.head
                |> Maybe.map (Tuple.first >> Frontend.View.Common.plainText)
                |> Maybe.withDefault "unnamed entry"

        reorderEntry row verb dropLocation =
            { label = "Move " ++ rowLabel row ++ " " ++ verb
            , target =
                Just
                    { node = row
                    , canMenu = False
                    , activate = MouseDragTo dropLocation
                    }
            , checkState = Nothing
            , sliderPercent = Nothing
            , fieldText = Nothing
            , expandedState = Nothing
            }

        dropOnRow targetRow =
            EveOnline.ParseUserInterface.centerFromDisplayRegion targetRow.totalDisplayRegionVisible

        entriesForQueue queue =
            let
                rowCount =
                    List.length queue.rows

                rowAtIndex index =
                    queue.rows |> List.drop index |> List.head

                {- Kept within the parent's visible region: with the measured 20 px slack the
                   drop can otherwise land past the bottom of a scrolled queue's viewport.
                -}
                dropBelowLastRow =
                    case ( queue.lastDropSlot, queue.rows |> List.drop (rowCount - 1) |> List.head ) of
                        ( Just _, Just lastRow ) ->
                            let
                                parentBottom =
                                    queue.parent.totalDisplayRegionVisible.y
                                        + queue.parent.totalDisplayRegionVisible.height

                                dropY =
                                    lastRow.totalDisplayRegionVisible.y
                                        + lastRow.totalDisplayRegionVisible.height
                                        + 20
                            in
                            if parentBottom < dropY then
                                Nothing

                            else
                                Just
                                    { x = (EveOnline.ParseUserInterface.centerFromDisplayRegion lastRow.totalDisplayRegionVisible).x
                                    , y = dropY
                                    }

                        _ ->
                            Nothing

                entriesForRow ( rowIndex, row ) =
                    --  List.drop with a negative count keeps the whole list, so an unguarded
                    --  index - 1 hands the first row itself back as its "row above".
                    [ if 1 <= rowIndex then
                        rowAtIndex (rowIndex - 1)
                            |> Maybe.map (\rowAbove -> reorderEntry row "up" (dropOnRow rowAbove))

                      else
                        Nothing
                    , if rowIndex + 2 <= rowCount - 1 then
                        rowAtIndex (rowIndex + 2)
                            |> Maybe.map (\rowBelowNext -> reorderEntry row "down" (dropOnRow rowBelowNext))

                      else if rowIndex == rowCount - 2 then
                        dropBelowLastRow |> Maybe.map (reorderEntry row "down")

                      else
                        Nothing
                    , if 2 <= rowIndex then
                        rowAtIndex 0
                            |> Maybe.map (\firstRow -> reorderEntry row "to top" (dropOnRow firstRow))

                      else
                        Nothing
                    , if rowIndex <= rowCount - 3 then
                        dropBelowLastRow |> Maybe.map (reorderEntry row "to end")

                      else
                        Nothing
                    ]
                        |> List.filterMap identity

                offeredRows =
                    queue.rows |> List.take maximumRowsOffered

                cutoffEntries =
                    if rowCount <= maximumRowsOffered then
                        []

                    else
                        [ Frontend.View.Common.prose
                            (String.fromInt (rowCount - maximumRowsOffered)
                                ++ " further queue entries are not offered here."
                            )
                        ]
            in
            if rowCount < 2 then
                []

            else
                (offeredRows
                    |> List.indexedMap Tuple.pair
                    |> List.concatMap entriesForRow
                )
                    ++ cutoffEntries

        reorderEntries =
            parsedUserInterface.uiTree
                |> collectQueues
                |> List.concatMap entriesForQueue
    in
    if List.isEmpty reorderEntries then
        []

    else
        [ Frontend.View.Common.section
            context
            "Reordering the skill queue"
            (\contextForContent -> [ Frontend.View.Common.actionList contextForContent reorderEntries ])
        , verticalSpacerFromHeightInEm 0.5
        ]


displayNeocom : Maybe InputRouteConfig -> EveOnline.ParseUserInterface.Neocom -> Html.Html Event
displayNeocom maybeInputRouteConfig neocom =
    let
        maybeInputRoute =
            maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig

        entriesHtml =
            neocom.buttons
                |> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
                |> List.map
                    (\button ->
                        (case maybeInputRoute of
                            Nothing ->
                                [ displayTextForNeocomButtonName button.name |> Html.text ]

                            Just inputRoute ->
                                [ [ displayTextForNeocomButtonName button.name |> Html.text ]
                                    |> Html.button
                                        [ HE.onClick (inputRoute button.uiNode MouseClickLeft)
                                        , Frontend.View.Common.tooltipGestureAttribute inputRoute button.uiNode
                                        ]
                                ]
                        )
                            |> Html.li [ HA.style "margin" "0.2em 0" ]
                    )
    in
    [ [ "Neocom" |> Html.text ] |> Html.h3 []
    , entriesHtml |> Html.ul [ HA.style "list-style" "none", HA.style "padding-inline-start" "0" ]
    ]
        |> Html.div []


{-| Map the internal names of the Neocom buttons to the labels players see in the game client.

The client leaves `_hint` empty on these buttons until the player points at one, so unlike most
controls there is nothing to read the label from and we have to keep this list. Every entry here
is a liability: it is in English only, and it goes stale when the client changes. Drop an entry
as soon as the client is observed to supply the name itself.

Names observed in readings from a docked client on 2026-07-21.

-}
displayTextForNeocomButtonName : String -> String
displayTextForNeocomButtonName name =
    case name of
        "agency" ->
            "Agency"

        "airCareerProgram" ->
            "Career Program"

        "assets" ->
            "Assets"

        "AurumStoreBtnDataNode" ->
            "Aurum Store"

        "chat" ->
            "Chat"

        "charSheetBtn" ->
            "Character Sheet"

        "eveMenuBtn" ->
            "EVE Menu"

        "fitting" ->
            "Fitting"

        "help" ->
            "Help"

        "inventory" ->
            "Inventory"

        "job_board" ->
            "Job Board"

        "mail" ->
            "Mail"

        "map_beta" ->
            "Map"

        "market" ->
            "Market"

        "newRedeemableItemsNotification" ->
            "Redeem Items"

        "omega_upsell_fixed" ->
            "Omega Offer"

        "ProjectDiscovery" ->
            "Project Discovery"

        "shipTree" ->
            "Ship Tree"

        "skillsBtn" ->
            "Skills"

        "wallet" ->
            "Wallet"

        other ->
            other


{-| A short summary of where the player is and what the game is currently asking of them.
This exists so the page answers "where am I and what now" on every refresh, without having to
descend into the UI tree to find out.
-}
displayOrientation : Maybe InputRouteConfig -> Dict.Dict String (List String) -> EveOnline.ParseUserInterface.ParsedUserInterface -> Html.Html Event
displayOrientation maybeInputRouteConfig typeHierarchy parsedUserInterface =
    let
        maybeInputRoute =
            maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig

        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3

        maybeLocationInfo =
            parsedUserInterface.infoPanelContainer
                |> Maybe.andThen .infoPanelLocationInfo

        locationLines =
            case maybeLocationInfo of
                Nothing ->
                    [ "Location unknown" ]

                Just locationInfo ->
                    let
                        systemLine =
                            case locationInfo.currentSolarSystemName of
                                Nothing ->
                                    "Solar system unknown"

                                Just systemName ->
                                    case locationInfo.securityStatusPercent of
                                        Nothing ->
                                            "System: " ++ systemName

                                        Just securityStatusPercent ->
                                            "System: "
                                                ++ systemName
                                                ++ " (security "
                                                ++ String.fromFloat (toFloat securityStatusPercent / 100)
                                                ++ ")"

                        stationLines =
                            case locationInfo.expandedContent |> Maybe.andThen .currentStationName of
                                Nothing ->
                                    []

                                Just stationName ->
                                    [ "Docked at: " ++ stationName ]
                    in
                    systemLine :: stationLines

        {- The route the player has set, from the client's route info panel: the header with the
           jump count, then the next system and the final destination -- each a control, since
           the client's own panels answer a right-click with the travel menu. The client names
           the roles itself, in the links' alt attributes; without them the two lines are
           near-identical system-security-region runs. The per-jump markers between them carry
           no text at all and are left out rather than presented as unlabeled stops.
        -}
        routeHtml =
            case parsedUserInterface.infoPanelContainer |> Maybe.andThen .infoPanelRoute of
                Nothing ->
                    []

                Just route ->
                    let
                        waypointEntry waypoint =
                            if not (Frontend.View.Common.isVisible waypoint.uiNode) then
                                Nothing

                            else
                                waypoint.text
                                    |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
                                    |> Maybe.map
                                        (\rawText ->
                                            let
                                                plainLine =
                                                    Frontend.View.Common.plainText rawText

                                                label =
                                                    case EveOnline.ParseUserInterface.altTextFromMarkup rawText of
                                                        Just role ->
                                                            role ++ ": " ++ plainLine

                                                        Nothing ->
                                                            plainLine
                                            in
                                            Frontend.View.Common.control label waypoint.uiNode
                                        )

                        routeEntries =
                            [ route.headerText
                                |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
                                |> Maybe.map (Frontend.View.Common.plainText >> Frontend.View.Common.prose)
                            , route.nextWaypoint |> Maybe.andThen waypointEntry
                            , route.destination |> Maybe.andThen waypointEntry
                            ]
                                |> List.filterMap identity
                    in
                    if routeEntries == [] then
                        []

                    else
                        [ Frontend.View.Common.actionList context routeEntries ]

        --  Panels no specialized reading claims still render, through the same walk a window's
        --  content goes through. Degrading over disappearing, as for the windows.
        otherPanelsHtml =
            parsedUserInterface.infoPanelContainer
                |> Maybe.map .otherPanels
                |> Maybe.withDefault []
                |> List.filter Frontend.View.Common.isVisible
                |> List.concatMap (Frontend.View.GenericWindow.panelBodyHtml typeHierarchy context)

        agentMissionEntries =
            parsedUserInterface.infoPanelContainer
                |> Maybe.map .agentMissionEntries
                |> Maybe.withDefault []

        missionsHtml =
            if agentMissionEntries == [] then
                [ [ "No current objective shown by the game." |> Html.text ] |> Html.p [] ]

            else
                agentMissionEntries
                    |> List.map
                        (\entry ->
                            let
                                infoHtml =
                                    entry.infoLines
                                        |> List.map (\text -> [ text |> Html.text ] |> Html.li [])
                                        |> Html.ul []

                                actionsHtml =
                                    case maybeInputRoute of
                                        Nothing ->
                                            []

                                        Just inputRoute ->
                                            [ entry.actions
                                                |> List.map
                                                    (\action ->
                                                        [ [ action.text |> Html.text ]
                                                            |> Html.button
                                                                [ HE.onClick (inputRoute action.uiNode MouseClickLeft)
                                                                , Frontend.View.Common.tooltipGestureAttribute inputRoute action.uiNode
                                                                ]
                                                        ]
                                                            |> Html.li [ HA.style "margin" "0.2em 0" ]
                                                    )
                                                |> Html.ul
                                                    [ HA.style "list-style" "none"
                                                    , HA.style "padding-inline-start" "0"
                                                    ]
                                            ]
                            in
                            (infoHtml :: actionsHtml) |> Html.div []
                        )
    in
    ([ [ "Where you are" |> Html.text ] |> Html.h3 []
     , locationLines
        |> List.map (\line -> [ line |> Html.text ] |> Html.li [])
        |> Html.ul []
     ]
        ++ routeHtml
        ++ otherPanelsHtml
        ++ [ [ "What the game is asking of you" |> Html.text ] |> Html.h3 []
           , missionsHtml |> Html.div []
           ]
    )
        |> Html.div []


{-| The overview, which the client shows one of per overview tab.

An overview window the client is not showing is left out rather than announced as empty, so a
docked client says nothing about the overview instead of saying it has none.

-}
displayOverviewWindows : Maybe InputRouteConfig -> List EveOnline.ParseUserInterface.OverviewWindow -> List (Html.Html Event)
displayOverviewWindows maybeInputRouteConfig overviewWindows =
    let
        context =
            viewContextFromInputRouteConfig maybeInputRouteConfig 3
    in
    overviewWindows
        |> List.filter (.uiNode >> Frontend.View.Common.isVisible)
        |> List.concatMap
            (\overviewWindow ->
                [ Frontend.View.Overview.view context overviewWindow
                , verticalSpacerFromHeightInEm 0.5
                ]
            )


cssColorFromColorPercent : EveOnline.ParseUserInterface.ColorComponents -> String
cssColorFromColorPercent colorPercent =
    "rgba("
        ++ (([ colorPercent.r, colorPercent.g, colorPercent.b ]
                |> List.map (\rgbComponent -> String.fromInt ((rgbComponent * 255) // 100))
            )
                ++ [ String.fromFloat ((colorPercent.a |> toFloat) / 100) ]
                |> String.join ","
           )
        ++ ")"


displayParsedContextMenus : Maybe InputRouteConfig -> List EveOnline.ParseUserInterface.ContextMenu -> Html.Html Event
displayParsedContextMenus maybeInputRoute contextMenus =
    contextMenus
        |> List.indexedMap
            (\i contextMenu ->
                [ [ ("Context menu " ++ (i |> String.fromInt)) |> Html.text ] |> Html.h4 []
                , contextMenu |> displayParsedContextMenu maybeInputRoute
                ]
                    |> Html.div []
            )
        |> Html.div []


displayParsedContextMenu : Maybe InputRouteConfig -> EveOnline.ParseUserInterface.ContextMenu -> Html.Html Event
displayParsedContextMenu maybeInputRouteConfig contextMenu =
    contextMenu.entries
        |> List.map (contextMenuEntryHtml (maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig))
        |> Html.div []


{-| One menu entry, as a single button the way `Common.controlElement` presents controls.

The states the client draws are carried as attributes rather than words: a checkable entry is a
toggle button (`aria-pressed`), so a screen reader announces `Distance, toggle button, pressed`
against `Tag, toggle button, not pressed`; an entry that opens a submenu announces that via
`aria-haspopup`. Without an input route there is no button to carry the attributes, so the states
become words after the label -- a reading loaded from a file still tells which columns were on.

-}
contextMenuEntryHtml : Maybe (InputRoute Event) -> EveOnline.ParseUserInterface.ContextMenuEntry -> Html.Html Event
contextMenuEntryHtml maybeInputRoute menuEntry =
    let
        stateAttributes =
            (case menuEntry.checkState of
                Nothing ->
                    []

                Just checked ->
                    [ HA.attribute "aria-pressed"
                        (if checked then
                            "true"

                         else
                            "false"
                        )
                    ]
            )
                ++ (if menuEntry.opensSubmenu then
                        [ HA.attribute "aria-haspopup" "menu" ]

                    else
                        []
                   )

        stateWords =
            (case menuEntry.checkState of
                Nothing ->
                    []

                Just True ->
                    [ "on" ]

                Just False ->
                    [ "off" ]
            )
                ++ (if menuEntry.opensSubmenu then
                        [ "submenu" ]

                    else
                        []
                   )
    in
    [ case maybeInputRoute of
        Nothing ->
            (menuEntry.text
                :: (if List.isEmpty stateWords then
                        []

                    else
                        [ "(" ++ String.join ", " stateWords ++ ")" ]
                   )
            )
                |> String.join " "
                |> Html.text

        Just inputRoute ->
            Html.button
                (HE.onClick (inputRoute menuEntry.uiNode MouseClickLeft)
                    :: Frontend.View.Common.tooltipGestureAttribute inputRoute menuEntry.uiNode
                    :: stateAttributes
                )
                [ menuEntry.text |> Html.text ]
    ]
        |> Html.div []


selectSourceHtml : State -> Html.Html Event
selectSourceHtml state =
    (([ "Select a source for the reading" |> Html.text ] |> Html.legend [])
        :: ([ ( "From file", FromFile )
            , ( "From live game client process", FromLiveProcess )
            ]
                |> List.map
                    (\( offeredSourceLabel, offeredSource ) ->
                        radioButtonHtml
                            "memoryreadingsource"
                            offeredSourceLabel
                            (state.selectedSource == offeredSource)
                            (UserInputSelectMemoryReadingSource offeredSource)
                    )
           )
    )
        |> Html.fieldset []


selectViewModeHtml : State -> Html.Html Event
selectViewModeHtml state =
    (([ "Select a view mode" |> Html.text ] |> Html.legend [])
        :: ([ ( "View Alternate UI", ViewAlternateUI )
            , ( "View Parsed User Interface", ViewParsedUI )
            , ( "View UI Tree", ViewUITree )
            ]
                |> List.map
                    (\( offeredModeLabel, offeredMode ) ->
                        radioButtonHtml
                            "viewmode"
                            offeredModeLabel
                            (state.selectedViewMode == offeredMode)
                            (UserInputSelectViewMode offeredMode)
                    )
           )
    )
        |> Html.fieldset []


radioButtonHtml : String -> String -> Bool -> event -> Html.Html event
radioButtonHtml groupName labelText isChecked msg =
    [ Html.input [ HA.type_ "radio", HA.name groupName, HE.onClick msg, HA.checked isChecked ] []
    , Html.text labelText
    ]
        |> Html.label [ HA.style "padding" "20px" ]


inputRouteFromInputConfig : InputRouteConfig -> Frontend.InspectParsedUserInterface.InputRoute Event
inputRouteFromInputConfig inputRouteConfig =
    \uiNode inputKind ->
        UserInputSendInputToUINode
            { uiNode = uiNode
            , input = inputKind
            , windowId = inputRouteConfig.windowId
            , delayMilliseconds =
                case inputKind of
                    {- The delay above guards against a real mouse click on the page landing on
                       the game client as well. A hover is only ever reached from the keyboard and
                       presses no button, so it has nothing to be separated from, and the delay
                       would be a third of a second added to a gesture whose whole worth is being
                       quick to answer.
                    -}
                    MouseHover ->
                        Nothing

                    _ ->
                        Just inputDelayDefaultMilliseconds
            }


viewTreeMemoryReadingUITreeNode :
    Maybe InputRouteConfig
    -> Dict.Dict String UITreeNodeWithDisplayRegion
    -> UITreeViewState
    -> EveOnline.MemoryReading.UITreeNode
    -> Html.Html Event
viewTreeMemoryReadingUITreeNode maybeInputRouteConfig uiNodesWithDisplayRegion viewState treeNode =
    let
        nodeIsExpanded nodeId =
            viewState.expandedNodes |> List.member nodeId
    in
    treeViewNodeFromMemoryReadingUITreeNode (maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig) uiNodesWithDisplayRegion treeNode
        |> renderInteractiveTreeView
            UserInputUISetTreeViewNodeIsExpanded
            nodeIsExpanded
            { focusedPath = viewState.focused
            , eventForFocus = UserInputFocusInUITree
            , setFocusEvent = UserInputNavigateToElement
            , htmlElementId = htmlElementIdFromUIPathNode
            }
            []


htmlElementIdFromUIPathNode : ExpandableViewNode -> String
htmlElementIdFromUIPathNode pathNode =
    case pathNode of
        Frontend.InspectParsedUserInterface.ExpandableUITreeNode nodeIdentity ->
            "UITreeNode_" ++ nodeIdentity.pythonObjectAddress

        Frontend.InspectParsedUserInterface.ExpandableUITreeNodeChildren ->
            "Children"

        Frontend.InspectParsedUserInterface.ExpandableUITreeNodeDictEntries ->
            "DictEntries"

        Frontend.InspectParsedUserInterface.ExpandableUITreeNodeAllDisplayTexts ->
            "AllDisplayTexts"


viewTreeParsedUserInterface :
    Maybe InputRouteConfig
    -> Dict.Dict String UITreeNodeWithDisplayRegion
    -> ParsedUITreeViewState
    -> EveOnline.ParseUserInterface.ParsedUserInterface
    -> Html.Html Event
viewTreeParsedUserInterface maybeInputRouteConfig uiNodesWithDisplayRegion viewState parsedUserInterface =
    let
        nodeIsExpanded nodeId =
            viewState.expandedNodes |> List.member nodeId
    in
    renderTreeNodeFromParsedUserInterface
        (maybeInputRouteConfig |> Maybe.map inputRouteFromInputConfig)
        uiNodesWithDisplayRegion
        parsedUserInterface
        |> renderInteractiveTreeView
            UserInputParsedUISetTreeViewNodeIsExpanded
            nodeIsExpanded
            { focusedPath = viewState.focused
            , eventForFocus = UserInputFocusInParsedUI
            , setFocusEvent = UserInputNavigateToElement
            , htmlElementId = htmlElementIdFromParsedUIPathNode
            }
            []


htmlElementIdFromParsedUIPathNode : ParsedUITreeViewPathNode -> String
htmlElementIdFromParsedUIPathNode pathNode =
    case pathNode of
        NamedNode name ->
            "NamedNode_" ++ name

        IndexedNode index ->
            "IndexedNode_" ++ (index |> String.fromInt)

        UITreeNode uiTreeNode ->
            "UITreeNode_" ++ htmlElementIdFromUIPathNode uiTreeNode


{-| TODO: Consolidate implementation to get visual tree: Also use `getExpandedPartOfTree`.
-}
renderInteractiveTreeView :
    (List expandPathNode -> Bool -> event)
    -> (List expandPathNode -> Bool)
    ->
        { focusedPath : List expandPathNode
        , eventForFocus : List expandPathNode -> event
        , setFocusEvent : String -> event
        , htmlElementId : expandPathNode -> String
        }
    -> List expandPathNode
    -> TreeViewNode event expandPathNode
    -> Html.Html event
renderInteractiveTreeView eventFromNodeIdAndExpandedState nodeIsExpanded focusConfig parentPath treeNode =
    let
        htmlElementIdFromNodePath =
            List.map focusConfig.htmlElementId >> String.join "-"

        expandIconHtmlFromIsExpanded isExpanded =
            (if isExpanded then
                "ᐯ"

             else
                "ᐳ"
            )
                |> Html.text
                |> List.singleton
                |> Html.span [ HA.style "margin" "0.3em", HA.style "font-weight" "bold" ]

        maybeChildren =
            case treeNode.children of
                NoChildren ->
                    Nothing

                ExpandableChildren pathNodeId getChildren ->
                    case getChildren () of
                        [] ->
                            Nothing

                        notEmptyChildren ->
                            Just { pathNodeId = pathNodeId, children = notEmptyChildren }

        ( maybeExpandIconHtml, childrenHtml, ariaAttributes ) =
            case maybeChildren of
                Nothing ->
                    ( Nothing, Nothing, [ Html.Attributes.Aria.role "none" ] )

                Just childrenInfo ->
                    let
                        currentPath =
                            parentPath ++ [ childrenInfo.pathNodeId ]

                        currentNodeIsExpanded =
                            nodeIsExpanded currentPath

                        expandableButtonHtml =
                            [ expandIconHtmlFromIsExpanded currentNodeIsExpanded ]
                                |> Html.span [ HE.onClick (eventFromNodeIdAndExpandedState currentPath (not currentNodeIsExpanded)), HA.style "cursor" "pointer" ]

                        expandableChildrenHtml =
                            if currentNodeIsExpanded then
                                childrenInfo.children
                                    |> List.map
                                        (renderInteractiveTreeView
                                            eventFromNodeIdAndExpandedState
                                            nodeIsExpanded
                                            focusConfig
                                            currentPath
                                        )
                                    |> Html.ul [ HA.style "padding-inline-start" "1em", HA.style "margin-block-start" "0" ]
                                    |> Just

                            else
                                Nothing

                        ariaExpanded =
                            if currentNodeIsExpanded then
                                "true"

                            else
                                "false"

                        -- https://www.w3.org/TR/wai-aria-practices/#kbd_roving_tabindex
                        tabIndex =
                            if focusConfig.focusedPath == currentPath then
                                0

                            else
                                -1

                        keyEventListeners =
                            if parentPath /= [] then
                                []

                            else
                                let
                                    immediateNeighborsPaths =
                                        searchImmediateNeighborsPaths
                                            focusConfig.focusedPath
                                            (treeNode |> getExpandedPartOfTree nodeIsExpanded [])
                                            { currentPath = [], up = Nothing, down = Nothing, left = Nothing, previousSibling = Nothing }
                                            |> Maybe.withDefault { up = Nothing, down = Nothing, left = Nothing, right = Nothing }

                                    jsonDecodeMapUserInputArrowToEvent inputArrow =
                                        case inputArrow of
                                            ArrowLeft ->
                                                if nodeIsExpanded focusConfig.focusedPath then
                                                    Json.Decode.succeed (eventFromNodeIdAndExpandedState focusConfig.focusedPath False)

                                                else
                                                    case immediateNeighborsPaths.left of
                                                        Nothing ->
                                                            Json.Decode.fail "Path to left not available."

                                                        Just pathToLeft ->
                                                            Json.Decode.succeed (focusConfig.setFocusEvent (htmlElementIdFromNodePath pathToLeft))

                                            ArrowRight ->
                                                if not (nodeIsExpanded focusConfig.focusedPath) then
                                                    Json.Decode.succeed (eventFromNodeIdAndExpandedState focusConfig.focusedPath True)

                                                else
                                                    case immediateNeighborsPaths.right of
                                                        Nothing ->
                                                            Json.Decode.fail "Path to right not available."

                                                        Just pathToRight ->
                                                            Json.Decode.succeed (focusConfig.setFocusEvent (htmlElementIdFromNodePath pathToRight))

                                            ArrowUp ->
                                                case immediateNeighborsPaths.up of
                                                    Nothing ->
                                                        Json.Decode.fail "Path up not available."

                                                    Just pathUp ->
                                                        Json.Decode.succeed (focusConfig.setFocusEvent (htmlElementIdFromNodePath pathUp))

                                            ArrowDown ->
                                                case immediateNeighborsPaths.down of
                                                    Nothing ->
                                                        Json.Decode.fail "Path down not available."

                                                    Just pathDown ->
                                                        Json.Decode.succeed (focusConfig.setFocusEvent (htmlElementIdFromNodePath pathDown))
                                in
                                [ HE.custom "keydown"
                                    (HE.keyCode
                                        |> Json.Decode.andThen
                                            (arrowKeyTypeFromKeyCode
                                                >> Maybe.map Json.Decode.succeed
                                                >> Maybe.withDefault (Json.Decode.fail "No arrow key")
                                            )
                                        |> Json.Decode.andThen jsonDecodeMapUserInputArrowToEvent
                                        |> Json.Decode.map
                                            (\inputEvent ->
                                                { message = inputEvent
                                                , stopPropagation = True
                                                , preventDefault = True
                                                }
                                            )
                                    )
                                ]
                    in
                    ( Just expandableButtonHtml
                    , expandableChildrenHtml
                    , [ HA.id (htmlElementIdFromNodePath currentPath)
                      , Html.Attributes.Aria.role "treeitem"
                      , Html.Attributes.Aria.ariaExpanded ariaExpanded
                      , HA.tabindex tabIndex
                      , HE.onFocus (focusConfig.eventForFocus currentPath)
                      ]
                        ++ keyEventListeners
                    )

        expandIconHtml =
            maybeExpandIconHtml
                |> Maybe.withDefault ([ expandIconHtmlFromIsExpanded False ] |> Html.span [ HA.style "visibility" "hidden" ])

        -- TODO: Implement navigation using keyboard, probably arrow keys.
    in
    [ [ expandIconHtml, treeNode.selfHtml ] |> Html.span []
    , childrenHtml |> Maybe.withDefault (Html.text "")
    ]
        |> Html.li (HA.style "list-style" "none" :: ariaAttributes)


type VisualTreeChild event pathNode
    = VisualWithoutChildren
    | VisualCollapsed
    | VisualExpanded pathNode (List (VisualTreeChild event pathNode))


mapEmptyChildrenToNotExpandable : TreeViewNode event pathNode -> TreeViewNode event pathNode
mapEmptyChildrenToNotExpandable tree =
    let
        children =
            case tree.children of
                NoChildren ->
                    NoChildren

                ExpandableChildren currentNodeId getChildren ->
                    case getChildren () of
                        [] ->
                            NoChildren

                        nonEmptyChildren ->
                            ExpandableChildren currentNodeId
                                (always (nonEmptyChildren |> List.map mapEmptyChildrenToNotExpandable))
    in
    { tree | children = children }


getExpandedPartOfTree : (List pathNode -> Bool) -> List pathNode -> TreeViewNode event pathNode -> TreeViewNode event pathNode
getExpandedPartOfTree nodeIsExpanded fromParentPath tree =
    let
        children =
            case tree.children of
                NoChildren ->
                    NoChildren

                ExpandableChildren currentNodeId getChildren ->
                    let
                        currentPath =
                            fromParentPath ++ [ currentNodeId ]
                    in
                    if nodeIsExpanded currentPath then
                        ExpandableChildren currentNodeId
                            (always (getChildren () |> List.map (getExpandedPartOfTree nodeIsExpanded currentPath)))

                    else
                        ExpandableChildren currentNodeId (always [])
    in
    { tree | children = children }


searchImmediateNeighborsPaths :
    List pathNode
    -> TreeViewNode event pathNode
    -> { currentPath : List pathNode, up : Maybe (List pathNode), down : Maybe (List pathNode), left : Maybe (List pathNode), previousSibling : Maybe (TreeViewNode event pathNode) }
    -> Maybe { up : Maybe (List pathNode), down : Maybe (List pathNode), left : Maybe (List pathNode), right : Maybe (List pathNode) }
searchImmediateNeighborsPaths pathToSearch tree fromParent =
    -- TODO: Check if impl can be simplified by using List of TreeViewNode instead of single one in 'tree'.
    case tree.children of
        NoChildren ->
            Nothing

        ExpandableChildren currentNodeId getVisualChildren ->
            let
                currentPath =
                    fromParent.currentPath ++ [ currentNodeId ]
            in
            case pathToSearch of
                pathToSearchFirstNode :: remainingPathToSearch ->
                    if pathToSearchFirstNode /= currentNodeId then
                        Nothing

                    else if remainingPathToSearch == [] then
                        let
                            pathDownFromExpandedContentNodeId =
                                let
                                    focusableChildren =
                                        case tree.children of
                                            NoChildren ->
                                                []

                                            ExpandableChildren _ getChildren ->
                                                getChildren ()
                                                    |> List.filterMap
                                                        (\candidate ->
                                                            case candidate.children of
                                                                NoChildren ->
                                                                    Nothing

                                                                ExpandableChildren childNodeId _ ->
                                                                    Just childNodeId
                                                        )
                                in
                                focusableChildren |> List.head

                            pathDownFromExpandedContent =
                                pathDownFromExpandedContentNodeId
                                    |> Maybe.map (List.singleton >> (++) currentPath)
                        in
                        Just
                            { up = fromParent.up
                            , down = pathDownFromExpandedContent |> maybeWithMaybeDefault fromParent.down
                            , left = fromParent.left
                            , right = pathDownFromExpandedContent
                            }

                    else
                        let
                            visualChildren =
                                getVisualChildren ()

                            focusableChildren =
                                visualChildren
                                    |> List.filter
                                        (\candidate ->
                                            case candidate.children of
                                                NoChildren ->
                                                    False

                                                ExpandableChildren _ _ ->
                                                    True
                                        )

                            getChildFromFocusableChildIndex childIndex =
                                -- TODO: make each visual children focusable, not only the expandable ones.
                                case focusableChildren |> List.Extra.getAt childIndex of
                                    Nothing ->
                                        Nothing

                                    Just child ->
                                        case child.children of
                                            NoChildren ->
                                                Nothing

                                            ExpandableChildren childPathNodeId _ ->
                                                Just ( child, currentPath ++ [ childPathNodeId ] )
                        in
                        focusableChildren
                            |> List.indexedMap
                                (\childIndex child ->
                                    let
                                        visualNextUpperPath =
                                            getChildFromFocusableChildIndex (childIndex - 1)
                                                |> Maybe.map Tuple.second
                                                |> maybeWithMaybeDefault (Just currentPath)

                                        visualNextLowerPath =
                                            getChildFromFocusableChildIndex (childIndex + 1)
                                                |> Maybe.map Tuple.second
                                                |> maybeWithMaybeDefault fromParent.down
                                    in
                                    searchImmediateNeighborsPaths
                                        remainingPathToSearch
                                        child
                                        { currentPath = currentPath
                                        , up = visualNextUpperPath
                                        , down = visualNextLowerPath
                                        , left = Just currentPath
                                        , previousSibling = getChildFromFocusableChildIndex (childIndex - 1) |> Maybe.map Tuple.first
                                        }
                                )
                            |> List.filterMap identity
                            |> List.head

                _ ->
                    Nothing


viewUITreeSvg : UITreeNodeWithDisplayRegion -> Svg.Svg e
viewUITreeSvg uiTree =
    let
        viewBox =
            [ uiTree.totalDisplayRegion.x
            , uiTree.totalDisplayRegion.y
            , uiTree.totalDisplayRegion.width
            , uiTree.totalDisplayRegion.height
            ]
                |> List.map String.fromInt
                |> String.join " "
    in
    Svg.svg
        [ Svg.Attributes.viewBox viewBox
        , HA.style "background" "#111"
        , HA.style "font-size" "60%"
        ]
        [ uiTree |> svgFromUINodeRecursive ]


svgFromUINodeRecursive : UITreeNodeWithDisplayRegion -> Svg.Svg e
svgFromUINodeRecursive uiNode =
    let
        childrenSvg =
            uiNode.children
                |> Maybe.withDefault []
                |> List.filterMap
                    (\child ->
                        case child of
                            EveOnline.ParseUserInterface.ChildWithRegion childWithRegion ->
                                Just childWithRegion

                            EveOnline.ParseUserInterface.ChildWithoutRegion _ ->
                                Nothing
                    )
                |> List.map svgFromUINodeRecursive

        displayTextSvg =
            case uiNode.uiNode |> EveOnline.ParseUserInterface.getDisplayText of
                Nothing ->
                    Html.text ""

                Just displayText ->
                    Svg.text_
                        [ Svg.Attributes.textLength (uiNode.selfDisplayRegion.width |> String.fromInt)
                        , Svg.Attributes.lengthAdjust "spacing"
                        , HA.style "fill" "grey"
                        , Svg.Attributes.x ((uiNode.selfDisplayRegion.width // 2) |> String.fromInt)
                        , Svg.Attributes.y ((uiNode.selfDisplayRegion.height // 2) |> String.fromInt)
                        , Svg.Attributes.dominantBaseline "middle"
                        , Svg.Attributes.textAnchor "middle"
                        ]
                        [ Svg.text displayText ]

        regionRectPlacementAttributes =
            [ Svg.Attributes.x "0"
            , Svg.Attributes.y "0"
            , Svg.Attributes.width (uiNode.selfDisplayRegion.width |> String.fromInt)
            , Svg.Attributes.height (uiNode.selfDisplayRegion.height |> String.fromInt)
            ]

        regionSvg =
            Svg.rect
                (regionRectPlacementAttributes
                    ++ [ HA.style "fill" "transparent"
                       , HA.style "stroke-width" "1"
                       , HA.style "stroke" "#7AB8FF"
                       , HA.style "stroke-opacity" "0.3"
                       ]
                )
                []

        colorIndicationSvg =
            case uiNode.uiNode |> EveOnline.ParseUserInterface.getColorPercentFromDictEntries of
                Nothing ->
                    Html.text ""

                Just colorPercent ->
                    Svg.rect
                        (regionRectPlacementAttributes
                            ++ [ Svg.Attributes.height (uiNode.selfDisplayRegion.height |> String.fromInt)
                               , HA.style "fill" "transparent"
                               , HA.style "stroke-width" "3"
                               , HA.style "stroke" (cssColorFromColorPercent colorPercent)
                               , HA.style "stroke-opacity" "0.5"
                               ]
                        )
                        []

        transformTranslateText =
            [ uiNode.selfDisplayRegion.x, uiNode.selfDisplayRegion.y ]
                |> List.map String.fromInt
                |> String.join " "
    in
    Svg.g [ Svg.Attributes.transform ("translate(" ++ transformTranslateText ++ ")") ]
        (regionSvg :: colorIndicationSvg :: displayTextSvg :: childrenSvg)


type ArrowKeyType
    = ArrowUp
    | ArrowDown
    | ArrowLeft
    | ArrowRight


arrowKeyTypeFromKeyCode : Int -> Maybe ArrowKeyType
arrowKeyTypeFromKeyCode keyCode =
    [ ( 38, ArrowUp )
    , ( 40, ArrowDown )
    , ( 37, ArrowLeft )
    , ( 39, ArrowRight )
    ]
        |> Dict.fromList
        |> Dict.get keyCode


parseMemoryReadingFromJson : Dict.Dict String (List String) -> String -> Result Json.Decode.Error ParseMemoryReadingSuccess
parseMemoryReadingFromJson typeHierarchy =
    EveOnline.MemoryReading.decodeMemoryReadingFromString
        >> Result.map
            (\uiTree ->
                let
                    uiTreeWithDisplayRegion =
                        uiTree |> EveOnline.ParseUserInterface.parseUITreeWithDisplayRegionFromUITree

                    parsedUserInterface =
                        EveOnline.ParseUserInterface.parseUserInterfaceFromUITree uiTreeWithDisplayRegion
                in
                { uiTree = uiTree
                , uiNodesWithDisplayRegion =
                    uiTreeWithDisplayRegion
                        :: (uiTreeWithDisplayRegion |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion)
                        |> List.map (\uiNodeWithRegion -> ( uiNodeWithRegion.uiNode.pythonObjectAddress, uiNodeWithRegion ))
                        |> Dict.fromList
                , parsedUserInterface = parsedUserInterface
                , typeHierarchy = typeHierarchy
                }
            )


{-| The type hierarchy arrives from the live client as its own JSON string: an object mapping each
type name to its inheritance chain. Absent (a file reading) or unreadable, it is simply empty, and
the views that consult it fall back to what the tree alone tells them.
-}
decodePythonTypeHierarchyFromJson : Maybe String -> Dict.Dict String (List String)
decodePythonTypeHierarchyFromJson maybeJson =
    case maybeJson of
        Nothing ->
            Dict.empty

        Just json ->
            json
                |> Json.Decode.decodeString (Json.Decode.dict (Json.Decode.list Json.Decode.string))
                |> Result.withDefault Dict.empty


globalStylesHtmlElement : Html.Html a
globalStylesHtmlElement =
    """
body {
font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
margin: 1em;
}
"""
        |> Html.text
        |> List.singleton
        |> Html.node "style" []


verticalSpacerFromHeightInEm : Float -> Html.Html a
verticalSpacerFromHeightInEm heightInEm =
    [] |> Html.div [ HA.style "height" ((heightInEm |> String.fromFloat) ++ "em") ]


httpExpectJson : (Result { error : Http.Error, bodyString : Maybe String } a -> msg) -> Json.Decode.Decoder a -> Http.Expect msg
httpExpectJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err { error = Http.BadUrl url, bodyString = Nothing }

                Http.Timeout_ ->
                    Err { error = Http.Timeout, bodyString = Nothing }

                Http.NetworkError_ ->
                    Err { error = Http.NetworkError, bodyString = Nothing }

                Http.BadStatus_ metadata body ->
                    Err { error = Http.BadStatus metadata.statusCode, bodyString = Just body }

                Http.GoodStatus_ metadata body ->
                    case Json.Decode.decodeString decoder body of
                        Ok value ->
                            Ok value

                        Err err ->
                            Err { error = Http.BadBody (Json.Decode.errorToString err), bodyString = Just body }


describeHttpError : HttpRequestErrorStructure -> String
describeHttpError { error, bodyString } =
    case error of
        Http.BadUrl errorMessage ->
            "Bad Url: " ++ errorMessage

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "Network Error"

        Http.BadStatus statusCode ->
            "BadStatus: "
                ++ (statusCode |> String.fromInt)
                ++ " ("
                ++ (bodyString |> Maybe.withDefault "No details in HTTP response body.")
                ++ ")"

        Http.BadBody errorMessage ->
            "BadPayload: " ++ errorMessage


linkHtmlFromUrl : String -> Html.Html a
linkHtmlFromUrl url =
    Html.a [ HA.href url ] [ Html.text url ]


maybeWithMaybeDefault : Maybe a -> Maybe a -> Maybe a
maybeWithMaybeDefault maybeB maybeA =
    case maybeA of
        Just a ->
            Just a

        Nothing ->
            maybeB
