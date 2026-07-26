using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Newtonsoft.Json.Linq;

namespace AlternateUiHost;

/*
Replacement for the Pine web service (Backend/Main.elm): three routes, no interpreted VM in the
path. See implement/alternate-ui/PLAN-dotnet-host.md for why and for the phase plan.

Phase 1 keeps the frontend byte-identical, so this host speaks the frontend's current envelope:
the body is the Pine-GENERATED encoding of InterfaceToFrontendClient.RequestFromClient, in which
every custom-type tag wraps its arguments in an array - {"Tag":[arg]} - and a Maybe is
{"Just":[v]} / {"Nothing":[]}. EnvelopeAdapter translates that into the DTOs VolatileHost uses
(which mirror the hand-written inner codec), and wraps the response back the same way. The
adapter dies in phase 3, when the frontend starts posting the inner request directly.
*/
public static class Program
{
    public static void Main(string[] args)
    {
        WinApi.SetProcessDPIAware();

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = args,
            ContentRootPath = AppContext.BaseDirectory,
        });

        /*
        Bind to localhost only unless told otherwise: this endpoint can send mouse and keyboard
        input to the game client, so it must not listen on every interface. Default port 8080
        while the pine instance keeps 80 (plan phase 4 swaps that).
        */
        if (builder.Configuration["urls"] is null
            && Environment.GetEnvironmentVariable("ASPNETCORE_URLS") is null)
        {
            builder.WebHost.UseUrls("http://localhost:8080");
        }

        var app = builder.Build();

        var frontendHtmlPath = Path.Combine(AppContext.BaseDirectory, "wwwroot", "alternate-ui.html");

        //  Built with `pine make --debug`, which turns on Elm's time-travelling debugger.
        var frontendDebugHtmlPath = Path.Combine(AppContext.BaseDirectory, "wwwroot", "alternate-ui-debug.html");

        IResult ServeFrontend(bool enableInspector)
        {
            var path =
                enableInspector && File.Exists(frontendDebugHtmlPath)
                    ? frontendDebugHtmlPath
                    : frontendHtmlPath;

            if (!File.Exists(path))
                return Results.Text(
                    "Frontend HTML not found at " + path +
                    "\nBuild it with start-alternate-ui-host.ps1 (which runs pine make).",
                    statusCode: 500);

            return Results.File(path, "text/html");
        }

        //  Cast to Delegate so this binds as a route handler (whose IResult is written to the
        //  response), not as a RequestDelegate (whose return value would be discarded).
        //  The router matches "/api/" (what the frontend posts to) against this same pattern.
        app.MapPost("/api", (Delegate)HandleApiRequest);

        app.MapGet("/with-inspector", () => ServeFrontend(enableInspector: true));

        //  The pine backend serves the frontend for every non-API route; keep that behaviour.
        app.MapFallback(() => ServeFrontend(enableInspector: false));

        app.Run();
    }

    static async Task<IResult> HandleApiRequest(HttpContext context)
    {
        string body;
        using (var reader = new StreamReader(context.Request.Body))
            body = await reader.ReadToEndAsync();

        JObject outer;
        try
        {
            outer = JObject.Parse(body);
        }
        catch (Exception e)
        {
            return Results.Text("Failed to decode request: " + e.Message, statusCode: 400);
        }

        if (outer.ContainsKey("ReadLogRequest"))
            return Results.Text("");

        if (EnvelopeAdapter.UnwrapTag(outer["RunInVolatileProcessRequest"]) is not JObject innerRequest)
            return Results.Text("Failed to decode request: expected RunInVolatileProcessRequest", statusCode: 400);

        var stopwatch = Stopwatch.StartNew();

        string exceptionToString = null;
        string returnValueToString = null;

        /*
        The request handler runs the game-client work synchronously (memory reads, effect
        sequences with their sleeps). Run it off the request thread so Kestrel's loop stays free;
        unlike the volatile process, two requests can be in flight at once - input effects still
        serialize on InputViaWindowMessages' own lock.
        */
        try
        {
            var request = EnvelopeAdapter.RequestFromGeneratedEncoding(innerRequest);

            var response = await Task.Run(() => VolatileHost.HandleRequest(request));

            returnValueToString = VolatileHost.SerializeToJsonForBot(response);
        }
        catch (Exception e)
        {
            exceptionToString = e.ToString();
        }

        var completeResponse = new JObject
        {
            ["exceptionToString"] = EnvelopeAdapter.MaybeString(exceptionToString),
            ["returnValueToString"] = EnvelopeAdapter.MaybeString(returnValueToString),
            ["durationInMilliseconds"] = stopwatch.ElapsedMilliseconds,
        };

        var envelope = new JObject
        {
            ["RunInVolatileProcessCompleteResponse"] = new JArray(completeResponse),
        };

        return Results.Text(envelope.ToString(Newtonsoft.Json.Formatting.None), "application/json");
    }
}

public static class EnvelopeAdapter
{
    /*
    A tag's arguments are always array-wrapped in the generated encoding; a nullary tag carries
    an empty array. Tolerate a bare value too, which is what the hand-written codec emits.
    */
    public static JToken UnwrapTag(JToken token) =>
        token is JArray array
            ? (array.Count > 0 ? array[0] : new JObject())
            : token;

