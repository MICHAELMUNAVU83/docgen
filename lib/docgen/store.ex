defmodule Docgen.Store do
  @moduledoc """
  Short-lived in-memory storage for generated files, keyed by random token.

  Files are served by `DocgenWeb.DocumentController` and expire after
  `:ttl` (default 30 minutes). The ETS table is public so reads never go
  through the owning process.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(5)

  @type file :: %{data: binary(), filename: String.t(), content_type: String.t()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stores `file` and returns its download token."
  @spec put(file()) :: String.t()
  def put(%{data: data, filename: _, content_type: _} = file) when is_binary(data) do
    token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    :ets.insert(@table, {token, file, System.monotonic_time(:millisecond) + ttl()})
    token
  end

  @doc "Fetches an unexpired file by token."
  @spec fetch(String.t()) :: {:ok, file()} | :error
  def fetch(token) when is_binary(token) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, token) do
      [{^token, file, expires_at}] when expires_at > now -> {:ok, file}
      _ -> :error
    end
  end

  @doc "Deletes expired files now. Returns how many were removed."
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  ## Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp ttl, do: Application.get_env(:docgen, __MODULE__, [])[:ttl] || :timer.minutes(30)
end
