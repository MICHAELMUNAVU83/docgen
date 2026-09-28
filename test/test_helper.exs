# Real LibreOffice tests only run where soffice is installed
# (or explicitly with `mix test --include libreoffice`).
exclude = if Docgen.SystemCheck.find(:soffice), do: [], else: [:libreoffice]

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Docgen.Repo, :manual)
