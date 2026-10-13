defmodule DocgenWeb.DocumentLiveTest do
  # async: false — one test swaps the global `:tools` config.
  use DocgenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag db: false

  defp change(view, params),
    do: view |> form("#document-form", document: params) |> render_change()

  test "shows an empty preview and disabled downloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#preview-empty")
    assert has_element?(view, "#download-docx[disabled]")
    assert has_element?(view, "#download-pdf[disabled]")
  end

  describe "steps" do
    test "later steps stay locked until there is content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#step-nav-1[aria-current='step']")
      assert has_element?(view, "#continue-1[disabled]")
      assert has_element?(view, "#step-nav-3[disabled]")

      render_click(view, "step", %{"step" => "3"})
      assert has_element?(view, "#step-content:not(.hidden)")
    end

    test "walks from content to format to style to download and back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      change(view, %{source: "# Report\n\nBody."})

      view |> element("#continue-1") |> render_click()
      assert has_element?(view, "#step-content.hidden")
      assert has_element?(view, "#step-format:not(.hidden)")
      assert has_element?(view, "#step-nav-2[aria-current='step']")

      view |> element("#continue-2") |> render_click()
      assert has_element?(view, "#step-format.hidden")
      assert has_element?(view, "#step-style:not(.hidden)")

      view |> element("#continue-3") |> render_click()
      assert has_element?(view, "#step-style.hidden")
      assert has_element?(view, "#step-download:not(.hidden)")

      view |> element("#back-4") |> render_click()
      assert has_element?(view, "#step-style:not(.hidden)")

      view |> element("#step-nav-1") |> render_click()
      assert has_element?(view, "#step-content:not(.hidden)")
      assert has_element?(view, "#document_source", "Body.")
    end

    test "choosing a format waits for Continue before its style", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      change(view, %{source: "# Report\n\nBody."})
      view |> element("#continue-1") |> render_click()

      view |> element("#kind-presentation") |> render_click()
      assert has_element?(view, "#step-format:not(.hidden)")

      view |> element("#continue-2") |> render_click()
      assert has_element?(view, "#step-style:not(.hidden)")
      assert has_element?(view, "#kind-presentation[aria-checked='true']")
      refute has_element?(view, "#template-picker")
      assert has_element?(view, "#document_presenter")
    end

    test "an uploaded file moves on to choosing a format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> file_input("#document-form", :source, [
        %{name: "notes.md", content: "# Uploaded\n\nFrom a file.", type: "text/markdown"}
      ])
      |> render_upload("notes.md")

      assert has_element?(view, "#step-format:not(.hidden)")
    end

    test "Auto marks the template it picked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#ai-pick")

      change(view, %{
        source: "# Retail results\n\n| Region | Done |\n| --- | --- |\n| East | 72% |"
      })

      render_async(view)

      assert has_element?(view, "label[for='template-advanced'] #ai-pick")
    end
  end

  test "pasted Markdown renders a live preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{source: "# Report\n\n## Scope\n\nSome **bold** text.\n\n- one\n- two"})

    assert has_element?(view, "#preview .gs1-title h1", "Report")
    assert has_element?(view, "#preview h3.gs1-h2", "Scope")
    assert has_element?(view, "#preview strong", "bold")
    assert has_element?(view, "#preview li", "two")
    refute has_element?(view, "#download-docx[disabled]")
  end

  test "metadata fields override the promoted title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{source: "# From heading\n\nBody.", title: "From form", subtitle: "Draft"})

    assert has_element?(view, "#preview .gs1-title h1", "From form")
    assert has_element?(view, "#preview .gs1-subtitle", "Draft")
  end

  test "plain text mode shows a low-confidence warning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{format: "text", source: "Intro text.\n\nBackground\n\nMore text."})

    assert has_element?(view, "#warnings", "Headings were guessed")
    assert has_element?(view, "#preview h2", "Background")
  end

  test "the metadata form follows the chosen template", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{template: "letterhead", source: "Thank you."})

    for field <-
          ~w(sender_name sender_title sender_address recipient date subject salutation closing hide_graphics) do
      assert has_element?(view, "#document_#{field}")
    end

    refute has_element?(view, "#document_subtitle")

    change(view, %{sender_name: "Jane Doe", recipient: "John Smith\nACME", subject: "Hello"})
    assert has_element?(view, "#preview .gs1-letter-sender", "Jane Doe")
    assert has_element?(view, "#preview .gs1-letter-subject", "Hello")
    refute has_element?(view, "#download-docx[disabled]")
  end

  test "GS1 Advanced has cover fields and downloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{template: "advanced", source: "## Scope\n\nText."})
    change(view, %{title: "Spec", cover: "retail"})

    for field <- ~w(title doc_type description cover) do
      assert has_element?(view, "#document_#{field}")
    end

    for field <- ~w(version status date) do
      refute has_element?(view, "#document_#{field}")
    end

    refute has_element?(view, "#analyze-document")

    assert has_element?(view, "#document_cover option[value='transport_and_logistics']")
    assert has_element?(view, "#preview .gs1-cover h1", "Spec")
    assert has_element?(view, "#preview .gs1-toc")
    refute has_element?(view, "#warnings")

    view |> form("#document-form") |> render_submit()
    assert_push_event(view, "download", %{url: url})
    parts = get(build_conn(), url) |> response(200) |> Docgen.DocxHelpers.unzip!()
    assert parts["docProps/custom.xml"] =~ "<vt:lpwstr>Spec</vt:lpwstr>"
  end

  test "downloading a .docx pushes a working download URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    change(view, %{source: "# Supplier Guide\n\nHello."})

    view |> form("#document-form") |> render_submit()
    assert_push_event(view, "download", %{url: "/documents/" <> _ = url})

    conn = get(build_conn(), url)
    assert response(conn, 200) |> binary_part(0, 2) == "PK"
    assert response_content_type(conn, :docx) =~ "wordprocessingml.document"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="Supplier-Guide.docx")
           ]
  end

  test "the sample button fills the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#load-sample") |> render_click()
    render_async(view)

    assert has_element?(view, "#preview .gs1-cover h1", "Supplier Onboarding Guide")
    assert has_element?(view, "#preview table.gs1-table")
  end

  test "AI designer automatically recommends and applies a template and asset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{
      source:
        "# Retail results\n\n| Region | Completion |\n| --- | --- |\n| East | 72% |\n| West | 48% |"
    })

    render_async(view)

    refute has_element?(view, "#ai-plan", "Recommended template")
    refute has_element?(view, "#ai-plan", "Official GS1 visual")
    assert has_element?(view, "#ai-chart-suggestions", "Bar graph")
    assert has_element?(view, "#ai-chart-0", "72%")

    assert has_element?(view, "#template-auto[checked]")
    assert has_element?(view, "#document_doc_type")
    assert has_element?(view, "#document_cover option[value='retail'][selected]")
    assert has_element?(view, "#preview .gs1-cover")
  end

  test "AI designer bullets lists written without markers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{
      source:
        "# Cloud Decisions\n\n## Projects\n\nAsake Kenya: ticketing\n\nCallWisely AI: voice calls\n\nWasomi AI: EdTech"
    })

    render_async(view)

    assert has_element?(view, "#preview ul li", "Asake Kenya: ticketing")
    assert has_element?(view, "#preview ul li", "Wasomi AI: EdTech")
  end

  test "an explicit template choice is not replaced by automatic analysis", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{
      template: "basic",
      source: "# Retail performance report\n\n| Area | Rating |\n| --- | --- |\n| Quality | 90% |"
    })

    refute has_element?(view, "#ai-plan")
    assert has_element?(view, "#template-basic[checked]")
    refute has_element?(view, "#preview .gs1-cover")
  end

  test "a manually selected cover is not overwritten by AI", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    change(view, %{
      source:
        "# Healthcare report\n\n| Area | Rating | Comment |\n| --- | --- | --- |\n| Safety | 90% | Strong |"
    })

    render_async(view)
    assert has_element?(view, "#document_cover option[value='healthcare'][selected]")

    change(view, %{cover: "retail"})
    render_async(view)

    assert has_element?(view, "#document_cover option[value='retail'][selected]")
  end

  test "uploading a Markdown file loads it into the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    file =
      file_input(view, "#document-form", :source, [
        %{name: "notes.md", content: "# Uploaded\n\nFrom a file.", type: "text/markdown"}
      ])

    render_upload(file, "notes.md")

    assert has_element?(view, "#paste-panel")
    assert has_element?(view, "#document_source", "From a file.")
    assert has_element?(view, "#preview .gs1-title h1", "Uploaded")
  end

  defp upload(view, name, content) do
    view
    |> file_input("#document-form", :source, [
      %{name: name, content: content, type: "application/octet-stream"}
    ])
    |> render_upload(name)

    render_async(view, 5000)
  end

  test "uploading a .docx imports it as editable Markdown with images", %{conn: conn} do
    import Docgen.DocxBuilder

    docx =
      build([
        p("Imported Report", style: "Title"),
        p("Overview", style: "Heading1"),
        p([r("Some "), r("bold", "<w:b/>"), r(" text.")]),
        p([image_run()])
      ])

    {:ok, view, _html} = live(conn, ~p"/")
    html = upload(view, "report.docx", docx)

    assert html =~ "Imported report.docx"
    assert has_element?(view, "#document_title[value='Imported Report']")
    assert has_element?(view, "#document_source", "# Overview")
    assert has_element?(view, "#document_source", "Some **bold** text.")
    assert has_element?(view, "#preview h2", "Overview")
    assert has_element?(view, "#preview img[src^='data:image/png;base64,']")

    # Editing keeps the imported image.
    change(view, %{source: "Edited.\n\n![](docgen-image:1)"})
    assert has_element?(view, "#preview img")
  end

  test "uploading a PDF shows the low-confidence warning", %{conn: conn} do
    pdf =
      Docgen.PdfBuilder.build([
        [{:text, 72, 760, 20, :bold, "PDF Title"}, {:text, 72, 730, 11, :regular, "Body text."}]
      ])

    {:ok, view, _html} = live(conn, ~p"/")
    upload(view, "scan.pdf", pdf)

    assert has_element?(view, "#warnings", "Converted from PDF")
    assert has_element?(view, "#preview .gs1-title h1", "PDF Title")
    assert has_element?(view, "#preview p", "Body text.")
  end

  test "a broken .docx shows an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert upload(view, "broken.docx", "PK nope") =~ "doesn&#39;t look like a valid Word document"
    refute has_element?(view, "#import-progress")
  end

  @tag :tmp_dir
  test "PDF errors are shown as a flash", %{conn: conn, tmp_dir: tmp_dir} do
    soffice = Path.join(tmp_dir, "soffice")
    File.write!(soffice, "#!/bin/sh\nexit 1\n")
    File.chmod!(soffice, 0o755)
    Application.put_env(:docgen, :tools, soffice: soffice)
    on_exit(fn -> Application.delete_env(:docgen, :tools) end)

    {:ok, view, _html} = live(conn, ~p"/")
    change(view, %{source: "Hello."})
    view |> element("#download-pdf") |> render_click()

    assert render_async(view, 2000) =~ "PDF conversion failed"
    refute has_element?(view, "#download-pdf[disabled]")
  end

  describe "exact previews" do
    # A stand-in LibreOffice that logs each conversion and writes a PDF.
    setup %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "conversions.log")
      soffice = Path.join(tmp_dir, "soffice")

      File.write!(soffice, """
      #!/bin/sh
      for arg in "$@"; do last="$arg"; done
      while [ $# -gt 0 ]; do [ "$1" = "--outdir" ] && out="$2"; shift; done
      echo "$last" >> "#{log}"
      printf '%%PDF-1.4 stand-in' > "$out/document.pdf"
      """)

      File.chmod!(soffice, 0o755)
      Application.put_env(:docgen, :tools, soffice: soffice)
      Application.put_env(:docgen, :exact_preview, true)

      on_exit(fn ->
        Application.delete_env(:docgen, :tools)
        Application.put_env(:docgen, :exact_preview, false)
      end)

      %{conversions: fn -> log |> File.read!() |> String.split("\n", trim: true) |> length() end}
    end

    @tag :tmp_dir
    test "every look is converted on leaving the content step, so switching never converts",
         %{conn: conn, conversions: conversions} do
      {:ok, view, _html} = live(conn, ~p"/")

      change(view, %{template: "basic", source: "## Scope\n\nBody."})
      render_async(view, 5000)
      refute has_element?(view, "#exact-pdf-preview")

      view |> element("#continue-1") |> render_click()
      render_async(view, 5000)

      assert has_element?(view, "#exact-pdf-preview")
      converted = conversions.()
      assert converted >= 4

      change(view, %{template: "letterhead"})
      assert has_element?(view, "#exact-pdf-preview")
      refute has_element?(view, "#preview-progress")
      refute has_element?(view, "#regenerate")

      view |> element("#kind-presentation") |> render_click()
      assert has_element?(view, "#exact-pdf-preview")

      view |> element("#kind-document") |> render_click()
      change(view, %{template: "basic"})
      assert has_element?(view, "#exact-pdf-preview")

      render_async(view, 5000)
      assert conversions.() == converted
    end

    @tag :tmp_dir
    test "typing a detail waits for Regenerate, which redoes only the looks that show it",
         %{conn: conn, conversions: conversions} do
      {:ok, view, _html} = live(conn, ~p"/")
      change(view, %{template: "advanced", source: "## Scope\n\nBody."})
      view |> element("#continue-1") |> render_click()
      render_async(view, 5000)
      converted = conversions.()
      refute has_element?(view, "#regenerate")

      change(view, %{doc_type: "Guideline"})
      render_async(view, 5000)

      # The last PDF stays up, marked as behind.
      assert has_element?(view, "#exact-pdf-preview")
      assert has_element?(view, "#preview-stale")
      refute has_element?(view, "#preview-progress")
      assert conversions.() == converted

      view |> element("#regenerate") |> render_click()
      assert has_element?(view, "#preview-progress")
      refute has_element?(view, "#regenerate")

      render_async(view, 5000)
      assert has_element?(view, "#exact-pdf-preview")
      refute has_element?(view, "#preview-progress")
      refute has_element?(view, "#preview-stale")
      assert conversions.() == converted + 1
    end

    @tag :tmp_dir
    test "progress arrives over PubSub while a preview is made", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      Phoenix.PubSub.subscribe(Docgen.PubSub, "document:" <> view.id)

      change(view, %{template: "basic", source: "## Scope\n\nBody."})
      view |> element("#continue-1") |> render_click()

      assert_receive {:preview_stage, "basic", key, :building}, 5000
      assert_receive {:preview_stage, "basic", ^key, :converting}, 5000
      render_async(view, 5000)
      refute has_element?(view, "#preview-progress")
    end
  end

  describe "slide photos" do
    setup do
      Application.put_env(:docgen, Docgen.Unsplash,
        access_key: "key",
        client: Docgen.UnsplashStub.client(self())
      )

      on_exit(fn -> Application.delete_env(:docgen, Docgen.Unsplash) end)
    end

    test "a presentation gets photos, which can be switched off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      change(view, %{source: "# Launch\n\n## Warehouse scanning\n\n- one\n- two"})
      refute has_element?(view, "#preview .gs1-slide-visual")

      view |> element("#kind-presentation") |> render_click()
      render_async(view)

      assert has_element?(view, "#visuals-option")
      assert has_element?(view, "#preview .gs1-slide-has-visual .gs1-slide-visual img")

      assert has_element?(
               view,
               "#preview .gs1-slide-visual figcaption",
               "Photographer 1 / Unsplash"
             )

      change(view, %{visuals: "false"})
      refute has_element?(view, "#preview .gs1-slide-visual")

      # Switching back on reuses the photos already found.
      change(view, %{visuals: "true"})
      assert has_element?(view, "#preview .gs1-slide-visual")
    end

    test "documents are left alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      change(view, %{source: "# Launch\n\n## Warehouse scanning\n\n- one\n- two"})
      render_async(view)

      refute has_element?(view, "#visuals-option")
      refute_received {:unsplash, _, _}
    end
  end

  describe "presentations" do
    test "switching to presentation shows slide fields and a slide preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#kind-presentation") |> render_click()
      change(view, %{source: "# Launch\n\n## Why\n\n- one\n- two", presenter: "Jo"})

      assert has_element?(view, "#kind-presentation[aria-checked='true']")
      refute has_element?(view, "#template-picker")

      for field <- ~w(title subtitle presenter date photo),
          do: assert(has_element?(view, "#document_#{field}"))

      assert has_element?(view, "#document_photo option[value='photo6']")
      assert has_element?(view, "#preview .gs1-slide-cover h2", "Launch")
      assert has_element?(view, "#preview .gs1-slide-title", "Why")
      assert has_element?(view, "#preview .gs1-slide li", "two")
      refute has_element?(view, "#download-pptx[disabled]")
      refute has_element?(view, "#download-docx")
    end

    test "downloading a presentation pushes a .pptx", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#kind-presentation") |> render_click()
      change(view, %{source: "# Launch\n\n## Why\n\nBecause.", photo: "none"})

      view |> form("#document-form") |> render_submit()
      assert_push_event(view, "download", %{url: url})

      conn = get(build_conn(), url)
      assert response_content_type(conn, :pptx) =~ "presentationml.presentation"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="Launch.pptx")
             ]

      parts = conn |> response(200) |> Docgen.DocxHelpers.unzip!()
      assert parts["ppt/slides/_rels/slide1.xml.rels"] =~ "slideLayout9.xml"
    end

    test "uploading a .pptx imports it as an editable presentation", %{conn: conn} do
      {:ok, pptx} =
        "# Why\n\n- one\n- two"
        |> Docgen.parse(:markdown,
          template: :presentation,
          meta: %{title: "Launch", subtitle: "Plan", presenter: "Jo"}
        )
        |> Docgen.to_pptx()

      {:ok, view, _html} = live(conn, ~p"/")
      html = upload(view, "deck.pptx", pptx)

      assert html =~ "Imported deck.pptx"
      assert has_element?(view, "#kind-presentation[aria-checked='true']")
      assert has_element?(view, "#document_title[value='Launch']")
      assert has_element?(view, "#document_presenter[value='Jo']")
      assert has_element?(view, "#document_source", "# Why")
      assert has_element?(view, "#preview .gs1-slide li", "two")

      # Both download formats are offered.
      refute has_element?(view, "#download-pptx[disabled]")
      refute has_element?(view, "#download-pdf[disabled]")
    end

    test "a broken .pptx shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert upload(view, "broken.pptx", "PK nope") =~
               "doesn&#39;t look like a valid PowerPoint presentation"
    end

    test "switching back restores the document form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#kind-presentation") |> render_click()
      view |> element("#kind-document") |> render_click()
      change(view, %{source: "Hello."})

      assert has_element?(view, "#template-picker")
      assert has_element?(view, "#download-docx")
    end
  end
end
