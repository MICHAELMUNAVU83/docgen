defmodule DocgenWeb.DocumentControllerTest do
  use DocgenWeb.ConnCase, async: true

  @moduletag db: false

  test "serves a stored file as an attachment", %{conn: conn} do
    token =
      Docgen.Store.put(%{data: "%PDF-1.7", filename: "a.pdf", content_type: "application/pdf"})

    conn = get(conn, ~p"/documents/#{token}/download")

    assert response(conn, 200) == "%PDF-1.7"
    assert response_content_type(conn, :pdf) =~ "application/pdf"
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="a.pdf")]
  end

  test "serves a generated PDF inline for the exact preview", %{conn: conn} do
    token =
      Docgen.Store.put(%{
        data: "%PDF-preview",
        filename: "preview.pdf",
        content_type: "application/pdf"
      })

    conn = get(conn, ~p"/documents/#{token}/download?inline=true")

    assert response(conn, 200) == "%PDF-preview"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="preview.pdf")]
  end

  test "unknown tokens are not found", %{conn: conn} do
    conn = get(conn, ~p"/documents/nope/download")
    assert response(conn, 404)
  end
end
