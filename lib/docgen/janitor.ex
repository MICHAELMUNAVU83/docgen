defmodule Docgen.Janitor do
  @moduledoc """
  Periodically deletes stale `docgen-*` temp files and directories.

  Conversions clean up after themselves, but a crash or a killed VM can
  leave work directories behind. LibreOffice profiles
  (`docgen-lo-profiles`) are kept.
  """

  use GenServer

  require Logger

  @interval :timer.minutes(30)
  @max_age_seconds 60 * 60
  @keep ~w(docgen-lo-profiles)

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Deletes stale temp entries in `dir` now; returns how many were removed."
  @spec sweep(String.t(), non_neg_integer()) :: non_neg_integer()
  def sweep(dir \\ System.tmp_dir!(), max_age_seconds \\ @max_age_seconds) do
    cutoff = System.os_time(:second) - max_age_seconds

    dir
    |> Path.join("docgen-*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in @keep))
    |> Enum.filter(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime < cutoff
        _ -> false
      end
    end)
    |> Enum.count(fn path -> match?({:ok, _}, File.rm_rf(path)) end)
  end

  @impl true
  def init(opts) do
    schedule(Keyword.get(opts, :interval, @interval))
    {:ok, opts}
  end

  @impl true
  def handle_info(:sweep, opts) do
    case sweep() do
      0 -> :ok
      n -> Logger.info("Removed #{n} stale temp files")
    end

    schedule(Keyword.get(opts, :interval, @interval))
    {:noreply, opts}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
