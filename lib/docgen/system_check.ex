defmodule Docgen.SystemCheck do
  @moduledoc """
  Verifies that the external tools document generation relies on are available.

    * `soffice` (LibreOffice) — DOCX → PDF conversion
    * `pdftotext` / `pdftohtml` (poppler) — PDF ingest

  Paths can be overridden in config:

      config :docgen, :tools, soffice: "/path/to/soffice"
  """

  require Logger

  @tools %{
    soffice: %{
      purpose: "PDF export",
      fallbacks: ["/Applications/LibreOffice.app/Contents/MacOS/soffice"]
    },
    pdftotext: %{purpose: "PDF input", fallbacks: []},
    pdftohtml: %{purpose: "PDF input", fallbacks: []}
  }

  @doc """
  Returns the executable path for `tool`, or `nil` if it can't be found.
  """
  @spec find(atom()) :: String.t() | nil
  def find(tool) when is_map_key(@tools, tool) do
    configured = Application.get_env(:docgen, :tools, [])[tool]

    candidates =
      [configured, System.find_executable(to_string(tool)) | @tools[tool].fallbacks]

    Enum.find(candidates, &(is_binary(&1) and File.exists?(&1)))
  end

  @doc """
  Returns `%{tool => path | nil}` for every required tool.
  """
  @spec check() :: %{atom() => String.t() | nil}
  def check do
    Map.new(@tools, fn {tool, _} -> {tool, find(tool)} end)
  end

  @doc """
  Logs a warning for every missing tool. Always returns `:ok`.
  """
  @spec log_warnings() :: :ok
  def log_warnings do
    for {tool, nil} <- check() do
      Logger.warning(
        "#{tool} not found — #{@tools[tool].purpose} will be unavailable. " <>
          "Install it or set `config :docgen, :tools, #{tool}: \"/path\"`."
      )
    end

    :ok
  end
end
