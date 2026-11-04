defmodule Compos.SpreadsheetModeTest do
  @moduledoc "Spreadsheet mode uses the text backend and rebuilds its app view."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Compos.TestHelpers.one_window!()

    dir = Path.join(System.tmp_dir!(), "compos-sheet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "budget.sheet.json")

    on_exit(fn ->
      for buffer <- Compos.Core.list_buffers(), String.contains?(buffer, dir) do
        Compos.Core.kill_buffer(buffer)
      end

      File.rm_rf!(dir)
      Compos.TestHelpers.one_window!()
    end)

    %{path: path, dir: dir}
  end

  defp call!(name, args) do
    assert {:ok, value} = Session.call_named(name, args)
    value
  end

  test "opens a new JSON text workbook as a running app", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])

    assert File.exists?(path)
    assert Jason.decode!(File.read!(path))["version"] == 1
    assert Buffer.get_local(buffer, "mode-name") == "spreadsheet-mode"
    assert Buffer.get_local(buffer, "render-mode") == "app"
    page = Buffer.text(buffer)
    # the grid script is a file beside the package, served from the
    # buffer's app-directory; the page names it and carries the theme
    dir = Buffer.get_local(buffer, "app-directory")
    script = File.read!(Path.join(dir, "spreadsheet.js"))
    assert page =~ ~s(<script src="spreadsheet.js"></script>)
    refute page =~ "<script>"
    assert page =~ "@univerjs/presets@0.25.1"
    assert page =~ "@univerjs/preset-sheets-core@0.25.1"
    assert page =~ "@univerjs/preset-sheets-drawing@0.25.1"
    assert script =~ "UniverSheetsCorePreset"
    assert script =~ "UniverSheetsDrawingPreset"
    assert script =~ "api.registerComponent('ComposChart',ComposChart)"
    assert script =~ "var dark=document.documentElement.dataset.theme==='dark'"
    assert script =~ "create(Object.assign(dark?{darkMode:true}:{},{"
    assert script =~ "dark?'dark':null"
    assert script =~ "if(dark&&api.toggleDarkMode)api.toggleDarkMode(true)"
    assert {:ok, _} = Session.eval(~s{(load-theme "compos-dark")})
    assert Buffer.text(buffer) =~ ~s(<html data-theme="dark">)
    assert Buffer.text(buffer) =~ ~s(<meta name="color-scheme" content="dark">)
    assert Buffer.text(buffer) =~ "color-scheme:dark"
    refute Buffer.text(buffer) =~ "prefers-color-scheme"

    assert {:ok, _} = Session.eval(~s{(load-theme "paper")})
    assert Buffer.text(buffer) =~ ~s(<html data-theme="light">)
    assert Buffer.text(buffer) =~ ~s(<meta name="color-scheme" content="light">)
    assert Buffer.text(buffer) =~ "color-scheme:light"

    assert {:ok, _} = Session.eval(~s{(load-theme "compos-dark")})
    assert script =~ "addFloatDomToPosition"
    refute script =~ "addFloatDomToRange"
    assert script =~ "initialChartPosition"
    assert script =~ "getCellRect()"
    assert script =~ "allowTransform:true"
    assert script =~ "eventPassThrough:true"
    assert script =~ "initPosition:initialChartPosition(sheet,spec.anchor)"
    assert script =~ "api.Enum.DrawingType.DRAWING_CHART"
    assert script =~ "existing.type!==chartType"
    assert Buffer.text(buffer) =~ ".compos-chart>*{pointer-events:none}"
    refute script =~ "allowTransform:false"
    assert script =~ "getFloatDomById"
    assert script =~ "updateFloatDom"
    assert script =~ "getAllFloatDoms"
    assert script =~ "removeFloatDom"
    assert script =~ "getDisplayValues()"
    assert script =~ "ResizeObserver"
    assert script =~ "chartRefreshTimer=setTimeout"
    assert script =~ "api.Event.LifeCycleChanged"
    assert script =~ "api.Enum.LifecycleStages.Rendered"
    assert script =~ "markChartDrawn(spec.id)"
    assert Buffer.text(buffer) =~ ~s(id="app" tabindex="0")
    assert script =~ "univerSnapshot"
    assert script =~ "book.save()"
    assert script =~ "getRange('A1').activate()"
    assert script =~ "compos:'request-focus'"
    assert script =~ "book.setActiveSheet(sheets[wanted])"
    assert script =~ "var endpoint='_compos/app'"

    # the app bridge reaches the spreadsheet through the one door
    assert [200, _] = call!("app-request", [buffer, "GET", ""])

    stored = File.read!(path)
    assert :ok = KeyDispatch.handle_key("C-x")
    assert :ok = KeyDispatch.handle_key("C-s")
    assert Editor.snapshot().minibuffer == nil
    assert File.read!(path) == stored
  end

  test "running spreadsheet mode on the JSON source does not replace its data", %{path: path} do
    workbook = ~s({"version":1,"sheets":[{"name":"Safe","data":[["value"]]}]}\n)
    File.write!(path, workbook)

    assert {:ok, _} = Session.eval(~s{(visit "#{path}")})
    source = Editor.current_buffer()
    assert Buffer.text(source) == workbook

    Buffer.set_local(source, "render-mode", "app")
    Buffer.set_local(source, "preview-renderer", "html")

    assert {:ok, _} = Session.eval(~s{(set-mode! "spreadsheet-mode")})

    assert Editor.current_buffer() == source
    assert Buffer.get_local(source, "mode-name") == "json-mode"
    assert Buffer.get_local(source, "render-mode") in [nil, false]
    assert Buffer.get_local(source, "preview-renderer") in [nil, false]
    assert Buffer.text(source) == workbook
    assert File.read!(path) == workbook
  end

  test "save-buffer refuses HTML in a workbook source", %{path: path} do
    workbook = ~s({"version":1,"sheets":[{"name":"Safe","data":[["value"]]}]}\n)
    File.write!(path, workbook)
    assert {:ok, _} = Session.eval(~s{(visit "#{path}")})

    source = Editor.current_buffer()
    html = "<!doctype html><html><body>internal app</body></html>"
    Buffer.replace_range(source, 0, Buffer.byte_size(source), html)

    assert {:error, message} = Session.eval(~s{(run-command "save-buffer")})
    assert message =~ "Refusing to save spreadsheet app HTML"
    assert File.read!(path) == workbook
  end

  test "agents can persist charts embedded in sheet ranges", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])

    workbook = %{
      "version" => 1,
      "sheets" => [
        %{
          "name" => "Budget",
          "data" => [["Month", "Spend"], ["Jan", 10], ["Feb", 12]]
        }
      ]
    }

    assert [200, _] =
             call!("spreadsheet-app-request", [buffer, "write", Jason.encode!(workbook)])

    assert true ==
             call!("spreadsheet-add-chart!", [
               buffer,
               "Budget",
               "monthly-spend",
               "line",
               "A1:B3",
               "D2:K18",
               "Monthly spending"
             ])

    stored = Jason.decode!(File.read!(path))
    chart = get_in(stored, ["extensions", "compos", "charts", Access.at(0)])

    assert chart == %{
             "id" => "monthly-spend",
             "sheet" => "Budget",
             "type" => "line",
             "source" => "A1:B3",
             "anchor" => "D2:K18",
             "title" => "Monthly spending"
           }

    assert true == call!("spreadsheet-delete-chart!", [buffer, "monthly-spend"])
    assert get_in(Jason.decode!(File.read!(path)), ["extensions", "compos", "charts"]) == []
  end

  test "agents can create a chart without choosing its ID or anchor", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])

    workbook = %{
      "version" => 1,
      "sheets" => [%{"name" => "Budget", "data" => [["Month", "Spend"], ["Jan", 10]]}]
    }

    assert [200, _] =
             call!("spreadsheet-app-request", [buffer, "write", Jason.encode!(workbook)])

    assert true ==
             call!("spreadsheet-chart!", [buffer, "Budget", "A1:B2", "column", "Spend"])

    [chart_pairs] = call!("spreadsheet-charts", [buffer])

    chart =
      chart_pairs
      |> Enum.chunk_every(2)
      |> Map.new(fn [{:sym, key}, value] -> {key, value} end)

    assert chart["id"] == "chart-1"
    assert chart["anchor"] == "D1:K16"

    status =
      call!("spreadsheet-chart-status", [buffer])
      |> Enum.chunk_every(2)
      |> Map.new(fn [{:sym, key}, value] -> {key, value} end)

    assert status["configured"] == ["chart-1"]
    assert status["state"] == "loading"
    assert status["mounted"] == []
    assert status["drawn"] == []
  end

  test "writes formulas through the backend and rejects invalid workbooks", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])

    workbook = %{
      "version" => 1,
      "univerSnapshot" => %{"styles" => %{}, "resources" => []},
      "sheets" => [
        %{
          "name" => "Budget",
          "data" => [["Total", "=SUM(B2:B3)"], ["Tea", 2], ["Coffee", 3]]
        }
      ]
    }

    assert [200, _] =
             call!("spreadsheet-app-request", [buffer, "write", Jason.encode!(workbook)])

    stored = Jason.decode!(File.read!(path))
    assert stored["univerSnapshot"]["styles"] == %{}

    assert get_in(stored, ["sheets", Access.at(0), "data", Access.at(0), Access.at(1)]) ==
             "=SUM(B2:B3)"

    original = File.read!(path)
    assert [400, error] = call!("spreadsheet-app-request", [buffer, "write", ~s({"bad":true})])
    assert error =~ "not valid"
    assert File.read!(path) == original
  end

  test "agents can read and write a workbook by buffer name without displaying it", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])
    generation = Buffer.get_local(buffer, "app-generation")

    workbook = %{
      "version" => 1,
      "activeSheet" => 0,
      "univerSnapshot" => %{
        "id" => "agent-book",
        "sheetOrder" => ["agent-sheet"],
        "sheets" => %{
          "agent-sheet" => %{
            "id" => "agent-sheet",
            "cellData" => %{"0" => %{"0" => %{"v" => "Task"}}}
          }
        }
      },
      "sheets" => [%{"name" => "Agent data", "data" => [["Task", "Done"], ["QA", true]]}]
    }

    buffer_literal = Jason.encode!(buffer)
    workbook_literal = workbook |> Jason.encode!() |> Jason.encode!()

    assert {:ok, "#t"} =
             Session.eval(
               "(spreadsheet-write! #{buffer_literal} (json-parse #{workbook_literal}))"
             )

    assert Buffer.get_local(buffer, "app-generation") == generation + 1

    assert {:ok, encoded} =
             Session.eval("(json-encode (spreadsheet-read #{buffer_literal}) #t)")

    assert encoded |> Jason.decode!() |> Jason.decode!() == workbook

    assert ["Agent data"] == call!("spreadsheet-sheet-names", [buffer])
    assert true == call!("spreadsheet-set-cell!", [buffer, 1, "B2", "=COUNTIF(B1:B1,\"Done\")"])
    assert "=COUNTIF(B1:B1,\"Done\")" == call!("spreadsheet-read-cell", [buffer, 1, "B2"])

    stored = Jason.decode!(File.read!(path))
    assert stored["activeSheet"] == 0
    assert stored["univerSnapshot"] == workbook["univerSnapshot"]

    assert get_in(stored, ["sheets", Access.at(0), "data", Access.at(1), Access.at(1)]) ==
             "=COUNTIF(B1:B1,\"Done\")"
  end

  test "the mode setup rebuilds the app and its reload command works through key dispatch", %{
    path: path
  } do
    buffer = call!("spreadsheet-open!", [path])
    Buffer.replace_range(buffer, 0, Buffer.byte_size(buffer), "stale")
    Buffer.set_local(buffer, "render-mode", false)

    assert {:ok, _} = Session.eval(~s{(set-mode! "spreadsheet-mode")})
    assert Buffer.text(buffer) =~ ~s(<script src="spreadsheet.js"></script>)
    assert Buffer.get_local(buffer, "render-mode") == "app"

    generation = Buffer.get_local(buffer, "app-generation")
    assert :ok = KeyDispatch.handle_key("g")
    assert Buffer.get_local(buffer, "app-generation") == generation + 1
  end
end
