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
    assert Buffer.text(buffer) =~ "jspreadsheet-ce@5.0.4"
    assert Buffer.text(buffer) =~ "_aimax/spreadsheet"
  end

  test "writes formulas through the backend and rejects invalid workbooks", %{path: path} do
    buffer = call!("spreadsheet-open!", [path])

    workbook = %{
      "version" => 1,
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
    assert get_in(stored, ["sheets", Access.at(0), "data", Access.at(0), Access.at(1)]) ==
             "=SUM(B2:B3)"

    original = File.read!(path)
    assert [400, error] = call!("spreadsheet-app-request", [buffer, "write", ~s({"bad":true})])
    assert error =~ "not valid"
    assert File.read!(path) == original
  end

  test "the mode setup rebuilds the app and its reload command works through key dispatch", %{
    path: path
  } do
    buffer = call!("spreadsheet-open!", [path])
    Buffer.replace_range(buffer, 0, Buffer.byte_size(buffer), "stale")
    Buffer.set_local(buffer, "render-mode", false)

    assert {:ok, _} = Session.eval(~s{(set-mode! "spreadsheet-mode")})
    assert Buffer.text(buffer) =~ "jspreadsheet"
    assert Buffer.get_local(buffer, "render-mode") == "app"

    generation = Buffer.get_local(buffer, "app-generation")
    assert :ok = KeyDispatch.handle_key("g")
    assert Buffer.get_local(buffer, "app-generation") == generation + 1
  end
end
