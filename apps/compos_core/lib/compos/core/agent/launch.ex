defmodule Compos.Core.Agent.Launch do
  @moduledoc """
  What an adapter command really runs. A connector names its adapter the
  way a shell would (`claude-agent-acp`, `npx -y @scope/pkg`), and each
  layer between that name and the program is a process of its own at every
  start: npx resolves and wraps the package, a version-manager shim (asdf,
  mise) runs bash and the manager to pick a version, and a `#!/usr/bin/env
  node` script goes through the node shim once more. This resolves the
  chain once and launches the installed program directly:

    1. `npx [flags] PKG args` becomes `BIN args` when PKG's bin is already
       installed on PATH; else npx stays, it is the only way to reach it.
    2. A shim resolves to the real program through its manager's `which`.
    3. A node script runs as `NODE SCRIPT args`, NODE being the node beside
       it (the install it was installed into), else node resolved the same
       way.

  Answers are cached per (command, cwd) and dropped when the program they
  name is gone (a version upgrade).
  """

  @doc "The executable path and argv CMD runs in CWD: {exe, args}. Raises when nothing runs it."
  def resolve(cmd, cwd \\ nil) do
    key = {__MODULE__, cmd, cwd}

    case :persistent_term.get(key, nil) do
      {exe, _args} = hit when is_binary(exe) ->
        if File.exists?(exe), do: hit, else: fresh(key, cmd, cwd)

      _ ->
        fresh(key, cmd, cwd)
    end
  end

  defp fresh(key, cmd, cwd) do
    answer = cmd |> String.split(" ", trim: true) |> unwrap_npx() |> direct(cwd)
    :persistent_term.put(key, answer)
    answer
  end

  @doc "npx PKG ARGS -> BIN ARGS when the package's bin is installed; other argv unchanged."
  def unwrap_npx(["npx" | rest] = argv) do
    case Enum.drop_while(rest, &npx_flag?/1) do
      [pkg | args] ->
        bin = bin_name(pkg)
        if System.find_executable(bin), do: [bin | args], else: argv

      [] ->
        argv
    end
  end

  def unwrap_npx(argv), do: argv

  defp npx_flag?(arg), do: arg in ["-y", "--yes", "-q", "--quiet", "--prefer-offline"]

  # @scope/name@1.2 -> name; name@latest -> name
  defp bin_name(pkg) do
    pkg
    |> String.replace(~r/(?<!^)@[^\/]*$/, "")
    |> String.split("/")
    |> List.last()
  end

  defp direct([exe | args], cwd) do
    path = System.find_executable(exe) || raise "agent adapter not found: #{exe}"
    real = unshim(path, Path.basename(exe), cwd)

    case node_script(real) do
      {:node, extra} ->
        node = node_beside(real) || unshim_exe("node", cwd)
        if node, do: {node, extra ++ [real | args]}, else: {real, args}

      :no ->
        {real, args}
    end
  end

  # a version manager's shim: ask the manager which program it would run
  defp unshim(path, name, cwd) do
    with manager when not is_nil(manager) <- shim_manager(path),
         bin when not is_nil(bin) <- System.find_executable(manager),
         {out, 0} <- System.cmd(bin, ["which", name], cmd_opts(cwd)),
         real = String.trim(out),
         true <- real != "" and File.exists?(real) do
      real
    else
      _ -> path
    end
  end

  defp unshim_exe(name, cwd) do
    case System.find_executable(name) do
      nil -> nil
      path -> unshim(path, name, cwd)
    end
  end

  defp cmd_opts(nil), do: [stderr_to_stdout: false]

  defp cmd_opts(cwd) do
    if File.dir?(cwd), do: [cd: cwd], else: []
  end

  @doc "The version manager whose shim PATH is, or nil."
  def shim_manager(path) do
    cond do
      String.contains?(path, "/.asdf/shims/") -> "asdf"
      String.contains?(path, "/mise/shims/") -> "mise"
      true -> nil
    end
  end

  @doc "{:node, extra-args} when FILE is a node script by its shebang, else :no."
  def node_script(file) do
    with {:ok, io} <- File.open(file, [:read, :binary]),
         head = IO.binread(io, 256),
         :ok <- File.close(io),
         true <- is_binary(head),
         "#!" <> line <- head |> String.split("\n", parts: 2) |> hd() do
      case String.split(line, ~r/\s+/, trim: true) do
        [env, "node" | extra] -> if Path.basename(env) == "env", do: {:node, extra}, else: :no
        [env, "-S", "node" | extra] -> if Path.basename(env) == "env", do: {:node, extra}, else: :no
        [interp | extra] -> if Path.basename(interp) == "node", do: {:node, extra}, else: :no
        _ -> :no
      end
    else
      _ -> :no
    end
  end

  # npm installs a package's bin beside the node that installed it; a
  # symlinked bin's own directory is the install's bin directory
  defp node_beside(file) do
    node = Path.join(Path.dirname(file), "node")
    if File.regular?(node) and shim_manager(node) == nil, do: node, else: nil
  end
end
