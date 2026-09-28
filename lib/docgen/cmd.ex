defmodule Docgen.Cmd do
  @moduledoc """
  Runs an external executable with a hard timeout.

  `System.cmd/3` can't time out, so this drives a Port and kills the OS
  process when the deadline passes.
  """

  @type result ::
          {:ok, output :: binary()}
          | {:error, {:exit_status, non_neg_integer(), output :: binary()}}
          | {:error, :timeout}

  @spec run(String.t(), [String.t()], timeout()) :: result()
  def run(executable, args, timeout), do: run(executable, args, timeout, [])

  @spec run(String.t(), [String.t()], timeout(), keyword()) :: result()
  def run(executable, args, timeout, opts) do
    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        env: env
      ])

    collect(port, [], System.monotonic_time(:millisecond) + timeout)
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [output, data], deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(output)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, IO.iodata_to_binary(output)}}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    if Port.info(port), do: Port.close(port)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
