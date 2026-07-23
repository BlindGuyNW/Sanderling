module ParseMemoryReadingTest exposing (allTests)

import Common.EffectOnWindow
import EveOnline.ParseUserInterface
import Expect
import Test


allTests : Test.Test
allTests =
    Test.describe "Parse memory reading"
        [ overview_entry_distance_text_to_meter
        , inventory_capacity_gauge_text
        , parse_module_button_tooltip_shortcut
        , parse_neocom_clock_text
        , parse_security_status_percent_from_ui_node_text
        , parse_current_solar_system_from_ui_node_text
        , column_cell_texts_from_row_text
        , alt_text_from_markup
        ]


alt_text_from_markup : Test.Test
alt_text_from_markup =
    [ -- 2026-07-23 route info panel, docked with a 3-jump route set. Both quote styles occur.
      ( "<center><a href=\"showinfo:5//30004972\" alt=\"Next System in Route\">Algogille</a></b> <hint=\"Security status\"><color=#ff3a9aeb>0.9</color></hint><fontsize=12><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><a href=\"showinfo:4//20000727\">Crux</a><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><a href=\"showinfo:3//10000064\">Essence</a></fontsize></center>"
      , Just "Next System in Route"
      )
    , ( "<center><a href=\"showinfo:5//30004969\" alt=\"Current Destination\">Oursulaert</a></b> <hint=\"Security status\"><color=#ff3a9aeb>0.9</color></hint></center>"
      , Just "Current Destination"
      )

    -- 2026-07-23 location info panel's nearest-location link, single quotes.
    , ( "<url=showinfo:14//40343805 alt='Nearest'>Couster II - Moon 1</url>"
      , Just "Nearest"
      )
    , ( "<a href=\"showinfo:4//20000727\">Crux</a>"
      , Nothing
      )
    ]
        |> List.map
            (\( markupText, expectedResult ) ->
                Test.test markupText <|
                    \_ ->
                        markupText
                            |> EveOnline.ParseUserInterface.altTextFromMarkup
                            |> Expect.equal expectedResult
            )
        |> Test.describe "Alt text from markup"


column_cell_texts_from_row_text : Test.Test
column_cell_texts_from_row_text =
    [ -- 2026-07-23 regional market sell-order rows (Essence region, Tritanium), observed live.
      -- Columns: Jumps, Quantity, Price, Location, Expires in.
      ( "<right>8<t><right>5,838<t><right><color='0xFFFFFFFF'>3.00 ISK</color></right><t>Annages VII - Astral Mining Inc. Mining Outpost<t>88d 20h 11m 52s"
      , [ "8", "5,838", "3.00 ISK", "Annages VII - Astral Mining Inc. Mining Outpost", "88d 20h 11m 52s" ]
      )
    , ( "<right>5<t><right>1,155,354<t><right><color='0xFFFFFFFF'>3.37 ISK</color></right><t>Villore VIII - Moon 7 - Federal Intelligence Office Logistic Support<t>89d 4h 27m 40s"
      , [ "5", "1,155,354", "3.37 ISK", "Villore VIII - Moon 7 - Federal Intelligence Office Logistic Support", "89d 4h 27m 40s" ]
      )

    -- A text with no tab tag is one cell, whatever other markup it carries.
    , ( "<right><color='0xFFFFFFFF'>3.00 ISK</color></right>"
      , [ "3.00 ISK" ]
      )
    ]
        |> List.map
            (\( rowText, expectedCells ) ->
                Test.test rowText <|
                    \_ ->
                        rowText
                            |> EveOnline.ParseUserInterface.columnCellTextsFromRowText
                            |> Expect.equal expectedCells
            )
        |> Test.describe "Column cell texts from row text"


