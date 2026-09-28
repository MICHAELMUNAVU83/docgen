defmodule DocgenWeb.HistoryLiveTest do
  use DocgenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Without a sandbox checkout, queries fail — as when the DB is down.
  @moduletag db: false

  test "shows a notice instead of crashing when the database is unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/history")
    assert has_element?(view, "#history-error")
  end
end
