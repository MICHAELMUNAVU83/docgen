defmodule Docgen.Convert.TocPagesTest do
  use ExUnit.Case, async: true

  alias Docgen.Convert.TocPages

  @headings [
    %{bookmark: "a", text: "Introduction"},
    %{bookmark: "b", text: "Scope of   the work"},
    %{bookmark: "c", text: "Details"}
  ]

  test "finds headings after the contents pages, in order" do
    pages = [
      "Supplier Guide\nRelease 1.0",
      "Document Summary",
      "Table of Contents\n1 Introduction 4\n1.1 Scope of the work 4",
      "2 Details 6",
      "1 Introduction\nIntroduction to the Details of…\n1.1 Scope of the work",
      "more text",
      "2 Details"
    ]

    assert TocPages.pages_from_text(pages, @headings) == %{"a" => 5, "b" => 5, "c" => 7}
  end

  test "headings that can't be found are left out" do
    pages = ["Table of Contents\nIntroduction\nDetails", "Introduction"]
    assert TocPages.pages_from_text(pages, @headings) == %{"a" => 2}
  end

  test "no headings" do
    assert TocPages.find("pdf", [], []) == {:ok, %{}}
  end

  test "missing pdftotext" do
    assert TocPages.find("pdf", @headings, pdftotext: nil) == {:error, :pdftotext_not_found}
  end
end