overview_entry_distance_text_to_meter : Test.Test
overview_entry_distance_text_to_meter =
    [ ( "2,856 m", Ok 2856 )
    , ( "123 m", Ok 123 )
    , ( "16 km", Ok 16000 )
    , ( "   345 m  ", Ok 345 )

    -- 2020-03-12 from TheRealManiac (https://forum.botlab.org/t/last-version-of-mining-bot/3149)
    , ( "6.621 m  ", Ok 6621 )

    -- 2020-03-22 from istu233 at https://forum.botlab.org/t/mining-bot-problem/3169
    , ( "2 980 m", Ok 2980 )

    -- Add case with more than two groups in number
    , ( " 3.444.555,6 m ", Ok 3444555 )
    ]
        |> List.map
            (\( displayText, expectedResult ) ->
                Test.test displayText <|
                    \_ ->
                        displayText
                            |> EveOnline.ParseUserInterface.parseOverviewEntryDistanceInMetersFromText
                            |> Expect.equal expectedResult
            )
        |> Test.describe "Overview entry distance text"


inventory_capacity_gauge_text : Test.Test
inventory_capacity_gauge_text =
    [ ( "1,211.9/5,000.0 m³", Ok { used = 1211, maximum = Just 5000, selected = Nothing } )
    , ( " 123.4 / 5,000.0 m³ ", Ok { used = 123, maximum = Just 5000, selected = Nothing } )

    -- Example from https://forum.botlab.org/t/standard-mining-bot-problems/2715/14
    , ( "4 999,8/5 000,0 m³", Ok { used = 4999, maximum = Just 5000, selected = Nothing } )

    -- 2020-01-31 sample 'process-sample-2FA2DCF580-[In Space with selected Ore Hold].zip' from Leon Bechen.
    , ( "0/5.000,0 m³", Ok { used = 0, maximum = Just 5000, selected = Nothing } )

    -- 2020-02-16-eve-online-sample
    , ( "(33.3) 53.6/450.0 m³", Ok { used = 53, maximum = Just 450, selected = Just 33 } )

    -- 2020-02-23 process-sample-FFE3312944 contributed by ORly (https://forum.botlab.org/t/mining-bot-i-cannot-see-the-ore-hold-capacity-gauge/3101/5)
    , ( "0/5\u{00A0}000,0 m³", Ok { used = 0, maximum = Just 5000, selected = Nothing } )

    -- 2020-07-26 scenario shared by neolexo at https://forum.botlab.org/t/issue-with-mining/3469/3
    , ( "0/5’000.0 m³", Ok { used = 0, maximum = Just 5000, selected = Nothing } )

    -- Add case with more than two groups in number
    , ( " 3.444.555,0 / 12.333.444,6 m³", Ok { used = 3444555, maximum = Just 12333444, selected = Nothing } )

    -- 2025-10-29 scenario shared by Tim Bbil at https://forum.botlab.org/t/eve-mining-bot-is-stuck-on-i-do-not-see-the-mining-hold-capacity-gauge/5272
    , ( "0/5'000.0 m³", Ok { used = 0, maximum = Just 5000, selected = Nothing } )
    ]
        |> List.map
            (\( text, expectedResult ) ->
                Test.test text <|
                    \_ ->
                        text
                            |> EveOnline.ParseUserInterface.parseInventoryCapacityGaugeText
                            |> Expect.equal expectedResult
            )
        |> Test.describe "Inventory capacity gauge text"


parse_module_button_tooltip_shortcut : Test.Test
parse_module_button_tooltip_shortcut =
    [ ( " F1 ", [ Common.EffectOnWindow.vkey_F1 ] )
    , ( " CTRL-F3 ", [ Common.EffectOnWindow.vkey_LCONTROL, Common.EffectOnWindow.vkey_F3 ] )
    , ( " STRG-F4 ", [ Common.EffectOnWindow.vkey_LCONTROL, Common.EffectOnWindow.vkey_F4 ] )
    , ( " ALT+F4 ", [ Common.EffectOnWindow.vkey_LMENU, Common.EffectOnWindow.vkey_F4 ] )
    , ( " SHIFT - F5 ", [ Common.EffectOnWindow.vkey_LSHIFT, Common.EffectOnWindow.vkey_F5 ] )
    , ( " UMSCH-F6 ", [ Common.EffectOnWindow.vkey_LSHIFT, Common.EffectOnWindow.vkey_F6 ] )
    ]
        |> List.map
            (\( text, expectedResult ) ->
                Test.test text <|
                    \_ ->
                        text
                            |> EveOnline.ParseUserInterface.parseModuleButtonTooltipShortcut
                            |> Expect.equal (Ok expectedResult)
            )
        |> Test.describe "Parse module button tooltip shortcut"


parse_neocom_clock_text : Test.Test
parse_neocom_clock_text =
    [ ( " 0:00 ", { hour = 0, minute = 0 } )
    , ( " 0:01 ", { hour = 0, minute = 1 } )
    , ( " 3 : 17 ", { hour = 3, minute = 17 } )
    , ( " 24 : 00 ", { hour = 24, minute = 0 } )
    ]
        |> List.map
            (\( text, expectedResult ) ->
                Test.test text <|
                    \_ ->
                        text
                            |> EveOnline.ParseUserInterface.parseNeocomClockText
                            |> Expect.equal (Ok expectedResult)
            )
        |> Test.describe "Parse neocom clock text"


parse_security_status_percent_from_ui_node_text : Test.Test
parse_security_status_percent_from_ui_node_text =
    [ ( """<url=showinfo:5//30000142 alt='Current Solar System'>Jita</url></b> <color=0xff4cffccL><hint='Security status'>0.9</hint></color><fontsize=12><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><url=showinfo:4//20000020>Kimotoro</url><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><url=showinfo:3//10000002>The Forge</url>""", Just 90 )

    -- Scenario by Samuel Pagé aka Mohano from https://forum.botlab.org/t/new-code-for-some-memory-elements-in-new-patch/3989
    , ( """<hint="Security status"><color=#ffffff00>0.5</color></hint>""", Just 50 )
    ]
        |> List.map
            (\( text, expectedResult ) ->
                Test.test text <|
                    \_ ->
                        text
                            |> EveOnline.ParseUserInterface.parseSecurityStatusPercentFromUINodeText
                            |> Expect.equal expectedResult
            )
        |> Test.describe "Parse security status from UI node text"


parse_current_solar_system_from_ui_node_text : Test.Test
parse_current_solar_system_from_ui_node_text =
    [ ( """<url=showinfo:5//30000142 alt='Current Solar System'>Jita</url></b> <color=0xff4cffccL><hint='Security status'>0.9</hint></color><fontsize=12><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><url=showinfo:4//20000020>Kimotoro</url><fontsize=8> </fontsize>&lt;<fontsize=8> </fontsize><url=showinfo:3//10000002>The Forge</url>""", Just "Jita" )

    -- Scenario by Breazy shared with `session-2021-10-26T06-47-59-025605.zip` (https://forum.botlab.org/t/error-with-anom-bot/4195)
    , ( """<a href="showinfo:5//30004759" alt="Current Solar System">1DQ1-A</a></b> <hint="Security status"><color=#ffff0000>-0.4</color></hint>""", Just "1DQ1-A" )
    ]
        |> List.map
            (\( text, expectedResult ) ->
                Test.test text <|
                    \_ ->
                        text
                            |> EveOnline.ParseUserInterface.parseCurrentSolarSystemFromUINodeText
                            |> Expect.equal expectedResult
            )
        |> Test.describe "Parse current solar system from UI node text"
