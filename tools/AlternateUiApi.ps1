<#
.SYNOPSIS
Drive a running alternate-UI backend over HTTP: read the live UI tree and send input.

.DESCRIPTION
Dot-source this file, then talk to the backend the same way the frontend does:

    . ./tools/AlternateUiApi.ps1
    $ctx = Connect-GameClient
    $tree = Read-UITree -Context $ctx
    Get-FlatNodes -Root $tree | Where-Object { $_.Name -eq 'charSheetBtn' }
    Send-MouseClick -Context $ctx -X 24 -Y 72

The point is to verify that an effect actually landed without needing to look at the game:
take a Get-WindowSignature before and after, and compare. That makes changes checkable
from the terminal alone.

Protocol notes, which are easy to get wrong:
  - Pine's generated JSON converters encode a custom-type tag as {"Tag":[arg, ...]} -
    tag arguments are ALWAYS wrapped in an array, even for a single argument.
  - The interesting payload comes back as returnValueToString.Just[0], which is itself a
    JSON *string* and needs a second parse.
  - Invoke-WebRequest hands back .Content as a byte array here, so decode it as UTF8.
#>

$script:AlternateUiApiUri = 'http://localhost/api'

function Set-AlternateUiEndpoint {
    <#
    .SYNOPSIS
    Point the helpers at a different port, e.g. a second instance started with -Port 8080.
    #>
    param([Parameter(Mandatory = $true)][int]$Port)
    $script:AlternateUiApiUri = "http://localhost:$Port/api"
    Write-Verbose "endpoint is now $script:AlternateUiApiUri"
}

function Invoke-VolatileRequest {
    <#
    .SYNOPSIS
    Send one request to the backend's volatile process and return the parsed response.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        $Payload = @{}
    )

    $body = @{ RunInVolatileProcessRequest = @(@{ $Tag = @($Payload) }) } |
        ConvertTo-Json -Depth 25 -Compress

    try {
        $response = Invoke-WebRequest -Uri $script:AlternateUiApiUri -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 60
    }
    catch {
        throw "request '$Tag' to $script:AlternateUiApiUri failed: $($_.Exception.Message)"
    }

    $outer = [System.Text.Encoding]::UTF8.GetString($response.Content) | ConvertFrom-Json
    $complete = $outer.RunInVolatileProcessCompleteResponse[0]

    if ($complete.exceptionToString.Just) {
        throw "volatile process raised: $($complete.exceptionToString.Just)"
    }

    if ($null -eq $complete.returnValueToString.Just) { return $null }

    return ($complete.returnValueToString.Just[0] | ConvertFrom-Json)
}

function Get-GameClientProcesses {
    (Invoke-VolatileRequest -Tag 'ListGameClientProcessesRequest').ListGameClientProcessesResponse
}

