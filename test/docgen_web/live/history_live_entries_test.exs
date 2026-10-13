defmodule DocgenWeb.HistoryLiveEntriesTest do
  # Needs Postgres (runs with `mix test`).
  use DocgenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Docgen.History

  defp record(title, opts \\ []) do
    source = "## Scope\n\n#{title} body."

    doc =
      Docgen.parse(source, :markdown,
        template: Keyword.get(opts, :template, :advanced),
        meta: %{title: title, doc_type: "Guideline"}
      )

    {:ok, data} = Docgen.to_native(doc)
    {:ok, entry} = History.record(doc, data, source: source, format: "markdown")
    entry
  end

  test "lists entries and searches them by title", %{conn: conn} do
    guide = record("Supplier Guide")
    spec = record("Barcode Spec")

    {:ok, view, _html} = live(conn, ~p"/history")
    assert has_element?(view, "#entries-#{guide.id}")
    assert has_element?(view, "#entries-#{spec.id}")
    refute has_element?(view, "#history-empty")

    view |> form("#history-search", %{q: "barcode"}) |> render_change()
    refute has_element?(view, "#entries-#{guide.id}")
    assert has_element?(view, "#entries-#{spec.id}")

    view |> form("#history-search", %{q: "100%"}) |> render_change()
    refute has_element?(view, "#entries-#{spec.id}")
    assert has_element?(view, "#history-empty")
  end

  test "deleting the last entry brings back the empty state", %{conn: conn} do
    entry = record("Supplier Guide")
    {:ok, view, _html} = live(conn, ~p"/history")

    view |> element("#delete-#{entry.id}") |> render_click()

    refute has_element?(view, "#entries-#{entry.id}")
    assert has_element?(view, "#history-empty")
  end

  test "Open reopens a document in the editor with its template and details", %{conn: conn} do
    entry = record("Supplier Guide")
    {:ok, view, _html} = live(conn, ~p"/history")

    {:ok, editor, _html} =
      view |> element("#open-#{entry.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(editor, "#step-style:not(.hidden)")
    assert has_element?(editor, "#template-advanced[checked]")
    assert has_element?(editor, "#document_title[value='Supplier Guide']")
    assert has_element?(editor, "#document_doc_type[value='Guideline']")
    assert has_element?(editor, "#document_source", "Supplier Guide body.")
    assert has_element?(editor, "#preview .gs1-cover h1", "Supplier Guide")
    refute has_element?(editor, "#download-docx[disabled]")
  end

  test "a presentation reopens as a presentation", %{conn: conn} do
    entry = record("Launch", template: :presentation)

    {:ok, editor, _html} = live(conn, ~p"/?from=#{entry.id}")

    assert has_element?(editor, "#kind-presentation[aria-checked='true']")
    assert has_element?(editor, "#download-pptx")
  end

  test "an entry that no longer exists shows an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?from=0")

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#step-content:not(.hidden)")
  end
end
