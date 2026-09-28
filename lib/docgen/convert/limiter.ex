defmodule Docgen.Convert.Limiter do
  @moduledoc """
  Counting semaphore that caps concurrent LibreOffice conversions.

  Each caller is handed a numbered slot for the duration of its work. A slot
  is used by one conversion at a time, so it can safely own a LibreOffice
  profile directory. Callers wait in FIFO order; a slot is freed when the
  work finishes or its caller dies.
  """

  use GenServer

  @type slot :: non_neg_integer()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Runs `fun.(slot)` once a slot is free and returns its result.
  """
  @spec run(GenServer.server(), (slot() -> result)) :: result when result: term()
  def run(server \\ __MODULE__, fun) do
    {ref, slot} = GenServer.call(server, :acquire, :infinity)

    try do
      fun.(slot)
    after
      GenServer.cast(server, {:release, ref})
    end
  end

  ## Callbacks

  @impl true
  def init(opts) do
    max = Keyword.get_lazy(opts, :max_concurrency, &default_max/0)
    {:ok, %{free: Enum.to_list(0..(max - 1)), busy: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, {pid, _} = from, state) do
    ref = Process.monitor(pid)

    case state.free do
      [slot | free] ->
        {:reply, {ref, slot}, %{state | free: free, busy: Map.put(state.busy, ref, slot)}}

      [] ->
        {:noreply, %{state | waiting: :queue.in({from, ref}, state.waiting)}}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, free_slot(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.busy, ref) do
      {:noreply, free_slot(state, ref)}
    else
      waiting = :queue.filter(fn {_from, r} -> r != ref end, state.waiting)
      {:noreply, %{state | waiting: waiting}}
    end
  end

  defp free_slot(state, ref) do
    {slot, busy} = Map.pop(state.busy, ref)
    state = %{state | busy: busy}

    case {slot, :queue.out(state.waiting)} do
      {nil, _} ->
        state

      {slot, {{:value, {from, next_ref}}, waiting}} ->
        GenServer.reply(from, {next_ref, slot})
        %{state | waiting: waiting, busy: Map.put(busy, next_ref, slot)}

      {slot, {:empty, _}} ->
        %{state | free: [slot | state.free]}
    end
  end

  defp default_max do
    Application.get_env(:docgen, Docgen.Convert.Pdf, [])[:max_concurrency] || 2
  end
end
