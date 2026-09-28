defmodule Docgen.Render.Html do
  @moduledoc """
  Renders a `Docgen.Document` as preview HTML.

  The markup uses `gs1-*` classes (see `assets/css/app.css`) that imitate the
  GS1 Word styles. It is a fast approximation for live editing; the
  downloaded `.docx`/PDF is the source of truth.

  For GS1 Advanced the preview adds a cover block and a table of contents,
  and numbers headings the way the template's heading styles do.
  Presentations show one 16:9 card per slide planned by
  `Docgen.Render.Pptx.Deck`.
  """

  alias Docgen.Document

  @safe_schemes ~w(http https mailto)

  @doc "Renders the document to safe HTML."
  @spec render(Document.t()) :: Phoenix.HTML.safe()
  def render(%Document{template: :advanced} = doc) do
    {headings, blocks} = doc.blocks |> Document.normalize_headings() |> number_headings()

    {:safe,
     [
       ~s(<article class="gs1-doc gs1-advanced">),
       cover(doc.meta),
       disclaimer_page(),
       toc(headings),
       ~s(<section class="gs1-preview-page gs1-content-page" aria-label="Document content">),
       Enum.map(blocks, &block/1),
       "</section>",
       "</article>"
     ]}
  end

  def render(%Document{template: :presentation} = doc) do
    slides = Docgen.Render.Pptx.Deck.build(doc)

    {:safe,
     [
       ~s(<div class="gs1-doc gs1-deck">),
       slides |> Enum.with_index(1) |> Enum.map(&slide/1),
       "</div>"
     ]}
  end

  def render(%Document{template: :letterhead} = doc) do
    values = Docgen.Render.Docx.Letter.values(doc.meta)

    lines = fn text ->
      text |> String.split(~r/\r?\n/) |> Enum.map(&esc/1) |> Enum.intersperse("<br>")
    end

    {:safe,
     [
       ~s(<article class="gs1-doc gs1-letter">),
       ~s(<div class="gs1-letter-sender">),
       lines.(values.sender_name),
       "<br>",
       lines.(values.sender_address),
       "</div>",
       ~s(<p class="gs1-letter-date">),
       esc(values.date),
       "</p>",
       ~s(<div class="gs1-letter-recipient">),
       lines.(values.recipient_name),
       "<br>",
       lines.(values.recipient_address),
       "</div>",
       if(values.subject == "",
         do: [],
         else: [~s(<p class="gs1-letter-subject">Subject: ), esc(values.subject), "</p>"]
       ),
       "<p>Dear ",
       esc(values.salutation),
       ",</p>",
       Enum.map(doc.blocks, &block/1),
       "<p>",
       esc(values.closing),
       ",</p>",
       ~s(<div class="gs1-letter-signature">),
       esc(values.sender_name),
       "<br>",
       esc(values.sender_title),
       "</div>",
       "</article>"
     ]}
  end

  def render(%Document{} = doc) do
    {:safe,
     [
       ~s(<article class="gs1-doc">),
       title(doc.meta),
       Enum.map(doc.blocks, &block/1),
       "</article>"
     ]}
  end

  defp title(meta) do
    title = meta[:title]
    subtitle = meta[:subtitle]

    if blank?(title) and blank?(subtitle) do
      []
    else
      [
        ~s(<header class="gs1-title">),
        if(blank?(title), do: [], else: ["<h1>", esc(title), "</h1>"]),
        if(blank?(subtitle), do: [], else: [~s(<p class="gs1-subtitle">), esc(subtitle), "</p>"]),
        "</header>"
      ]
    end
  end

  ## GS1 Advanced

  defp cover(meta) do
    name = if blank?(meta[:title]), do: "Untitled document", else: meta[:title]

    release =
      [
        present(meta[:status]) || "Draft",
        present(meta[:date])
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    [
      ~s(<header class="gs1-cover gs1-preview-page gs1-cover-page">),
      [
        "<h1>",
        esc(name),
        if(blank?(meta[:doc_type]), do: [], else: [" ", esc(meta[:doc_type])]),
        "</h1>"
      ],
      if(blank?(meta[:description]),
        do: [],
        else: [~s(<p class="gs1-cover-description">), esc(meta[:description]), "</p>"]
      ),
      cover_visual(meta[:cover]),
      [~s(<p class="gs1-cover-release">), esc(release), "</p>"],
      "</header>"
    ]
  end

  defp disclaimer_page do
    [
      ~s(<section class="gs1-front-matter gs1-preview-page" aria-label="Disclaimer">),
      ~s(<h2 class="gs1-intro-heading">Disclaimer</h2>),
      ~s(<p class="gs1-disclaimer">The standard GS1 disclaimer from the Advanced template is included in the generated document.</p>),
      "</section>"
    ]
  end

  defp cover_visual(cover) do
    case Docgen.Template.cover_icon(cover || "") do
      {:ok, png} ->
        [
          ~s(<img class="gs1-cover-visual" src="data:image/png;base64,),
          Base.encode64(png),
          ~s(" alt="Selected GS1 industry visual">)
        ]

      :error ->
        []
    end
  end

  defp toc([]), do: []

  defp toc(headings) do
    [
      ~s(<nav class="gs1-toc gs1-preview-page" aria-label="Table of contents"><p class="gs1-toc-title">Table of Contents</p><ol>),
      for {level, number, inlines} <- headings, level <= 3 do
        [
          ~s(<li class="gs1-toc-#{level}"><span>),
          esc(number),
          "</span> ",
          esc(Document.plain_text(inlines)),
          "</li>"
        ]
      end,
      "</ol></nav>"
    ]
  end

  # Prefixes headings with outline numbers (1, 1.1, …) and collects them for the TOC.
  defp number_headings(blocks) do
    {blocks, {_counters, headings}} =
      Enum.map_reduce(blocks, {[], []}, fn
        {:heading, level, inlines}, {counters, headings} ->
          counters =
            counters
            |> Enum.take(level)
            |> then(&(&1 ++ List.duplicate(0, level - length(&1))))
            |> List.update_at(level - 1, &(&1 + 1))

          number = Enum.join(counters, ".")

          {{:numbered_heading, level, number, inlines},
           {counters, [{level, number, inlines} | headings]}}

        block, acc ->
          {block, acc}
      end)

    {Enum.reverse(headings), blocks}
  end

  defp present(value), do: if(blank?(value), do: nil, else: value)

  ## Presentations

  defp slide({%{kind: :title} = slide, number}) do
    details =
      for text <- [slide.presenter, slide.date], not blank?(text) do
        [~s(<p class="gs1-slide-detail">), esc(text), "</p>"]
      end

    [
      slide_open("gs1-slide-cover", number, "Title slide"),
      ~s(<div class="gs1-slide-cover-text"><span class="gs1-slide-rule"></span>),
      ["<h2>", esc(slide.title), "</h2>"],
      if(blank?(slide.subtitle),
        do: [],
        else: [~s(<p class="gs1-slide-subtitle">), esc(slide.subtitle), "</p>"]
      ),
      details,
      "</div>",
      if(slide.photo == "none", do: [], else: ~s(<div class="gs1-slide-photo"></div>)),
      "</section>"
    ]
  end

  defp slide({%{kind: :section} = slide, number}) do
    [
      slide_open("gs1-slide-divider", number, "Section"),
      ["<h2>", esc(slide.title), "</h2>"],
      "</section>"
    ]
  end

  defp slide({%{kind: :agenda} = slide, number}) do
    [
      slide_open("", number, "Agenda"),
      slide_title(slide.title),
      ~s(<div class="gs1-slide-body"><ul>),
      Enum.map(slide.items, &["<li>", esc(&1), "</li>"]),
      "</ul></div></section>"
    ]
  end

  defp slide({%{kind: :content} = slide, number}) do
    [
      slide_open("", number, slide.title),
      slide_title(slide.title),
      ~s(<div class="gs1-slide-body">),
      Enum.map(slide.blocks, &block/1),
      "</div></section>"
    ]
  end

  defp slide({%{kind: :table} = slide, number}) do
    [
      slide_open("", number, slide.title),
      slide_title(slide.title),
      ~s(<div class="gs1-slide-body">),
      if(slide.caption,
        do: [~s(<p class="gs1-caption gs1-caption-table">), esc(slide.caption), "</p>"],
        else: []
      ),
      block({:table, slide.header_rows, slide.rows}),
      "</div></section>"
    ]
  end

  defp slide({%{kind: :image} = slide, number}) do
    [
      slide_open("", number, slide.title),
      slide_title(slide.title),
      ~s(<div class="gs1-slide-body gs1-slide-image">),
      block({:image, slide.image, slide.caption}),
      "</div></section>"
    ]
  end

  defp slide_open(class, number, label) do
    [
      ~s(<section class="gs1-slide ),
      class,
      ~s(" aria-label="Slide ),
      Integer.to_string(number),
      if(blank?(label), do: [], else: [": ", esc(label)]),
      ~s(" data-slide="),
      Integer.to_string(number),
      ~s(">)
    ]
  end

  defp slide_title(""), do: []
  defp slide_title(title), do: [~s(<h3 class="gs1-slide-title">), esc(title), "</h3>"]

  ## Blocks

  defp block({:subheading, inlines}),
    do: [~s(<p class="gs1-slide-subheading">), inlines(inlines), "</p>"]

  defp block({:numbered_list, _level, items, start}),
    do: [~s(<ol start="#{start}">), list_items(items), "</ol>"]

  defp block({:numbered_heading, level, number, inlines}) do
    tag = "h#{min(level + 1, 6)}"

    [
      "<",
      tag,
      ~s( class="gs1-h#{level}"><span class="gs1-heading-number">),
      esc(number),
      "</span> ",
      inlines(inlines),
      "</",
      tag,
      ">"
    ]
  end

  defp block({:heading, level, inlines}) do
    tag = "h#{min(level + 1, 6)}"
    ["<", tag, ~s( class="gs1-h#{level}">), inlines(inlines), "</", tag, ">"]
  end

  defp block({:paragraph, inlines}), do: ["<p>", inlines(inlines), "</p>"]
  defp block({:note, inlines}), do: [~s(<aside class="gs1-note">), inlines(inlines), "</aside>"]

  defp block({:important, inlines}),
    do: [~s(<aside class="gs1-note gs1-important">), inlines(inlines), "</aside>"]

  defp block({:caption, :table, inlines}),
    do: [~s(<p class="gs1-caption gs1-caption-table">), inlines(inlines), "</p>"]

  defp block({:code_block, text}),
    do: [~s(<pre class="gs1-code"><code>), esc(text), "</code></pre>"]

  defp block({:bullet_list, _level, items}), do: ["<ul>", list_items(items), "</ul>"]
  defp block({:numbered_list, _level, items}), do: ["<ol>", list_items(items), "</ol>"]

  defp block({:table, header_rows, rows}) do
    [
      ~s(<div class="gs1-table-wrap"><table class="gs1-table">),
      if(header_rows == [], do: [], else: ["<thead>", rows(header_rows, "th"), "</thead>"]),
      "<tbody>",
      rows(rows, "td"),
      "</tbody></table></div>"
    ]
  end

  defp block({:image, image, caption}) do
    caption_html =
      if blank?(caption),
        do: [],
        else: [~s(<figcaption class="gs1-caption">), esc(caption), "</figcaption>"]

    picture =
      if Docgen.Image.web_safe?(image) do
        [
          ~s(<img src="data:),
          image.content_type,
          ";base64,",
          Base.encode64(image.data),
          ~s(" alt="),
          esc(caption || ""),
          ~s(">)
        ]
      else
        [~s(<div class="gs1-image-placeholder">Image (), esc(image.content_type), ")</div>"]
      end

    [~s(<figure class="gs1-figure">), picture, caption_html, "</figure>"]
  end

  defp block(:page_break), do: ~s(<hr class="gs1-page-break">)

  defp list_items(items) do
    for {inlines, children} <- items do
      ["<li>", inlines(inlines), Enum.map(children, &block/1), "</li>"]
    end
  end

  defp rows(rows, cell_tag) do
    for cells <- rows do
      [
        "<tr>",
        for(cell <- cells, do: ["<", cell_tag, ">", inlines(cell), "</", cell_tag, ">"]),
        "</tr>"
      ]
    end
  end

  ## Inlines

  defp inlines(inlines), do: Enum.map(inlines, &inline/1)

  defp inline({:text, text}) do
    text |> String.split("\n") |> Enum.map(&esc/1) |> Enum.intersperse("<br>")
  end

  defp inline({:bold, children}), do: ["<strong>", inlines(children), "</strong>"]
  defp inline({:italic, children}), do: ["<em>", inlines(children), "</em>"]
  defp inline({:code, text}), do: ["<code>", esc(text), "</code>"]

  defp inline({:link, url, children}) do
    if safe_url?(url) do
      [
        ~s(<a href="),
        esc(url),
        ~s(" target="_blank" rel="noopener noreferrer">),
        inlines(children),
        "</a>"
      ]
    else
      inlines(children)
    end
  end

  defp safe_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} -> scheme in @safe_schemes
      _ -> false
    end
  end

  defp esc(text), do: Phoenix.HTML.Engine.html_escape(text)

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
