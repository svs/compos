defmodule Aimax.SpreadsheetModeTest do
  @moduledoc "Spreadsheet mode uses the text backend and rebuilds its app view."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    dir = Path.join(System.tmp_dir!(), "aimax-sheet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "budget.sheet.json")

    on_exit(fn ->
      for buffer <- Aimax.Core.list_buffers(), String.contains?(buffer, dir) do
        Aimax.Core.kill_buffer(buffer)
      end

      File.rm_rf!(dir)
      Editor.delete_other_windows()
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
    assert Buffer.text(buffer) =~ "@univerjs/presets@0.25.1"
    assert Buffer.text(buffer) =~ "@univerjs/preset-sheets-core@0.25.1"
    assert Buffer.text(buffer) =~ "@univerjs/preset-sheets-drawing@0.25.1"
    assert Buffer.text(buffer) =~ "UniverSheetsCorePreset"
    assert Buffer.text(buffer) =~ "UniverSheetsDrawingPreset"
    assert Buffer.text(buffer) =~ "api.registerComponent('AimaxChart',AimaxChart)"
    assert Buffer.text(buffer) =~ "addFloatDomToPosition"
    refute Buffer.text(buffer) =~ "addFloatDomToRange"
    assert Buffer.text(buffer) =~ "initialChartPosition"
    assert Buffer.text(buffer) =~ "getCellRect()"
    assert Buffer.text(buffer) =~ "allowTransform:true"
    assert Buffer.text(buffer) =~ "eventPassThrough:true"
    assert Buffer.text(buffer) =~ "initPosition:initialChartPosition(sheet,spec.anchor)"
    assert Buffer.text(buffer) =~ "api.Enum.DrawingType.DRAWING_CHART"
    assert Buffer.text(buffer) =~ "existing.type!==chartType"
    assert Buffer.text(buffer) =~ ".aimax-chart>*{pointer-events:none}"
    refute Buffer.text(buffer) =~ "allowTransform:false"
    assert Buffer.text(buffer) =~ "getFloatDomById"
    assert Buffer.text(buffer) =~ "updateFloatDom"
    assert Buffer.text(buffer) =~ "getAllFloatDoms"
    assert Buffer.text(buffer) =~ "removeFloatDom"
    assert Buffer.text(buffer) =~ "getDisplayValues()"
    assert Buffer.text(buffer) =~ "ResizeObserver"
    assert Buffer.text(buffer) =~ "chartRefreshTimer=setTimeout"
    assert Buffer.text(buffer) =~ "api.Event.LifeCycleChanged"
    assert Buffer.text(buffer) =~ "api.Enum.LifecycleStages.Rendered"
    assert Buffer.text(buffer) =~ "markChartDrawn(spec.id)"
    assert Buffer.text(buffer) =~ ~s(id="app" tabindex="0")
    assert Buffer.text(buffer) =~ "univerSnapshot"
    assert Buffer.text(buffer) =~ "book.save()"
    assert Buffer.text(buffer) =~ "getRange('A1').activate()"
    assert Buffer.text(buffer) =~ "aimax:'request-focus'"
    assert Buffer.text(buffer) =~ "book.setActiveSheet(sheets[wanted])"
    assert Buffer.text(buffer) =~ "_aimax/spreadsheet"
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
    chart = get_in(stored, ["extensions", "aimax", "charts", Access.at(0)])

    assert chart == %{
             "id" => "monthly-spend",
             "sheet" => "Budget",
             "type" => "line",
             "source" => "A1:B3",
             "anchor" => "D2:K18",
             "title" => "Monthly spending"
           }

    assert true == call!("spreadsheet-delete-chart!", [buffer, "monthly-spend"])
    assert get_in(Jason.decode!(File.read!(path)), ["extensions", "aimax", "charts"]) == []
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
    assert Buffer.text(buffer) =~ "UniverSheetsCorePreset"
    assert Buffer.get_local(buffer, "render-mode") == "app"

    generation = Buffer.get_local(buffer, "app-generation")
    assert :ok = KeyDispatch.handle_key("g")
    assert Buffer.get_local(buffer, "app-generation") == generation + 1
  end
end
