defmodule Aimax.KeysTest do
  @moduledoc """
  The key chain is Scheme (packages/keys.scm). Elixir asks for a key by
  name and holds no idea where one lives — these tests drive the chain the
  way every caller does, through the session.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  setup do
    eval!("(key-forget-all!)")

    on_exit(fn ->
      System.delete_env("ZZ_KEYS_TEST")
      File.rm(Path.join(Aimax.Core.home(), "zz_keys_file-key"))
      eval!("(key-forget-all!)")
    end)

    :ok
  end

  test "the environment answers first" do
    System.put_env("ZZ_KEYS_TEST", "from-env")
    assert eval!(~s{(key-get "ZZ_KEYS_TEST")}) == ~s("from-env")
  end

  test "an empty environment variable is not an answer" do
    System.put_env("ZZ_KEYS_TEST", "")
    assert eval!(~s{(getenv "ZZ_KEYS_TEST")}) == "#f"
  end

  test "a file under ~/.aimax answers when the environment does not" do
    File.write!(Path.join(Aimax.Core.home(), "zz_keys_file-key"), "from-file\n")
    assert eval!(~s{(key-get "ZZ_KEYS_FILE")}) == ~s("from-file")
  end

  test "an _API_KEY name maps to the short file name" do
    assert eval!(~s{(key--file-name "GOOGLE_API_KEY")}) == ~s("google")
    assert eval!(~s{(key--file-name "MXROUTE_PASSWORD")}) == ~s("mxroute_password")
  end

  test "a miss is #f, and the miss caches so doppler runs once" do
    assert eval!(~s{(key-get "ZZ_KEYS_ABSENT")}) == "#f"
    assert eval!(~s{(member "ZZ_KEYS_ABSENT" (key-cached-names))}) != "#f"
  end

  test "key-forget! drops one name and the next lookup reads again" do
    System.put_env("ZZ_KEYS_TEST", "first")
    assert eval!(~s{(key-get "ZZ_KEYS_TEST")}) == ~s("first")

    System.put_env("ZZ_KEYS_TEST", "second")
    assert eval!(~s{(key-get "ZZ_KEYS_TEST")}) == ~s("first")

    eval!(~s{(key-forget! "ZZ_KEYS_TEST")})
    assert eval!(~s{(key-get "ZZ_KEYS_TEST")}) == ~s("second")
  end

  test "key-cached-names reports names and never values" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")
    eval!(~s{(key-get "ZZ_KEYS_TEST")})
    out = eval!("(key-cached-names)")

    assert out =~ "ZZ_KEYS_TEST"
    refute out =~ "sekrit"
  end

  test "key-resolve turns a @VAR reference into the key, and leaves the rest" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")
    assert eval!(~s{(key-resolve "@ZZ_KEYS_TEST")}) == ~s("sekrit")
    assert eval!(~s{(key-resolve "plain")}) == ~s("plain")
    # an unresolvable reference becomes "" — never the literal "@VAR"
    assert eval!(~s{(key-resolve "@ZZ_KEYS_ABSENT")}) == ~s("")
  end

  test "a list of parts joins after each part resolves" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")
    assert eval!(~s{(key-resolve '("Bearer " "@ZZ_KEYS_TEST"))}) == ~s("Bearer sekrit")
  end

  test "an MCP spec resolves its env, headers and url" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")

    assert eval!(~s{(mcp-resolve-spec '(command "npx" env (K "@ZZ_KEYS_TEST" J "plain")))}) ==
             ~s[(command "npx" env (K "sekrit" J "plain"))]

    # a whole-value reference in the url, the form a server that takes its
    # key as a query parameter needs
    assert eval!(~s{(mcp-resolve-spec '(url "@ZZ_KEYS_TEST" headers (x-api-key "@ZZ_KEYS_TEST")))}) ==
             ~s[(url "sekrit" headers (x-api-key "sekrit"))]

    # ...and the composed form, which is what a query parameter really looks like
    assert eval!(~s{(mcp-resolve-spec '(url ("https://h/mcp?k=" "@ZZ_KEYS_TEST")))}) ==
             ~s[(url "https://h/mcp?k=sekrit")]

    # args are not a reference site: "@adenot/mcp-google-search" is a package
    assert eval!(~s{(mcp-resolve-spec '(args ("-y" "@ZZ_KEYS_TEST")))}) ==
             ~s[(args ("-y" "@ZZ_KEYS_TEST"))]
  end

  test "a url shows without its query string, wherever it is displayed" do
    assert eval!(~s{(mcp-url-shown "https://h/mcp?exaApiKey=sekrit")}) == ~s("https://h/mcp?…")
    assert eval!(~s{(mcp-url-shown "https://h/mcp")}) == ~s("https://h/mcp")
  end

  test "the ACP entry carries the resolved url, the surface line does not" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")

    eval!(~s{(mcp-register! 'zz-keys-acp '(url ("https://h/mcp?k=" "@ZZ_KEYS_TEST")))})
    entry = eval!(~s{(mcp-acp-server 'zz-keys-acp)})
    line = eval!(~s{(mcp-acp-surface-line (mcp-acp-server 'zz-keys-acp))})

    assert entry =~ "sekrit"
    refute line =~ "sekrit"
    assert line =~ "https://h/mcp?…"
  end

  test "the registry keeps the reference; only the resolved copy holds the key" do
    System.put_env("ZZ_KEYS_TEST", "sekrit")

    eval!(~s{(mcp-register! 'zz-keys '(url "https://h/mcp" headers (a "@ZZ_KEYS_TEST")))})
    out = eval!(~s{(assoc 'zz-keys *mcp-registry*)})

    assert out =~ "@ZZ_KEYS_TEST"
    refute out =~ "sekrit"
  end
end
