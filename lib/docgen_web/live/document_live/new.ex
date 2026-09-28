defmodule DocgenWeb.DocumentLive.New do
  use DocgenWeb, :live_view

  alias Docgen.Store

  @templates [
    {"Auto — AI recommended", "auto"},
    {"GS1 Basic", "basic"},
    {"GS1 Advanced", "advanced"},
    {"GS1 Letterhead", "letterhead"}
  ]

  @template_atoms %{"basic" => :basic, "advanced" => :advanced, "letterhead" => :letterhead}

  # {param, meta key, label, input type} shown for each template. The
  # "cover" select gets its options from the bundled industry icons.
  @meta_fields %{
    "basic" => [
      {"title", :title, "Title", "text"},
      {"subtitle", :subtitle, "Subtitle", "text"}
    ],
    "advanced" => [
      {"title", :title, "Document name", "text"},
      {"doc_type", :doc_type, "Document type", "text"},
      {"description", :description, "Description", "textarea"},
      {"status", :status, "Status", "text"},
      {"date", :date, "Date", "date"},
      {"cover", :cover, "Cover graphic", "select"}
    ],
    "letterhead" => [
      {"sender_name", :sender_name, "Sender's name", "text"},
      {"sender_title", :sender_title, "Sender's title", "text"},
      {"sender_address", :sender_address, "Sender's address", "textarea"},
      {"recipient", :recipient, "Recipient (name, then address)", "textarea"},
      {"date", :date, "Date", "date"},
      {"subject", :subject, "Subject", "text"},
      {"salutation", :salutation, "Salutation (Dear …)", "text"},
      {"closing", :closing, "Closing", "text"},
      {"hide_graphics", :hide_graphics, "Hide letterhead graphics (pre-printed paper)",
       "checkbox"}
    ]
  }

  @defaults %{
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
    "hide_graphics" => "false"
  }

  @text_extensions ~w(.txt .md .markdown)
  @binary_extensions ~w(.docx .pdf)
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
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "New document",
       templates: @templates,
       cover_options:
         [{"GS1 corporate visual", "corporate"}, {"No graphic", "none"}] ++
           Enum.map(Docgen.Template.cover_icons(), fn {slug, label} ->
             {"Icon: " <> label, slug}
           end),
       tab: "paste",
       pdf_loading: false,
       preview_loading: false,
       preview_url: nil,
       ai_loading: false,
       ai_plan: nil,
       cover_mode: :auto,
       importing: nil,
       images: %{},
       import_warnings: [],
       params: @defaults
     )
     |> allow_upload(:source,
       accept: ~w(.txt .md .docx .pdf),
       max_entries: 1,
       max_file_size: @max_file_size,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> update_document()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="document-workspace"
        phx-hook=".Download"
        class="grid gap-8 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]"
      >
        <section class="space-y-6">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight text-[#002C6C]">New document</h1>
            <p class="mt-1 text-sm text-slate-500">
              Paste or upload your content and download it in the official GS1 house style.
            </p>
          </div>

          <.form
            for={@form}
            id="document-form"
            phx-change="validate"
            phx-submit="download_docx"
            class="space-y-6"
          >
            <div class="rounded-2xl border border-slate-200 bg-white shadow-sm">
              <div class="flex border-b border-slate-200 px-2" role="tablist">
                <button
                  :for={
                    {tab, label, icon} <- [
                      {"paste", "Paste text", "hero-pencil-square"},
                      {"upload", "Upload file", "hero-arrow-up-tray"}
                    ]
                  }
                  type="button"
                  id={"tab-#{tab}"}
                  role="tab"
                  aria-selected={to_string(@tab == tab)}
                  phx-click="tab"
                  phx-value-tab={tab}
                  class={[
                    "-mb-px flex items-center gap-2 border-b-2 px-4 py-3 text-sm font-medium transition-colors",
                    if(@tab == tab,
                      do: "border-[#F26334] text-[#002C6C]",
                      else: "border-transparent text-slate-500 hover:text-slate-800"
                    )
                  ]}
                >
                  <.icon name={icon} class="size-4" /> {label}
                </button>
              </div>

              <div :if={@tab == "paste"} id="paste-panel" class="space-y-3 p-4">
                <div class="flex items-center justify-between gap-3">
                  <div class="w-44">
                    <.input
                      field={@form[:format]}
                      type="select"
                      options={[{"Markdown", "markdown"}, {"Plain text", "text"}]}
                      class="w-full rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm focus:border-[#002C6C] focus:outline-none focus:ring-2 focus:ring-[#002C6C]/20"
                    />
                  </div>
                  <button
                    type="button"
                    id="load-sample"
                    phx-click="load_sample"
                    class="text-sm font-medium text-[#008DBD] transition-colors hover:text-[#002C6C]"
                  >
                    Try a sample
                  </button>
                </div>
                <.input
                  field={@form[:source]}
                  type="textarea"
                  rows="18"
                  phx-debounce="300"
                  placeholder="# Title&#10;&#10;Write or paste your content here…"
                  class="block w-full resize-y rounded-xl border border-slate-300 bg-slate-50/60 p-4 font-mono text-sm leading-relaxed text-slate-800 transition focus:border-[#002C6C] focus:bg-white focus:outline-none focus:ring-2 focus:ring-[#002C6C]/20"
                />
              </div>

              <div :if={@tab == "upload"} id="upload-panel" class="space-y-3 p-4">
                <label
                  for={@uploads.source.ref}
                  phx-drop-target={@uploads.source.ref}
                  class="group flex cursor-pointer flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed border-slate-300 bg-slate-50/60 px-6 py-12 text-center transition hover:border-[#002C6C] hover:bg-[#002C6C]/5 phx-drop-target-active:border-[#F26334]"
                >
                  <span class="flex size-12 items-center justify-center rounded-full bg-white shadow-sm ring-1 ring-slate-200 transition group-hover:scale-105">
                    <.icon name="hero-document-arrow-up" class="size-6 text-[#002C6C]" />
                  </span>
                  <span class="text-sm font-medium text-slate-700">
                    Drop a file here or <span class="text-[#008DBD]">browse</span>
                  </span>
                  <span class="text-xs text-slate-500">
                    Markdown, text, Word (.docx) or PDF — up to 20 MB
                  </span>
                  <.live_file_input upload={@uploads.source} class="sr-only" />
                </label>

                <div
                  :for={entry <- @uploads.source.entries}
                  id={"upload-#{entry.ref}"}
                  class="flex items-center gap-3 rounded-lg border border-slate-200 px-3 py-2 text-sm"
                >
                  <.icon name="hero-document-text" class="size-5 text-slate-400" />
                  <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
                  <span class="w-10 text-right tabular-nums text-slate-500">{entry.progress}%</span>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    aria-label="Cancel upload"
                    class="text-slate-400 hover:text-slate-700"
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

                <div
                  :if={@importing}
                  id="import-progress"
                  class="flex items-center gap-2 rounded-lg bg-[#002C6C]/5 px-3 py-2 text-sm text-[#002C6C]"
                >
                  <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Importing {@importing}…
                </div>

                <p
                  :for={err <- upload_errors(@uploads.source)}
                  id="upload-error"
                  class="text-sm text-red-600"
                >
                  {upload_error_message(err)}
                </p>
              </div>
            </div>

            <div class="space-y-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <.input
                field={@form[:template]}
                type="select"
                label="Template"
                options={@templates}
                class="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-[#002C6C] focus:outline-none focus:ring-2 focus:ring-[#002C6C]/20"
              />

              <div id="metadata-fields" class="grid gap-x-4 sm:grid-cols-2">
                <div
                  :for={{name, _key, label, type} <- @meta_fields}
                  class={[type in ["textarea", "select", "checkbox"] && "sm:col-span-2"]}
                >
                  <.input
                    :if={type == "select"}
                    field={@form[name]}
                    type="select"
                    label={label}
                    options={@cover_options}
                    class="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-[#002C6C] focus:outline-none focus:ring-2 focus:ring-[#002C6C]/20"
                  />
                  <.input
                    :if={type == "checkbox"}
                    field={@form[name]}
                    type="checkbox"
                    label={label}
                    class="size-4 rounded border-slate-300 text-[#002C6C] focus:ring-[#002C6C]/20"
                  />
                  <.input
                    :if={type not in ["select", "checkbox"]}
                    field={@form[name]}
                    type={type}
                    label={label}
                    rows="2"
                    phx-debounce="300"
                    class="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-[#002C6C] focus:outline-none focus:ring-2 focus:ring-[#002C6C]/20"
                  />
                </div>
              </div>
            </div>

            <div
              :if={@warnings != []}
              id="warnings"
              class="flex gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-amber-500" />
              <ul class="space-y-1">
                <li :for={warning <- @warnings}>{warning}</li>
              </ul>
            </div>

            <div class="rounded-2xl border border-[#008DBD]/25 bg-[#008DBD]/5 p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="flex items-center gap-2 text-sm font-semibold text-[#002C6C]">
                    <.icon name="hero-sparkles" class="size-5 text-[#F26334]" /> AI document designer
                  </h2>
                  <p class="mt-1 text-sm text-slate-600">
                    Get a template recommendation and find data that would read better as a graph.
                  </p>
                </div>
                <button
                  type="button"
                  id="analyze-document"
                  phx-click="analyze_document"
                  disabled={@ai_loading or @empty?}
                  class="inline-flex shrink-0 items-center gap-2 rounded-lg bg-white px-3 py-2 text-sm font-semibold text-[#002C6C] shadow-sm ring-1 ring-[#002C6C]/15 transition hover:-translate-y-px hover:shadow disabled:cursor-not-allowed disabled:opacity-40"
                >
                  <.icon
                    name={if(@ai_loading, do: "hero-arrow-path", else: "hero-sparkles")}
                    class={["size-4", @ai_loading && "animate-spin"]}
                  />
                  {if(@ai_loading, do: "Analyzing…", else: "Analyze")}
                </button>
              </div>

              <div
                :if={@ai_plan}
                id="ai-plan"
                class="mt-4 space-y-3 border-t border-[#008DBD]/20 pt-4"
              >
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-wider text-slate-500">
                      Recommended template
                    </p>
                    <p class="font-semibold capitalize text-[#002C6C]">GS1 {@ai_plan.template}</p>
                  </div>
                  <button
                    :if={
                      Atom.to_string(@ai_plan.template) != @effective_template or
                        (@ai_plan.template == :advanced and
                           @ai_plan.cover_asset != @params["cover"])
                    }
                    type="button"
                    id="apply-ai-template"
                    phx-click="apply_ai_template"
                    class="rounded-lg bg-[#002C6C] px-3 py-2 text-xs font-semibold text-white transition hover:bg-[#003d94]"
                  >
                    Use this template
                  </button>
                </div>
                <p class="text-sm text-slate-700">{@ai_plan.template_reason}</p>
                <div class="rounded-xl bg-white p-3 ring-1 ring-slate-200">
                  <p class="text-xs font-semibold uppercase tracking-wider text-slate-500">
                    Official GS1 visual
                  </p>
                  <p class="mt-1 text-sm font-semibold text-slate-800">
                    {asset_label(@ai_plan.cover_asset)}
                  </p>
                  <img
                    :if={cover_icon_data(@ai_plan.cover_asset)}
                    src={cover_icon_data(@ai_plan.cover_asset)}
                    alt={"#{asset_label(@ai_plan.cover_asset)} GS1 visual"}
                    class="mt-3 size-20 rounded-lg object-contain"
                  />
                  <p class="mt-1 text-xs text-slate-600">{@ai_plan.asset_reason}</p>
                  <div class="mt-3 flex items-center gap-2">
                    <span
                      id="cover-selection-mode"
                      class="rounded-full bg-[#002C6C]/8 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-[#002C6C]"
                    >
                      {if(@cover_mode == :auto, do: "AI selected", else: "Manual override")}
                    </span>
                    <button
                      :if={@cover_mode == :manual}
                      type="button"
                      id="use-ai-cover"
                      phx-click="use_ai_cover"
                      class="text-xs font-semibold text-[#008DBD] hover:text-[#002C6C]"
                    >
                      Use AI visual
                    </button>
                  </div>
                </div>
                <p class="text-xs text-slate-500">{@ai_plan.summary}</p>

                <div :if={@ai_plan.charts != []} id="ai-chart-suggestions" class="space-y-2">
                  <div
                    :for={{chart, index} <- Enum.with_index(@ai_plan.charts)}
                    id={"ai-chart-#{index}"}
                    class="rounded-xl bg-white p-3 ring-1 ring-slate-200"
                  >
                    <p class="text-sm font-semibold text-slate-800">
                      {String.capitalize(Atom.to_string(chart.type))} graph — {chart.title}
                    </p>
                    <p class="mt-1 text-xs text-slate-600">{chart.reason}</p>
                    <p class="mt-2 line-clamp-2 border-l-2 border-[#F26334] pl-2 text-xs italic text-slate-500">
                      {chart.source_excerpt}
                    </p>
                  </div>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap gap-3">
              <button
                type="submit"
                id="download-docx"
                disabled={not @downloadable?}
                class="inline-flex items-center gap-2 rounded-lg bg-[#002C6C] px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-px hover:bg-[#003d94] hover:shadow disabled:translate-y-0 disabled:cursor-not-allowed disabled:opacity-40"
              >
                <.icon name="hero-document-arrow-down" class="size-5" /> Download .docx
              </button>
              <button
                type="button"
                id="download-pdf"
                phx-click="download_pdf"
                disabled={not @downloadable? or @pdf_loading}
                class="inline-flex items-center gap-2 rounded-lg border border-[#002C6C] bg-white px-4 py-2.5 text-sm font-semibold text-[#002C6C] shadow-sm transition hover:-translate-y-px hover:bg-[#002C6C]/5 hover:shadow disabled:translate-y-0 disabled:cursor-not-allowed disabled:opacity-40"
              >
                <%= if @pdf_loading do %>
                  <.icon name="hero-arrow-path" class="size-5 animate-spin" /> Converting…
                <% else %>
                  <.icon name="hero-document" class="size-5" /> Download PDF
                <% end %>
              </button>
            </div>
          </.form>
        </section>

        <section class="lg:sticky lg:top-6 lg:self-start">
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-slate-500">Preview</h2>
            <span class="text-xs text-slate-400">
              {if(@preview_url, do: "Exact generated PDF", else: "Preparing exact preview")}
            </span>
          </div>
          <div
            id="preview"
            class={[
              "max-h-[calc(100vh-9rem)] overflow-y-auto rounded-sm bg-white shadow-xl ring-1 ring-slate-200",
              if(@preview_url, do: "p-0", else: "px-10 py-12 sm:px-14")
            ]}
          >
            <%= cond do %>
              <% @preview_url -> %>
                <iframe
                  id="exact-pdf-preview"
                  title="Exact generated PDF preview"
                  src={@preview_url <> "?inline=true#toolbar=0&navpanes=0"}
                  class="h-[calc(100vh-12rem)] min-h-[720px] w-full border-0"
                />
              <% @preview_loading -> %>
                <div
                  id="preview-loading"
                  class="flex flex-col items-center py-24 text-center text-slate-500"
                >
                  <.icon name="hero-arrow-path" class="size-10 animate-spin text-[#002C6C]" />
                  <p class="mt-3 text-sm">Generating the exact PDF preview…</p>
                </div>
              <% @empty? -> %>
                <div
                  id="preview-empty"
                  class="flex flex-col items-center py-24 text-center text-slate-400"
                >
                  <.icon name="hero-document-text" class="size-12" />
                  <p class="mt-3 text-sm">Your formatted document will appear here.</p>
                </div>
              <% true -> %>
                {@preview}
            <% end %>
          </div>
        </section>
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

  ## Events

  @impl true
  def handle_event("validate", %{"document" => params}, socket) do
    cover_mode =
      if Map.has_key?(params, "cover") and params["cover"] != socket.assigns.params["cover"],
        do: :manual,
        else: socket.assigns.cover_mode

    {:noreply,
     socket
     |> assign(ai_plan: nil, cover_mode: cover_mode)
     |> merge_params(params)
     |> update_document()
     |> maybe_auto_analyze()}
  end

  # Upload-only changes (e.g. picking a file) carry no document params.
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(paste upload) do
    {:noreply, assign(socket, :tab, tab)}
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

  def handle_event("download_docx", params, socket) do
    socket = merge_params(socket, Map.get(params, "document", %{})) |> update_document()
    doc = socket.assigns.doc

    case Docgen.to_docx(doc) do
      {:ok, docx} ->
        record_history(doc, docx, socket.assigns.params)

        {:noreply,
         push_download(socket, %{
           data: docx,
           filename: Docgen.filename(doc, "docx"),
           content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
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

  def handle_event("analyze_document", _params, %{assigns: %{ai_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("analyze_document", _params, socket) do
    {:noreply, socket |> refine_source() |> start_ai_analysis()}
  end

  def handle_event("apply_ai_template", _params, %{assigns: %{ai_plan: plan}} = socket)
      when not is_nil(plan) do
    {:noreply,
     socket
     |> assign(:cover_mode, :auto)
     |> merge_params(%{
       "template" => Atom.to_string(plan.template),
       "cover" => plan.cover_asset
     })
     |> update_document()}
  end

  def handle_event("use_ai_cover", _params, %{assigns: %{ai_plan: plan}} = socket)
      when not is_nil(plan) do
    socket =
      socket
      |> assign(:cover_mode, :auto)
      |> merge_params(%{"cover" => plan.cover_asset})
      |> update_document()

    {:noreply, maybe_start_exact_preview(socket)}
  end

  @impl true
  def handle_async(:pdf, {:ok, {filename, {:ok, pdf}}}, socket) do
    {:noreply,
     socket
     |> assign(:pdf_loading, false)
     |> push_download(%{data: pdf, filename: filename, content_type: "application/pdf"})}
  end

  def handle_async(:pdf, {:ok, {_filename, {:error, reason}}}, socket) do
    {:noreply, socket |> assign(:pdf_loading, false) |> put_flash(:error, error_message(reason))}
  end

  def handle_async(:pdf, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(:pdf_loading, false) |> put_flash(:error, error_message(:conversion_failed))}
  end

  def handle_async(:ai_plan, {:ok, {:ok, plan}}, socket) do
    socket = socket |> assign(ai_loading: false, ai_plan: plan) |> refine_source()

    socket =
      if socket.assigns.params["template"] == "auto" and socket.assigns.cover_mode == :auto do
        merge_params(socket, %{"cover" => plan.cover_asset})
      else
        socket
      end

    socket = update_document(socket)

    {:noreply, maybe_start_exact_preview(socket)}
  end

  def handle_async(:preview_pdf, {:ok, {:ok, pdf}}, socket) do
    token =
      Store.put(%{
        data: pdf,
        filename: Docgen.filename(socket.assigns.doc, "pdf"),
        content_type: "application/pdf"
      })

    {:noreply,
     assign(socket, preview_loading: false, preview_url: ~p"/documents/#{token}/download")}
  end

  def handle_async(:preview_pdf, _result, socket),
    do: {:noreply, assign(socket, preview_loading: false, preview_url: nil)}

  def handle_async(:ai_plan, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:ai_plan, _result, socket) do
    {:noreply,
     socket
     |> assign(:ai_loading, false)
     |> put_flash(
       :error,
       "The document designer couldn't analyze this content. Please try again."
     )}
  end

  def handle_async(:import, {:ok, {name, {:ok, doc}}}, socket) do
    {markdown, images} = Docgen.to_markdown(doc)

    {:noreply,
     socket
     |> assign(importing: nil, images: images, import_warnings: doc.warnings, tab: "paste")
     |> merge_params(%{
       "source" => markdown,
       "format" => "markdown",
       "title" => doc.meta[:title] || "",
       "subtitle" => doc.meta[:subtitle] || ""
     })
     |> update_document()
     |> maybe_auto_analyze()
     |> put_flash(:info, "Imported #{name} — edit the Markdown to fix anything that looks off.")}
  end

  def handle_async(:import, {:ok, {_name, {:error, reason}}}, socket) do
    {:noreply, socket |> assign(:importing, nil) |> put_flash(:error, import_error(reason))}
  end

  def handle_async(:import, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:importing, nil) |> put_flash(:error, import_error(:crash))}
  end

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
           |> assign(images: %{}, import_warnings: [])
           |> merge_params(%{"source" => content, "format" => format_param(name)})
           |> update_document()
           |> maybe_auto_analyze()
           |> assign(:tab, "paste")
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
    do: "Only .md, .txt, .docx and .pdf files are accepted."

  defp upload_error_message(:too_many_files), do: "Upload one file at a time."
  defp upload_error_message(_), do: "The upload failed. Please try again."

  ## Document state

  defp merge_params(socket, params) do
    params = Map.take(params, Map.keys(@defaults))
    assign(socket, :params, Map.merge(socket.assigns.params, params))
  end

  defp update_document(socket) do
    params = socket.assigns.params

    template_param =
      cond do
        params["template"] == "auto" and socket.assigns.ai_plan ->
          Atom.to_string(socket.assigns.ai_plan.template)

        params["template"] == "auto" ->
          "basic"

        Map.has_key?(@template_atoms, params["template"]) ->
          params["template"]

        true ->
          "basic"
      end

    template = Map.fetch!(@template_atoms, template_param)
    fields = Map.fetch!(@meta_fields, template_param)
    meta = Map.new(fields, fn {name, key, _label, _type} -> {key, params[name]} end)
    format = if params["format"] == "text", do: :text, else: :markdown

    doc =
      Docgen.parse(params["source"] || "", format,
        template: template,
        meta: meta,
        images: socket.assigns.images
      )

    supported? = Docgen.supported_template?(template)

    warnings =
      Enum.uniq(socket.assigns.import_warnings ++ doc.warnings) ++
        if(supported?,
          do: [],
          else: ["Downloads for this template are coming soon — use GS1 Basic for now."]
        )

    assign(socket,
      form: to_form(params, as: :document),
      preview_url: nil,
      effective_template: template_param,
      meta_fields: fields,
      doc: doc,
      preview: Docgen.to_html(doc),
      empty?: doc.blocks == [] and doc.meta[:title] in [nil, ""],
      warnings: warnings,
      downloadable?: supported? and doc.blocks != []
    )
  end

  defp maybe_auto_analyze(socket) do
    if not socket.assigns.empty? do
      socket = refine_source(socket)

      if socket.assigns.params["template"] == "auto" do
        start_ai_analysis(socket)
      else
        socket
      end
    else
      socket
    end
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

  defp maybe_start_exact_preview(socket) do
    if Application.get_env(:docgen, :exact_preview, true) and socket.assigns.downloadable? do
      doc = socket.assigns.doc

      socket
      |> assign(preview_loading: true, preview_url: nil)
      |> start_async(:preview_pdf, fn -> Docgen.to_pdf(doc) end)
    else
      socket
    end
  end

  defp record_history(doc, docx, params) do
    if Application.get_env(:docgen, :history, true) do
      Task.start(fn ->
        Docgen.History.record_quietly(doc, docx,
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

  defp error_message(:soffice_not_found),
    do: "PDF export isn't available: LibreOffice is not installed on the server."

  defp error_message(:timeout), do: "PDF conversion timed out. Try again, or download the .docx."

  defp error_message(:conversion_failed),
    do: "PDF conversion failed. The .docx download still works."

  defp error_message({:unsupported_template, _}),
    do: "This template isn't available for download yet."

  defp error_message(_), do: "Something went wrong generating the document."

  defp asset_label("corporate"), do: "GS1 corporate visual"
  defp asset_label("none"), do: "No cover visual"

  defp asset_label(slug) do
    Docgen.Template.cover_icons()
    |> Enum.find_value(slug, fn {known, label} -> if known == slug, do: label end)
  end

  defp cover_icon_data(slug) do
    case Docgen.Template.cover_icon(slug) do
      {:ok, png} -> "data:image/png;base64," <> Base.encode64(png)
      :error -> nil
    end
  end
end
