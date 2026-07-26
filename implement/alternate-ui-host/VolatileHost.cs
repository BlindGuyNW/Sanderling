using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace AlternateUiHost;

/*
Ported from implement/alternate-ui/source/src/EveOnline/VolatileProcess.csx, which ran inside the
Pine runtime as a volatile process. The request/response contract (and its JSON shape, produced by
Newtonsoft with nulls omitted) is unchanged: the Elm frontend's hand-written codecs in
EveOnline/VolatileProcessInterface.elm decode exactly this.

The foreground input path (WindowMotor / InputSimulator, selected by bringWindowToForeground =
true) was NOT ported: the frontend always passes false, and dropping the path drops four
hash-pinned assembly dependencies. A request with bringWindowToForeground = true now fails
explicitly instead of stealing focus.
*/

public class Request
{
    public object ListGameClientProcessesRequest;

    public SearchUIRootAddressStructure SearchUIRootAddress;

    public ReadFromWindowStructure ReadFromWindow;

    public TaskOnWindow<EffectSequenceElement[]> EffectSequenceOnWindow;

    public class SearchUIRootAddressStructure
    {
        public int processId;
    }

    public class ReadFromWindowStructure
    {
        public string windowId;

        public ulong uiRootAddress;
    }

    public class TaskOnWindow<Task>
    {
        public string windowId;

        public bool bringWindowToForeground;

        public Task task;
    }

    public class EffectSequenceElement
    {
        public EffectOnWindowStructure effect;

        public int? delayMilliseconds;
    }

    public class EffectOnWindowStructure
    {
        public MouseMoveToStructure MouseMoveTo;

        public VerticalScrollAtStructure VerticalScrollAt;

        public KeyboardKey KeyDown;

        public KeyboardKey KeyUp;
    }

    public class VerticalScrollAtStructure
    {
        public Location2d location;

        public int deltaTicks;
    }

    public class KeyboardKey
    {
        public int virtualKeyCode;
    }

    public class MouseMoveToStructure
    {
        public Location2d location;
    }
}

public class Response
{
    public GameClientProcessSummaryStruct[] ListGameClientProcessesResponse;

    public SearchUIRootAddressResponseStruct SearchUIRootAddressResponse;

    public ReadFromWindowResultStructure ReadFromWindowResult;

    public string FailedToBringWindowToFront;

    public object CompletedEffectSequenceOnWindow;

    public class GameClientProcessSummaryStruct
    {
        public int processId;

        public string mainWindowId;

        public string mainWindowTitle;

        public int mainWindowZIndex;
    }

    public class SearchUIRootAddressResponseStruct
    {
        public int processId;

        public SearchUIRootAddressStage stage;
    }

    public class SearchUIRootAddressStage
    {
        public SearchUIRootAddressInProgressStruct SearchUIRootAddressInProgress;

        public SearchUIRootAddressCompletedStruct SearchUIRootAddressCompleted;
    }

    public class SearchUIRootAddressInProgressStruct
    {
        public long searchBeginTimeMilliseconds;

        public long currentTimeMilliseconds;
    }

    public class SearchUIRootAddressCompletedStruct
    {
        public string uiRootAddress;
    }

    public class ReadFromWindowResultStructure
    {
        public object ProcessNotFound;

        public CompletedStructure Completed;

        public class CompletedStructure
        {
            public int processId;

            public Location2d windowClientRectOffset;

            public string readingId;

            public string memoryReadingSerialRepresentationJson;

            public string pythonTypeHierarchySerialRepresentationJson;
        }
    }
}

public struct Location2d
{
    public Int64 x, y;
}

public static class VolatileHost
{
    static int readingFromGameCount = 0;

    static readonly System.Diagnostics.Stopwatch generalStopwatch = System.Diagnostics.Stopwatch.StartNew();

    static readonly ConcurrentDictionary<int, SearchUIRootAddressTask> searchUIRootAddressTasks = new();

    class SearchUIRootAddressTask
    {
        public Request.SearchUIRootAddressStructure request;

        public TimeSpan beginTime;

        public Response.SearchUIRootAddressCompletedStruct completed;

        public SearchUIRootAddressTask(Request.SearchUIRootAddressStructure request)
        {
            this.request = request;
            beginTime = generalStopwatch.Elapsed;

            System.Threading.Tasks.Task.Run(() =>
            {
                var uiTreeRootAddress = FindUIRootAddressFromProcessId(request.processId);

                completed = new Response.SearchUIRootAddressCompletedStruct
                {
                    uiRootAddress = uiTreeRootAddress?.ToString()
                };
            });
        }
    }

    /*
    Same wire entry point the .csx exposed (`InterfaceToHost_Request`): the hand-written inner
    JSON in, the response JSON out. Not used by the phase-1 envelope adapter (which translates
    the Pine-generated format and calls HandleRequest directly), but it is the contract the
    frontend will speak after the envelope collapse.
    */
    public static string SerialRequest(string serializedRequest)
    {
        var requestStructure = Newtonsoft.Json.JsonConvert.DeserializeObject<Request>(serializedRequest);

        var response = HandleRequest(requestStructure);

        return SerializeToJsonForBot(response);
    }

