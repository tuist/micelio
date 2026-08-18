defmodule Micelio.Auth.Allow do
  @moduledoc """
  Grants everything to everyone.

  Exists so that a single node started with no configuration is immediately
  usable. It is refused in production configuration on purpose: an open Git
  server that happens to work is the kind of thing that survives to
  deployment.
  """

  @behaviour Micelio.Auth

  alias Micelio.Auth.Principal

  @impl true
  def authenticate(_credential, _config) do
    {:ok,
     %Principal{
       subject: "anonymous",
       account: nil,
       grants: [Principal.grant("**", [:admin])],
       source: :allow
     }}
  end
end
