defmodule Docgen.StoreTest do
  use ExUnit.Case, async: false

  alias Docgen.Store

  @file_attrs %{data: "x", filename: "x.docx", content_type: "application/octet-stream"}

  test "stores and fetches by unguessable token" do
    token = Store.put(@file_attrs)
    assert byte_size(token) >= 32
    assert {:ok, %{data: "x"}} = Store.fetch(token)
    assert Store.fetch("missing") == :error
  end

  test "expired files are not served and get swept" do
    Application.put_env(:docgen, Store, ttl: -1)
    on_exit(fn -> Application.delete_env(:docgen, Store) end)

    token = Store.put(@file_attrs)
    assert Store.fetch(token) == :error
    assert Store.sweep() >= 1
  end
end
