defmodule DocgenWeb.DocumentLive.New do
  use DocgenWeb, :live_view

  alias Docgen.Store

  # {label, value, hint} for the template cards.
  @templates [
    {"Auto", "auto", "We pick the best fit for your content"},
    {"Basic", "basic", "Short reports, notes and guides"},
    {"Advanced", "advanced", "Cover page, contents and numbered sections"},
    {"Letterhead", "letterhead", "Formal letters"}
  ]

  @steps [{1, "Content"}, {2, "Format"}, {3, "Style"}, {4, "Download"}]

  # Every look gets an exact PDF preview up front, so switching between them
  # never waits on a conversion.
  @preview_templates ~w(basic advanced letterhead presentation)
  @preview_ttl :timer.minutes(20)

  @template_atoms %{
    "basic" => :basic,
    "advanced" => :advanced,
    "letterhead" => :letterhead,
    "presentation" => :presentation
  }

  @kinds [
    {"document", "Document", "hero-document-text", "A Word document, also available as PDF"},
    {"presentation", "Presentation", "hero-presentation-chart-bar",
     "PowerPoint slides, also available as PDF"}
  ]

  # {param, meta key, label, input type} shown for each template. The
  # "cover" select gets its options from the bundled industry icons, the
  # "photo" select from the presentation template's title slide photos.
  @meta_fields %{
    "basic" => [
      {"title", :title, "Title", "text"},
      {"subtitle", :subtitle, "Subtitle", "text"}
    ],
    "advanced" => [
      {"title", :title, "Document name", "text"},
      {"doc_type", :doc_type, "Document type", "text"},
      {"description", :description, "Description", "textarea"},
      {"cover", :cover, "Cover graphic", "select"}
    ],
    "letterhead" => [
      {"sender_name", :sender_name, "Sender's name", "text"},
      {"sender_title", :sender_title, "Sender's title", "text"},
      {"sender_address", :sender_address, "Sender's address", "textarea"},
      {"recipient", :recipient, "Recipient", "textarea"},
      {"date", :date, "Date", "date"},
      {"subject", :subject, "Subject", "text"},
      {"salutation", :salutation, "Salutation", "text"},
      {"closing", :closing, "Closing", "text"},
      {"hide_graphics", :hide_graphics, "Hide letterhead graphics (pre-printed paper)",
       "checkbox"}
    ],
    "presentation" => [
      {"title", :title, "Presentation title", "text"},
      {"subtitle", :subtitle, "Subtitle", "text"},
      {"presenter", :presenter, "Presenter", "text"},
      {"date", :date, "Date", "date"},
      {"photo", :cover, "Title slide photo", "select"}
    ]
  }

  # Hints that used to crowd the labels.
  @placeholders %{
    "recipient" => "Name, then address",
    "salutation" => "Dear …",
    "closing" => "Kind regards",
    "presenter" => "Name, title, company",
    "doc_type" => "e.g. Guideline"
  }

  @defaults %{
    "kind" => "document",
    "source" => "",
    "format" => "markdown",
    "template" => "auto",
    "title" => "",
    "subtitle" => "",
    "doc_type" => "",
    "description" => "",
    "sender_name" => "",
    "sender_address" => "",
    "recipient" => "",
    "date" => "",
    "version" => "1.0",
    "status" => "Draft",
    "cover" => "corporate",
    "sender_title" => "",
    "subject" => "",
    "salutation" => "",
    "closing" => "",
    "hide_graphics" => "false",
    "presenter" => "",
    "photo" => "photo1",
    "visuals" => "true"
  }

  @text_extensions ~w(.txt .md .markdown)
  @binary_extensions ~w(.docx .pptx .pdf)
  @max_file_size 20_000_000

  @sample """
  # Supplier Onboarding Guide

  ## Purpose

  This guide explains how new suppliers share **product data** with retailers
  using [GS1 standards](https://www.gs1.org/standards).

  ## Before you start

  - A GS1 company prefix
  - A GTIN for every trade item
    - Assigned at the lowest packaging level
  - Product images and dimensions

  ## Steps

  1. Register your products
  2. Validate the data
  3. Publish to your trading partners

  | Identifier | Digits | Used for |
  |------------|:------:|----------|
  | GTIN       | 14     | Trade items |
  | GLN        | 13     | Locations |

  > Keys must never be reused for a different item.
  """

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "New document",
        templates: @templates,
        kinds: @kinds,
        steps: @steps,
        step: 1,
        select_options: %{
          "cover" =>
            [{"GS1 corporate visual", "corporate"}, {"No graphic", "none"}] ++
              Enum.map(Docgen.Template.cover_icons(), fn {slug, label} ->
                {label, slug}
              end),
          "photo" =>
            Enum.map(Docgen.Render.Pptx.Deck.photos(), fn {slug, label} ->
              {label, slug}
            end) ++ [{"No photo", "none"}]
        },
        pdf_loading: false,
        previews: %{},
        preview_jobs: %{},
        ai_loading: false,
        ai_plan: nil,
        analyzed: nil,
        visuals?: Docgen.AI.Visuals.available?(),
        visuals_stage: nil,
        preview_stages: %{},
        topic: "document:" <> socket.id,
        visuals: %{},
        visuals_for: nil,
        visuals_loading: false,
        cover_mode: :auto,
        importing: nil,
        images: %{},
        import_warnings: [],
        params: @defaults
      )
      |> allow_upload(:source,
        accept: ~w(.txt .md .docx .pptx .pdf),
        max_entries: 1,
        max_file_size: @max_file_size,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> open_from_history(params)
      |> update_document()

    # Background work reports its progress here (see `handle_info/2`).
    if connected?(socket), do: Phoenix.PubSub.subscribe(Docgen.PubSub, socket.assigns.topic)

    {:ok, auto_previews(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:new}>
      <div id="document-workspace" phx-hook=".Download" class="space-y-8">
        <div class="mx-auto flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <ol id="stepper" class="flex items-center gap-2 text-sm">
            <li :for={{number, label} <- @steps} class="flex items-center gap-2">
              <span :if={number > 1} class="h-px w-5 bg-slate-300 sm:w-10"></span>
              <button
                type="button"
                id={"step-nav-#{number}"}
                phx-click="step"
                phx-value-step={number}
                disabled={number > 1 and not @content?}
                aria-current={@step == number && "step"}
                class="group flex items-center gap-2 rounded-full py-1 pr-2 transition disabled:cursor-not-allowed"
              >
                <span class={[
                  "flex size-7 items-center justify-center rounded-full text-xs font-semibold transition",
                  cond do
                    @step == number ->
                      "bg-gs1-navy text-white"

                    @step > number ->
                      "bg-gs1-navy/10 text-gs1-navy group-hover:bg-gs1-navy/20"

                    true ->
                      "border border-slate-300 text-slate-500 group-enabled:group-hover:border-gs1-navy"
                  end
                ]}>
                  <%= if @step > number do %>
                    <.icon name="hero-check-micro" class="size-4" />
                  <% else %>
                    {number}
                  <% end %>
                </span>
                <span class={[
                  "font-medium",
                  if(@step == number, do: "text-gs1-navy", else: "hidden text-slate-600 sm:inline")
                ]}>
                  {label}
                </span>
              </button>
            </li>
          </ol>

          <.status
            importing={@importing}
            ai_loading={@ai_loading}
            pdf_loading={@pdf_loading}
            preview_loading={@preview_loading}
            visuals_stage={@visuals_loading && (@visuals_stage || :planning)}
          />
        </div>

        <.form for={@form} id="document-form" phx-change="validate" phx-submit="download">
          <%!-- Every step stays in the DOM so the form keeps all of its fields. --%>
          <section id="step-content" class={["space-y-6", @step != 1 && "hidden"]}>
            <header>
              <h1 class="text-2xl font-semibold tracking-tight text-gs1-navy">Add your content</h1>
              <p class="mt-1 text-sm text-slate-600">
                Upload a file or paste your text. The GS1 house style is applied for you.
              </p>
            </header>

            <div id="upload-panel" class="space-y-3">
              <label
                for={@uploads.source.ref}
                phx-drop-target={@uploads.source.ref}
                class="group flex cursor-pointer items-center gap-4 rounded-lg border border-dashed border-slate-300 px-5 py-6 transition hover:border-gs1-navy hover:bg-gs1-navy/5 phx-drop-target-active:border-gs1-orange phx-drop-target-active:bg-gs1-orange/5"
              >
                <span class="flex size-11 shrink-0 items-center justify-center rounded-full bg-gs1-navy/5 transition group-hover:bg-white">
                  <.icon name="hero-arrow-up-tray" class="size-5 text-gs1-navy" />
                </span>
                <span class="min-w-0">
                  <span class="block text-sm font-medium text-slate-800">
                    Drop a file here, or <span class="text-gs1-navy underline">browse</span>
                  </span>
                  <span class="mt-0.5 block text-xs text-slate-500">
                    Word, PowerPoint, PDF, Markdown or text — up to 20 MB
                  </span>
                </span>
                <.live_file_input upload={@uploads.source} class="sr-only" />
              </label>

              <div
                :for={entry <- @uploads.source.entries}
                id={"upload-#{entry.ref}"}
                class="flex flex-wrap items-center gap-3 rounded-md border border-slate-200 px-3 py-2 text-sm"
              >
                <.icon name="hero-document-text" class="size-5 text-slate-400" />
                <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
                <span class="w-10 text-right tabular-nums text-slate-500">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  aria-label="Cancel upload"
                  class="text-slate-400 transition hover:text-slate-700"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
                <p
                  :for={err <- upload_errors(@uploads.source, entry)}
                  class="basis-full text-xs text-red-600"
                >
                  {upload_error_message(err)}
                </p>
              </div>

              <p
                :for={err <- upload_errors(@uploads.source)}
                id="upload-error"
                class="text-sm text-red-600"
              >
                {upload_error_message(err)}
              </p>
            </div>

            <div class="flex items-center gap-4 text-xs font-medium uppercase tracking-wider text-slate-400">
              <span class="h-px flex-1 bg-slate-200"></span>
              or paste text <span class="h-px flex-1 bg-slate-200"></span>
            </div>

            <div id="paste-panel">
              <.input
                field={@form[:source]}
                type="textarea"
                rows="14"
                phx-debounce="300"
                placeholder="# Title\n\nWrite or paste your content here…"
                class="block w-full resize-y rounded-lg border border-slate-300 bg-white p-4 font-mono text-sm leading-relaxed text-slate-800 transition focus:border-gs1-navy focus:outline-none focus:ring-2 focus:ring-gs1-navy/20"
              />
              <div class="flex items-center justify-between gap-3">
                <div class="flex items-center gap-2 text-sm text-slate-600">
                  <label for={@form[:format].id}>Read as</label>
                  <div class="-mb-4 w-36">
                    <.input
                      field={@form[:format]}
                      type="select"
                      options={[{"Markdown", "markdown"}, {"Plain text", "text"}]}
                      class={[input_class(), "py-1.5"]}
                    />
                  </div>
                </div>
                <button
                  type="button"
                  id="load-sample"
                  phx-click="load_sample"
                  class="text-sm font-medium text-gs1-navy underline-offset-4 transition hover:underline"
                >
                  Try a sample
                </button>
              </div>
            </div>

            <div class="flex justify-end border-t border-slate-200 pt-6">
              <button
                type="button"
                id="continue-1"
                phx-click="step"
                phx-value-step="2"
                disabled={not @content?}
                class={navy_button()}
              >
                Continue <.icon name="hero-arrow-right-mini" class="size-5" />
              </button>
            </div>
          </section>

          <section id="step-format" class={["space-y-6", @step != 2 && "hidden"]}>
            <header>
              <h1 class="text-2xl font-semibold tracking-tight text-gs1-navy">
                What are you making?
              </h1>
              <p class="mt-1 text-sm text-slate-600">
                Pick one, then continue. You can change this later.
              </p>
            </header>

            <div
              id="kind-switch"
              role="radiogroup"
              aria-label="What are you making?"
              class="grid gap-4 sm:grid-cols-2"
            >
              <button
                :for={{kind, label, icon, hint} <- @kinds}
                type="button"
                id={"kind-#{kind}"}
                role="radio"
                aria-checked={to_string(@params["kind"] == kind)}
                phx-click="kind"
                phx-value-kind={kind}
                class={[
                  "group flex flex-col items-start gap-4 rounded-lg border p-5 text-left transition hover:-translate-y-0.5 hover:border-gs1-navy hover:shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gs1-navy",
                  if(@params["kind"] == kind,
                    do: "border-gs1-navy ring-1 ring-gs1-navy",
                    else: "border-slate-200"
                  )
                ]}
              >
                <span class="flex size-11 items-center justify-center rounded-full bg-gs1-navy/5 transition group-hover:bg-gs1-navy/10">
                  <.icon name={icon} class="size-5 text-gs1-navy" />
                </span>
                <span>
                  <span class="block text-base font-semibold text-slate-900">{label}</span>
                  <span class="mt-1 block text-sm text-slate-600">{hint}</span>
                </span>
              </button>
            </div>

            <div class="flex items-center justify-between border-t border-slate-200 pt-6">
              <button
                type="button"
                id="back-2"
                phx-click="step"
                phx-value-step="1"
                class={quiet_button()}
              >
                <.icon name="hero-arrow-left-mini" class="size-5" /> Back
              </button>
              <button
                type="button"
                id="continue-2"
                phx-click="step"
                phx-value-step="3"
                disabled={not @content?}
                class={navy_button()}
              >
                Continue <.icon name="hero-arrow-right-mini" class="size-5" />
              </button>
            </div>
          </section>

          <div class={[
            "grid gap-8",
            @step in [1, 2] && "hidden",
            @step == 3 && "lg:grid-cols-[minmax(0,26rem)_minmax(0,1fr)]",
            @step == 4 && "lg:grid-cols-[minmax(0,1fr)_19rem]"
          ]}>
            <section id="step-style" class={["space-y-6", @step != 3 && "hidden"]}>
              <header>
                <h1 class="text-2xl font-semibold tracking-tight text-gs1-navy">Choose a style</h1>
                <p class="mt-1 text-sm text-slate-600">
                  {if(@presentation?,
                    do: "Fill in the details for your title slide.",
                    else: "Pick a template, then fill in the details."
                  )}
                </p>
              </header>

              <fieldset :if={not @presentation?} id="template-picker">
                <legend class="mb-2 text-sm font-medium text-slate-700">Template</legend>
                <div class="grid grid-cols-2 gap-3">
                  <label
                    :for={{label, value, hint} <- @templates}
                    for={"template-#{value}"}
                    class="relative flex cursor-pointer flex-col gap-3 rounded-lg border border-slate-200 p-3 transition hover:border-slate-400 has-checked:border-gs1-navy has-checked:ring-1 has-checked:ring-gs1-navy has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-gs1-navy"
                  >
                    <input
                      type="radio"
                      id={"template-#{value}"}
                      name={@form[:template].name}
                      value={value}
                      checked={@params["template"] == value}
                      class="sr-only"
                    />
                    <.template_thumb name={value} />
                    <span>
                      <span class="block text-sm font-semibold text-slate-900">{label}</span>
                      <span class="mt-0.5 block text-xs leading-snug text-slate-500">{hint}</span>
                    </span>
                    <span
                      :if={
                        (@params["template"] == "auto" and @ai_plan) && @effective_template == value
                      }
                      id="ai-pick"
                      class="absolute right-2 top-2 rounded-full bg-gs1-orange/10 px-2 py-0.5 text-[0.6875rem] font-semibold text-gs1-orange-strong"
                    >
                      Auto pick
                    </span>
                  </label>
                </div>
              </fieldset>

              <fieldset>
                <legend class="mb-3 text-sm font-medium text-slate-700">Details</legend>
                <%!-- One column: labels never wrap and fields line up. --%>
                <div id="metadata-fields">
                  <div :for={{name, _key, label, type} <- @meta_fields}>
                    <.input
                      :if={type == "select"}
                      field={@form[name]}
                      type="select"
                      label={label}
                      options={@select_options[name]}
                      class={input_class()}
                    />
                    <.input
                      :if={type == "checkbox"}
                      field={@form[name]}
                      type="checkbox"
                      label={label}
                      class="size-4 rounded border-slate-300 accent-gs1-navy"
                    />
                    <.input
                      :if={type not in ["select", "checkbox"]}
                      field={@form[name]}
                      type={type}
                      label={label}
                      rows="2"
                      placeholder={placeholder(name)}
                      autocomplete="off"
                      phx-debounce="300"
                      class={input_class()}
                    />
                  </div>
                </div>
                <div :if={@presentation? and @visuals?} id="visuals-option">
                  <.input
                    field={@form[:visuals]}
                    type="checkbox"
                    label="Add charts, icons and photos to slides"
                    class="size-4 rounded border-slate-300 accent-gs1-navy"
                  />
                </div>
              </fieldset>

              <div class="flex items-center justify-between border-t border-slate-200 pt-6">
                <button
                  type="button"
                  id="back-3"
                  phx-click="step"
                  phx-value-step="2"
                  class={quiet_button()}
                >
                  <.icon name="hero-arrow-left-mini" class="size-5" /> Back
                </button>
                <button
                  type="button"
                  id="continue-3"
                  phx-click="step"
                  phx-value-step="4"
                  disabled={not @content?}
                  class={navy_button()}
                >
                  Review <.icon name="hero-arrow-right-mini" class="size-5" />
                </button>
              </div>
            </section>

            <section
              id="preview-pane"
              class={["min-w-0", @step == 3 && "hidden lg:sticky lg:top-6 lg:block lg:self-start"]}
            >
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-xs font-semibold uppercase tracking-wider text-slate-500">Preview</h2>
                <div class="flex items-center gap-3">
                  <span
                    :if={@preview_stale? and @preview_url}
                    id="preview-stale"
                    class="text-xs text-amber-700"
                  >
                    Your latest changes aren't shown yet
                  </span>
                  <button
                    :if={@preview_stale?}
                    type="button"
                    id="regenerate"
                    phx-click="regenerate"
                    class="inline-flex items-center gap-1.5 rounded-md border border-gs1-navy px-2.5 py-1 text-xs font-semibold text-gs1-navy transition hover:bg-gs1-navy/5"
                  >
                    <.icon name="hero-arrow-path-mini" class="size-4" />
                    {if(@preview_url, do: "Regenerate", else: "Generate exact preview")}
                  </button>
                  <span :if={not @preview_stale?} id="preview-kind" class="text-xs text-slate-500">
                    {if(@preview_url, do: "Exact PDF", else: "Quick preview")}
                  </span>
                </div>
              </div>
              <div
                id="preview"
                class="relative overflow-hidden rounded-lg border border-slate-200 bg-slate-50"
              >
                <div
                  :if={@preview_loading}
                  id="preview-progress"
                  role="status"
                  class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-3 bg-white/85 text-center backdrop-blur-sm"
                >
                  <.icon
                    name="hero-arrow-path"
                    class="size-8 text-gs1-orange motion-safe:animate-spin"
                  />
                  <p id="preview-stage" class="text-sm font-medium text-gs1-navy">
                    {preview_stage_label(@preview_stage)}
                  </p>
                  <p :if={@preview_pending > 1} class="text-xs text-slate-500">
                    {@preview_pending} looks are being prepared
                  </p>
                </div>
                <%= cond do %>
                  <% @preview_url -> %>
                    <iframe
                      id="exact-pdf-preview"
                      title="Exact generated PDF preview"
                      src={@preview_url <> "?inline=true#toolbar=0&navpanes=0"}
                      class="h-[calc(100vh-13rem)] min-h-[640px] w-full border-0"
                    />
                  <% @empty? -> %>
                    <div
                      id="preview-empty"
                      class="flex flex-col items-center px-6 py-24 text-center text-slate-500"
                    >
                      <.icon name="hero-document-text" class="size-10 text-slate-300" />
                      <p class="mt-3 text-sm">
                        {if(@presentation?,
                          do: "Your GS1 slides will appear here.",
                          else: "Your formatted document will appear here."
                        )}
                      </p>
                    </div>
                  <% true -> %>
                    <div class="max-h-[calc(100vh-13rem)] overflow-y-auto p-3 sm:p-6">
                      <div class="mx-auto max-w-3xl bg-white px-8 py-10 shadow-sm ring-1 ring-slate-200 sm:px-12">
                        {@preview}
                      </div>
                    </div>
                <% end %>
              </div>
            </section>

            <aside
              id="step-download"
              class={[
                "order-first space-y-5 lg:sticky lg:top-6 lg:order-none lg:self-start",
                @step != 4 && "hidden"
              ]}
            >
              <header>
                <h1 class="text-2xl font-semibold tracking-tight text-gs1-navy">
                  Review and download
                </h1>
                <p class="mt-1 text-sm text-slate-600">Check the preview, then download.</p>
              </header>

              <dl id="summary" class="divide-y divide-slate-200 border-y border-slate-200 text-sm">
                <div class="flex justify-between gap-4 py-2.5">
                  <dt class="text-slate-500">Template</dt>
                  <dd class="font-medium text-slate-800">{template_label(@effective_template)}</dd>
                </div>
                <div class="flex justify-between gap-4 py-2.5">
                  <dt class="text-slate-500">File</dt>
                  <dd class="min-w-0 truncate font-medium text-slate-800">
                    {Docgen.filename(@doc, @native_ext)}
                  </dd>
                </div>
              </dl>

              <div class="grid gap-2">
                <button
                  type="submit"
                  id={"download-#{@native_ext}"}
                  disabled={not @downloadable?}
                  class={orange_button()}
                >
                  <.icon name="hero-arrow-down-tray-mini" class="size-5" />
                  Download {if(@presentation?, do: "PowerPoint", else: "Word")} (.{@native_ext})
                </button>
                <button
                  type="button"
                  id="download-pdf"
                  phx-click="download_pdf"
                  disabled={not @downloadable? or @pdf_loading}
                  class={outline_button()}
                >
                  <%= if @pdf_loading do %>
                    <.icon name="hero-arrow-path" class="size-5 motion-safe:animate-spin" />
                    Converting…
                  <% else %>
                    <.icon name="hero-arrow-down-tray-mini" class="size-5" /> Download PDF
                  <% end %>
                </button>
              </div>

              <div
                :if={@warnings != []}
                id="warnings"
                class="flex gap-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-amber-600" />
                <ul class="space-y-1">
                  <li :for={warning <- @warnings}>{warning}</li>
                </ul>
              </div>

              <div :if={@ai_plan && @ai_plan.charts != []} id="ai-plan" class="space-y-2">
                <h2 class="text-sm font-medium text-slate-700">Chart ideas from your data</h2>
                <div id="ai-chart-suggestions" class="space-y-2">
                  <div
                    :for={{chart, index} <- Enum.with_index(@ai_plan.charts)}
                    id={"ai-chart-#{index}"}
                    class="rounded-lg border border-slate-200 p-3"
                  >
                    <p class="text-sm font-semibold text-slate-800">
                      {String.capitalize(Atom.to_string(chart.type))} graph — {chart.title}
                    </p>
                    <p class="mt-1 text-xs text-slate-600">{chart.reason}</p>
                    <p class="mt-2 line-clamp-2 border-l-2 border-gs1-orange pl-2 text-xs italic text-slate-500">
                      {chart.source_excerpt}
                    </p>
                  </div>
                </div>
              </div>

              <button
                type="button"
                id="back-4"
                phx-click="step"
                phx-value-step="3"
                class={quiet_button()}
              >
                <.icon name="hero-arrow-left-mini" class="size-5" /> Back to style
              </button>
            </aside>
          </div>
        </.form>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Download">
        export default {
          mounted() {
            this.handleEvent("download", ({url}) => { window.location.href = url })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :importing, :string, default: nil
  attr :ai_loading, :boolean, default: false
  attr :pdf_loading, :boolean, default: false
  attr :preview_loading, :boolean, default: false
  attr :visuals_stage, :any, default: false

  # The one place background work is reported.
  defp status(assigns) do
    ~H"""
    <p id="status" aria-live="polite" class="flex min-h-5 items-center gap-2 text-sm text-slate-600">
      <.icon
        :if={@importing || @ai_loading || @visuals_stage || @pdf_loading || @preview_loading}
        name="hero-arrow-path"
        class="size-4 text-gs1-orange motion-safe:animate-spin"
      />
      <%= cond do %>
        <% @importing -> %>
          <span id="import-progress">Importing {@importing}…</span>
        <% @ai_loading -> %>
          <span id="ai-loading">Reading your content…</span>
        <% @visuals_stage -> %>
          <span id="visuals-loading">{visuals_stage_label(@visuals_stage)}</span>
        <% @pdf_loading -> %>
          <span>Converting to PDF…</span>
        <% @preview_loading -> %>
          <span id="preview-loading">Preparing the exact preview…</span>
        <% true -> %>
      <% end %>
    </p>
    """
  end

  attr :name, :string, required: true

  # A miniature page sketching each template's layout.
  defp template_thumb(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class="flex h-16 w-12 flex-col gap-1 overflow-hidden rounded-sm border border-slate-200 bg-white p-1.5"
    >
      <%= case @name do %>
        <% "auto" -> %>
          <span class="flex flex-1 items-center justify-center">
            <.icon name="hero-sparkles" class="size-5 text-gs1-orange" />
          </span>
        <% "basic" -> %>
          <span class="h-1.5 w-6 rounded-[1px] bg-gs1-navy"></span>
          <span class="h-0.5 w-full bg-gs1-orange"></span>
          <span :for={width <- ~w(w-full w-full w-5 w-full w-6)} class={["h-0.5 bg-slate-300", width]}></span>
        <% "advanced" -> %>
          <span class="-mx-1.5 -mt-1.5 flex h-8 items-end border-b-2 border-gs1-orange bg-gs1-navy/10 p-1.5">
            <span class="h-1.5 w-6 rounded-[1px] bg-gs1-navy"></span>
          </span>
          <span :for={width <- ~w(w-full w-5 w-full)} class={["h-0.5 bg-slate-300", width]}></span>
        <% "letterhead" -> %>
          <span class="h-1 w-3 self-end rounded-[1px] bg-gs1-navy"></span>
          <span class="h-0.5 w-4 self-end bg-slate-300"></span>
          <span class="mt-1 h-0.5 w-5 bg-gs1-navy"></span>
          <span :for={width <- ~w(w-full w-full w-6)} class={["h-0.5 bg-slate-300", width]}></span>
          <span class="mt-1 h-0.5 w-4 bg-slate-300"></span>
      <% end %>
    </span>
    """
  end

  defp placeholder(name), do: Map.get(@placeholders, name)

  defp preview_stage_label(:converting), do: "Converting to PDF…"
  defp preview_stage_label(:building), do: "Building the file…"
  defp preview_stage_label(_queued), do: "Waiting to start…"

  defp visuals_stage_label(:searching), do: "Searching Unsplash for photos…"
  defp visuals_stage_label(:checking), do: "Checking the photos fit your slides…"
  defp visuals_stage_label(:downloading), do: "Adding the photos…"
  defp visuals_stage_label(_planning), do: "Choosing charts, icons and photos…"

  defp input_class,
    do:
      "w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 transition focus:border-gs1-navy focus:outline-none focus:ring-2 focus:ring-gs1-navy/20"

  @button "inline-flex items-center justify-center gap-2 rounded-md px-4 py-2.5 text-sm font-semibold transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gs1-navy disabled:cursor-not-allowed"

  # Orange is reserved for the download; everything else stays navy or quiet.
  defp orange_button,
    do: [
      @button,
      "bg-gs1-orange-strong text-white hover:bg-gs1-orange-hover disabled:bg-slate-200 disabled:text-slate-500"
    ]

  defp navy_button,
    do: [
      @button,
      "bg-gs1-navy text-white hover:bg-gs1-navy-hover disabled:bg-slate-200 disabled:text-slate-500"
    ]

  defp outline_button,
    do: [
      @button,
      "border border-gs1-navy text-gs1-navy hover:bg-gs1-navy/5 disabled:border-slate-300 disabled:text-slate-400"
    ]

  defp quiet_button,
    do:
      "inline-flex items-center gap-1.5 rounded-md py-2 text-sm font-medium text-slate-600 transition hover:text-gs1-navy"

  defp template_label("basic"), do: "GS1 Basic"
  defp template_label("advanced"), do: "GS1 Advanced"
  defp template_label("letterhead"), do: "GS1 Letterhead"
  defp template_label("presentation"), do: "GS1 Presentation"

  ## Events

  @impl true
  def handle_event("validate", %{"document" => params}, socket) do
    cover_mode =
      if Map.has_key?(params, "cover") and params["cover"] != socket.assigns.params["cover"],
        do: :manual,
        else: socket.assigns.cover_mode

    # The designer's plan belongs to the text it read, not to the details.
    ai_plan =
      if content_key(Map.merge(socket.assigns.params, params)) ==
           content_key(socket.assigns.params),
         do: socket.assigns.ai_plan,
         else: nil

    {:noreply,
     socket
     |> assign(ai_plan: ai_plan, cover_mode: cover_mode)
     |> merge_params(params)
     |> update_document()
     |> maybe_auto_analyze()}
  end

  # Upload-only changes (e.g. picking a file) carry no document params.
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # Steps past the first need something to style and download. Leaving the
  # content step is when the exact previews are made.
  def handle_event("step", %{"step" => step}, socket) when step in ~w(1 2 3 4) do
    step = String.to_integer(step)

    cond do
      step == 1 ->
        {:noreply, assign(socket, :step, 1)}

      not socket.assigns.content? ->
        {:noreply, socket}

      socket.assigns.step == 1 ->
        {:noreply, socket |> assign(:step, step) |> ensure_previews()}

      true ->
        {:noreply, assign(socket, :step, step)}
    end
  end

  # Details are typed freely; the exact preview catches up when asked.
  def handle_event("regenerate", _params, socket), do: {:noreply, ensure_previews(socket)}

  def handle_event("kind", %{"kind" => kind}, socket) when kind in ~w(document presentation) do
    {:noreply,
     socket
     |> assign(page_title: page_title(kind))
     |> merge_params(%{"kind" => kind})
     |> update_document()
     |> maybe_auto_analyze()}
  end

  def handle_event("load_sample", _params, socket) do
    {:noreply,
     socket
     |> assign(images: %{}, import_warnings: [], ai_plan: nil)
     |> merge_params(%{"source" => @sample, "format" => "markdown"})
     |> update_document()
     |> maybe_auto_analyze()}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :source, ref)}
  end

  # Downloads the native file: .docx for documents, .pptx for presentations.
  def handle_event("download", params, socket) do
    socket = merge_params(socket, Map.get(params, "document", %{})) |> update_document()
    doc = socket.assigns.doc
    {ext, content_type} = Docgen.native_format(doc)

    case Docgen.to_native(doc) do
      {:ok, data} ->
        record_history(doc, data, socket.assigns.params)

        {:noreply,
         push_download(socket, %{
           data: data,
           filename: Docgen.filename(doc, ext),
           content_type: content_type
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, ext))}
    end
  end

  def handle_event("download_pdf", _params, %{assigns: %{pdf_loading: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("download_pdf", _params, socket) do
    doc = socket.assigns.doc

    {:noreply,
     socket
     |> assign(:pdf_loading, true)
     |> clear_flash()
     |> start_async(:pdf, fn -> {Docgen.filename(doc, "pdf"), Docgen.to_pdf(doc)} end)}
  end

  @impl true
  def handle_async(:pdf, {:ok, {filename, {:ok, pdf}}}, socket) do
    {:noreply,
     socket
     |> assign(:pdf_loading, false)
     |> push_download(%{data: pdf, filename: filename, content_type: "application/pdf"})}
  end

  def handle_async(:pdf, {:ok, {_filename, {:error, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(:pdf_loading, false)
     |> put_flash(:error, error_message(reason, socket.assigns.native_ext))}
  end

  def handle_async(:pdf, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:pdf_loading, false)
     |> put_flash(:error, error_message(:conversion_failed, socket.assigns.native_ext))}
  end

  def handle_async(:ai_plan, {:ok, {:ok, plan}}, socket) do
    socket = socket |> assign(ai_loading: false, ai_plan: plan) |> refine_source()

    socket =
      if socket.assigns.params["template"] == "auto" and socket.assigns.cover_mode == :auto do
        merge_params(socket, %{"cover" => plan.cover_asset})
      else
        socket
      end

    {:noreply, socket |> update_document() |> auto_previews()}
  end

  def handle_async(:visuals, {:ok, visuals}, socket) do
    {:noreply,
     socket
     |> assign(visuals: visuals, visuals_loading: false, visuals_stage: nil)
     |> update_document()
     |> auto_previews()}
  end

  # Visuals are a nicety: without them the slides stay as they were.
  def handle_async(:visuals, _result, socket) do
    {:noreply, socket |> assign(visuals_loading: false, visuals_stage: nil) |> auto_previews()}
  end

  def handle_async({:preview, template}, {:ok, {key, result}}, socket) do
    %{previews: previews, preview_jobs: jobs} = socket.assigns

    # A result for a look that has since changed is dropped.
    if jobs[template] == key do
      previews =
        case result do
          {:ok, pdf} ->
            token =
              Store.put(%{data: pdf, filename: "preview.pdf", content_type: "application/pdf"})

            Map.put(previews, template, %{
              key: key,
              url: ~p"/documents/#{token}/download",
              expires_at: System.monotonic_time(:millisecond) + @preview_ttl
            })

          _error ->
            previews
        end

      {:noreply,
       socket
       |> assign(
         previews: previews,
         preview_jobs: Map.delete(jobs, template),
         preview_stages: Map.delete(socket.assigns.preview_stages, template)
       )
       |> sync_preview()}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:preview, _template}, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async({:preview, template}, _result, socket) do
    {:noreply,
     socket
     |> assign(:preview_jobs, Map.delete(socket.assigns.preview_jobs, template))
     |> sync_preview()}
  end

  def handle_async(:ai_plan, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:ai_plan, _result, socket) do
    {:noreply,
     socket
     |> assign(:ai_loading, false)
     |> auto_previews()
     |> put_flash(
       :error,
       "The document designer couldn't analyze this content. Please try again."
     )}
  end

  def handle_async(:import, {:ok, {name, {:ok, doc}}}, socket) do
    {markdown, images} = Docgen.to_markdown(doc)

    # An uploaded deck is re-laid as GS1 slides, whatever was being made.
    deck_params =
      if Docgen.format_for(name) == :pptx,
        do: %{"kind" => "presentation", "presenter" => doc.meta[:presenter] || ""},
        else: %{}

    socket =
      assign(
        socket,
        :page_title,
        page_title(deck_params["kind"] || socket.assigns.params["kind"])
      )

    {:noreply,
     socket
     |> assign(importing: nil, images: images, import_warnings: doc.warnings, ai_plan: nil)
     |> merge_params(
       Map.merge(deck_params, %{
         "source" => markdown,
         "format" => "markdown",
         "title" => doc.meta[:title] || "",
         "subtitle" => doc.meta[:subtitle] || ""
       })
     )
     |> update_document()
     |> maybe_auto_analyze()
     |> advance_to_format()
     |> auto_previews()
     |> put_flash(:info, "Imported #{name} — go back to Content to fix anything that looks off.")}
  end

  def handle_async(:import, {:ok, {_name, {:error, reason}}}, socket) do
    {:noreply, socket |> assign(:importing, nil) |> put_flash(:error, import_error(reason))}
  end

  def handle_async(:import, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:importing, nil) |> put_flash(:error, import_error(:crash))}
  end

  ## Progress

  @impl true
  def handle_info({:preview_stage, template, key, stage}, socket) do
    if socket.assigns.preview_jobs[template] == key do
      {:noreply,
       socket
       |> assign(:preview_stages, Map.put(socket.assigns.preview_stages, template, stage))
       |> sync_preview()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:visuals_stage, stage}, socket),
    do: {:noreply, assign(socket, :visuals_stage, stage)}

  ## Uploads

  defp handle_progress(:source, entry, socket) do
    if entry.done? do
      ext = entry.client_name |> Path.extname() |> String.downcase()
      name = entry.client_name

      content =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      cond do
        ext in @text_extensions ->
          {:noreply,
           socket
           |> assign(images: %{}, import_warnings: [], ai_plan: nil)
           |> merge_params(%{"source" => content, "format" => format_param(name)})
           |> update_document()
           |> maybe_auto_analyze()
           |> advance_to_format()
           |> auto_previews()
           |> put_flash(:info, "Loaded #{name}")}

        ext in @binary_extensions ->
          format = Docgen.format_for(name)

          {:noreply,
           socket
           |> assign(:importing, name)
           |> clear_flash()
           |> start_async(:import, fn -> {name, Docgen.ingest(content, format)} end)}
      end
    else
      {:noreply, socket}
    end
  end

  defp format_param(filename) do
    if Docgen.format_for(filename) == :markdown, do: "markdown", else: "text"
  end

  defp import_error(:invalid_docx), do: "That file doesn't look like a valid Word document."

  defp import_error(:invalid_pptx),
    do: "That file doesn't look like a valid PowerPoint presentation."

  defp import_error(:too_large), do: "That document is too large to import."

  defp import_error(:no_text),
    do: "This PDF has no selectable text — it may be a scanned image, which can't be imported."

  defp import_error(:unreadable_pdf),
    do: "The PDF couldn't be read. It may be damaged, password-protected or restrict copying."

  defp import_error(:pdftohtml_not_found),
    do: "PDF import isn't available: poppler (pdftohtml) is not installed on the server."

  defp import_error(:timeout), do: "Importing took too long. Try a smaller file."
  defp import_error(_), do: "The file couldn't be imported."

  defp upload_error_message(:too_large), do: "That file is larger than 20 MB."

  defp upload_error_message(:not_accepted),
    do: "Only .md, .txt, .docx, .pptx and .pdf files are accepted."

  defp upload_error_message(:too_many_files), do: "Upload one file at a time."
  defp upload_error_message(_), do: "The upload failed. Please try again."

  ## Document state

  # A file is a finished piece of content, so uploading one moves on.
  defp advance_to_format(socket) do
    if socket.assigns.content?, do: assign(socket, :step, 2), else: socket
  end

  # `/?from=ID` reopens a history entry for editing. Its images aren't kept,
  # so only the text, template and details come back.
  defp open_from_history(socket, %{"from" => id}) do
    case Docgen.History.fetch(id) do
      {:ok, entry} ->
        kind = if entry.template == "presentation", do: "presentation", else: "document"

        details =
          for {name, key, _label, _type} <- Map.fetch!(@meta_fields, entry.template),
              value = entry.meta[Atom.to_string(key)],
              into: %{},
              do: {name, to_string(value)}

        socket
        |> assign(step: 3, cover_mode: :manual, page_title: page_title(kind))
        |> merge_params(
          Map.merge(details, %{
            "kind" => kind,
            "template" => if(kind == "document", do: entry.template, else: "auto"),
            "source" => entry.source,
            "format" => entry.source_format
          })
        )

      :error ->
        put_flash(socket, :error, "That document couldn't be opened from the history.")
    end
  end

  defp open_from_history(socket, _params), do: socket

  defp merge_params(socket, params) do
    params = Map.take(params, Map.keys(@defaults))
    assign(socket, :params, Map.merge(socket.assigns.params, params))
  end

  defp update_document(socket) do
    params = socket.assigns.params

    template_param =
      cond do
        params["kind"] == "presentation" ->
          "presentation"

        params["template"] == "auto" and socket.assigns.ai_plan ->
          Atom.to_string(socket.assigns.ai_plan.template)

        params["template"] == "auto" ->
          "basic"

        params["template"] in ~w(basic advanced letterhead) ->
          params["template"]

        true ->
          "basic"
      end

    template = Map.fetch!(@template_atoms, template_param)
    doc = build_doc(socket, template_param)

    supported? = Docgen.supported_template?(template)

    warnings =
      Enum.uniq(socket.assigns.import_warnings ++ doc.warnings) ++
        if(supported?,
          do: [],
          else: ["Downloads for this template are coming soon — use GS1 Basic for now."]
        )

    socket
    |> assign(
      form: to_form(params, as: :document),
      effective_template: template_param,
      presentation?: template == :presentation,
      native_ext: doc |> Docgen.native_format() |> elem(0),
      meta_fields: Map.fetch!(@meta_fields, template_param),
      doc: doc,
      doc_key: :erlang.phash2(doc),
      preview: Docgen.to_html(doc),
      empty?: doc.blocks == [] and doc.meta[:title] in [nil, ""],
      content?: doc.blocks != [],
      warnings: warnings,
      downloadable?: supported? and doc.blocks != []
    )
    |> sync_preview()
  end

  # The document as `template_param` would lay it out, with that template's
  # own details.
  defp build_doc(socket, template_param) do
    params = socket.assigns.params
    template = Map.fetch!(@template_atoms, template_param)

    meta =
      Map.new(Map.fetch!(@meta_fields, template_param), fn {name, key, _label, _type} ->
        {key, params[name]}
      end)

    # Visuals chosen for this text go on the slides, unless switched off.
    meta =
      if template == :presentation and params["visuals"] == "true" and
           socket.assigns.visuals != %{} and socket.assigns.visuals_for == content_key(params),
         do: Map.put(meta, :visuals, socket.assigns.visuals),
         else: meta

    doc =
      Docgen.parse(
        params["source"] || "",
        if(params["format"] == "text", do: :text, else: :markdown),
        template: template,
        meta: meta,
        images: socket.assigns.images
      )

    # Paragraphs the designer read as list items take the template's bullets.
    case socket.assigns.ai_plan do
      %{list_items: [_ | _] = items} when template != :presentation ->
        Docgen.AI.Refiner.bullet_paragraphs(doc, items)

      _ ->
        doc
    end
  end

  # What the designer reads. Browsers send textareas with CRLF line ends.
  defp content_key(params),
    do: {String.replace(params["source"] || "", "\r\n", "\n"), params["format"]}

  # Presentations have a single template, so they skip the AI template
  # choice. The designer reads each piece of content once: changing the
  # format, template or details never sends it back.
  defp maybe_auto_analyze(socket) do
    cond do
      socket.assigns.empty? -> socket
      socket.assigns.presentation? -> socket |> refine_source() |> find_visuals_once()
      socket.assigns.params["template"] == "auto" -> socket |> refine_source() |> analyze_once()
      true -> refine_source(socket)
    end
  end

  # Visuals are chosen once per piece of content, the first time it is a
  # presentation.
  defp find_visuals_once(socket) do
    key = content_key(socket.assigns.params)

    if connected?(socket) and socket.assigns.visuals? and
         socket.assigns.params["visuals"] == "true" and key != socket.assigns.visuals_for do
      socket = assign(socket, visuals: %{}, visuals_for: key, visuals_loading: true)
      doc = build_doc(socket, "presentation")
      topic = socket.assigns.topic

      start_async(socket, :visuals, fn ->
        Docgen.AI.Visuals.find(doc, progress: &broadcast(topic, {:visuals_stage, &1}))
      end)
    else
      socket
    end
  end

  defp analyze_once(socket) do
    key = content_key(socket.assigns.params)

    if key == socket.assigns.analyzed,
      do: socket,
      else: socket |> assign(:analyzed, key) |> start_ai_analysis()
  end

  defp refine_source(%{assigns: %{params: %{"format" => "markdown"}}} = socket) do
    source = socket.assigns.params["source"] || ""
    refined = Docgen.AI.Refiner.refine_markdown(source)

    if String.trim(refined) == String.trim(source) do
      socket
    else
      socket
      |> merge_params(%{"source" => refined})
      |> update_document()
    end
  end

  defp refine_source(socket), do: socket

  defp start_ai_analysis(socket) do
    socket =
      if socket.assigns.ai_loading do
        cancel_async(socket, :ai_plan)
      else
        socket
      end

    doc = socket.assigns.doc

    socket
    |> assign(ai_loading: true, ai_plan: nil)
    |> clear_flash()
    |> start_async(:ai_plan, fn -> Docgen.AI.Planner.analyze(doc) end)
  end

  # Exact previews are made on their own once the content step is behind:
  # when leaving it, and when the designer's plan or the visuals arrive.
  # After that, edits wait for "Regenerate".
  defp auto_previews(socket) do
    if socket.assigns.step > 1, do: ensure_previews(socket), else: socket
  end

  # Queues an exact PDF for every look that doesn't have an up-to-date one,
  # the look on screen first.
  defp ensure_previews(socket) do
    if exact_previews?(socket) do
      current = socket.assigns.effective_template

      [current | @preview_templates -- [current]]
      |> Enum.reduce(socket, &ensure_preview(&2, &1))
      |> sync_preview()
    else
      socket
    end
  end

  defp exact_previews?(socket) do
    connected?(socket) and Application.get_env(:docgen, :exact_preview, true) and
      socket.assigns.content?
  end

  defp ensure_preview(socket, template) do
    doc = build_doc(socket, template)
    key = :erlang.phash2(doc)
    jobs = socket.assigns.preview_jobs

    cond do
      # Document looks wait for the designer, whose plan changes them.
      socket.assigns.ai_loading and template != "presentation" ->
        socket

      # ... and the slides wait for their visuals.
      socket.assigns.visuals_loading and template == "presentation" ->
        socket

      not Docgen.supported_template?(doc.template) ->
        socket

      jobs[template] == key or match?(%{key: ^key}, cached_preview(socket, template)) ->
        socket

      true ->
        socket =
          if Map.has_key?(jobs, template),
            do: cancel_async(socket, {:preview, template}),
            else: socket

        topic = socket.assigns.topic

        socket
        |> assign(
          preview_jobs: Map.put(jobs, template, key),
          preview_stages: Map.delete(socket.assigns.preview_stages, template)
        )
        |> start_async({:preview, template}, fn ->
          broadcast(topic, {:preview_stage, template, key, :building})

          with {:ok, _file} <- Docgen.to_native(doc) do
            broadcast(topic, {:preview_stage, template, key, :converting})
            {key, Docgen.to_pdf(doc)}
          else
            error -> {key, error}
          end
        end)
    end
  end

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(Docgen.PubSub, topic, message)

  # The last exact PDF made for `template`, whatever it was made from.
  defp cached_preview(socket, template) do
    case socket.assigns.previews do
      %{^template => %{expires_at: expires_at} = preview} ->
        if expires_at > System.monotonic_time(:millisecond), do: preview

      _ ->
        nil
    end
  end

  # Points the preview pane at the PDF for the look on screen. It stays up
  # while newer edits are waiting, marked stale.
  defp sync_preview(socket) do
    %{effective_template: template, doc_key: key, preview_jobs: jobs} = socket.assigns
    cached = cached_preview(socket, template)
    loading? = Map.has_key?(jobs, template)

    assign(socket,
      preview_url: cached && cached.url,
      preview_loading: loading?,
      preview_stale?:
        exact_previews?(socket) and not loading? and not match?(%{key: ^key}, cached),
      preview_stage: socket.assigns.preview_stages[template],
      preview_pending: map_size(jobs)
    )
  end

  defp record_history(doc, data, params) do
    if Application.get_env(:docgen, :history, true) do
      Task.start(fn ->
        Docgen.History.record_quietly(doc, data,
          source: params["source"],
          format: params["format"]
        )
      end)
    end
  end

  defp push_download(socket, file) do
    token = Store.put(file)
    push_event(socket, "download", %{url: ~p"/documents/#{token}/download"})
  end

  defp page_title("presentation"), do: "New presentation"
  defp page_title(_kind), do: "New document"

  defp error_message(:soffice_not_found, _ext),
    do: "PDF export isn't available: LibreOffice is not installed on the server."

  defp error_message(:timeout, ext),
    do: "PDF conversion timed out. Try again, or download the .#{ext}."

  defp error_message(:conversion_failed, ext),
    do: "PDF conversion failed. The .#{ext} download still works."

  defp error_message({:unsupported_template, _}, _ext),
    do: "This template isn't available for download yet."

  defp error_message(_reason, _ext), do: "Something went wrong generating the document."
end
