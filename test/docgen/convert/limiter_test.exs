defmodule Docgen.Convert.LimiterTest do
  use ExUnit.Case, async: true

  alias Docgen.Convert.Limiter

  setup context do
    name = Module.concat(__MODULE__, "L#{context.line}")
    start_supervised!({Limiter, name: name, max_concurrency: 2})
    %{limiter: name}
  end

  test "never runs more than max_concurrency at once, on distinct slots", %{limiter: limiter} do
    counter = :counters.new(2, [])
    test_pid = self()

    1..6
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Limiter.run(limiter, fn slot ->
          :counters.add(counter, 1, 1)
          :counters.put(counter, 2, max(:counters.get(counter, 2), :counters.get(counter, 1)))
          send(test_pid, {:slot, slot})
          Process.sleep(20)
          :counters.sub(counter, 1, 1)
          slot
        end)
      end)
    end)
    |> Task.await_many()

    assert :counters.get(counter, 2) == 2

    slots =
      for _ <- 1..6 do
        assert_receive {:slot, slot}
        slot
      end

    assert slots |> Enum.uniq() |> Enum.sort() == [0, 1]
  end

  test "returns the function's result and frees the slot after a raise", %{limiter: limiter} do
    assert Limiter.run(limiter, fn _ -> :done end) == :done
    assert_raise RuntimeError, fn -> Limiter.run(limiter, fn _ -> raise "boom" end) end
    assert_raise RuntimeError, fn -> Limiter.run(limiter, fn _ -> raise "boom" end) end
    assert Limiter.run(limiter, fn slot -> slot end) in [0, 1]
  end

  test "frees the slot when the caller dies", %{limiter: limiter} do
    for _ <- 1..2 do
      pid = spawn(fn -> Limiter.run(limiter, fn _ -> Process.sleep(:infinity) end) end)
      Process.sleep(10)
      Process.exit(pid, :kill)
    end

    task = Task.async(fn -> Limiter.run(limiter, fn slot -> slot end) end)
    assert Task.await(task, 1000) in [0, 1]
  end
end
