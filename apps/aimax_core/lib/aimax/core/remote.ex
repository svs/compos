defmodule Aimax.Core.Remote do
  @moduledoc """
  ssh file transport — mechanism only. Path syntax (`/ssh:host:/file`), what a
  remote buffer is, and when to fetch are Scheme (`priv/editor.scm`).

  Shells out to the system `ssh` binary so `~/.ssh/config` (aliases, keys,
  agent, ControlMaster, ProxyJump) applies unchanged. BatchMode: the daemon
  has no tty to prompt on — auth must come from keys/agent.
  """

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]

  # tests point :ssh_cmd at a fake that executes the remote command locally
  def ssh, do: Application.get_env(:aimax_core, :ssh_cmd, "ssh")

  @doc "Fetch a remote file: {:ok, text} | :directory | :absent (new file) | {:error, msg}"
  def read(host, path) do
    q = sh_quote(path)
    # exit 43: a directory (open dired); exit 44: no such file (open an
    # empty buffer, like Emacs); other failures (permissions) are errors
    cmd = "if [ -d #{q} ]; then exit 43; fi; test -e #{q} || exit 44; cat -- #{q}"

    case System.cmd(ssh(), @ssh_opts ++ [host, cmd]) do
      {out, 0} -> {:ok, out}
      {_, 43} -> :directory
      {_, 44} -> :absent
      {_, 255} -> {:error, "cannot reach #{host}"}
      {_, n} -> {:error, "read failed on #{host} (exit #{n})"}
    end
  rescue
    e in [ErlangError] -> {:error, "ssh spawn failed: #{Exception.message(e)}"}
  end

  @doc """
  List a remote directory in one round-trip:
  {:ok, [[name, [perms, size, date]], ...]} | {:error, msg}.
  Directory names carry a trailing "/" (the list-dir convention).
  """
  def list_dir(host, dir) do
    case System.cmd(ssh(), @ssh_opts ++ [host, "LC_ALL=C ls -lA -- #{sh_quote(dir)}"]) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.flat_map(&ls_entry/1)}
      {_, 255} -> {:error, "cannot reach #{host}"}
      {_, n} -> {:error, "ls failed on #{host} (exit #{n})"}
    end
  rescue
    e in [ErlangError] -> {:error, "ssh spawn failed: #{Exception.message(e)}"}
  end

  @doc "Run a command on the remote host: :ok | {:error, msg}"
  def sh(host, cmd) do
    case System.cmd(ssh(), @ssh_opts ++ [host, cmd], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, 255} -> {:error, "cannot reach #{host}"}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in [ErlangError] -> {:error, "ssh spawn failed: #{Exception.message(e)}"}
  end

  # "drwxr-xr-x 2 svs staff 64 Aug 7 10:00 logs" -> [["logs/", [perms, size, date]]]
  # ("total N" and unparseable lines drop out)
  defp ls_entry(line) do
    case String.split(line, ~r/\s+/, parts: 9) do
      [perms, _links, _owner, _group, size, mon, day, tim, name] when byte_size(perms) >= 10 ->
        name = name |> String.split(" -> ") |> hd()
        name = if String.starts_with?(perms, "d"), do: name <> "/", else: name
        [[name, [perms, size, "#{mon} #{day} #{tim}"]]]

      _ ->
        []
    end
  end

  @doc "Write text to a remote file: :ok | {:error, msg}"
  def write(host, path, text) do
    # System.cmd can't feed stdin: stage the text in a temp file and let the
    # local shell pipe it into `ssh host "cat > path"`
    tmp = Path.join(System.tmp_dir!(), "aimax-remote-#{System.unique_integer([:positive])}")
    File.write!(tmp, text)

    remote = sh_quote("cat > #{sh_quote(path)}")
    local = Enum.join([sh_quote(ssh())] ++ @ssh_opts ++ [sh_quote(host), remote], " ")

    try do
      case System.shell("#{local} < #{sh_quote(tmp)}", stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, 255} -> {:error, "cannot reach #{host}"}
        {out, _} -> {:error, String.trim(out)}
      end
    after
      File.rm(tmp)
    end
  end

  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
