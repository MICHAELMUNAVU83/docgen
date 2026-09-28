defmodule Docgen.Render.HtmlTest do
  use ExUnit.Case, async: true

  alias Docgen.Document

  defp html(doc), do: doc |> Docgen.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders title band, headings, lists and tables" do
    html =
      "# T\n\n## H\n\nText\n\n- a\n  1. b\n\n| x |\n|---|\n| y |"
      |> Docgen.parse(:markdown, meta: %{subtitle: "S"})
      |> html()

    assert html =~ ~s(<header class="gs1-title"><h1>T</h1><p class="gs1-subtitle">S</p></header>)
    assert html =~ ~s(<h3 class="gs1-h2">H</h3>)
    assert html =~ "<ul><li>a<ol><li>b</li></ol></li></ul>"
    assert html =~ "<thead><tr><th>x</th></tr></thead><tbody><tr><td>y</td></tr></tbody>"
  end

  test "escapes text and drops unsafe links" do
    doc = %Document{
      blocks: [
        {:paragraph,
         [
           {:text, "<script>&"},
           {:link, "javascript:alert(1)", [text: "bad"]},
           {:link, "https://x.org/?a=1&b=2", [text: "ok"]}
         ]}
      ]
    }

    html = html(doc)
    assert html =~ "&lt;script&gt;&amp;"
    refute html =~ "javascript:"
    assert html =~ ~s(href="https://x.org/?a=1&amp;b=2")
  end

  test "line breaks inside text become <br>" do
    assert html(%Document{blocks: [{:paragraph, [text: "a\nb"]}]}) =~ "<p>a<br>b</p>"
  end

  test "web images inline as data URIs; others get a placeholder" do
    png = %{data: "PNGDATA", content_type: "image/png", width: nil, height: nil}
    emf = %{data: "EMF", content_type: "image/x-emf", width: nil, height: nil}
    html = html(%Document{blocks: [{:image, png, "Cap <1>"}, {:image, emf, nil}]})

    assert html =~
             ~s(<img src="data:image/png;base64,#{Base.encode64("PNGDATA")}" alt="Cap &lt;1&gt;">)

    assert html =~ "<figcaption"
    assert html =~ "Image (image/x-emf)"
  end

  test "GS1 Advanced previews show a cover, contents and numbered headings" do
    html =
      "## One\n\n### Sub\n\n## Two\n\n> **Important:** x"
      |> Docgen.parse(:markdown,
        template: :advanced,
        meta: %{title: "Spec", doc_type: "Standard", status: "Final"}
      )
      |> html()

    assert html =~
             ~s(<header class="gs1-cover gs1-preview-page gs1-cover-page"><h1>Spec Standard</h1>)

    assert html =~ "Final"
    refute html =~ "Release 1.0"
    refute html =~ "Document Summary"
    refute html =~ "Contributors"
    assert html =~ "Disclaimer"
    refute html =~ "Document Version"
    refute html =~ "Log of Changes"
    assert html =~ ~s(<li class="gs1-toc-2"><span>1.1</span> Sub</li>)
    assert html =~ ~s(<h2 class="gs1-h1"><span class="gs1-heading-number">2</span> Two</h2>)
    assert html =~ ~s(<aside class="gs1-note gs1-important">)
  end

  test "letters preview as a letter" do
    html =
      "Body text."
      |> Docgen.parse(:markdown,
        template: :letterhead,
        meta: %{sender_name: "Jane", recipient: "Bob\nStreet 1", salutation: "Bob"}
      )
      |> html()

    assert html =~ ~s(<article class="gs1-doc gs1-letter">)
    assert html =~ "Bob<br>Street 1"
    assert html =~ "<p>Dear Bob,</p><p>Body text.</p><p>Kind regards,</p>"
  end
end
