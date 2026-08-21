defmodule Micelio.Issues do
  @moduledoc """
  Repository issues stored in a private Git reference.

  The source repository's `refs/micelio/issues` reference is part of the same
  write-ahead log as its source code, but it is never advertised through Git.
  Each mutation adds an immutable event and rewrites a small current-state
  projection in one commit. The event's actor is the verified principal, not a
  client-supplied Git author header.

  Git is deliberately the durable ledger here, not a local query database. A
  node can lose its entire repository directory and rebuild issue history from
  the log exactly as it rebuilds source references.
  """

  alias Micelio.Auth.Principal
  alias Micelio.Git
  alias Micelio.Ingest
  alias Micelio.Replica
  alias Micelio.WAL
  alias Micelio.Wal.V1

  @ref "refs/micelio/issues"
  @meta_path "issues/meta.json"
  @write_attempts 12

  @type result :: {:ok, map()} | {:error, String.t()}

  @doc "The private Git reference containing issue state."
  @spec ref() :: String.t()
  def ref, do: @ref

  @doc "Create an open issue and its first immutable event."
  @spec create(String.t(), String.t(), String.t(), Principal.t()) :: result()
  def create(repo_id, title, body, %Principal{} = principal) do
    with {:ok, title} <- title(title),
         :ok <- issue_body(body) do
      mutate(repo_id, fn view -> create_in_view(repo_id, view, title, body, principal) end)
    end
  end

  @doc "Add an immutable comment event and update the issue projection."
  @spec add_comment(String.t(), pos_integer(), String.t(), Principal.t()) :: result()
  def add_comment(repo_id, number, body, %Principal{} = principal) do
    with :ok <- issue_number(number),
         {:ok, body} <- comment_body(body) do
      mutate(repo_id, fn view -> comment_in_view(repo_id, view, number, body, principal) end)
    end
  end

  @doc "Update an issue's title, body, or open and closed state."
  @spec update(String.t(), pos_integer(), map(), Principal.t()) :: result()
  def update(repo_id, number, attrs, %Principal{} = principal) when is_map(attrs) do
    with :ok <- issue_number(number),
         {:ok, attrs} <- issue_updates(attrs) do
      mutate(repo_id, fn view -> update_in_view(repo_id, view, number, attrs, principal) end)
    end
  end

  def update(_repo_id, _number, _attrs, _principal), do: {:error, "issue changes must be an object"}

  @doc "Create an immutable deletion event and hide an issue from current views."
  @spec delete(String.t(), pos_integer(), Principal.t()) :: result()
  def delete(repo_id, number, %Principal{} = principal) do
    with :ok <- issue_number(number) do
      mutate(repo_id, fn view -> delete_in_view(repo_id, view, number, principal) end)
    end
  end

  @doc "Read one current comment."
  @spec get_comment(String.t(), pos_integer(), String.t()) :: result()
  def get_comment(repo_id, number, id) do
    with :ok <- issue_number(number),
         :ok <- comment_id(id) do
      in_repository(repo_id, fn view ->
        with {:ok, issue} <- live_issue(view.path, number),
             {:ok, comment} <- find_live_comment(issue, id) do
          {:ok, %{issue: number, comment: present_comment(comment)}}
        else
          {:error, :not_found} -> {:error, "comment #{id} not found on issue ##{number}"}
          {:error, reason} -> {:error, "could not read comment #{id}: #{inspect(reason)}"}
        end
      end)
    end
  end

  @doc "Replace a comment's current body while retaining its immutable history."
  @spec update_comment(String.t(), pos_integer(), String.t(), String.t(), Principal.t()) :: result()
  def update_comment(repo_id, number, id, body, %Principal{} = principal) do
    with :ok <- issue_number(number),
         :ok <- comment_id(id),
         {:ok, body} <- comment_body(body) do
      mutate(repo_id, fn view -> update_comment_in_view(repo_id, view, number, id, body, principal) end)
    end
  end

  @doc "Create a comment tombstone while retaining its immutable history."
  @spec delete_comment(String.t(), pos_integer(), String.t(), Principal.t()) :: result()
  def delete_comment(repo_id, number, id, %Principal{} = principal) do
    with :ok <- issue_number(number),
         :ok <- comment_id(id) do
      mutate(repo_id, fn view -> delete_comment_in_view(repo_id, view, number, id, principal) end)
    end
  end

  @doc "Read one issue's current projection."
  @spec get(String.t(), pos_integer()) :: result()
  def get(repo_id, number) do
    with :ok <- issue_number(number) do
      in_repository(repo_id, fn view ->
        with {:ok, head} <- issue_head(view.path),
             true <- is_binary(head),
             {:ok, issue} <- read_issue(view.path, head, number),
             :ok <- active_issue(issue) do
          {:ok, %{issue: present_issue(issue)}}
        else
          false -> {:error, "issue ##{number} not found"}
          {:error, :not_found} -> {:error, "issue ##{number} not found"}
          {:error, reason} -> {:error, "could not read issue ##{number}: #{inspect(reason)}"}
        end
      end)
    end
  end

  @doc "List the current issue projection for every issue in a repository."
  @spec list(String.t()) :: result()
  def list(repo_id) do
    in_repository(repo_id, fn view ->
      with {:ok, head} <- issue_head(view.path) do
        issues =
          case head do
            nil -> []
            _ -> list_issues(view.path, head)
          end

        {:ok, %{issues: issues, count: length(issues)}}
      else
        {:error, reason} -> {:error, "could not list issues: #{inspect(reason)}"}
      end
    end)
  end

  @doc "Read the immutable events that make up an issue's audit history."
  @spec events(String.t(), pos_integer()) :: result()
  def events(repo_id, number) do
    with :ok <- issue_number(number) do
      in_repository(repo_id, fn view ->
        with {:ok, head} <- issue_head(view.path),
             true <- is_binary(head),
             {:ok, events} <- read_events(view.path, head, number) do
          {:ok, %{issue: number, events: events, count: length(events)}}
        else
          false -> {:error, "issue ##{number} not found"}
          {:error, :not_found} -> {:error, "issue ##{number} not found"}
          {:error, reason} -> {:error, "could not read issue ##{number}: #{inspect(reason)}"}
        end
      end)
    end
  end

  # ----------------------------------------------------------------------

  defp create_in_view(repo_id, view, title, body, principal) do
    with {:ok, head} <- issue_head(view.path),
         {:ok, number} <- next_number(view.path, head) do
      occurred_at = timestamp()
      actor = actor(principal)

      issue = %{
        "number" => number,
        "title" => title,
        "body" => body,
        "state" => "open",
        "author" => actor,
        "created_at" => occurred_at,
        "updated_at" => occurred_at,
        "comments" => []
      }

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "issue_opened",
        "issue" => number,
        "actor" => actor,
        "occurred_at" => occurred_at,
        "payload" => %{"title" => title, "body" => body}
      }

      persist(repo_id, view, head, number, issue, event, %{"next_number" => number + 1}, principal)
    end
  end

  defp comment_in_view(repo_id, view, number, body, principal) do
    with {:ok, head} <- issue_head(view.path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(view.path, head, number) do
      occurred_at = timestamp()
      actor = actor(principal)

      comment = %{
        "id" => event_id(),
        "author" => actor,
        "body" => body,
        "created_at" => occurred_at
      }

      issue =
        issue
        |> Map.update("comments", [comment], &(&1 ++ [comment]))
        |> Map.put("updated_at", occurred_at)

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "comment_added",
        "issue" => number,
        "actor" => actor,
        "occurred_at" => occurred_at,
        "payload" => %{"comment" => comment}
      }

      persist(repo_id, view, head, number, issue, event, nil, principal)
    else
      false -> {:error, "issue ##{number} not found"}
      {:error, :not_found} -> {:error, "issue ##{number} not found"}
      {:error, reason} -> {:error, "could not add a comment to issue ##{number}: #{inspect(reason)}"}
    end
  end

  defp update_in_view(repo_id, view, number, attrs, principal) do
    with {:ok, head} <- issue_head(view.path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(view.path, head, number),
         :ok <- active_issue(issue) do
      occurred_at = timestamp()

      issue =
        Enum.reduce(attrs, issue, fn {key, value}, issue -> Map.put(issue, Atom.to_string(key), value) end)

      issue = Map.put(issue, "updated_at", occurred_at)

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "issue_updated",
        "issue" => number,
        "actor" => actor(principal),
        "occurred_at" => occurred_at,
        "payload" => Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)
      }

      persist(repo_id, view, head, number, issue, event, nil, principal)
    else
      false -> {:error, "issue ##{number} not found"}
      {:error, :not_found} -> {:error, "issue ##{number} not found"}
      {:error, reason} -> {:error, "could not update issue ##{number}: #{inspect(reason)}"}
    end
  end

  defp delete_in_view(repo_id, view, number, principal) do
    with {:ok, head} <- issue_head(view.path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(view.path, head, number),
         :ok <- active_issue(issue) do
      occurred_at = timestamp()

      issue =
        issue
        |> Map.put("state", "deleted")
        |> Map.put("updated_at", occurred_at)
        |> Map.put("deleted_at", occurred_at)

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "issue_deleted",
        "issue" => number,
        "actor" => actor(principal),
        "occurred_at" => occurred_at,
        "payload" => %{}
      }

      persist(repo_id, view, head, number, issue, event, nil, principal)
    else
      false -> {:error, "issue ##{number} not found"}
      {:error, :not_found} -> {:error, "issue ##{number} not found"}
      {:error, reason} -> {:error, "could not delete issue ##{number}: #{inspect(reason)}"}
    end
  end

  defp update_comment_in_view(repo_id, view, number, id, body, principal) do
    with {:ok, head} <- issue_head(view.path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(view.path, head, number),
         :ok <- active_issue(issue),
         {:ok, position, comment} <- find_live_comment_position(issue, id) do
      occurred_at = timestamp()
      comment = comment |> Map.put("body", body) |> Map.put("updated_at", occurred_at)
      issue = replace_comment(issue, position, comment, occurred_at)

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "comment_updated",
        "issue" => number,
        "actor" => actor(principal),
        "occurred_at" => occurred_at,
        "payload" => %{"comment_id" => id, "body" => body}
      }

      persist(repo_id, view, head, number, issue, event, nil, principal)
    else
      false -> {:error, "issue ##{number} not found"}
      {:error, :not_found} -> {:error, "comment #{id} not found on issue ##{number}"}
      {:error, reason} -> {:error, "could not update comment #{id}: #{inspect(reason)}"}
    end
  end

  defp delete_comment_in_view(repo_id, view, number, id, principal) do
    with {:ok, head} <- issue_head(view.path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(view.path, head, number),
         :ok <- active_issue(issue),
         {:ok, position, comment} <- find_live_comment_position(issue, id) do
      occurred_at = timestamp()

      comment =
        comment
        |> Map.delete("body")
        |> Map.put("deleted_at", occurred_at)

      issue = replace_comment(issue, position, comment, occurred_at)

      event = %{
        "version" => 1,
        "id" => event_id(),
        "type" => "comment_deleted",
        "issue" => number,
        "actor" => actor(principal),
        "occurred_at" => occurred_at,
        "payload" => %{"comment_id" => id}
      }

      persist(repo_id, view, head, number, issue, event, nil, principal)
    else
      false -> {:error, "issue ##{number} not found"}
      {:error, :not_found} -> {:error, "comment #{id} not found on issue ##{number}"}
      {:error, reason} -> {:error, "could not delete comment #{id}: #{inspect(reason)}"}
    end
  end

  # A mutation that loses the private reference race simply re-reads the
  # projection and rebuilds its commit. This is the same optimistic retry the
  # repository log uses for concurrent source writes.
  defp mutate(repo_id, build) do
    in_repository(repo_id, fn _view -> retry_mutation(repo_id, build, @write_attempts) end)
  end

  defp retry_mutation(_repo_id, _build, 0), do: {:error, "issue changed concurrently; please retry"}

  defp retry_mutation(repo_id, build, attempts) do
    with {:ok, view} <- Replica.ensure_fresh(repo_id) do
      case build.(view) do
        {:retry, _reason} -> retry_mutation(repo_id, build, attempts - 1)
        result -> result
      end
    else
      {:error, reason} -> {:error, "repository unavailable: #{inspect(reason)}"}
    end
  end

  defp persist(repo_id, view, head, number, issue, event, meta, principal) do
    with {:ok, changes} <- issue_changes(view.path, number, issue, event, meta),
         {:ok, tree} <- Git.write_tree(view.path, head, changes),
         {:ok, commit} <-
           Git.commit_tree(view.path, tree, parents(head), commit_message(event), system_author()),
         {:ok, result} <-
           Ingest.update_refs_raw(
             repo_id,
             [ref_command(head, commit)],
             actor: log_actor(principal),
             internal?: true
           ) do
      {:ok,
       %{
         issue: present_issue(issue),
         seq: result.seq,
         epoch: result.epoch
       }}
    else
      {:error, {:stale, _ref, _expected, _actual}} -> {:retry, :stale}
      {:error, reason} -> {:error, "could not persist issue: #{inspect(reason)}"}
    end
  end

  defp issue_changes(repo_path, number, issue, event, meta) do
    values =
      [
        {state_path(number), issue},
        {event_path(number, event["id"]), event}
      ] ++ if(meta, do: [{@meta_path, meta}], else: [])

    Enum.reduce_while(values, {:ok, []}, fn {path, value}, {:ok, changes} ->
      case write_json(repo_path, path, value) do
        {:ok, change} -> {:cont, {:ok, [change | changes]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      error -> error
    end
  end

  defp write_json(repo_path, path, value) do
    with {:ok, oid} <- Git.write_blob(repo_path, JSON.encode!(value)) do
      {:ok, %{path: path, oid: oid, mode: "100644"}}
    end
  end

  defp next_number(_repo_path, nil), do: {:ok, 1}

  defp next_number(repo_path, head) do
    case read_json(repo_path, head, @meta_path) do
      {:ok, %{"next_number" => number}} when is_integer(number) and number > 0 -> {:ok, number}
      {:error, :not_found} -> {:ok, 1}
      _ -> {:error, :invalid_issue_index}
    end
  end

  defp read_issue(repo_path, head, number), do: read_json(repo_path, head, state_path(number))

  defp live_issue(repo_path, number) do
    with {:ok, head} <- issue_head(repo_path),
         true <- is_binary(head),
         {:ok, issue} <- read_issue(repo_path, head, number),
         :ok <- active_issue(issue) do
      {:ok, issue}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp read_events(repo_path, head, number) do
    dir = "issues/#{number}/events"

    with {:ok, entries} <- Git.list_tree(repo_path, head, dir, recursive: true) do
      entries
      |> Enum.filter(&(&1.type == "blob"))
      |> Enum.sort_by(& &1.path)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, events} ->
        case read_json(repo_path, head, entry.path) do
          {:ok, event} -> {:cont, {:ok, [present_event(event) | events]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, []} -> {:error, :not_found}
        {:ok, events} -> {:ok, Enum.reverse(events) |> Enum.sort_by(&{&1.occurred_at, &1.id})}
        error -> error
      end
    else
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp list_issues(repo_path, head) do
    case Git.list_tree(repo_path, head, "issues", recursive: false) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(&1.type == "tree"))
        |> Enum.map(&issue_number_from_path/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.flat_map(fn number ->
          case read_issue(repo_path, head, number) do
            {:ok, %{"state" => "deleted"}} -> []
            {:ok, issue} -> [issue_summary(issue)]
            {:error, _} -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp issue_number_from_path(%{path: "issues/" <> number}) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp issue_number_from_path(_entry), do: nil

  defp read_json(repo_path, head, path) do
    case Git.read_file(repo_path, head, path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:error, :invalid_issue_data}
        end

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp issue_head(repo_path) do
    with {:ok, refs} <- Git.refs(repo_path), do: {:ok, Map.get(refs, @ref)}
  end

  defp in_repository(repo_id, fun) do
    case Replica.via_owner(repo_id, fn ->
           case Replica.ensure_fresh(repo_id) do
             {:ok, view} -> fun.(view)
             {:error, :no_such_repository} -> {:error, "repository #{repo_id} not found"}
             {:error, reason} -> {:error, "repository unavailable: #{inspect(reason)}"}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, "could not reach a replica: #{inspect(reason)}"}
    end
  end

  defp ref_command(nil, commit), do: %V1.RefCommand{ref: @ref, old_oid: WAL.Entry.zero_oid(), new_oid: commit}
  defp ref_command(head, commit), do: %V1.RefCommand{ref: @ref, old_oid: head, new_oid: commit}

  defp parents(nil), do: []
  defp parents(head), do: [head]

  defp state_path(number), do: "issues/#{number}/state.json"
  defp event_path(number, id), do: "issues/#{number}/events/#{id}.json"

  defp commit_message(%{"type" => type, "issue" => number}) do
    action =
      type
      |> String.replace_prefix("issue_", "")
      |> String.replace_prefix("comment_", "comment ")
      |> String.replace("_", " ")

    "issue ##{number} #{action}\n"
  end

  defp system_author, do: %{name: "Micelio", email: "issues@micelio.local"}

  defp log_actor(principal) do
    %V1.Actor{
      subject: principal.subject,
      account: principal.account || "",
      node: Micelio.Config.node_id()
    }
  end

  defp actor(principal) do
    %{subject: principal.subject}
    |> maybe_put(:account, principal.account)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_issue(issue) do
    comments =
      issue["comments"]
      |> Kernel.||([])
      |> Enum.reject(&(not is_nil(&1["deleted_at"])))

    %{
      number: issue["number"],
      title: issue["title"],
      body: issue["body"],
      state: issue["state"],
      author: present_actor(issue["author"]),
      created_at: issue["created_at"],
      updated_at: issue["updated_at"],
      comments: Enum.map(comments, &present_comment/1),
      comment_count: length(comments)
    }
  end

  defp issue_summary(issue) do
    %{
      number: issue["number"],
      title: issue["title"],
      state: issue["state"],
      author: present_actor(issue["author"]),
      created_at: issue["created_at"],
      updated_at: issue["updated_at"],
      comment_count: issue["comments"] |> Kernel.||([]) |> Enum.count(&is_nil(&1["deleted_at"]))
    }
  end

  defp present_comment(comment) do
    result = %{
      id: comment["id"],
      author: present_actor(comment["author"]),
      created_at: comment["created_at"]
    }

    case comment["deleted_at"] do
      nil -> result |> Map.put(:body, comment["body"]) |> maybe_put(:updated_at, comment["updated_at"])
      deleted_at -> result |> Map.put(:deleted, true) |> Map.put(:deleted_at, deleted_at)
    end
  end

  defp present_event(event) do
    %{
      id: event["id"],
      type: event["type"],
      issue: event["issue"],
      actor: present_actor(event["actor"]),
      occurred_at: event["occurred_at"],
      payload: event["payload"]
    }
  end

  defp present_actor(actor) do
    %{subject: actor["subject"]}
    |> maybe_put(:account, actor["account"])
  end

  defp event_id do
    timestamp = System.system_time(:microsecond) |> Integer.to_string() |> String.pad_leading(20, "0")

    sequence =
      System.unique_integer([:positive, :monotonic]) |> Integer.to_string() |> String.pad_leading(20, "0")

    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    "#{timestamp}-#{sequence}-#{suffix}"
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp issue_number(number) when is_integer(number) and number > 0, do: :ok
  defp issue_number(_number), do: {:error, "issue number must be a positive integer"}

  defp title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "issue title cannot be empty"}
      title -> {:ok, title}
    end
  end

  defp title(_value), do: {:error, "issue title must be text"}

  defp issue_body(value) when is_binary(value), do: :ok
  defp issue_body(_value), do: {:error, "issue body must be text"}

  defp comment_body(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "comment body cannot be empty"}
      body -> {:ok, body}
    end
  end

  defp comment_body(_value), do: {:error, "comment body must be text"}

  defp issue_updates(attrs) do
    attrs = Map.take(attrs, [:title, :body, :state])

    with false <- map_size(attrs) == 0,
         {:ok, attrs} <- validate_issue_update(attrs) do
      {:ok, attrs}
    else
      true -> {:error, "supply at least one issue change"}
      error -> error
    end
  end

  defp validate_issue_update(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {:title, value}, {:ok, valid} ->
        case title(value) do
          {:ok, title} -> {:cont, {:ok, Map.put(valid, :title, title)}}
          error -> {:halt, error}
        end

      {:body, value}, {:ok, valid} when is_binary(value) ->
        {:cont, {:ok, Map.put(valid, :body, value)}}

      {:body, _value}, _acc ->
        {:halt, {:error, "issue body must be text"}}

      {:state, value}, {:ok, valid} when value in ["open", "closed"] ->
        {:cont, {:ok, Map.put(valid, :state, value)}}

      {:state, _value}, _acc ->
        {:halt, {:error, "issue state must be open or closed"}}
    end)
  end

  defp active_issue(%{"state" => "deleted"}), do: {:error, :not_found}
  defp active_issue(_issue), do: :ok

  defp comment_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp comment_id(_id), do: {:error, "comment id must be text"}

  defp find_live_comment(issue, id) do
    case Enum.find(issue["comments"] || [], &(&1["id"] == id and is_nil(&1["deleted_at"]))) do
      nil -> {:error, :not_found}
      comment -> {:ok, comment}
    end
  end

  defp find_live_comment_position(issue, id) do
    case Enum.find_index(issue["comments"] || [], &(&1["id"] == id and is_nil(&1["deleted_at"]))) do
      nil -> {:error, :not_found}
      position -> {:ok, position, Enum.at(issue["comments"], position)}
    end
  end

  defp replace_comment(issue, position, comment, occurred_at) do
    issue
    |> Map.update!("comments", &List.replace_at(&1, position, comment))
    |> Map.put("updated_at", occurred_at)
  end
end
