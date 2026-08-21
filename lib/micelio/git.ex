defmodule Micelio.Git do
  @moduledoc """
  Every interaction with the `git` binary.

  Micelio deliberately does not reimplement Git. Object storage, delta
  compression, connectivity checking, reachability, the wire protocol and every
  optimisation the Git project has accumulated over twenty years come for free
  by running the same client everyone else runs. What Micelio owns is *where
  the bytes live and in what order*; Git owns what they mean.

  ## Process supervision

  A Git server's characteristic failure is orphaned processes: an `upload-pack`
  serving a large monorepo runs for minutes, and if the client vanishes or the
  handler dies, a stranded process keeps holding CPU and file descriptors.

  Three shapes of invocation exist here, supervised differently, and the
  differences are forced rather than chosen:

    * `run/3` runs plumbing whose output we need. It uses `System.cmd/3`,
      wrapped in `isolated/2` so that no port failure can kill the caller.

    * `run_supervised/3` runs long, expensive commands whose output we do not
      need — `repack` above all. These go through MuonTrap, which ties the OS
      process to the owning Erlang process and, on Linux, can confine it to a
      cgroup. This is where that protection is worth having: a repack can run
      for minutes and saturate a core, and it is the invocation most likely to
      be interrupted halfway.

    * `stream/3` runs the protocol endpoints, which need a live bidirectional
      pipe. `terminate/1` reproduces the part of MuonTrap's guarantee that
      matters here by signalling the process on abort.

  ### Why MuonTrap is not used everywhere

  It cannot be, in either direction.

  For the protocol endpoints it is unusable: without `--capture-output` its
  wrapper sends the child's stdout to `/dev/null`, and it consumes its own
  stdin as a flow-control channel instead of forwarding it, so there is no way
  to both write a request and read a response.

  For commands whose output we need it is unsafe on Linux. `MuonTrap.cmd/3`
  acknowledges consumed bytes by writing back to the port, and when the child
  has already exited that write fails. MuonTrap guards it with `rescue`, which
  catches the `ArgumentError` case but not the `:epipe` case — and `:epipe`
  arrives as an exit signal, which no `try/catch` in the calling process can
  stop. In a container this is not a rare race but the normal outcome: a
  measured thirty out of thirty `git --version` invocations took the caller
  down with them. The same call producing no output is completely reliable,
  which is exactly the shape `run_supervised/3` is restricted to.

  Every invocation runs with system and global configuration disabled, so a
  node behaves identically regardless of what is in the operator's
  `~/.gitconfig`.
  """

  require Logger

  alias Micelio.WAL.Entry
  alias Micelio.Wal.V1

  @type path :: Path.t()
  @type oid :: String.t()

  @doc "Absolute path to the `git` binary this node will use."
  @spec executable() :: String.t()
  def executable do
    Application.get_env(:micelio, :git_executable) || System.find_executable("git") ||
      raise "git executable not found in PATH"
  end

  @doc "Version string reported by the `git` binary, e.g. `\"2.47.0\"`."
  @spec version() :: {:ok, String.t()} | {:error, term()}
  def version do
    with {:ok, out} <- run(nil, ["--version"]) do
      case Regex.run(~r/git version ([0-9][^\s]*)/, out) do
        [_, version] -> {:ok, version}
        nil -> {:error, {:unrecognised_version, out}}
      end
    end
  end

  @doc """
  Create a bare repository configured the way Micelio needs it.

  Three settings carry real weight:

    * `receive.unpackLimit = 1` keeps every push as a packfile instead of
      exploding small pushes into loose objects. The log records packs, so this
      makes the on-disk artefact and the logged artefact the same bytes.
    * `gc.auto = 0` disables Git's own background maintenance. Compaction is a
      log event every replica follows, so it must happen when we say it does,
      not when some fetch trips a heuristic and silently rewrites packs that
      the log still refers to.
    * `uploadpack.allowFilter` enables partial clone, which is how a client
      fetches a slice of a large monorepo instead of its entire history.
  """
  @spec init_bare(path(), keyword()) :: :ok | {:error, term()}
  def init_bare(path, opts \\ []) do
    head = Keyword.get(opts, :head, "refs/heads/main")
    File.mkdir_p!(path)

    settings = [
      {"receive.unpackLimit", "1"},
      {"receive.denyDeletes", "false"},
      {"receive.denyNonFastForwards", "false"},
      {"receive.denyCurrentBranch", "ignore"},
      {"gc.auto", "0"},
      {"maintenance.auto", "false"},
      {"core.logAllRefUpdates", "true"},
      {"repack.writeBitmaps", "true"},
      {"uploadpack.allowFilter", "true"},
      # Private forge state shares this object database with source code, but
      # it is not part of the Git transport. Do not advertise it, accept an
      # update to it, or allow an object id to bypass the hidden reference.
      {"uploadpack.allowAnySHA1InWant", "false"},
      {"transfer.hideRefs", "refs/micelio"},
      {"uploadpack.hideRefs", "refs/micelio"},
      {"receive.hideRefs", "refs/micelio"}
    ]

    with {:ok, _} <- run(nil, ["init", "--bare", "--quiet", path]),
         :ok <- Enum.reduce_while(settings, :ok, &apply_setting(path, &1, &2)) do
      set_head(path, head)
    end
  end

  defp apply_setting(path, {key, value}, _acc) do
    case config(path, key, value) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @spec config(path(), String.t(), String.t()) :: :ok | {:error, term()}
  def config(path, key, value) do
    with {:ok, _} <- run(path, ["config", key, value]), do: :ok
  end

  @doc "Point `HEAD` at a branch, whether or not that branch exists yet."
  @spec set_head(path(), String.t()) :: :ok | {:error, term()}
  def set_head(path, ref) do
    with {:ok, _} <- run(path, ["symbolic-ref", "HEAD", ref]), do: :ok
  end

  @spec head(path()) :: {:ok, String.t()} | {:error, term()}
  def head(path) do
    with {:ok, out} <- run(path, ["symbolic-ref", "HEAD"]), do: {:ok, String.trim(out)}
  end

  @doc "Every ref in the repository as a `ref => oid` map."
  @spec refs(path()) :: {:ok, %{optional(String.t()) => oid()}} | {:error, term()}
  def refs(path) do
    with {:ok, out} <- run(path, ["for-each-ref", "--format=%(refname) %(objectname)"]) do
      refs =
        out
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [ref, oid] = String.split(line, " ", parts: 2)
          {ref, oid}
        end)

      {:ok, refs}
    end
  end

  @doc """
  Apply a batch of ref updates in a single Git transaction.

  When `check_old?` is false the update is applied without asserting the
  previous value. That is what replay wants: the log is the source of truth and
  its order is already settled, so a replica should converge on it rather than
  argue with it. The check matters only on the ingest path, where a client is
  proposing a change and a stale proposal must be rejected.
  """
  @spec update_refs(path(), [V1.RefCommand.t()], keyword()) :: :ok | {:error, term()}
  def update_refs(path, commands, opts \\ [])
  def update_refs(_path, [], _opts), do: :ok

  def update_refs(path, commands, opts) do
    zero = Entry.zero_oid()
    check_old? = Keyword.get(opts, :check_old?, false)

    stdin =
      Enum.map_join(commands, fn %V1.RefCommand{ref: ref, old_oid: old, new_oid: new} ->
        cond do
          new == zero and check_old? -> "delete #{ref} #{old}\n"
          new == zero -> "delete #{ref}\n"
          check_old? -> "update #{ref} #{new} #{old}\n"
          true -> "update #{ref} #{new}\n"
        end
      end)

    with {:ok, _} <- run(path, ["update-ref", "--stdin"], stdin: stdin), do: :ok
  end

  @doc """
  Force the repository's refs to exactly `refs`, deleting anything else.

  Used when a replica adopts a compaction base: the base states the ref set in
  full, so anything left locally is stale by definition.
  """
  @spec reset_refs(path(), %{optional(String.t()) => oid()}) :: :ok | {:error, term()}
  def reset_refs(path, refs) do
    with {:ok, current} <- refs(path) do
      zero = Entry.zero_oid()

      deletions =
        current
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(refs, &1))
        |> Enum.map(&%V1.RefCommand{ref: &1, old_oid: Map.fetch!(current, &1), new_oid: zero})

      updates =
        refs
        |> Enum.reject(fn {ref, oid} -> Map.get(current, ref) == oid end)
        |> Enum.map(fn {ref, oid} -> %V1.RefCommand{ref: ref, old_oid: zero, new_oid: oid} end)

      update_refs(path, deletions ++ updates)
    end
  end

  @doc """
  Install a packfile that is already on disk into the repository.

  `git index-pack` verifies the pack and writes the `.idx` beside it, so a
  corrupt or truncated download fails here rather than surfacing later as an
  inexplicable repository error.
  """
  @spec install_pack(path(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def install_pack(repo_path, pack_file) do
    destination = Path.join([repo_path, "objects", "pack", Path.basename(pack_file)])
    File.mkdir_p!(Path.dirname(destination))
    if Path.expand(pack_file) != Path.expand(destination), do: File.cp!(pack_file, destination)

    idx = Path.rootname(destination) <> ".idx"

    if File.exists?(idx) do
      # The index came down with the pack; verifying it is cheaper than
      # rebuilding it, and it is what lets replicas skip index-pack entirely.
      case run(repo_path, ["verify-pack", "-q", idx]) do
        {:ok, _} -> {:ok, destination}
        {:error, _} -> rebuild_index(repo_path, destination)
      end
    else
      rebuild_index(repo_path, destination)
    end
  end

  defp rebuild_index(repo_path, destination) do
    with {:ok, _} <- run(repo_path, ["index-pack", destination]), do: {:ok, destination}
  end

  @doc "Packfiles currently in the repository, as absolute paths."
  @spec packs(path()) :: [Path.t()]
  def packs(repo_path) do
    repo_path |> Path.join("objects/pack/*.pack") |> Path.wildcard() |> Enum.sort()
  end

  @doc """
  Repack the repository into as few packfiles as possible.

  This is the expensive half of compaction and the reason only one node runs
  it. A repack is CPU-bound and produces a deterministic artefact, so paying
  for it once and letting every replica download the result is strictly better
  than every replica recomputing the same packs.
  """
  @spec repack(path()) :: {:ok, [Path.t()]} | {:error, term()}
  def repack(repo_path) do
    case run(repo_path, ["repack", "-a", "-d", "-f", "--write-bitmap-index", "--quiet"],
           timeout: :timer.hours(2)
         ) do
      {:ok, _} ->
        {:ok, packs(repo_path)}

      # Bitmaps cannot be written for every repository shape. The pack is what
      # the log records, so fall back rather than fail compaction over an index.
      {:error, _} ->
        with {:ok, _} <- run(repo_path, ["repack", "-a", "-d", "--quiet"], timeout: :timer.hours(2)) do
          {:ok, packs(repo_path)}
        end
    end
  end

  @doc "Remove any packfile in the repository that is not named in `keep`."
  @spec prune_packs(path(), [String.t()]) :: :ok
  def prune_packs(repo_path, keep) do
    keep = MapSet.new(keep)

    for pack <- packs(repo_path), not MapSet.member?(keep, Path.basename(pack)) do
      base = Path.rootname(pack)
      for ext <- [".pack", ".idx", ".rev", ".bitmap", ".promisor", ".keep"], do: File.rm(base <> ext)
    end

    :ok
  end

  @doc "Whether the object exists in the repository."
  @spec object?(path(), oid()) :: boolean()
  def object?(repo_path, oid), do: match?({:ok, _}, run(repo_path, ["cat-file", "-e", oid <> "^{object}"]))

  @doc "Resolve a revision (branch, tag, oid, `HEAD`) to a full object id."
  @spec resolve(path(), String.t()) :: {:ok, oid()} | {:error, term()}
  def resolve(repo_path, rev) do
    with {:ok, out} <- run(repo_path, ["rev-parse", "--verify", "--end-of-options", rev <> "^{commit}"]) do
      {:ok, String.trim(out)}
    end
  end

  @doc "Whether a commit is reachable from a non-private reference."
  @spec public_commit?(path(), oid()) :: boolean()
  def public_commit?(repo_path, commit) do
    case run(repo_path, ["for-each-ref", "--contains=#{commit}", "--format=%(refname)"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(&(not Micelio.Git.Ref.internal?(&1)))

      {:error, _reason} ->
        false
    end
  end

  @doc "Read a blob's contents at a revision."
  @spec read_file(path(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(repo_path, rev, file) do
    run(repo_path, ["cat-file", "blob", "#{rev}:#{file}"])
  end

  @doc "List a tree at a revision, one level deep unless `recursive: true`."
  @spec list_tree(path(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tree(repo_path, rev, dir \\ "", opts \\ []) do
    # An empty pathspec is an error in git rather than a synonym for the root,
    # so the `--` is omitted entirely when listing the top level.
    pathspec = if dir in [nil, "", "/"], do: [], else: ["--", dir]

    args =
      ["ls-tree", "--long", "-z"] ++
        if(Keyword.get(opts, :recursive, false), do: ["-r"], else: []) ++
        [rev] ++ pathspec

    with {:ok, out} <- run(repo_path, args) do
      entries =
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&parse_tree_entry/1)
        |> Enum.reject(&is_nil/1)

      {:ok, entries}
    end
  end

  defp parse_tree_entry(line) do
    case Regex.run(~r/^(\d+)\s+(\w+)\s+(\S+)\s+(\S+)\t(.*)$/s, line) do
      [_, mode, type, oid, size, name] ->
        %{mode: mode, type: type, oid: oid, size: parse_size(size), path: name}

      _ ->
        nil
    end
  end

  defp parse_size("-"), do: nil
  defp parse_size(value), do: String.to_integer(String.trim(value))

  @doc "Commit history, newest first."
  @spec log(path(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def log(repo_path, rev, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    sep = "\x1f"
    rec = "\x1e"
    format = Enum.join(["%H", "%an", "%ae", "%aI", "%cI", "%s", "%b"], sep) <> rec

    args = ["log", "--max-count=#{limit}", "--format=#{format}"]
    args = args ++ if(path = opts[:path], do: ["--", path], else: [])

    with {:ok, out} <- run(repo_path, (args ++ [rev]) |> reorder_rev(rev)) do
      commits =
        out
        |> String.split(rec, trim: true)
        |> Enum.map(fn chunk ->
          case String.split(String.trim_leading(chunk, "\n"), sep) do
            [oid, an, ae, ai, ci, subject | body] ->
              %{
                oid: oid,
                author: %{name: an, email: ae},
                authored_at: ai,
                committed_at: ci,
                subject: subject,
                body: Enum.join(body, sep)
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, commits}
    end
  end

  # `git log <opts> <rev> -- <path>` requires the revision before the `--`.
  defp reorder_rev(args, rev) do
    case Enum.split_while(args, &(&1 != "--")) do
      {before, []} -> before
      {before, rest} -> Enum.reject(before, &(&1 == rev)) ++ [rev] ++ rest
    end
  end

  @doc "Unified diff between two revisions."
  @spec diff(path(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(repo_path, from, to, opts \\ []) do
    args = ["diff", "--no-color", "--find-renames"]
    args = args ++ if(Keyword.get(opts, :stat_only, false), do: ["--stat"], else: [])
    args = args ++ ["#{from}..#{to}"]
    args = args ++ if(path = opts[:path], do: ["--", path], else: [])
    run(repo_path, args)
  end

  @doc "Search the tree at a revision. Returns `path:line:text` matches."
  @spec grep(path(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def grep(repo_path, rev, pattern, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    args =
      ["grep", "--line-number", "--no-color", "-I", "--max-count=#{limit}"] ++
        if(Keyword.get(opts, :ignore_case, false), do: ["--ignore-case"], else: []) ++
        if(Keyword.get(opts, :fixed, true), do: ["--fixed-strings"], else: ["--extended-regexp"]) ++
        ["-e", pattern, rev] ++
        if(path = opts[:path], do: ["--", path], else: [])

    case run(repo_path, args) do
      {:ok, out} ->
        matches =
          out
          |> String.split("\n", trim: true)
          |> Enum.take(limit)
          |> Enum.map(fn line ->
            case String.split(line, ":", parts: 4) do
              [_rev, path, num, text] -> %{path: path, line: String.to_integer(num), text: text}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, matches}

      # git grep exits 1 when there are simply no matches.
      {:error, {:git, 1, _}} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Write a blob into the object database, returning its object id.

  Used by the agent-facing API to build commits without a working tree.
  """
  @spec write_blob(path(), binary()) :: {:ok, oid()} | {:error, term()}
  def write_blob(repo_path, content) do
    with {:ok, out} <- run(repo_path, ["hash-object", "-w", "--stdin"], stdin: content) do
      {:ok, String.trim(out)}
    end
  end

  @doc "Read a tree into a scratch index, then apply changes and write it back."
  @spec write_tree(path(), String.t() | nil, [map()]) :: {:ok, oid()} | {:error, term()}
  def write_tree(repo_path, base_rev, changes) do
    index = Path.join(System.tmp_dir!(), "micelio-index-" <> random_suffix())
    env = [{"GIT_INDEX_FILE", index}]

    try do
      with :ok <- read_base_tree(repo_path, base_rev, env),
           :ok <- apply_index_changes(repo_path, changes, env),
           {:ok, out} <- run(repo_path, ["write-tree"], env: env) do
        {:ok, String.trim(out)}
      end
    after
      File.rm(index)
    end
  end

  defp read_base_tree(_repo_path, nil, _env), do: :ok

  defp read_base_tree(repo_path, rev, env) do
    with {:ok, _} <- run(repo_path, ["read-tree", rev], env: env), do: :ok
  end

  # `--index-info` is used rather than `--add`/`--force-remove` for two reasons:
  # it applies the whole batch in a single invocation, and `--force-remove`
  # insists on a work tree, which a bare repository does not have. A mode of
  # zero is how the index-info format expresses a deletion.
  defp apply_index_changes(_repo_path, [], _env), do: :ok

  defp apply_index_changes(repo_path, changes, env) do
    zero = Entry.zero_oid()

    stdin =
      Enum.map_join(changes, fn
        %{path: path, oid: nil} -> "0 #{zero}\t#{path}\n"
        %{path: path, oid: oid} = change -> "#{Map.get(change, :mode, "100644")} #{oid}\t#{path}\n"
      end)

    with {:ok, _} <- run(repo_path, ["update-index", "--index-info"], env: env, stdin: stdin), do: :ok
  end

  @doc "Create a commit object from a tree and parents."
  @spec commit_tree(path(), oid(), [oid()], String.t(), map()) :: {:ok, oid()} | {:error, term()}
  def commit_tree(repo_path, tree, parents, message, author) do
    args = ["commit-tree", tree] ++ Enum.flat_map(parents, &["-p", &1])

    env = [
      {"GIT_AUTHOR_NAME", author[:name] || "Micelio"},
      {"GIT_AUTHOR_EMAIL", author[:email] || "micelio@localhost"},
      {"GIT_COMMITTER_NAME", author[:name] || "Micelio"},
      {"GIT_COMMITTER_EMAIL", author[:email] || "micelio@localhost"}
    ]

    with {:ok, out} <- run(repo_path, args, stdin: message, env: env), do: {:ok, String.trim(out)}
  end

  @doc """
  Pack exactly the objects reachable from `include` but not from `exclude`.

  Used by the agent-facing write path, where objects are created loose and then
  have to become a packfile before they can be logged.

  `git repack` is the wrong tool here for two reasons. It only packs objects
  reachable from a ref, and on this path the new commit has no ref yet — the
  ref is what we are about to propose — so a repack would quietly leave the new
  objects out, producing a log entry that names an object no pack provides.
  It would also rewrite and re-upload the *entire* repository on every commit,
  which for a large repository is an absurd cost for adding one file.

  Returns the path to the packfile, or `nil` when there was nothing new.
  """
  @spec pack_objects(path(), [oid()], [oid()], Path.t()) :: {:ok, Path.t() | nil} | {:error, term()}
  def pack_objects(repo_path, include, exclude, dir) do
    File.mkdir_p!(dir)

    revs =
      Enum.map_join(include, &"#{&1}\n") <>
        Enum.map_join(exclude, &"^#{&1}\n")

    # `git pack-objects <base>` writes <base>-<hash>.pack and its .idx, and
    # prints the hash. The conventional "pack" base name keeps the result
    # indistinguishable from one receive-pack produced.
    base = Path.join(dir, "pack")

    args = ["pack-objects", "--revs", "--delta-base-offset", "-q", base]

    with {:ok, out} <- run(repo_path, args, stdin: revs) do
      # stderr is merged into stdout for logging, and pack-objects writes
      # progress there, so pick out the line that is actually an object name
      # rather than assuming it is the first one.
      case Enum.find(String.split(out, "\n"), &Regex.match?(~r/^[0-9a-f]{40,64}$/, String.trim(&1))) do
        nil ->
          {:ok, nil}

        hash ->
          pack = base <> "-" <> String.trim(hash) <> ".pack"
          if File.exists?(pack), do: {:ok, pack}, else: {:ok, nil}
      end
    end
  end

  @doc "Object count and on-disk size, for the admin and MCP APIs."
  @spec stats(path()) :: %{objects: non_neg_integer(), size_kb: non_neg_integer(), packs: non_neg_integer()}
  def stats(repo_path) do
    case run(repo_path, ["count-objects", "-v"]) do
      {:ok, out} ->
        values =
          out
          |> String.split("\n", trim: true)
          |> Map.new(fn line ->
            case String.split(line, ": ", parts: 2) do
              [k, v] -> {k, v}
              _ -> {line, "0"}
            end
          end)

        %{
          objects: to_int(values["in-pack"]) + to_int(values["count"]),
          size_kb: to_int(values["size-pack"]) + to_int(values["size"]),
          packs: to_int(values["packs"])
        }

      {:error, _} ->
        %{objects: 0, size_kb: 0, packs: 0}
    end
  end

  @doc """
  Run a git command to completion and return its combined output.

  `path` is the repository to operate on, or `nil` for commands that need none.
  """
  @spec run(path() | nil, [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {:git, integer() | :timeout, String.t()}}
  def run(path, args, opts \\ []) do
    args = if path, do: ["--git-dir", path | args], else: args
    started = System.monotonic_time(:microsecond)

    {output, status} = isolated(fn -> invoke(args, opts) end)

    duration = System.monotonic_time(:microsecond) - started

    :telemetry.execute([:micelio, :git, :command], %{duration_us: duration, bytes: byte_size(output)}, %{
      subcommand: subcommand(args),
      status: status
    })

    if status == 0 do
      {:ok, output}
    else
      Logger.debug("git #{Enum.join(args, " ")} exited #{inspect(status)}: #{output}")
      {:error, {:git, status, String.trim(output)}}
    end
  end

  defp invoke(args, opts) do
    case Keyword.get(opts, :stdin) do
      nil -> System.cmd(executable(), args, cmd_opts(opts))
      stdin -> run_with_stdin(args, stdin, opts)
    end
  end

  @doc """
  Run a long, expensive command whose output is not needed.

  Goes through MuonTrap, so the OS process dies with its owner and can be
  confined to a cgroup. Output is deliberately discarded — see the note above
  on why capturing it through MuonTrap is unsafe — so on failure the command is
  re-run through `run/3` purely to obtain a diagnostic.
  """
  @spec run_supervised(path(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_supervised(path, args, opts \\ []) do
    full = ["--git-dir", path | args]
    started = System.monotonic_time(:microsecond)

    {_output, status} =
      isolated(fn ->
        MuonTrap.cmd(executable(), full, supervised_opts(opts))
      end)

    :telemetry.execute(
      [:micelio, :git, :command],
      %{duration_us: System.monotonic_time(:microsecond) - started, bytes: 0},
      %{
        subcommand: subcommand(full),
        status: status
      }
    )

    if status == 0 do
      {:ok, ""}
    else
      # Re-run to find out why. Rare enough that the cost does not matter, and
      # a repack that fails without an explanation is unactionable.
      case run(path, args, opts) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # stderr is deliberately not merged: any output at all would exercise
  # MuonTrap's acknowledgement path, which is the unsafe one.
  defp supervised_opts(opts) do
    base = [env: env(opts), delay_to_sigkill: 1_000]
    base = if timeout = opts[:timeout], do: Keyword.put(base, :timeout, timeout), else: base

    case Keyword.get(opts, :cgroup) do
      nil -> base
      {controllers, path} -> base ++ [cgroup_controllers: controllers, cgroup_path: path]
    end
  end

  # A port failure — MuonTrap acknowledging bytes on a pipe whose child has
  # already exited, most notably — arrives as an exit signal, which no
  # `try/catch` in the calling process can stop. Running the command in a
  # monitored process turns it into a value we can act on instead of a dead
  # request handler.
  #
  # The single retry is safe because every command run this way is idempotent.
  defp isolated(fun, attempt \\ 1) do
    parent = self()
    tag = make_ref()

    {pid, monitor} = spawn_monitor(fn -> send(parent, {tag, fun.()}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        if attempt < 2 do
          Logger.debug("git invocation died with #{inspect(reason)}; retrying once")
          isolated(fun, attempt + 1)
        else
          {"git invocation failed: #{inspect(reason)}", 125}
        end
    end
  end

  # Neither System.cmd/3 nor MuonTrap.cmd/3 can write to stdin, and a port has
  # no way to half-close it, which matters because `update-ref --stdin` and
  # `hash-object --stdin` only act on EOF. Handing the payload to the shell as
  # a redirect gives a real EOF without quoting anything: `sh -c script name
  # args...` binds $0 and $@, so neither the git path nor its arguments are
  # ever re-parsed by the shell.
  defp run_with_stdin(args, stdin, opts) do
    tmp = Path.join(System.tmp_dir!(), "micelio-stdin-" <> random_suffix())
    File.write!(tmp, stdin)

    try do
      System.cmd(
        "/bin/sh",
        ["-c", ~S(exec "$0" "$@" < "$MICELIO_GIT_STDIN"), executable() | args],
        cmd_opts(Keyword.update(opts, :env, [{"MICELIO_GIT_STDIN", tmp}], &[{"MICELIO_GIT_STDIN", tmp} | &1]))
      )
    after
      File.rm(tmp)
    end
  end

  @doc """
  Spawn a git process with a live bidirectional pipe, for the protocol
  endpoints.

  The process is launched through the `muontrap` wrapper binary rather than
  spawning `git` directly, so that when the port closes — a client disconnects
  mid-clone, the handler crashes, the node shuts down — the child is killed
  instead of being left behind. A Git server that leaks `upload-pack`
  processes degrades in a way that is very hard to diagnose from the outside.

  Returns the port. The caller owns it and must consume `{port, {:data, _}}`
  and `{port, {:exit_status, _}}`, and must call `terminate/1` if it stops
  before the process exits.
  """
  @spec stream(path(), [String.t()], keyword()) :: port()
  def stream(path, args, opts \\ []) do
    args = if path, do: ["--git-dir", path | args], else: args

    Port.open({:spawn_executable, executable()}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:env, charlist_env(env(opts))}
    ])
  end

  @doc """
  Stop a streamed process and make sure nothing is left behind.

  Closing the port alone is not quite enough. It closes the pipes, which `git`
  usually notices, but a process blocked on something other than I/O would
  survive, and a Git server that accumulates stranded `upload-pack` processes
  degrades in a way that is very hard to attribute.
  """
  @spec terminate(port()) :: :ok
  def terminate(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if os_pid do
      # SIGTERM only. Escalating to SIGKILL would mean signalling a pid we may
      # already have reaped, and pids are recycled.
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp cmd_opts(opts) do
    base = [stderr_to_stdout: true, env: env(opts)]
    if cd = opts[:cd], do: Keyword.put(base, :cd, cd), else: base
  end

  defp env(opts) do
    [
      # Determinism: never read the operator's git configuration.
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", ""},
      {"HOME", System.tmp_dir!()},
      {"LC_ALL", "C"}
    ] ++ Keyword.get(opts, :env, [])
  end

  # Erlang's port env takes a charlist value, or `false` to unset the variable.
  # An empty string becomes the empty charlist, which is neither, so it has to
  # be translated explicitly rather than passed through.
  defp charlist_env(env) do
    Enum.map(env, fn
      {key, nil} -> {String.to_charlist(key), false}
      {key, ""} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp subcommand(args), do: Enum.find(args, "unknown", &(not String.starts_with?(&1, "-")))

  defp random_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp to_int(nil), do: 0
  defp to_int(value), do: String.to_integer(String.trim(value))
end
