defmodule DocgenWeb.PageController do
  use DocgenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
