defmodule Micelio.Auth.Principal do
  @moduledoc """
  Who is making a request, and what they are allowed to do.

  Grants are patterns rather than repository lists because the interesting
  identities are not people. A CI job, an agent, or a pod does not have an
  enumerable set of repositories; it has a namespace it is entitled to. Storing
  a pattern lets a token be issued once and stay correct as repositories are
  created and destroyed underneath it, which is the normal case when agents are
  creating repositories at machine speed.
  """

  @type permission :: :read | :write | :execute | :admin

  @type grant :: %{pattern: String.t(), permissions: [permission()]}

  @type t :: %__MODULE__{
          subject: String.t(),
          account: String.t() | nil,
          grants: [grant()],
          claims: map(),
          expires_at: DateTime.t() | nil,
          source: atom()
        }

  defstruct subject: "anonymous", account: nil, grants: [], claims: %{}, expires_at: nil, source: :unknown

  @doc "Build a grant from a pattern and permission list."
  @spec grant(String.t(), [permission()]) :: grant()
  def grant(pattern, permissions), do: %{pattern: pattern, permissions: permissions}

  @doc "Convert one externally supplied permission name without creating an atom."
  @spec permission(String.t() | atom()) :: permission() | nil
  def permission("read"), do: :read
  def permission("write"), do: :write
  def permission("execute"), do: :execute
  def permission("admin"), do: :admin
  def permission(:read), do: :read
  def permission(:write), do: :write
  def permission(:execute), do: :execute
  def permission(:admin), do: :admin
  def permission(_), do: nil

  @doc false
  @spec permission!(String.t() | atom()) :: permission()
  def permission!(value) do
    case permission(value) do
      nil -> raise ArgumentError, "unknown Micelio permission #{inspect(value)}"
      permission -> permission
    end
  end

  @doc """
  Whether the principal may perform `permission` on `repo_id`.

  `admin` implies everything, so an operator token does not need every
  permission spelled out.
  """
  @spec allows?(t(), String.t(), permission()) :: boolean()
  def allows?(%__MODULE__{grants: grants}, repo_id, permission) do
    Enum.any?(grants, fn %{pattern: pattern, permissions: permissions} ->
      matches?(pattern, repo_id) and (permission in permissions or :admin in permissions)
    end)
  end

  @doc """
  Glob matching over repository ids.

  `*` matches within one path segment and `**` matches across segments, which
  is the distinction that makes `acme/*` mean "the account's repositories" and
  `acme/**` mean "those and anything nested under them".
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?("**", _repo_id), do: true
  def matches?(pattern, repo_id), do: Regex.match?(compile(pattern), repo_id)

  defp compile(pattern) do
    source =
      pattern
      |> String.split("**")
      |> Enum.map_join(".*", fn segment ->
        segment
        |> String.split("*")
        |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  @doc "Whether the principal's credential has expired."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(now, at) == :gt

  @doc "Redacted form for logs, traces and the admin API."
  @spec describe(t()) :: map()
  def describe(%__MODULE__{} = principal) do
    %{
      subject: principal.subject,
      account: principal.account,
      source: principal.source,
      grants: Enum.map(principal.grants, &"#{&1.pattern}:#{Enum.join(&1.permissions, ",")}")
    }
  end
end
