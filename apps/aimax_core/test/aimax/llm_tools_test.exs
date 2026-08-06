defmodule Aimax.LLMToolsTest do
  @moduledoc "define-tool! registry + the gptel-style native tool_use loop."

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp stub_chat(fun) do
    Application.put_env(:aimax_core, :llm_chat_fun, fun)
    on_exit(fn -> Application.delete_env(:aimax_core, :llm_chat_fun) end)
  end

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn m ->
      is_list(m.content) and Enum.any?(m.content, &(is_map(&1) and &1[:type] == "tool_result"))
    end)
  end

  describe "registry" do
    test "define-tool! + llm-tool-call round trip" do
      eval!("""
      (define-tool! 'zz-echo "Echo a value." (list (list 'v "string" "value"))
        (lambda (args) (string-append "echo:" (custom--plist-get args 'v))))
      """)

      assert eval!(~s{(llm-tool-call "zz-echo" (list 'v "hi"))}) == ~s{"echo:hi"}
    end

    test "unknown tool reports instead of crashing" do
      assert eval!(~s{(llm-tool-call "no-such" '())}) == ~s{"no such tool: no-such"}
    end

    test "specs include the built-in toolbox" do
      specs = eval!("(map car (llm-tool-specs))")
      for t <- ~w(eval-scheme apropos-api describe-variables customize-save customize-save-face list-themes load-theme) do
        assert specs =~ t
      end
    end

    test "apropos-api finds globals and commands by regex" do
      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "buffer-append"))})
      assert out =~ "buffer-append!"

      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "^chat"))})
      assert out =~ "chat-send"

      # the system skill warns the model off elisp and teaches the core API
      assert eval!("*llm-system*") =~ "NOT Emacs Lisp"
      assert eval!("*llm-system*") =~ "buffer-append!"
    end
  end

  describe "tool loop" do
    test "dispatches tool_use, feeds results back, delivers final text" do
      me = self()

      stub_chat(fn %{messages: messages, tools: tools, system: system} ->
        send(me, {:chat, messages, tools, system})

        if has_tool_result?(messages) do
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "Org font is now ToolFont."}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_1",
                 "name" => "customize-save",
                 "input" => %{"name" => "org-font-family", "value" => ~s{"ToolFont"}}
               }
             ]
           }}
        end
      end)

      eval!(~s{(llm-with-tools "change my org font to ToolFont"
                 (lambda (t) (set-symbol-value! 'zz-reply t)))})

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-reply)")) end)

      assert eval!("zz-reply") == ~s{"Org font is now ToolFont."}
      assert eval!("org-font-family") == ~s{"ToolFont"}
      assert File.read!(Path.join(Aimax.Core.home(), "custom.scm")) =~
               ~s{'(org-font-family "ToolFont")}

      # the request carried the registry as JSON tool defs + the system skill
      assert_received {:chat, _, tools, system}
      save = Enum.find(tools, &(&1.name == "customize-save"))
      assert save.input_schema.properties["name"].type == "string"
      assert "value" in save.input_schema.required
      assert system =~ "ai-max"

      # round 2 saw the tool_result
      assert_received {:chat, messages2, _, _}
      assert has_tool_result?(messages2)
    end

    test "a failing tool handler becomes an error result, loop survives" do
      stub_chat(fn %{messages: messages} ->
        if has_tool_result?(messages) do
          [%{content: results} | _] = Enum.reverse(messages)
          [%{content: err} | _] = results
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "tool said: #{err}"}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_err",
                 "name" => "eval-scheme",
                 "input" => %{"code" => "(this-does-not-exist)"}
               }
             ]
           }}
        end
      end)

      eval!(~s{(llm-with-tools "break something"
                 (lambda (t) (set-symbol-value! 'zz-err-reply t)))})

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-err-reply)")) end)
      assert eval!("zz-err-reply") =~ "error:"
    end

    test "runaway tool loop is cut off" do
      stub_chat(fn _ ->
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [
             %{"type" => "tool_use", "id" => "tu_n", "name" => "list-themes", "input" => %{}}
           ]
         }}
      end)

      eval!(~s{(llm-with-tools "loop forever" (lambda (t) (set-symbol-value! 'zz-runaway t)))})

      # error lands in *messages*, callback never fires
      wait_until(fn ->
        {:ok, text} = Session.eval(~s{(buffer-text "*messages*")})
        text =~ "exceeded"
      end)

      assert {:ok, "#f"} = Session.eval("(boundp 'zz-runaway)")
    end
  end
end
