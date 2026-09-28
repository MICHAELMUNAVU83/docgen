defmodule Docgen.JanitorTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "removes stale docgen temp entries but keeps profiles and fresh ones", %{tmp_dir: dir} do
    old = System.os_time(:second) - 2 * 3600

    for name <- ~w(docgen-pdf-1 docgen-lo-profiles other-old) do
      File.mkdir_p!(Path.join(dir, name))
      File.touch!(Path.join(dir, name), old)
    end

    File.mkdir_p!(Path.join(dir, "docgen-pdf-2"))

    assert Docgen.Janitor.sweep(dir) == 1
    assert dir |> File.ls!() |> Enum.sort() == ~w(docgen-lo-profiles docgen-pdf-2 other-old)
  end
end
