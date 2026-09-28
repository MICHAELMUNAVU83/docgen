defmodule Docgen.Ingest.TextTest do
  use ExUnit.Case, async: true

  alias Docgen.Ingest.Text

  test "first heading-like line becomes the title" do
    doc = Text.parse("Quarterly Report\n\nSome text here.")
    assert doc.meta.title == "Quarterly Report"
    assert doc.blocks == [{:paragraph, [text: "Some text here."]}]
  end

  test "wrapped lines are joined; markup is literal" do
    doc = Text.parse("This is a\nwrapped *paragraph*.", promote_title: false)
    assert doc.blocks == [{:paragraph, [text: "This is a wrapped *paragraph*."]}]
  end

  test "short lines without punctuation are headings" do
    doc = Text.parse("Intro text.\n\nBackground\n\nMore text.")
    assert Enum.at(doc.blocks, 1) == {:heading, 1, [text: "Background"]}
  end

  test "section numbers set the heading level" do
    doc = Text.parse("Body.\n\n1 Scope\n\nBody.\n\n1.2 Details\n\nBody.")
    assert {:heading, 1, [text: "1 Scope"]} in doc.blocks
    assert {:heading, 2, [text: "1.2 Details"]} in doc.blocks
  end

  test "ALL CAPS headings outrank others" do
    doc = Text.parse("Body.\n\nOVERVIEW\n\nBody.\n\nDetails\n\nBody.")
    assert {:heading, 1, [text: "OVERVIEW"]} in doc.blocks
    assert {:heading, 2, [text: "Details"]} in doc.blocks
  end

  test "lists with intro line, nesting and continuations" do
    text = "Features:\n• one\n  continued\n  - nested\n• two\n\n1. first\n2) second"

    assert Text.parse(text, promote_title: false).blocks == [
             {:paragraph, [text: "Features:"]},
             {:bullet_list, 1,
              [
                {[text: "one continued"], [{:bullet_list, 2, [{[text: "nested"], []}]}]},
                {[text: "two"], []}
              ]},
             {:numbered_list, 1, [{[text: "first"], []}, {[text: "second"], []}]}
           ]
  end

  test "CRLF input" do
    assert Text.parse("a\r\nb\r\n\r\nc.", promote_title: false).blocks == [
             {:paragraph, [text: "a b"]},
             {:paragraph, [text: "c."]}
           ]
  end
end
