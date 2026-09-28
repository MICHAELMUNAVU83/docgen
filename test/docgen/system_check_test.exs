defmodule Docgen.SystemCheckTest do
  use ExUnit.Case, async: false

  alias Docgen.SystemCheck

  test "check/0 reports every required tool" do
    assert SystemCheck.check() |> Map.keys() |> Enum.sort() == [:pdftohtml, :pdftotext, :soffice]
  end

  test "find/1 prefers the configured path" do
    path = Path.join(System.tmp_dir!(), "fake_soffice")
    File.write!(path, "")
    Application.put_env(:docgen, :tools, soffice: path)

    on_exit(fn ->
      Application.delete_env(:docgen, :tools)
      File.rm(path)
    end)

    assert SystemCheck.find(:soffice) == path
  end

  test "templates are bundled in priv/templates" do
    dir = Application.app_dir(:docgen, "priv/templates")

    for name <- ~w(basic advanced letterhead) do
      assert File.exists?(Path.join(dir, "#{name}.dotm"))
    end
  end
end
