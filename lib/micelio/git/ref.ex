defmodule Micelio.Git.Ref do
  @moduledoc """
  Reference-name validation, applied before a name can enter the log.

  Git will refuse to create a reference whose name breaks its rules, and that
  refusal is normally harmless — the client is told no and nothing changes.
  Here it is not harmless, because the log is written first and every replica
  converges on it afterwards. A name Git cannot represent, once recorded,
  cannot be applied by anyone: every replica fails to converge, forever, and
  the repository becomes unservable the moment it is evicted from the last
  cache holding it.

  So the log is the boundary this is enforced at. Names arriving from
  `receive-pack` were already vetted by Git, but names arriving through the
  agent API are whatever a caller typed, and both go through the same door.

  The rules are `git check-ref-format`'s, and are deliberately re-implemented
  rather than shelled out to: this runs inside the compare-and-swap retry loop,
  where a process spawn per attempt would be a poor trade for a check that is a
  handful of comparisons.
  """

  @control_characters 0..31
  @internal_root "refs/micelio"

  @doc "Whether a reference is reserved for Micelio's private state."
  @spec internal?(term()) :: boolean()
  def internal?(name) when is_binary(name),
    do: name == @internal_root or String.starts_with?(name, @internal_root <> "/")

  def internal?(_name), do: false

  @doc "Whether Git could represent this reference name."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) do
    components = String.split(name, "/")

    valid_shape?(name) and valid_components?(components) and no_forbidden_characters?(name)
  end

  def valid?(_name), do: false

  defp valid_shape?(name) do
    String.length(name) > 0 and
      name != "@" and
      not String.starts_with?(name, "/") and
      not String.ends_with?(name, "/") and
      not String.ends_with?(name, ".") and
      not String.contains?(name, "..") and
      not String.contains?(name, "@{")
  end

  defp valid_components?(components),
    do: length(components) > 1 and Enum.all?(components, &valid_component?/1)

  defp valid_component?(component) do
    component != "" and
      not String.starts_with?(component, ".") and
      not String.ends_with?(component, ".lock")
  end

  # Space, DEL and the control characters are rejected outright; the rest are
  # the characters Git reserves for revision syntax and pathspec globbing.
  defp no_forbidden_characters?(name) do
    name
    |> String.to_charlist()
    |> Enum.all?(fn character ->
      character not in @control_characters and
        character != 127 and
        character not in ~c" ~^:?*[\\"
    end)
  end

  @doc """
  Validate a batch of reference names, naming the first that is unusable.
  """
  @spec validate([String.t()]) :: :ok | {:error, {:invalid_ref, String.t()}}
  def validate(names) do
    case Enum.find(names, &(not valid?(&1))) do
      nil -> :ok
      invalid -> {:error, {:invalid_ref, invalid}}
    end
  end
end
