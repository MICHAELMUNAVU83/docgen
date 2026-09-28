defmodule Docgen.HistoryTest do
  # Needs Postgres (runs with `mix test`).
  use Docgen.DataCase, async: true

  alias Docgen.History

  setup do
    doc =
      Docgen.parse("# Report\n\nBody.", :markdown,
        template: :advanced,
        meta: %{doc_type: "Guideline"}
      )

    {:ok, docx} = Docgen.to_docx(doc)
    %{doc: doc, docx: docx}
  end

  test "records, lists without data, fetches with data and deletes", %{doc: doc, docx: docx} do
    assert {:ok, entry} =
             History.record(doc, docx, source: "# Report\n\nBody.", format: "markdown")

    assert entry.title == "Report"
    assert entry.template == "advanced"
    assert entry.meta == %{"title" => "Report", "doc_type" => "Guideline"}

    assert [listed] = History.list()
    assert listed.id == entry.id
    assert listed.docx == nil

    assert History.get!(entry.id).docx == docx

    assert {:ok, _} = History.delete(listed)
    assert History.list() == []
  end

  test "record_quietly never raises", %{doc: doc} do
    assert History.record_quietly(%{doc | template: :basic}, nil) == :ok
  end
end