    public static Response HandleRequest(Request request)
    {
        if (request.ListGameClientProcessesRequest != null)
        {
            return new Response
            {
                ListGameClientProcessesResponse =
                    ListGameClientProcesses().ToArray(),
            };
        }

        if (request.SearchUIRootAddress != null)
        {
            var searchTask =
                searchUIRootAddressTasks.GetOrAdd(
                    request.SearchUIRootAddress.processId,
                    _ => new SearchUIRootAddressTask(request.SearchUIRootAddress));

            return new Response
            {
                SearchUIRootAddressResponse = new Response.SearchUIRootAddressResponseStruct
                {
                    processId = request.SearchUIRootAddress.processId,
                    stage = SearchUIRootAddressTaskAsResponseStage(searchTask)
                },
            };
        }

        if (request.ReadFromWindow is { } readFromWindow)
        {
            var readingFromGameIndex = System.Threading.Interlocked.Increment(ref readingFromGameCount);

            var readingId = readingFromGameIndex.ToString("D6") + "-" + generalStopwatch.ElapsedMilliseconds;

            var windowId = readFromWindow.windowId;
            var windowHandle = new IntPtr(long.Parse(windowId));

            WinApi.GetWindowThreadProcessId(windowHandle, out var processIdUnsigned);

            if (processIdUnsigned is 0)
            {
                return new Response
                {
                    ReadFromWindowResult = new Response.ReadFromWindowResultStructure
                    {
                        ProcessNotFound = new object(),
                    }
                };
            }

            var processId = (int)processIdUnsigned;

            var windowRect = new WinApi.Rect();
            WinApi.GetWindowRect(windowHandle, ref windowRect);

            var clientRectOffsetFromScreen = new WinApi.Point(0, 0);
            WinApi.ClientToScreen(windowHandle, ref clientRectOffsetFromScreen);

            var windowClientRectOffset =
                new Location2d
                { x = clientRectOffsetFromScreen.x - windowRect.left, y = clientRectOffsetFromScreen.y - windowRect.top };

            string memoryReadingSerialRepresentationJson = null;

            //  The client's class inheritance, one entry per type name in the tree, most-derived
            //  first. This is the signal the frontend uses to tell a control from the container
            //  that holds it - a fact the type name alone does not carry. Read here, while the
            //  memory reader is alive, because it resolves type objects out of the same process.
            string pythonTypeHierarchySerialRepresentationJson = null;

            using (var memoryReader = new read_memory_64_bit.MemoryReaderFromLiveProcess(processId))
            {
                var uiTree = read_memory_64_bit.EveOnline64.ReadUITreeFromAddress(readFromWindow.uiRootAddress, memoryReader, 99);

                if (uiTree != null)
                {
                    memoryReadingSerialRepresentationJson =
                    read_memory_64_bit.EveOnline64.SerializeMemoryReadingNodeToJson(
                        uiTree.WithOtherDictEntriesRemoved());

                    pythonTypeHierarchySerialRepresentationJson =
                    Newtonsoft.Json.JsonConvert.SerializeObject(
                        read_memory_64_bit.EveOnline64.ReadPythonTypeHierarchy(uiTree, memoryReader));
                }
            }

            return new Response
            {
                ReadFromWindowResult = new Response.ReadFromWindowResultStructure
                {
                    Completed = new Response.ReadFromWindowResultStructure.CompletedStructure
                    {
                        processId = processId,
                        windowClientRectOffset = windowClientRectOffset,
                        memoryReadingSerialRepresentationJson = memoryReadingSerialRepresentationJson,
                        pythonTypeHierarchySerialRepresentationJson = pythonTypeHierarchySerialRepresentationJson,
                        readingId = readingId
                    },
                },
            };
        }

        if (request?.EffectSequenceOnWindow?.task != null)
        {
            var windowHandle = new IntPtr(long.Parse(request.EffectSequenceOnWindow.windowId));

            if (request.EffectSequenceOnWindow.bringWindowToForeground)
            {
                //  The foreground path was not ported; see the comment at the top of this file.
                return new Response
                {
                    FailedToBringWindowToFront =
                        "This host does not support bringWindowToForeground; send the sequence with bringWindowToForeground = false.",
                };
            }

            foreach (var sequenceElement in request.EffectSequenceOnWindow.task)
            {
                if (sequenceElement?.effect != null)
                    ExecuteEffectOnWindowViaMessages(sequenceElement.effect, windowHandle);

                if (sequenceElement?.delayMilliseconds != null)
                    System.Threading.Thread.Sleep(sequenceElement.delayMilliseconds.Value);
            }

            return new Response
            {
                CompletedEffectSequenceOnWindow = new object(),
            };
        }

        return null;
    }

