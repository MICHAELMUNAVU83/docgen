defmodule DocgenWeb.DocumentController do
  use DocgenWeb, :controller

  alias Docgen.Store

  def download(conn, %{"token" => token} = params) do
    case Store.fetch(token) do
      {:ok, file} ->
        send_download(conn, {:binary, file.data},
          filename: file.filename,
          content_type: file.content_type,
          disposition: if(params["inline"] == "true", do: :inline, else: :attachment)
        )

      :error ->
        conn
        |> put_status(:not_found)
        |> put_view(html: DocgenWeb.ErrorHTML)
        |> render(:"404")
    end
  end
end
