defmodule Docgen.Convert.Pdf do
  @moduledoc """
  Converts `.docx` binaries to PDF with headless LibreOffice.

  Each conversion runs in its own temp directory. Concurrency is capped by
  `Docgen.Convert.Limiter`; every limiter slot owns a LibreOffice profile
  (`-env:UserInstallation`), because a profile can't be shared by two running
  instances. Reusing it per slot avoids LibreOffice's slow first-run setup
  on every call.

  Configuration:

      config :docgen, Docgen.Convert.Pdf,
        max_concurrency: 2,
        timeout: :timer.seconds(60),
        profile_dir: "/tmp/docgen-lo-profiles"
  """

  require Logger

  alias Docgen.Convert.Limiter
  alias Docgen.SystemCheck

  @type error :: :soffice_not_found | :timeout | :conversion_failed

  @doc """
  Converts a `.docx` binary to a PDF binary.

  ## Options

    * `:timeout` — milliseconds before LibreOffice is killed
    * `:limiter` — the `Docgen.Convert.Limiter` to queue on
    * `:profile_dir` — where per-slot LibreOffice profiles live
    * `:soffice` — path to the executable (default: `Docgen.SystemCheck.find(:soffice)`)
  """
  @spec from_docx(binary(), keyword()) :: {:ok, binary()} | {:error, error()}
  def from_docx(docx, opts \\ []) when is_binary(docx) do
    case Keyword.get_lazy(opts, :soffice, fn -> SystemCheck.find(:soffice) end) do
      nil ->
        {:error, :soffice_not_found}

      soffice ->
        limiter = Keyword.get(opts, :limiter, Limiter)
        Limiter.run(limiter, &convert(soffice, docx, &1, opts))
    end
  end

  defp convert(soffice, docx, slot, opts) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> config(:timeout, :timer.seconds(60)) end)
    profile = Path.join(profile_dir(opts), "slot-#{slot}")
    work = Path.join(System.tmp_dir!(), "docgen-pdf-#{System.unique_integer([:positive])}")
    input = Path.join(work, "document.docx")

    File.mkdir_p!(work)
    File.write!(input, docx)

    args = [
      "--headless",
      "--norestore",
      "--nolockcheck",
      "-env:UserInstallation=" <> file_url(profile),
      "--convert-to",
      "pdf",
      "--outdir",
      work,
      input
    ]

    try do
      with {:ok, output} <- Docgen.Cmd.run(soffice, args, timeout),
           {:ok, pdf} <- read_pdf(Path.join(work, "document.pdf"), output) do
        {:ok, pdf}
      else
        {:error, :timeout} ->
          Logger.warning("LibreOffice timed out after #{timeout}ms; resetting profile #{profile}")
          # A killed instance can leave the profile half-written.
          File.rm_rf(profile)
          {:error, :timeout}

        {:error, {:exit_status, status, output}} ->
          Logger.warning("LibreOffice exited with status #{status}: #{String.trim(output)}")
          {:error, :conversion_failed}

        {:error, :conversion_failed} ->
          {:error, :conversion_failed}
      end
    after
      File.rm_rf(work)
    end
  end

  defp read_pdf(path, output) do
    case File.read(path) do
      {:ok, <<"%PDF", _::binary>> = pdf} ->
        {:ok, pdf}

      _ ->
        Logger.warning("LibreOffice produced no PDF: #{String.trim(output)}")
        {:error, :conversion_failed}
    end
  end

  ## Helpers

  defp profile_dir(opts) do
    Keyword.get_lazy(opts, :profile_dir, fn ->
      config(:profile_dir, Path.join(System.tmp_dir!(), "docgen-lo-profiles"))
    end)
  end

  defp file_url(path), do: "file://" <> URI.encode(Path.expand(path))

  defp config(key, default) do
    Application.get_env(:docgen, __MODULE__, []) |> Keyword.get(key, default)
  end
end