    static Response.SearchUIRootAddressStage SearchUIRootAddressTaskAsResponseStage(SearchUIRootAddressTask task)
    {
        return task.completed switch
        {
            Response.SearchUIRootAddressCompletedStruct completed =>
            new Response.SearchUIRootAddressStage { SearchUIRootAddressCompleted = completed },

            _ => new Response.SearchUIRootAddressStage
            {
                SearchUIRootAddressInProgress = new Response.SearchUIRootAddressInProgressStruct
                {
                    searchBeginTimeMilliseconds = (long)task.beginTime.TotalMilliseconds,
                    currentTimeMilliseconds = generalStopwatch.ElapsedMilliseconds,
                }
            }
        };
    }

    static ulong? FindUIRootAddressFromProcessId(int processId)
    {
        var candidatesAddresses =
            read_memory_64_bit.EveOnline64.EnumeratePossibleAddressesForUIRootObjectsFromProcessId(processId);

        using (var memoryReader = new read_memory_64_bit.MemoryReaderFromLiveProcess(processId))
        {
            var uiTrees =
                candidatesAddresses
                .Select(candidateAddress => read_memory_64_bit.EveOnline64.ReadUITreeFromAddress(candidateAddress, memoryReader, 99))
                .ToList();

            return
                uiTrees
                .OrderByDescending(uiTree => uiTree?.EnumerateSelfAndDescendants().Count() ?? -1)
                .FirstOrDefault()
                ?.pythonObjectAddress;
        }
    }

    static void ExecuteEffectOnWindowViaMessages(
        Request.EffectOnWindowStructure effectOnWindow,
        IntPtr windowHandle)
    {
        if (effectOnWindow?.MouseMoveTo != null)
        {
            InputViaWindowMessages.MouseMoveTo(
                windowHandle,
                (int)effectOnWindow.MouseMoveTo.location.x,
                (int)effectOnWindow.MouseMoveTo.location.y);
        }

        if (effectOnWindow?.VerticalScrollAt != null)
        {
            InputViaWindowMessages.VerticalScroll(
                windowHandle,
                (int)effectOnWindow.VerticalScrollAt.location.x,
                (int)effectOnWindow.VerticalScrollAt.location.y,
                effectOnWindow.VerticalScrollAt.deltaTicks);
        }

        /*
        The interface models a mouse click as a key down/up on the LBUTTON/RBUTTON virtual key codes,
        so those have to be split back out into mouse messages here.
        */
        if (effectOnWindow?.KeyDown != null)
        {
            var virtualKeyCode = effectOnWindow.KeyDown.virtualKeyCode;

            if (InputViaWindowMessages.IsMouseButton(virtualKeyCode))
                InputViaWindowMessages.MouseButtonDown(windowHandle, virtualKeyCode);
            else
                InputViaWindowMessages.KeyDown(windowHandle, virtualKeyCode);
        }

        if (effectOnWindow?.KeyUp != null)
        {
            var virtualKeyCode = effectOnWindow.KeyUp.virtualKeyCode;

            if (InputViaWindowMessages.IsMouseButton(virtualKeyCode))
                InputViaWindowMessages.MouseButtonUp(windowHandle, virtualKeyCode);
            else
                InputViaWindowMessages.KeyUp(windowHandle, virtualKeyCode);
        }
    }

    public static string SerializeToJsonForBot<T>(T value) =>
        Newtonsoft.Json.JsonConvert.SerializeObject(
            value,
            new Newtonsoft.Json.JsonSerializerSettings
            {
                //  The Elm decoders treat absent and present-but-null fields differently in
                //  places (jsonDecode_optionalField); omitting nulls preserves the .csx's shape.
                NullValueHandling = Newtonsoft.Json.NullValueHandling.Ignore,

                ReferenceLoopHandling = Newtonsoft.Json.ReferenceLoopHandling.Ignore,
            });

    static System.Diagnostics.Process[] GetWindowsProcessesLookingLikeEVEOnlineClient() =>
        System.Diagnostics.Process.GetProcessesByName("exefile");

    static IReadOnlyList<Response.GameClientProcessSummaryStruct> ListGameClientProcesses()
    {
        var allWindowHandlesInZOrder = WinApi.ListWindowHandlesInZOrder();

        int? zIndexFromWindowHandle(IntPtr windowHandleToSearch) =>
            allWindowHandlesInZOrder
            .Select((windowHandle, index) => (windowHandle, index: (int?)index))
            .FirstOrDefault(handleAndIndex => handleAndIndex.windowHandle == windowHandleToSearch)
            .index;

        var processes =
            GetWindowsProcessesLookingLikeEVEOnlineClient()
            .Select(process =>
            {
                return new Response.GameClientProcessSummaryStruct
                {
                    processId = process.Id,
                    mainWindowId = process.MainWindowHandle.ToInt64().ToString(),
                    mainWindowTitle = process.MainWindowTitle,
                    mainWindowZIndex = zIndexFromWindowHandle(process.MainWindowHandle) ?? 9999,
                };
            })
            .ToList();

        return processes;
    }
}