function Get-UIRootAddress {
    <#
    .SYNOPSIS
    Search for the UI root object, polling until the search completes.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $stage = (Invoke-VolatileRequest -Tag 'SearchUIRootAddress' `
                -Payload @{ processId = $ProcessId }).SearchUIRootAddressResponse.stage
        if ($stage.SearchUIRootAddressCompleted) {
            return $stage.SearchUIRootAddressCompleted.uiRootAddress
        }
        Start-Sleep -Milliseconds 800
    }
    throw "timed out after ${TimeoutSeconds}s searching for the UI root address"
}

function Connect-GameClient {
    <#
    .SYNOPSIS
    Resolve the game client once and return a context to pass to the other helpers.
    #>
    param([int]$ProcessId)

    $clients = @(Get-GameClientProcesses)
    if ($clients.Count -eq 0) { throw "no EVE Online client process found" }

    $client = if ($ProcessId) {
        $clients | Where-Object { $_.processId -eq $ProcessId } | Select-Object -First 1
    }
    else { $clients[0] }

    if (-not $client) { throw "no game client with process id $ProcessId" }

    [pscustomobject]@{
        ProcessId     = $client.processId
        WindowId      = $client.mainWindowId
        WindowTitle   = $client.mainWindowTitle
        UIRootAddress = Get-UIRootAddress -ProcessId $client.processId
    }
}

function Read-UITree {
    <#
    .SYNOPSIS
    Read the current UI tree. Pass -SaveTo to also write the raw JSON to a file.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$SaveTo
    )
    $result = Invoke-VolatileRequest -Tag 'ReadFromWindow' -Payload @{
        windowId      = $Context.WindowId
        uiRootAddress = $Context.UIRootAddress
    }
    $completed = $result.ReadFromWindowResult.Completed
    if (-not $completed) {
        throw "read failed: $($result | ConvertTo-Json -Depth 6 -Compress)"
    }
    $json = $completed.memoryReadingSerialRepresentationJson
    if ($SaveTo) { Set-Content -Path $SaveTo -Value $json -Encoding UTF8 }
    return $json | ConvertFrom-Json
}

function Get-NodeInt {
    <#
    .SYNOPSIS
    Read an integer dict entry. The reader emits some of these as {int, int_low32}.
    #>
    param($Node, [string]$Key)
    $property = $Node.dictEntriesOfInterest.PSObject.Properties[$Key]
    if ($null -eq $property) { return $null }
    $value = $property.Value
    if ($value -is [int] -or $value -is [long] -or $value -is [double]) { return [int]$value }
    if ($null -ne $value.int_low32) { return [int]$value.int_low32 }
    return $null
}

function Walk-UINode {
    param($Node, [int]$OffX, [int]$OffY, [int]$Depth, [string]$PathStr, $Sink)
    if ($null -eq $Node) { return }

    $dx = Get-NodeInt $Node '_displayX'; if ($null -eq $dx) { $dx = 0 }
    $dy = Get-NodeInt $Node '_displayY'; if ($null -eq $dy) { $dy = 0 }
    $w = Get-NodeInt $Node '_displayWidth'
    $h = Get-NodeInt $Node '_displayHeight'
    $absX = $OffX + $dx
    $absY = $OffY + $dy

    $text = $Node.dictEntriesOfInterest._setText
    if ($null -eq $text) { $text = $Node.dictEntriesOfInterest._text }

    [void]$Sink.Add([pscustomobject]@{
            Depth = $Depth
            Type  = $Node.pythonObjectTypeName
            Name  = $Node.dictEntriesOfInterest._name
            Text  = $text
            X     = $absX; Y = $absY; W = $w; H = $h
            CX    = $(if ($null -ne $w) { $absX + [int]($w / 2) } else { $absX })
            CY    = $(if ($null -ne $h) { $absY + [int]($h / 2) } else { $absY })
            Path  = $PathStr
        })

    $index = 0
    foreach ($child in $Node.children) {
        Walk-UINode -Node $child -OffX $absX -OffY $absY -Depth ($Depth + 1) `
            -PathStr "$PathStr/$index" -Sink $Sink
        $index++
    }
}

function Get-FlatNodes {
    <#
    .SYNOPSIS
    Flatten a UI tree into rows with absolute display regions. CX/CY are click targets.
    #>
    param([Parameter(Mandatory = $true)]$Root)
    $sink = New-Object System.Collections.ArrayList
    Walk-UINode -Node $Root -OffX 0 -OffY 0 -Depth 0 -PathStr '' -Sink $sink
    return $sink
}

