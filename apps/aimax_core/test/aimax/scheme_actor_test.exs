defmodule Aimax.SchemeActorTest do
  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  test "messages cannot contain live closures" do
    eval!("""
    (define *data-actor*
      (actor-spawn (lambda (state message) (list state message)) #f))
    """)

    assert {:error, message} =
             Session.eval("(actor-send! *data-actor* (lambda () #t))")

    assert message =~ "message cannot contain a closure"

    assert {:error, message} = Session.eval("(actor-send! *data-actor* +)")
    assert message =~ "message cannot contain an executable value"
    eval!("(actor-stop! *data-actor*)")
  end

  test "an isolated actor cannot export a raw closure to a host callback" do
    eval!("""
    (define *guarded-actor*
      (actor-spawn
        (lambda (state message)
          (list state (on-change! "unused" (lambda (p i d s) #t) 'eager)))
        #f))
    """)

    assert {:error, message} = Session.eval("(actor-call *guarded-actor* 'register)")
    assert message =~ "cannot export a closure through on-change!"
    eval!("(actor-stop! *guarded-actor*)")
  end
end