    public static JObject MaybeString(string value) =>
        value is null
            ? new JObject { ["Nothing"] = new JArray() }
            : new JObject { ["Just"] = new JArray(value) };

    public static Request RequestFromGeneratedEncoding(JObject inner)
    {
        if (inner.ContainsKey("ListGameClientProcessesRequest"))
            return new Request { ListGameClientProcessesRequest = new object() };

        if (UnwrapTag(inner["SearchUIRootAddress"]) is JObject search)
            return new Request
            {
                SearchUIRootAddress = new Request.SearchUIRootAddressStructure
                {
                    processId = (int)search["processId"],
                },
            };

        if (UnwrapTag(inner["ReadFromWindow"]) is JObject read)
            return new Request
            {
                ReadFromWindow = new Request.ReadFromWindowStructure
                {
                    windowId = (string)read["windowId"],
                    //  A string on the wire (Elm has no 64-bit integer), a ulong in the DTO.
                    uiRootAddress = ulong.Parse((string)read["uiRootAddress"]),
                },
            };

        if (UnwrapTag(inner["EffectSequenceOnWindow"]) is JObject sequence)
        {
            var task = new System.Collections.Generic.List<Request.EffectSequenceElement>();

            foreach (var elementToken in (JArray)sequence["task"])
            {
                var element = (JObject)elementToken;

                if (UnwrapTag(element["Effect"]) is JObject effect)
                    task.Add(new Request.EffectSequenceElement
                    {
                        effect = EffectFromGeneratedEncoding(effect),
                    });
                else if (element.ContainsKey("DelayMilliseconds"))
                    task.Add(new Request.EffectSequenceElement
                    {
                        delayMilliseconds = (int)UnwrapTag(element["DelayMilliseconds"]),
                    });
                else
                    throw new Exception("Unknown effect sequence element: " + element.ToString());
            }

            return new Request
            {
                EffectSequenceOnWindow = new Request.TaskOnWindow<Request.EffectSequenceElement[]>
                {
                    windowId = (string)sequence["windowId"],
                    bringWindowToForeground = (bool)sequence["bringWindowToForeground"],
                    task = task.ToArray(),
                },
            };
        }

        throw new Exception("Unknown request: " + inner.ToString());
    }

    static Request.EffectOnWindowStructure EffectFromGeneratedEncoding(JObject effect)
    {
        if (UnwrapTag(effect["MouseMoveTo"]) is JObject mouseMoveTo)
            return new Request.EffectOnWindowStructure
            {
                MouseMoveTo = new Request.MouseMoveToStructure
                {
                    location = LocationFromJson((JObject)mouseMoveTo["location"]),
                },
            };

        if (UnwrapTag(effect["VerticalScrollAt"]) is JObject verticalScrollAt)
            return new Request.EffectOnWindowStructure
            {
                VerticalScrollAt = new Request.VerticalScrollAtStructure
                {
                    location = LocationFromJson((JObject)verticalScrollAt["location"]),
                    deltaTicks = (int)verticalScrollAt["deltaTicks"],
                },
            };

        if (UnwrapTag(effect["KeyDown"]) is JObject keyDown)
            return new Request.EffectOnWindowStructure
            {
                KeyDown = new Request.KeyboardKey { virtualKeyCode = VirtualKeyCodeFromJson(keyDown) },
            };

        if (UnwrapTag(effect["KeyUp"]) is JObject keyUp)
            return new Request.EffectOnWindowStructure
            {
                KeyUp = new Request.KeyboardKey { virtualKeyCode = VirtualKeyCodeFromJson(keyUp) },
            };

        if (effect.ContainsKey("TypeCharacter"))
            return new Request.EffectOnWindowStructure
            {
                TypeCharacter = new Request.TypeCharacterStructure
                {
                    characterCode = CharacterCodeFromJson(effect["TypeCharacter"]),
                },
            };

        throw new Exception("Unknown effect: " + effect.ToString());
    }

    static Location2d LocationFromJson(JObject location) =>
        new Location2d { x = (long)location["x"], y = (long)location["y"] };

    /*
    Common.EffectOnWindow.VirtualKeyCode has the single constructor VirtualKeyCodeFromInt, so the
    generated encoding is {"VirtualKeyCodeFromInt":[code]}. The hand-written inner codec instead
    writes {"virtualKeyCode":code}; accept both so this keeps working after the envelope collapse.
    */
    static int VirtualKeyCodeFromJson(JObject key)
    {
        if (key.ContainsKey("VirtualKeyCodeFromInt"))
            return (int)UnwrapTag(key["VirtualKeyCodeFromInt"]);

        if (key.ContainsKey("virtualKeyCode"))
            return (int)key["virtualKeyCode"];

        throw new Exception("Unknown virtual key code: " + key.ToString());
    }

    /*
    The generated encoding array-wraps a tag argument, so a character, carrying no record of its
    own, arrives as {"TypeCharacter":[code]}; the hand-written inner codec would write the bare
    {"TypeCharacter":code}. Accept both, as above.
    */
    static int CharacterCodeFromJson(JToken typeCharacter) =>
        (int)UnwrapTag(typeCharacter);
}
