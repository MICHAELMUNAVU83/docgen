defmodule DocgenWeb.HistoryLive.Index do
  use DocgenWeb, :live_view

  require Logger

  alias Docgen.History

  @impl true
  def mount(_params, _session, socket) do
    {entries, error?} =
      try do
        {History.list(), false}
      rescue
        error ->
          Logger.warning("Could not load document history: #{Exception.message(error)}")
          {[], true}
      end

    {:ok,
     socket
     |> assign(page_title: "History", empty?: entries == [], error?: error?)
     |> stream(:entries, entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-4xl space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight text-[#002C6C]">History</h1>
          <p class="mt-1 text-sm text-slate-500">Documents generated with Docgen, newest first.</p>
        </div>

        <div
          :if={@error?}
          id="history-error"
          class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
        >
          History is unavailable right now — the database can't be reached.
        </div>

        <div class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <p
            :if={@empty? and not @error?}
            id="history-empty"
            class="p-8 text-center text-sm text-slate-500"
          >
            Nothing yet — documents appear here after you download them.
          </p>
          <ul id="history" phx-update="stream" class="divide-y divide-slate-100">
            <li
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              class="flex flex-wrap items-center gap-4 px-5 py-4 transition hover:bg-slate-50"
            >
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium text-slate-800">{entry.title}</p>
                <p class="text-xs text-slate-500">
                  GS1 {String.capitalize(entry.template)} · {Calendar.strftime(
                    entry.inserted_at,
                    "%d %b %Y, %H:%M"
                  )} UTC
                </p>
              </div>
              <a
                href={~p"/history/#{entry.id}/download?format=docx"}
                class="rounded-lg border border-slate-300 px-3 py-1.5 text-sm font-medium text-[#002C6C] transition hover:bg-[#002C6C]/5"
              >
                .docx
              </a>
              <a
                href={~p"/history/#{entry.id}/download?format=pdf"}
                class="rounded-lg border border-slate-300 px-3 py-1.5 text-sm font-medium text-[#002C6C] transition hover:bg-[#002C6C]/5"
              >
                PDF
              </a>
              <button
                id={"delete-#{entry.id}"}
                phx-click="delete"
                phx-value-id={entry.id}
                data-confirm="Delete this document from the history?"
                aria-label="Delete"
                class="text-slate-400 transition hover:text-red-600"
              >
                <.icon name="hero-trash" class="size-5" />
              </button>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    entry = History.get!(id)
    {:ok, _} = History.delete(entry)
    {:noreply, stream_delete(socket, :entries, entry)}
  end
end
