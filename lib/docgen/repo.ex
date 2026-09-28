defmodule Docgen.Repo do
  use Ecto.Repo,
    otp_app: :docgen,
    adapter: Ecto.Adapters.Postgres
end