function Get-RawNode {
    <#
    .SYNOPSIS
    Resolve a Path from Get-FlatNodes back to the raw node, to inspect all its dict entries.
    #>
    param([Parameter(Mandatory = $true)]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $node = $Root
    foreach ($index in ($Path -split '/' | Where-Object { $_ -ne '' })) {
        $node = $node.children[[int]$index]
    }
    return $node
}

function Get-WindowSignature {
    <#
    .SYNOPSIS
    A stable summary of which game windows are open - the oracle for "did that effect land?".

    .DESCRIPTION
    WindowUnderlay rects change when a game window opens or closes, which makes them a far
    better signal than raw node count (which drifts with hover states and live values).
    #>
    param([Parameter(Mandatory = $true)]$Tree)
    $flat = Get-FlatNodes -Root $Tree
    $underlays = @($flat |
        Where-Object { $_.Type -eq 'WindowUnderlay' } |
        ForEach-Object { "$($_.X),$($_.Y),$($_.W)x$($_.H)" } |
        Sort-Object)
    $menuRoot = $flat | Where-Object { $_.Name -eq 'l_menu' } | Select-Object -First 1
    $menuNodes = if ($menuRoot) {
        @($flat | Where-Object { $_.Path -like "$($menuRoot.Path)/*" }).Count
    }
    else { 0 }

    [pscustomobject]@{
        UnderlayCount = $underlays.Count
        Underlays     = $underlays
        MenuNodeCount = $menuNodes   # context menus land in the l_menu layer
        NodeCount     = $flat.Count
    }
}

function Compare-WindowSignature {
    <#
    .SYNOPSIS
    Report whether the set of open windows changed between two signatures.
    #>
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After,
        [string]$Label = 'effect'
    )
    <#
    Judge on windows AND menus. A right click opens a context menu without touching any
    WindowUnderlay, so reporting on underlays alone calls a working click "no change" -
    a false negative that is worse than noise, because it sends you debugging input
    delivery when input was fine.
    #>
    $windowsChanged = ($Before.Underlays -join '|') -ne ($After.Underlays -join '|')
    $menuChanged = $Before.MenuNodeCount -ne $After.MenuNodeCount

    $verdict =
    if ($windowsChanged -and $menuChanged) { 'CHANGED (windows+menu)' }
    elseif ($windowsChanged) { 'CHANGED (windows)' }
    elseif ($menuChanged) { 'CHANGED (menu)' }
    else { 'no change' }

    "{0,-24} underlays {1} -> {2}   menu {3} -> {4}   nodes {5} -> {6}   [{7}]" -f `
        $Label, $Before.UnderlayCount, $After.UnderlayCount, `
        $Before.MenuNodeCount, $After.MenuNodeCount, `
        $Before.NodeCount, $After.NodeCount, $verdict

    foreach ($rect in ($After.Underlays | Where-Object { $_ -notin $Before.Underlays })) {
        "    appeared: $rect"
    }
    foreach ($rect in ($Before.Underlays | Where-Object { $_ -notin $After.Underlays })) {
        "    vanished: $rect"
    }
}

function Send-EffectSequence {
    <#
    .SYNOPSIS
    Send a raw effect sequence, going through the same path the frontend uses.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][array]$Task,
        [switch]$BringWindowToForeground
    )
    Invoke-VolatileRequest -Tag 'EffectSequenceOnWindow' -Payload @{
        windowId                = $Context.WindowId
        bringWindowToForeground = [bool]$BringWindowToForeground
        task                    = $Task
    } | Out-Null
}

function Send-MouseClick {
    <#
    .SYNOPSIS
    Click at a location in client coordinates, without bringing the window to the foreground.

    .DESCRIPTION
    Note the volatile process enforces its own wait between the move and the button down;
    the delay elements here only pace the sequence.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left'
    )
    $virtualKeyCode = if ($Button -eq 'Left') { 1 } else { 2 }
    Send-EffectSequence -Context $Context -Task @(
        @{ Effect = @(@{ MouseMoveTo = @(@{ location = @{ x = $X; y = $Y } }) }) },
        @{ DelayMilliseconds = @(30) },
        @{ Effect = @(@{ KeyDown = @(@{ VirtualKeyCodeFromInt = @($virtualKeyCode) }) }) },
        @{ DelayMilliseconds = @(30) },
        @{ Effect = @(@{ KeyUp = @(@{ VirtualKeyCodeFromInt = @($virtualKeyCode) }) }) }
    )
}

function Send-KeyStroke {
    <#
    .SYNOPSIS
    Press and release a virtual key. Only WM_KEYDOWN/WM_KEYUP are sent - never WM_CHAR,
    which the client would turn into a second copy of the character.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][int]$VirtualKeyCode
    )
    Send-EffectSequence -Context $Context -Task @(
        @{ Effect = @(@{ KeyDown = @(@{ VirtualKeyCodeFromInt = @($VirtualKeyCode) }) }) },
        @{ DelayMilliseconds = @(40) },
        @{ Effect = @(@{ KeyUp = @(@{ VirtualKeyCodeFromInt = @($VirtualKeyCode) }) }) }
    )
}
