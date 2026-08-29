defmodule Compos.WebServerTest do
  use ExUnit.Case, async: false

  alias Compos.Core.{Session, WebServer}

  defp eval!(source) do
    case Session.eval(source) do
      {:ok, value} -> value
      {:error, message} -> flunk(message)
    end
  end

  defp start_server(name, handler, spec \\ "'(port 0)") do
    eval!("(web-server-start! \"#{name}\" #{spec} #{handler})")
    detail = WebServer.detail(name)
    on_exit(fn -> WebServer.stop(name) end)
    detail
  end

  test "a Scheme handler routes and builds the HTTP response" do
    detail =
      start_server(
        "callback-route",
        """
        (lambda (request)
          (if (and (equal? (plist-get request 'method) "POST")
                   (equal? (plist-get request 'path) "/hooks/done")
                   (equal? (plist-get request 'query) "job=42"))
              (list 'status 202
                    'headers '(("content-type" "application/json") ("x-agent" "yes"))
                    'body (string-append "{\\\"received\\\":"
                                         (number->string (string-length (plist-get request 'body)))
                                         "}"))
              (list 'status 404 'body "missing")))
        """
      )

    response =
      Req.post!(detail.url <> "/hooks/done?job=42",
        body: "payload",
        headers: [{"content-type", "text/plain"}]
      )

    assert response.status == 202
    assert response.headers["x-agent"] == ["yes"]
    assert response.body == %{"received" => 7}
  end

  test "servers use distinct ephemeral ports and stop independently" do
    first = start_server("callback-first", ~s{(lambda (request) "first")})
    second = start_server("callback-second", ~s{(lambda (request) "second")})

    assert first.port != second.port
    assert Req.get!(first.url).body == "first"
    assert Req.get!(second.url).body == "second"

    assert :ok = WebServer.stop("callback-first")
    assert WebServer.detail("callback-first") == nil
    assert Req.get!(second.url).body == "second"
  end

  test "a server enforces its configurable body limit before Scheme runs" do
    detail =
      start_server(
        "callback-limit",
        ~s{(lambda (request) (list 'status 200 'body "handler ran"))},
        "'(port 0 max-body 4)"
      )

    response = Req.post!(detail.url, body: "12345")
    assert response.status == 413
    assert response.body == "request body is too large"
  end

  test "duplicate names fail without replacing the running handler" do
    detail = start_server("callback-duplicate", ~s{(lambda (request) "original")})

    assert {:error, message} =
             Session.eval(
               ~s{(web-server-start! "callback-duplicate" '(port 0) (lambda (request) "new"))}
             )

    assert message =~ "already exists"
    assert Req.get!(detail.url).body == "original"
  end
end
